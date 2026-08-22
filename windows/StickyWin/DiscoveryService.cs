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

    private readonly Dictionary<string, StickyDevice> _peers = [];
    private readonly UdpClient? _listener;
    private readonly Timer _announceTimer;
    private readonly Timer _expiryTimer;
    private readonly CancellationTokenSource _stop = new();
    private StickyDevice _self;
    private Task? _receiveTask;

    public event Action<StickyDevice>? PeerFound;
    public event Action? PeersChanged;
    public event Action<string>? Failed;

    public DiscoveryService(string deviceId, string machineName)
    {
        _self = new StickyDevice(deviceId, machineName, "win", LocalIPv4().ToString(), DiscoveryPort, DateTimeOffset.UtcNow);
        try
        {
            _listener = new UdpClient(DiscoveryPort) { EnableBroadcast = true };
            _listener.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _receiveTask = ReceiveAsync(_stop.Token);
        }
        catch (SocketException ex)
        {
            Failed?.Invoke($"Discovery listener unavailable: {ex.Message}");
        }

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
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
        {
            Failed?.Invoke($"Announcement failed: {ex.Message}");
        }
    }

    private async Task ReceiveAsync(CancellationToken stopping)
    {
        while (!stopping.IsCancellationRequested && _listener != null)
        {
            try
            {
                UdpReceiveResult result = await _listener.ReceiveAsync(stopping);
                Announcement? announcement = JsonSerializer.Deserialize<Announcement>(result.Buffer);
                if (announcement?.Id is not { Length: > 0 } || announcement.Id == _self.Id)
                    continue;

                StickyDevice peer = new(
                    announcement.Id,
                    string.IsNullOrWhiteSpace(announcement.Name) ? "Unknown device" : announcement.Name,
                    announcement.Platform ?? "unknown",
                    result.RemoteEndPoint.Address.ToString(),
                    announcement.Port ?? DiscoveryPort,
                    DateTimeOffset.UtcNow);
                bool added;
                lock (_peers)
                {
                    added = !_peers.TryGetValue(peer.Id, out _);
                    _peers[peer.Id] = peer;
                }
                if (added) PeerFound?.Invoke(peer);
                PeersChanged?.Invoke();
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex) when (ex is SocketException or JsonException or ObjectDisposedException)
            {
                if (ex is not ObjectDisposedException) Failed?.Invoke($"Discovery receive failed: {ex.Message}");
            }
        }
    }

    private void RemoveExpired()
    {
        lock (_peers)
        {
            List<string> expired = [.. _peers.Where(pair => DateTimeOffset.UtcNow - pair.Value.LastSeen > PeerLifetime).Select(pair => pair.Key)];
            foreach (string id in expired) _peers.Remove(id);
            if (expired.Count > 0) PeersChanged?.Invoke();
        }
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs e) => _ = AnnounceAsync();
    private void OnWake() => _ = AnnounceAsync();

    private void RefreshSelfAddress()
    {
        IPAddress address = LocalIPv4();
        if (address.ToString().Equals(_self.Host, StringComparison.OrdinalIgnoreCase)) return;
        _self = _self with { Host = address.ToString(), LastSeen = DateTimeOffset.UtcNow };
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
        _announceTimer.Dispose();
        _expiryTimer.Dispose();
        _stop.Cancel();
        _listener?.Dispose();
        try { _receiveTask?.Wait(TimeSpan.FromSeconds(1)); } catch (AggregateException) { }
        _stop.Dispose();
    }

    private sealed record Announcement(string? Id, string? Name, string? Platform, int? Port);
}
