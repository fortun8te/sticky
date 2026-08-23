using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;

namespace StickyWin;

public record StickyDevice(
    string Id,
    string Name,
    string Platform,
    string Host,
    int Port,
    DateTimeOffset LastSeen = default)
{
    public StickyDevice MarkSeen() => this with { LastSeen = DateTimeOffset.UtcNow };
}

public sealed class DiscoveryService : IDisposable
{
    public const int DiscoveryPort = 53317;
    private static readonly TimeSpan PeerLifetime = TimeSpan.FromSeconds(30);
    /// <summary>Delay before retrying a listener bind that failed (port still held, stack reset).</summary>
    private static readonly TimeSpan RebindDelay = TimeSpan.FromSeconds(5);

    private readonly Dictionary<string, StickyDevice> _peers = [];
    /// <summary>Last address refused per device id, so one hostile announcer cannot flood <see cref="Failed"/>.</summary>
    private readonly Dictionary<string, string> _reportedConflicts = [];
    private readonly object _listenerSync = new();
    private readonly PairingService? _pairing;
    private readonly Timer _announceTimer;
    private readonly Timer _expiryTimer;
    private readonly Timer _rebindTimer;
    private readonly CancellationTokenSource _stop = new();
    private UdpClient? _listener;
    private StickyDevice _self;
    private Task? _receiveTask;
    private bool _disposed;

    public event Action<StickyDevice>? PeerFound;
    public event Action? PeersChanged;
    public event Action<string>? Failed;

    /// <param name="pairing">
    /// Optional, and only used to tell a paired device from a stranger: without it an
    /// unverified address change for a paired peer cannot be recognised and is accepted.
    /// Pass the same instance the transfer service uses so pairings made at runtime count.
    /// </param>
    public DiscoveryService(string deviceId, string machineName, PairingService? pairing = null)
    {
        _pairing = pairing;
        _self = new StickyDevice(deviceId, machineName, "win", LocalIPv4().ToString(), DiscoveryPort, DateTimeOffset.UtcNow);

        // A bind failure used to leave discovery dead for the whole session: the PC kept
        // announcing but never received, so the peer list stayed empty until a restart.
        // The timer re-arms the bind instead. Created before the first bind attempt
        // because a failed attempt schedules itself on it.
        _rebindTimer = new Timer(_ => BindListener(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        BindListener();

        _announceTimer = new Timer(async _ => await AnnounceAsync(), null, 500, 10_000);
        _expiryTimer = new Timer(_ => RemoveExpired(), null, 5_000, 5_000);
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
        SystemEventsPower.Wake += OnWake;
    }

    public StickyDevice Self => _self;

    public IReadOnlyList<StickyDevice> Peers
    {
        get
        {
            lock (_peers)
                return [.. _peers.Values.OrderByDescending(peer => peer.LastSeen)];
        }
    }

    public StickyDevice? GetBestPeer()
    {
        lock (_peers)
            return _peers.Values.Where(peer => peer.Platform != "win")
                .OrderByDescending(peer => peer.LastSeen).FirstOrDefault();
    }

    public async Task AnnounceAsync()
    {
        try
        {
            RefreshSelfAddress();
            using UdpClient udp = new() { EnableBroadcast = true };
            byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new
            {
                id = _self.Id,
                name = _self.Name,
                platform = _self.Platform,
                ver = "1.0",
                port = _self.Port
            });
            foreach (IPAddress address in BroadcastAddresses())
                await udp.SendAsync(payload, payload.Length, new IPEndPoint(address, DiscoveryPort));
        }
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException or NetworkInformationException)
        {
            // The timer callback is `async void`, so anything escaping here would take the
            // process down. Enumerating adapters during a network change can throw too.
            Failed?.Invoke($"Announcement failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Binds the discovery socket. Safe to call at any time and from any thread: it is a
    /// no-op while a listener is already bound, and a failure schedules its own retry.
    /// </summary>
    private void BindListener()
    {
        // The failure message is raised AFTER the lock is released. A subscriber
        // that reacts by calling Dispose() would otherwise deadlock, because
        // Dispose takes this same lock — every other event in this file is
        // already raised outside its lock for exactly this reason.
        string? failure = null;
        lock (_listenerSync)
        {
            if (_disposed || _stop.IsCancellationRequested || _listener != null) return;
            try
            {
                UdpClient listener = new(DiscoveryPort) { EnableBroadcast = true };
                listener.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                _listener = listener;
                _receiveTask = ReceiveAsync(listener, _stop.Token);
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
            {
                // Relaunching while the previous process still owns the port used to kill
                // discovery for the whole session. Retry instead.
                failure = $"Discovery listener unavailable: {ex.Message}. Retrying in {RebindDelay.TotalSeconds:0}s.";
                ScheduleRebind();
            }
        }

        if (failure != null) Failed?.Invoke(failure);
    }

    private void ScheduleRebind()
    {
        lock (_listenerSync)
        {
            if (_disposed) return;
            try
            {
                _rebindTimer.Change(RebindDelay, Timeout.InfiniteTimeSpan);
            }
            catch (ObjectDisposedException)
            {
                // Raced a Dispose; there is nothing left to rebind for.
            }
        }
    }

    /// <summary>
    /// Drops <paramref name="listener"/> only if it is still the live one, so a late failure
    /// from an already-replaced socket cannot tear down its successor.
    /// </summary>
    private void DropListener(UdpClient listener)
    {
        lock (_listenerSync)
        {
            if (!ReferenceEquals(_listener, listener)) return;
            _listener = null;
        }
        listener.Dispose();
    }

    private async Task ReceiveAsync(UdpClient listener, CancellationToken stopping)
    {
        while (!stopping.IsCancellationRequested)
        {
            try
            {
                UdpReceiveResult result = await listener.ReceiveAsync(stopping);
                HandleAnnouncement(result);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (SocketException ex) when (ex.SocketErrorCode is SocketError.ConnectionReset or SocketError.MessageSize)
            {
                // An ICMP port-unreachable answering one of our own broadcasts surfaces
                // here on Windows. The socket is still usable, so keep reading.
            }
            catch (Exception ex)
            {
                // Interface torn down, stack reset, port stolen on wake: this socket is
                // finished. Rebind instead of spinning on a dead handle. Deliberately
                // broad — an exception escaping this loop would leave the socket bound
                // with nothing reading it, which is the dead-discovery failure the
                // rebind path exists to prevent.
                Failed?.Invoke($"Discovery receive failed: {ex.Message}");
                DropListener(listener);
                ScheduleRebind();
                break;
            }
        }
    }

    private void HandleAnnouncement(UdpReceiveResult result)
    {
        Announcement? announcement;
        try
        {
            announcement = JsonSerializer.Deserialize<Announcement>(result.Buffer);
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException or ArgumentException)
        {
            // Other traffic on the discovery port. Dropping the packet has to stay
            // cheaper than dropping the socket, or anyone could keep discovery rebinding
            // by spraying garbage at it.
            return;
        }

        if (announcement?.Id is not { Length: > 0 }) return;

        StickyDevice peer = new(
            announcement.Id,
            string.IsNullOrWhiteSpace(announcement.Name) ? "Unknown device" : announcement.Name,
            announcement.Platform ?? "unknown",
            // The UDP source is the only trustworthy address. An announcement could
            // otherwise advertise a trusted id with a chosen host.
            result.RemoteEndPoint.Address.ToString(),
            announcement.Port ?? DiscoveryPort,
            DateTimeOffset.UtcNow);

        if (IsSelf(peer, result.RemoteEndPoint.Address)) return;
        if (IsSpoofedUpdate(peer)) return;

        bool added;
        lock (_peers)
        {
            added = !_peers.ContainsKey(peer.Id);
            _peers[peer.Id] = peer;
        }
        if (added) PeerFound?.Invoke(peer);
        PeersChanged?.Invoke();
    }

    /// <summary>
    /// Is this announcement really us coming back around?
    /// </summary>
    /// <remarks>
    /// The device id alone is not enough. An earlier install, a development build, or a
    /// second copy keeps its own id, so it announces as a stranger — and the app then
    /// believes a device is nearby, sends to itself, and every transfer fails with an
    /// opaque retry. An announcement whose source address is one of our own is us,
    /// whatever id it claims.
    /// </remarks>
    private bool IsSelf(StickyDevice peer, IPAddress source)
    {
        StickyDevice self = _self;
        if (string.Equals(peer.Id, self.Id, StringComparison.OrdinalIgnoreCase)) return true;
        if (IPAddress.IsLoopback(source)) return true;
        if (LocalAddresses().Contains(NormalizeAddress(source))) return true;

        // Backstop for a stale identity reaching us over an interface we do not
        // enumerate. Same machine name and same platform is us. The cost if two
        // genuinely different PCs share a name is that they cannot pair with each other;
        // the cost of getting it wrong the other way is every transfer failing silently.
        return string.Equals(peer.Platform, self.Platform, StringComparison.OrdinalIgnoreCase) &&
               string.Equals(peer.Name, self.Name, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Announcements are unauthenticated: any LAN host can claim a paired peer's id and move
    /// its address, which makes every pinned-TLS send fail with an opaque error. A live paired
    /// record therefore keeps its address; if the real peer genuinely changed IP its old record
    /// simply stops being refreshed and expires, after which the new address is accepted.
    /// </summary>
    private bool IsSpoofedUpdate(StickyDevice incoming)
    {
        if (_pairing?.IsPeerPaired(incoming.Id) != true) return false;

        string peerName;
        bool report;
        lock (_peers)
        {
            if (!_peers.TryGetValue(incoming.Id, out StickyDevice? existing) || existing is null) return false;
            if (string.IsNullOrEmpty(existing.Host)) return false;
            if (string.Equals(existing.Host, incoming.Host, StringComparison.OrdinalIgnoreCase)) return false;
            if (DateTimeOffset.UtcNow - existing.LastSeen > PeerLifetime) return false;

            peerName = existing.Name;
            report = !_reportedConflicts.TryGetValue(incoming.Id, out string? reported) ||
                     !string.Equals(reported, incoming.Host, StringComparison.OrdinalIgnoreCase);
            _reportedConflicts[incoming.Id] = incoming.Host;
        }

        if (report) Failed?.Invoke($"Ignored an unverified address change for paired device {peerName}.");
        return true;
    }

    private void RemoveExpired()
    {
        List<string> expired;
        lock (_peers)
        {
            expired = [.. _peers.Where(pair => DateTimeOffset.UtcNow - pair.Value.LastSeen > PeerLifetime).Select(pair => pair.Key)];
            foreach (string id in expired)
            {
                _peers.Remove(id);
                // Forget the conflict report too, so a later genuine address change is
                // surfaced instead of being silently suppressed.
                _reportedConflicts.Remove(id);
            }
        }
        // Raised outside the lock: a handler that reads Peers from another thread would
        // otherwise be blocked by the very callback it is answering.
        if (expired.Count > 0) PeersChanged?.Invoke();
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs e) => RefreshAfterNetworkChange();
    private void OnWake() => RefreshAfterNetworkChange();

    private void RefreshAfterNetworkChange()
    {
        // A path change is the best moment to recover a socket that never bound (or that
        // died): the interface that blocked it may now be gone.
        BindListener();
        _ = AnnounceAsync();
    }

    private void RefreshSelfAddress()
    {
        // `_self` is a record, so a reader on another thread always sees a whole device
        // and never a half-written one. Read it once anyway, so the comparison and the
        // rewrite cannot straddle a concurrent update.
        StickyDevice current = _self;
        string address = LocalIPv4().ToString();
        if (address.Equals(current.Host, StringComparison.OrdinalIgnoreCase)) return;
        _self = current with { Host = address, LastSeen = DateTimeOffset.UtcNow };
    }

    private static IEnumerable<IPAddress> BroadcastAddresses()
    {
        yield return IPAddress.Broadcast;
        foreach (NetworkInterface network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up ||
                network.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                continue;
            foreach (UnicastIPAddressInformation info in network.GetIPProperties().UnicastAddresses)
                if (info.Address.AddressFamily == AddressFamily.InterNetwork && info.IPv4Mask != null)
                    yield return GetBroadcastAddress(info.Address, info.IPv4Mask);
        }
    }

    /// <summary>
    /// Every address this machine currently holds — Wi-Fi, Ethernet, and the virtual
    /// interfaces VMs and containers add — v4 and v6, scope suffix stripped.
    /// </summary>
    private static HashSet<string> LocalAddresses()
    {
        HashSet<string> addresses = new(StringComparer.OrdinalIgnoreCase);
        NetworkInterface[] networks;
        try
        {
            networks = NetworkInterface.GetAllNetworkInterfaces();
        }
        catch (NetworkInformationException)
        {
            return addresses;
        }

        foreach (NetworkInterface network in networks)
        {
            if (network.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            IPInterfaceProperties properties;
            try
            {
                properties = network.GetIPProperties();
            }
            catch (NetworkInformationException)
            {
                // A tunnel or virtual adapter that is going away. Skip it.
                continue;
            }
            foreach (UnicastIPAddressInformation info in properties.UnicastAddresses)
                addresses.Add(NormalizeAddress(info.Address));
        }
        return addresses;
    }

    /// <summary>Address text without the `%scope` suffix a link-local IPv6 address carries.</summary>
    private static string NormalizeAddress(IPAddress address)
    {
        string text = address.ToString();
        int scope = text.IndexOf('%');
        return scope >= 0 ? text[..scope] : text;
    }

    private static IPAddress GetBroadcastAddress(IPAddress address, IPAddress mask)
    {
        byte[] addressBytes = address.GetAddressBytes();
        byte[] maskBytes = mask.GetAddressBytes();
        for (int index = 0; index < addressBytes.Length; index++)
            addressBytes[index] |= (byte)~maskBytes[index];
        return new IPAddress(addressBytes);
    }

    private static IPAddress LocalIPv4()
    {
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up &&
                              network.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(network => network.GetIPProperties().UnicastAddresses)
            .FirstOrDefault(info => info.Address.AddressFamily == AddressFamily.InterNetwork)?.Address
            ?? IPAddress.Loopback;
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        SystemEventsPower.Wake -= OnWake;

        UdpClient? listener;
        Task? receiveTask;
        lock (_listenerSync)
        {
            _disposed = true;
            listener = _listener;
            _listener = null;
            receiveTask = _receiveTask;
        }

        _rebindTimer.Dispose();
        _announceTimer.Dispose();
        _expiryTimer.Dispose();
        _stop.Cancel();
        listener?.Dispose();
        try { receiveTask?.Wait(TimeSpan.FromSeconds(1)); } catch (AggregateException) { }
        _stop.Dispose();
    }

    private sealed record Announcement(string? Id, string? Name, string? Platform, int? Port);
}
