using System.IO;
using System.Net.NetworkInformation;
using System.IO.Compression;
using System.Security;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;

namespace StickyWin;

public sealed class TransferService : IDisposable
{
    private const int Port = DiscoveryService.DiscoveryPort;
    private const int ChunkSize = 64 * 1024;
    private const int MaximumIncomingSessions = 3;
    private const int MaximumIncomingFiles = 100;
    private const long MaximumIncomingBytes = 2L * 1024 * 1024 * 1024;
    private const long MaximumControlBodyBytes = 1024 * 1024;

    private readonly DiscoveryService _discovery;
    private readonly PairingService _pairing;
    private readonly Dictionary<string, IncomingSession> _sessions = [];
    private readonly CancellationTokenSource _stop = new();
    private TcpListener? _listener;
    private Task? _acceptTask;
    private readonly Timer _cleanupTimer;
    private readonly object _pairingCodeSync = new();
    private string _currentPin;
    private DateTimeOffset _pinExpiresAt = DateTimeOffset.UtcNow.AddMinutes(5);
    private int _pinAttempts;

    public event Action<TransferProgress>? Sending;
    public event Action<TransferProgress>? Receiving;
    public event Action<string, int, TransferKind>? IncomingOffer;
    public event Action<int>? IncomingCompleted;
    public event Action<string, string>? ClipboardReceived;
    public event Action<string>? Failed;

    public event Action<string, NotchState>? StateChanged;

    public TransferService(DiscoveryService discovery, PairingService pairing)
    {
        _discovery = discovery;
        _pairing = pairing;
        _currentPin = pairing.GeneratePin();
        _cleanupTimer = new Timer(_ => CleanupExpiredSessions(), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));
        NetworkChange.NetworkAddressChanged += HandleNetworkChanged;
        SystemEventsPower.Wake += HandleWake;
    }

    public string CurrentPin
    {
        get
        {
            lock (_pairingCodeSync)
            {
                if (DateTimeOffset.UtcNow >= _pinExpiresAt) RotatePinLocked();
                return _currentPin;
            }
        }
    }

    private void RotatePin()
    {
        lock (_pairingCodeSync) RotatePinLocked();
    }

    private void RotatePinLocked()
    {
        _currentPin = _pairing.GeneratePin();
        _pinExpiresAt = DateTimeOffset.UtcNow.AddMinutes(5);
        _pinAttempts = 0;
    }

    private bool ConsumePairingCode(string supplied)
    {
        lock (_pairingCodeSync)
        {
            if (DateTimeOffset.UtcNow >= _pinExpiresAt) RotatePinLocked();
            if (!ConstantTimeEquals(supplied, _currentPin))
            {
                _pinAttempts++;
                if (_pinAttempts >= 5) RotatePinLocked();
                return false;
            }
            RotatePinLocked();
            return true;
        }
    }

    public void UnpairAll()
    {
        _pairing.UnpairAll();
        RotatePin();
    }

    private void HandleNetworkChanged(object? sender, EventArgs e)
    {
        CleanupStaleConnections();
    }

    private void HandleWake() => CleanupStaleConnections();

    private void CleanupStaleConnections() => CleanupExpiredSessions();

    private void PublishState(NotchState state) => StateChanged?.Invoke(GetType().Name, state);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public void Start()
    {
        if (_listener != null) return;
        X509Certificate2 certificate = _pairing.GetOrCreateCertificate();
        _listener = new TcpListener(IPAddress.Any, Port);
        _listener.Start();
        _acceptTask = AcceptLoopAsync(certificate, _stop.Token);
    }

    private async Task AcceptLoopAsync(X509Certificate2 certificate, CancellationToken stopping)
    {
        while (!stopping.IsCancellationRequested && _listener != null)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(stopping);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (SocketException ex)
            {
                PublishFailure($"Transfer listener failed: {ex.Message}");
                continue;
            }
            _ = HandleClientAsync(client, certificate, stopping);
        }
    }

    private async Task HandleClientAsync(TcpClient client, X509Certificate2 certificate, CancellationToken stopping)
    {
        using TcpClient connection = client;
        connection.NoDelay = true;
        await using NetworkStream raw = connection.GetStream();
        await using SslStream secure = new(raw, false);
        try
        {
            using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(stopping);
            timeout.CancelAfter(TimeSpan.FromSeconds(10));
            await secure.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = certificate,
                ClientCertificateRequired = true,
                EnabledSslProtocols = SslProtocols.Tls13,
                RemoteCertificateValidationCallback = (_, _, _, _) => true
            }, timeout.Token);
            X509Certificate2 remote = new(secure.RemoteCertificate ?? throw new AuthenticationException("Client certificate required."));
            string peerFingerprint = _pairing.Fingerprint(remote);
            timeout.CancelAfter(TimeSpan.FromMinutes(10));
            await ServeAsync(secure, peerFingerprint, timeout.Token);
        }
        catch (Exception ex) when (ex is IOException or SocketException or AuthenticationException or OperationCanceledException)
        {
            if (ex is not OperationCanceledException) PublishFailure($"Transfer connection failed: {ex.Message}");
        }
    }

    private async Task ServeAsync(SslStream stream, string peerFingerprint, CancellationToken stopping)
    {
        (byte[] HeaderBytes, byte[] InitialBody) header = await ReadHeadersAsync(stream, stopping);
        HttpRequest request = ParseRequest(Encoding.UTF8.GetString(header.HeaderBytes));
        switch ((request.Method, request.Path))
        {
            case ("GET", "/api/v1/info"):
                StickyDevice self = _discovery.Self;
                await WriteJsonAsync(stream, 200, JsonSerializer.Serialize(new { id = self.Id, name = self.Name, platform = "win", ver = "1.0" }), stopping);
                break;
            case ("POST", "/api/v1/pair"):
                await HandlePairAsync(stream, await ReadBodyAsync(stream, header.InitialBody, request.ContentLength, stopping, MaximumControlBodyBytes), peerFingerprint, stopping);
                break;
            case ("POST", "/api/v1/prepare-upload"):
                await HandlePrepareAsync(stream, request, await ReadBodyAsync(stream, header.InitialBody, request.ContentLength, stopping, MaximumControlBodyBytes), peerFingerprint, stopping);
                break;
            case ("POST", "/api/v1/upload"):
                await HandleUploadAsync(stream, request, header.InitialBody, peerFingerprint, stopping);
                break;
            case ("POST", "/api/v1/complete"):
                await HandleCompleteAsync(stream, request, peerFingerprint, stopping);
                break;
            case ("POST", "/api/v1/cancel"):
                if (!IsAuthorized(request, ParseQuery(request.Query).GetValueOrDefault("session"), peerFingerprint))
                {
                    await WriteEmptyAsync(stream, 403, stopping);
                    return;
                }
                CancelSession(ParseQuery(request.Query)["session"]);
                await WriteEmptyAsync(stream, 204, stopping);
                break;
            case ("POST", "/api/v1/clipboard"):
                await HandleClipboardAsync(stream, request, await ReadBodyAsync(stream, header.InitialBody, request.ContentLength, stopping, MaximumControlBodyBytes), peerFingerprint, stopping);
                break;
            default:
                await WriteEmptyAsync(stream, 404, stopping);
                break;
        }
    }

    private async Task HandlePairAsync(SslStream stream, byte[] body, string actualFingerprint, CancellationToken stopping)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            string providedPin = document.RootElement.GetProperty("pin").GetString() ?? "";
            string deviceId = document.RootElement.GetProperty("device").GetProperty("id").GetString() ?? "";
            string returnToken = document.RootElement.GetProperty("returnToken").GetString() ?? "";
            string peerFingerprint = document.RootElement.GetProperty("fingerprint").GetString() ?? "";
            if (deviceId.Length == 0 || returnToken.Length != 64 || !returnToken.All(char.IsAsciiHexDigit) ||
                peerFingerprint.Length != 64 || !peerFingerprint.All(char.IsAsciiHexDigit) ||
                !peerFingerprint.Equals(actualFingerprint, StringComparison.OrdinalIgnoreCase) ||
                !ConsumePairingCode(providedPin))
            {
                await WriteEmptyAsync(stream, 401, stopping);
                return;
            }
                _pairing.PinPeer(deviceId, actualFingerprint);
                _pairing.SetOutgoingToken(deviceId, returnToken);
                string pairingToken = _pairing.CreateIncomingToken(deviceId);
                await WriteJsonAsync(stream, 200, JsonSerializer.Serialize(new { paired = true, token = pairingToken }), stopping);
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException)
        {
            await WriteEmptyAsync(stream, 400, stopping);
        }
    }

    private async Task HandlePrepareAsync(SslStream stream, HttpRequest request, byte[] body, string peerFingerprint, CancellationToken stopping)
    {
        try
        {
            TransferRequest transferRequest = JsonSerializer.Deserialize<TransferRequest>(body, JsonOptions) ??
                                      throw new JsonException("Empty transfer request");
            if (!IsSafeIncomingRequest(transferRequest))
            {
                await WriteEmptyAsync(stream, 403, stopping);
                return;
            }
            int responseStatus;
            string? responseBody = null;
            lock (_sessions)
            {
                if (_sessions.Count >= MaximumIncomingSessions || _sessions.ContainsKey(transferRequest.Session))
                {
                    responseStatus = 409;
                }
                else if (!_pairing.IsValidIncomingToken(transferRequest.Sender.Id, AuthorizationToken(request)) ||
                         !_pairing.IsPinned(transferRequest.Sender.Id, peerFingerprint))
                {
                    responseStatus = 401;
                }
                else
                {
                    Dictionary<string, string> tokens = transferRequest.Files.ToDictionary(file => file.Id, _ => Guid.NewGuid().ToString("N"));
                    string root = DestinationRoot();
                    Directory.CreateDirectory(root);
                    IncomingSession incoming = new(transferRequest, tokens, root, 0, transferRequest.Files.Sum(file => file.Size));
                    _sessions[transferRequest.Session] = incoming;
                    responseStatus = 200;
                    responseBody = JsonSerializer.Serialize(new PrepareResponse(transferRequest.Session, tokens));
                }
            }
            if (responseStatus != 200)
            {
                await WriteEmptyAsync(stream, responseStatus, stopping);
                return;
            }
            IncomingOffer?.Invoke(transferRequest.Sender.Name, transferRequest.Files.Length, transferRequest.Kind);
            await WriteJsonAsync(stream, 200, responseBody!, stopping);
        }
        catch (JsonException)
        {
            await WriteEmptyAsync(stream, 400, stopping);
        }
    }

    private static bool IsSafeIncomingRequest(TransferRequest request)
    {
        if (request.Files.Length == 0 || request.Files.Length > MaximumIncomingFiles ||
            (request.Kind == TransferKind.Clipboard && string.IsNullOrEmpty(request.Text)) ||
            request.Files.Select(file => file.Id).Distinct(StringComparer.Ordinal).Count() != request.Files.Length)
            return false;

        long total = 0;
        foreach (StickyFileMeta file in request.Files)
        {
            if (file.Size < 0 || !IsSafeRelativePath(file.Path) || file.Size > MaximumIncomingBytes - total)
                return false;
            total += file.Size;
        }
        return true;
    }

    private async Task HandleUploadAsync(SslStream stream, HttpRequest request, byte[] initialBody, string peerFingerprint, CancellationToken stopping)
    {
        Dictionary<string, string> query = ParseQuery(request.Query);
        IncomingSession? session;
        lock (_sessions)
            _sessions.TryGetValue(query.GetValueOrDefault("session") ?? "", out session);
        string fileId = query.GetValueOrDefault("file") ?? "";
        if (session == null || !session.Tokens.TryGetValue(fileId, out string? token) || token != query.GetValueOrDefault("token") ||
            !_pairing.IsValidIncomingToken(session.Request.Sender.Id, AuthorizationToken(request)) ||
            !_pairing.IsPinned(session.Request.Sender.Id, peerFingerprint))
        {
            await WriteEmptyAsync(stream, 403, stopping);
            return;
        }
        string expectedChecksum = request.Headers.GetValueOrDefault("x-sticky-checksum") ??
                                  session.Request.Files.FirstOrDefault(file => file.Id == fileId)?.Sha256 ?? "";
        if (!IsChecksum(expectedChecksum))
        {
            await WriteEmptyAsync(stream, 422, stopping);
            return;
        }

        StickyFileMeta meta = session.Request.Files.First(file => file.Id == fileId);
        if (request.ContentLength != meta.Size)
        {
            await WriteEmptyAsync(stream, 413, stopping);
            return;
        }
        string tempPath = Path.Combine(session.Root, ".sticky-temp", session.Request.Session, $"{fileId}.part");
        Directory.CreateDirectory(Path.GetDirectoryName(tempPath)!);
        try
        {
            await using FileStream output = new(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, ChunkSize, true);
            using IncrementalHash hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long written = Math.Min(initialBody.Length, request.ContentLength);
            if (written > 0)
            {
                await output.WriteAsync(initialBody.AsMemory(0, (int)written), stopping);
                hasher.AppendData(initialBody.AsSpan(0, (int)written));
                lock (_sessions) session.LastActivity = DateTimeOffset.UtcNow;
            }
            byte[] buffer = new byte[ChunkSize];
            while (written < request.ContentLength)
            {
                int read = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, request.ContentLength - written)), stopping);
                if (read == 0) throw new IOException("Upload ended before Content-Length was reached");
                await output.WriteAsync(buffer.AsMemory(0, read), stopping);
                hasher.AppendData(buffer.AsSpan(0, read));
                written += read;
                long completed;
                lock (_sessions) { session.ReceivedBytes += read; session.LastActivity = DateTimeOffset.UtcNow; completed = session.ReceivedBytes; }
                TransferProgress progress = new(session.TotalBytes == 0 ? 1 : (double)completed / session.TotalBytes, meta.Path);
                Receiving?.Invoke(progress);
                StateChanged?.Invoke("receive", new NotchState(NotchStateKind.Receiving, progress.Progress, session.Request.Files.Length, meta.Path));
            }
            await output.FlushAsync(stopping);
            if (!Convert.ToHexString(hasher.GetHashAndReset()).Equals(expectedChecksum, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Upload checksum mismatch");
            await WriteEmptyAsync(stream, 204, stopping);
        }
        catch
        {
            try { File.Delete(tempPath); } catch (IOException) { }
            throw;
        }
    }

    private async Task HandleCompleteAsync(SslStream stream, HttpRequest request, string peerFingerprint, CancellationToken stopping)
    {
        string sessionId = ParseQuery(request.Query)["session"];
        IncomingSession? session;
        lock (_sessions)
            _sessions.TryGetValue(sessionId, out session);
        if (session == null)
        {
            await WriteEmptyAsync(stream, 404, stopping);
            return;
        }
        if (!_pairing.IsValidIncomingToken(session.Request.Sender.Id, AuthorizationToken(request)) ||
            !_pairing.IsPinned(session.Request.Sender.Id, peerFingerprint))
        {
            await WriteEmptyAsync(stream, 403, stopping);
            return;
        }

        if (session.Request.Files.Any(file => !File.Exists(Path.Combine(session.Root, ".sticky-temp", sessionId, $"{file.Id}.part"))))
        {
            await WriteEmptyAsync(stream, 409, stopping);
            return;
        }

        List<string> received = [];
        foreach (StickyFileMeta meta in session.Request.Files)
        {
            string tempPath = Path.Combine(session.Root, ".sticky-temp", sessionId, $"{meta.Id}.part");
            if (!File.Exists(tempPath)) continue;
            string destination = CollisionFreePath(SafeRelativePath(session.Root, meta.Path));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Move(tempPath, destination);
            received.Add(destination);
        }
        try { Directory.Delete(Path.Combine(session.Root, ".sticky-temp", sessionId), true); } catch (IOException) { }
        lock (_sessions) _sessions.Remove(sessionId);
        IncomingCompleted?.Invoke(received.Count);
        await WriteJsonAsync(stream, 200, JsonSerializer.Serialize(new CompleteResponse([.. received])), stopping);
    }

    private async Task HandleClipboardAsync(SslStream stream, HttpRequest request, byte[] body, string peerFingerprint, CancellationToken stopping)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            string text = document.RootElement.GetProperty("text").GetString() ?? "";
            string senderId = document.RootElement.GetProperty("sender").GetProperty("id").GetString() ?? "";
            if (!_pairing.IsValidIncomingToken(senderId, AuthorizationToken(request)) ||
                !_pairing.IsPinned(senderId, peerFingerprint))
            {
                await WriteEmptyAsync(stream, 403, stopping);
                return;
            }
            string senderName = "Unknown";
            if (document.RootElement.TryGetProperty("sender", out JsonElement sender))
                senderName = sender.TryGetProperty("name", out JsonElement name) ? name.GetString() ?? senderName : senderName;
            ClipboardReceived?.Invoke(text, senderName);
            await WriteJsonAsync(stream, 200, "{}", stopping);
        }
        catch (JsonException)
        {
            await WriteEmptyAsync(stream, 400, stopping);
        }
    }

    public async Task SendFilesAsync(IReadOnlyList<string> paths, StickyDevice peer)
    {
        List<string> sources = ExpandPaths(paths);
        string sourceRoot = paths.Count == 1 && Directory.Exists(paths[0])
            ? Directory.GetParent(Path.GetFullPath(paths[0]))?.FullName ?? FindCommonRoot(sources)
            : FindCommonRoot(sources);
        string? temporaryZip = null;
        if (sources.Count > 50)
        {
            temporaryZip = Path.Combine(Path.GetTempPath(), $"sticky-{Guid.NewGuid():N}.zip");
            await CreateZipAsync(sources, temporaryZip, sourceRoot, _stop.Token);
            sources = [temporaryZip];
        }

        string commonRoot = temporaryZip == null ? sourceRoot : FindCommonRoot(sources);
        List<StickyFileMeta> metas = [];
        foreach (string source in sources)
        {
            FileInfo info = new(source);
            metas.Add(new StickyFileMeta(Guid.NewGuid().ToString("N"), MakeRelative(commonRoot, source), info.Length, MimeFor(info.FullName), PreviewFor(info.FullName), await SHA256FileAsync(source, _stop.Token)));
        }
        TransferRequest request = new(Guid.NewGuid().ToString(), new SenderInfo(_discovery.Self.Id, _discovery.Self.Name), [.. metas], null, TransferKind.Files);
        (string fingerprint, string authorizationToken, PrepareResponse prepared) = await PrepareUploadAsync(request, peer, _stop.Token);
        long totalBytes = Math.Max(metas.Sum(meta => meta.Size), 1);
        long sentBytes = 0;
        Dictionary<string, string> sourceById = sources.Select((path, index) => (metas[index].Id, path)).ToDictionary(pair => pair.Item1, pair => pair.Item2);
        using SemaphoreSlim gate = new(4, 4);
        List<Task> uploads = [];
        foreach (StickyFileMeta meta in metas)
        {
            string source = sourceById[meta.Id];
            uploads.Add(Task.Run(async () =>
            {
                await gate.WaitAsync(_stop.Token);
                try
                {
                    long fileBase = Interlocked.Read(ref sentBytes);
                    await RetryAsync($"upload {meta.Path}", async () =>
                    {
                        long uploaded = await UploadFileAsync(source, meta, request.Session, prepared.Tokens[meta.Id], peer, fingerprint, authorizationToken, totalBytes, fileBase, _stop.Token);
                        Interlocked.Add(ref sentBytes, uploaded);
                    });
                }
                finally { gate.Release(); }
            }, _stop.Token));
        }
        try
        {
            await Task.WhenAll(uploads);
            await PostAsync(peer, fingerprint, $"/api/v1/complete?session={Uri.EscapeDataString(request.Session)}", [], _stop.Token, authorizationToken);
            Sending?.Invoke(new TransferProgress(1, null));
        }
        catch
        {
            try { await PostAsync(peer, fingerprint, $"/api/v1/cancel?session={Uri.EscapeDataString(request.Session)}", [], CancellationToken.None, authorizationToken); } catch { }
            throw;
        }
        finally
        {
            if (temporaryZip != null) File.Delete(temporaryZip);
        }
    }

    private static async Task<string> SHA256FileAsync(string path, CancellationToken stopping)
    {
        await using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read, ChunkSize, true);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream, stopping)).ToLowerInvariant();
    }

    private static async Task RetryAsync(string operationName, Func<Task> operation)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                await operation();
                return;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception) when (attempt < 3 && attempt is 1 or 2)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(250 * Math.Pow(2, attempt - 1)));
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"{operationName} failed after retries.", ex);
            }
        }
    }

    public async Task SendClipboardAsync(string text, StickyDevice peer)
    {
        object payload = new
        {
            text,
            sender = new { id = _discovery.Self.Id, name = _discovery.Self.Name },
            ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
        };
        (string fingerprint, string authorizationToken) = await EnsurePairedAsync(peer, _stop.Token);
        await PostAsync(peer, fingerprint, "/api/v1/clipboard", JsonSerializer.SerializeToUtf8Bytes(payload), _stop.Token, authorizationToken);
    }

    public async Task PairAsync(StickyDevice peer, string pin, CancellationToken stopping = default)
    {
        if (pin.Length != 6 || !pin.All(char.IsAsciiDigit))
            throw new ArgumentException("Enter the six-digit code shown in Sticky on the other computer.", nameof(pin));

        HttpResponse info = await RequestAsync(peer, null, "GET", "/api/v1/info", null, stopping);
        if (info.StatusCode != 200) throw new InvalidOperationException("The other Sticky app did not answer.");
        using JsonDocument infoDocument = JsonDocument.Parse(info.Body);
        string peerId = infoDocument.RootElement.GetProperty("id").GetString() ?? "";
        string fingerprint = info.Fingerprint ?? throw new SecurityException("The other Sticky app presented no certificate.");
        if (peerId.Length == 0) throw new SecurityException("The other Sticky app did not provide an identity.");

        string returnToken = _pairing.GenerateToken();
        string localFingerprint = _pairing.Fingerprint(_pairing.GetOrCreateCertificate());
        object payload = new { pin, returnToken, fingerprint = localFingerprint, device = new { id = _discovery.Self.Id, name = _discovery.Self.Name } };
        HttpResponse pair = await RequestAsync(peer, null, "POST", "/api/v1/pair", JsonSerializer.SerializeToUtf8Bytes(payload), stopping);
        if (pair.StatusCode != 200) throw new UnauthorizedAccessException("That pairing code was not accepted.");
        string token = JsonSerializer.Deserialize<JsonElement>(pair.Body, JsonOptions).GetProperty("token").GetString() ??
                       throw new UnauthorizedAccessException("The other Sticky app did not finish pairing.");
        _pairing.PinPeer(peerId, fingerprint);
        _pairing.SetOutgoingToken(peerId, token);
        _pairing.SetIncomingToken(peerId, returnToken);
    }

    private async Task<(string Fingerprint, string AuthorizationToken, PrepareResponse Response)> PrepareUploadAsync(TransferRequest request, StickyDevice peer, CancellationToken stopping)
    {
        (string fingerprint, string authorizationToken) = await EnsurePairedAsync(peer, stopping);
        HttpResponse response = await PostAsync(peer, fingerprint, "/api/v1/prepare-upload", JsonSerializer.SerializeToUtf8Bytes(request, JsonOptions), stopping, authorizationToken);
        if (response.StatusCode != 200) throw new InvalidOperationException($"Receiver rejected the transfer ({response.StatusCode}).");
        return (fingerprint, authorizationToken, JsonSerializer.Deserialize<PrepareResponse>(response.Body, JsonOptions) ?? throw new InvalidOperationException("Invalid prepare response."));
    }

    private async Task<(string Fingerprint, string AuthorizationToken)> EnsurePairedAsync(StickyDevice peer, CancellationToken stopping)
    {
        HttpResponse info = await RequestAsync(peer, null, "GET", "/api/v1/info", null, stopping);
        if (info.StatusCode != 200) throw new InvalidOperationException("Peer did not answer its info endpoint.");
        using JsonDocument document = JsonDocument.Parse(info.Body);
        string peerId = document.RootElement.GetProperty("id").GetString() ?? "";
        string fingerprint = info.Fingerprint ?? throw new SecurityException("Peer presented no certificate.");
        string? expected = _pairing.GetPinnedFingerprint(peerId);
        string? storedToken = _pairing.GetOutgoingToken(peerId);
        if (expected != null && _pairing.IsPinned(peerId, fingerprint) && storedToken is { Length: 64 })
            return (fingerprint, storedToken!);

        throw new UnauthorizedAccessException($"Pair {peer.Name} first using the six-digit code shown on that computer.");
    }

    private async Task<HttpResponse> PostAsync(StickyDevice peer, string fingerprint, string pathAndQuery, byte[] body, CancellationToken stopping, string? authorizationToken = null) =>
        await RequestAsync(peer, fingerprint, "POST", pathAndQuery, body, stopping, authorizationToken);

    private async Task<HttpResponse> RequestAsync(StickyDevice peer, string? expectedFingerprint, string method, string pathAndQuery, byte[]? body, CancellationToken stopping, string? authorizationToken = null)
    {
        using TcpClient client = new();
        await client.ConnectAsync(peer.Host, peer.Port, stopping);
        string? responseFingerprint = null;
        await using NetworkStream raw = client.GetStream();
        await using SslStream secure = new(raw, false, (_, _, _, _) => true);
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(stopping);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        await secure.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = peer.Host,
            EnabledSslProtocols = SslProtocols.Tls13,
            RemoteCertificateValidationCallback = (_, _, _, _) => true,
            ClientCertificates = new X509CertificateCollection { _pairing.GetOrCreateCertificate() }
        }, timeout.Token);
        X509Certificate2 remote = new(secure.RemoteCertificate ?? throw new InvalidOperationException("Peer presented no certificate."));
        string fingerprint = _pairing.Fingerprint(remote);
        responseFingerprint = fingerprint;
        if (expectedFingerprint != null && !string.Equals(fingerprint, expectedFingerprint, StringComparison.OrdinalIgnoreCase))
            throw new SecurityException("Peer certificate changed.");

        string authorization = authorizationToken == null ? "" : $"Authorization: Bearer {authorizationToken}\r\n";
        string headers = $"{method} {pathAndQuery} HTTP/1.1\r\nHost: {peer.Host}:{peer.Port}\r\n{authorization}Connection: close\r\nContent-Type: application/json\r\nContent-Length: {body?.Length ?? 0}\r\n\r\n";
        byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
        await secure.WriteAsync(headerBytes, stopping);
        if (body is { Length: > 0 }) await secure.WriteAsync(body, stopping);
        await secure.FlushAsync(stopping);
        (byte[] HeaderBytes, byte[] InitialBody) responseHeader = await ReadHeadersAsync(secure, stopping);
        HttpResponse response = ParseResponse(Encoding.UTF8.GetString(responseHeader.HeaderBytes));
        byte[] responseBody = await ReadBodyAsync(secure, responseHeader.InitialBody, response.ContentLength, stopping);
        return response with { Body = responseBody, Fingerprint = responseFingerprint };
    }

    private async Task<long> UploadFileAsync(string source, StickyFileMeta meta, string sessionId, string token, StickyDevice peer, string fingerprint, string authorizationToken, long totalBytes, long alreadyQueued, CancellationToken stopping)
    {
        await using FileStream input = new(source, FileMode.Open, FileAccess.Read, FileShare.Read, ChunkSize, true);
        using TcpClient client = new();
        await client.ConnectAsync(peer.Host, peer.Port, stopping);
        await using NetworkStream raw = client.GetStream();
        await using SslStream secure = new(raw, false, (_, _, _, _) => true);
        await secure.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = peer.Host,
            EnabledSslProtocols = SslProtocols.Tls13,
            RemoteCertificateValidationCallback = (_, _, _, _) => true,
            ClientCertificates = new X509CertificateCollection { _pairing.GetOrCreateCertificate() }
        }, stopping);
        X509Certificate2 remote = new(secure.RemoteCertificate ?? throw new InvalidOperationException("Peer presented no certificate."));
        if (!_pairing.Fingerprint(remote).Equals(fingerprint, StringComparison.OrdinalIgnoreCase))
            throw new SecurityException("Peer certificate changed during upload.");

        string query = $"session={Uri.EscapeDataString(sessionId)}&file={Uri.EscapeDataString(meta.Id)}&token={Uri.EscapeDataString(token)}";
        string checksum = meta.Sha256 ?? Convert.ToHexString(await SHA256.HashDataAsync(input, stopping)).ToLowerInvariant();
        input.Seek(0, SeekOrigin.Begin);
        string headers = $"POST /api/v1/upload?{query} HTTP/1.1\r\nHost: {peer.Host}:{peer.Port}\r\nAuthorization: Bearer {authorizationToken}\r\nX-Sticky-Checksum: {checksum}\r\nContent-Type: application/octet-stream\r\nContent-Length: {input.Length}\r\nConnection: close\r\n\r\n";
        await secure.WriteAsync(Encoding.ASCII.GetBytes(headers), stopping);
        byte[] buffer = new byte[ChunkSize];
        int read;
        while ((read = await input.ReadAsync(buffer, stopping)) > 0)
        {
            await secure.WriteAsync(buffer.AsMemory(0, read), stopping);
            long complete = Interlocked.Add(ref alreadyQueued, read);
                TransferProgress progress = new((double)complete / totalBytes, meta.Path);
                Sending?.Invoke(progress);
                StateChanged?.Invoke("send", new NotchState(NotchStateKind.Sending, progress.Progress, 0, meta.Path));
        }
        await secure.FlushAsync(stopping);
        (byte[] HeaderBytes, byte[] InitialBody) responseHeader = await ReadHeadersAsync(secure, stopping);
        HttpResponse response = ParseResponse(Encoding.UTF8.GetString(responseHeader.HeaderBytes));
        if (response.StatusCode is < 200 or >= 300) throw new InvalidOperationException($"Upload failed ({response.StatusCode}).");
        return input.Length;
    }

    private void CancelSession(string? sessionId)
    {
        if (sessionId == null) return;
        IncomingSession? session;
        lock (_sessions)
        {
            _sessions.Remove(sessionId, out session);
        }
        if (session != null)
            try { Directory.Delete(Path.Combine(session.Root, ".sticky-temp", sessionId), true); } catch (DirectoryNotFoundException) { }
    }

    private void CleanupExpiredSessions()
    {
        string[] sessionIds;
        lock (_sessions) sessionIds = [.. _sessions.Keys];
        DateTimeOffset cutoff = DateTimeOffset.UtcNow - TimeSpan.FromMinutes(10);
        foreach (string sessionId in sessionIds)
        {
            IncomingSession? session;
            lock (_sessions) _sessions.TryGetValue(sessionId, out session);
            if (session?.LastActivity < cutoff)
                CancelSession(sessionId);
        }
    }

    private void PublishFailure(string message)
    {
        Failed?.Invoke(message);
        StateChanged?.Invoke("failure", new NotchState(NotchStateKind.Failure, 0, 0, null, message));
    }

    private static string? AuthorizationToken(HttpRequest request)
    {
        string value = request.Headers.GetValueOrDefault("authorization", "");
        if (value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return value["Bearer ".Length..].Trim();
        return null;
    }

    private bool IsAuthorized(HttpRequest request, string? sessionId, string peerFingerprint)
    {
        if (sessionId == null) return false;
        IncomingSession? session;
        lock (_sessions) _sessions.TryGetValue(sessionId, out session);
        return session != null &&
               _pairing.IsValidIncomingToken(session.Request.Sender.Id, AuthorizationToken(request)) &&
               _pairing.IsPinned(session.Request.Sender.Id, peerFingerprint);
    }

    private static async Task<(byte[] HeaderBytes, byte[] InitialBody)> ReadHeadersAsync(Stream stream, CancellationToken stopping)
    {
        using MemoryStream data = new();
        byte[] buffer = new byte[ChunkSize];
        while (data.Length < 64 * 1024)
        {
            int read = await stream.ReadAsync(buffer, stopping);
            if (read == 0) break;
            await data.WriteAsync(buffer.AsMemory(0, read), stopping);
            byte[] bytes = data.ToArray();
            int marker = SearchSequence(bytes, "\r\n\r\n"u8);
            if (marker >= 0)
                return (bytes[..marker], bytes[(marker + 4)..]);
        }
        throw new IOException("HTTP headers were too large.");
    }

    private static async Task<byte[]> ReadBodyAsync(Stream stream, byte[] initialBody, long contentLength, CancellationToken stopping, long maximumBytes = MaximumControlBodyBytes)
    {
        if (contentLength <= 0) return [];
        if (contentLength > maximumBytes)
            throw new IOException("HTTP body was too large.");
        using MemoryStream result = new((int)Math.Min(contentLength, 1024 * 1024));
        int initial = (int)Math.Min(initialBody.Length, contentLength);
        await result.WriteAsync(initialBody.AsMemory(0, initial), stopping);
        byte[] buffer = new byte[ChunkSize];
        while (result.Length < contentLength)
        {
            int read = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, contentLength - result.Length)), stopping);
            if (read == 0) throw new IOException("HTTP body ended early.");
            await result.WriteAsync(buffer.AsMemory(0, read), stopping);
        }
        return result.ToArray();
    }

    private static async Task WriteJsonAsync(Stream stream, int statusCode, string json, CancellationToken stopping) =>
        await WriteResponseAsync(stream, statusCode, "application/json", Encoding.UTF8.GetBytes(json), stopping);

    private static async Task WriteEmptyAsync(Stream stream, int statusCode, CancellationToken stopping) =>
        await WriteResponseAsync(stream, statusCode, null, [], stopping);

    private static async Task WriteResponseAsync(Stream stream, int statusCode, string? contentType, byte[] body, CancellationToken stopping)
    {
        StringBuilder builder = new();
        builder.Append("HTTP/1.1 ").Append(statusCode).Append(' ').Append(ReasonPhrase(statusCode)).Append("\r\n");
        if (contentType != null) builder.Append("Content-Type: ").Append(contentType).Append("\r\n");
        builder.Append("Content-Length: ").Append(body.Length).Append("\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(builder.ToString()), stopping);
        if (body.Length > 0) await stream.WriteAsync(body, stopping);
        await stream.FlushAsync(stopping);
    }

    private static HttpRequest ParseRequest(string headerText)
    {
        string[] lines = headerText.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        string[] first = lines.FirstOrDefault()?.Split(' ') ?? [];
        string rawTarget = first.ElementAtOrDefault(1) ?? "/";
        int queryIndex = rawTarget.IndexOf('?');
        string path = queryIndex < 0 ? rawTarget : rawTarget[..queryIndex];
        string query = queryIndex < 0 ? "" : rawTarget[(queryIndex + 1)..];
        long contentLength = 0;
        Dictionary<string, string> headers = new(StringComparer.OrdinalIgnoreCase);
        foreach (string line in lines.Skip(1))
        {
            int colon = line.IndexOf(':');
            if (colon <= 0) continue;
            string name = line[..colon].Trim();
            string value = line[(colon + 1)..].Trim();
            headers[name] = value;
            if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                long.TryParse(value, out contentLength);
        }
        return new HttpRequest(first.FirstOrDefault() ?? "", path, query, contentLength, headers);
    }

    private static HttpResponse ParseResponse(string headerText)
    {
        HttpRequest request = ParseRequest(headerText);
        int statusCode = int.TryParse(headerText.Split(' ').ElementAtOrDefault(1), out int parsed) ? parsed : 500;
        return new HttpResponse(statusCode, [], request.ContentLength);
    }

    private static int SearchSequence(byte[] data, ReadOnlySpan<byte> sequence)
    {
        for (int index = 0; index <= data.Length - sequence.Length; index++)
            if (data.AsSpan(index, sequence.Length).SequenceEqual(sequence)) return index;
        return -1;
    }

    private static Dictionary<string, string> ParseQuery(string query) =>
        query.Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Split('=', 2))
            .ToDictionary(parts => Uri.UnescapeDataString(parts[0]), parts => parts.Length > 1 ? Uri.UnescapeDataString(parts[1]) : "");

    private static string ReasonPhrase(int statusCode) => statusCode switch
    {
        200 => "OK", 204 => "No Content", 400 => "Bad Request", 401 => "Unauthorized",
        403 => "Forbidden", 404 => "Not Found", 409 => "Busy", 422 => "Unprocessable Entity",
        _ => "Error"
    };

    private static string DestinationRoot() => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Sticky");

    private static string SafeRelativePath(string root, string relative)
    {
        string normalized = relative.Replace('\\', '/').TrimStart('/');
        string combined = Path.GetFullPath(Path.Combine(root, normalized));
        if (!combined.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal)) throw new IOException("Unsafe file path rejected.");
        return combined;
    }

    private static bool IsSafeRelativePath(string relative)
    {
        string normalized = relative.Replace('\\', '/').TrimStart('/');
        return normalized.Length > 0 && !normalized.StartsWith('/') && normalized.Split('/').All(part => part is not (".." or ""));
    }

    private static bool IsChecksum(string value) =>
        value.Length == 64 && value.All(char.IsAsciiHexDigit);

    private static bool ConstantTimeEquals(string left, string right)
    {
        byte[] leftBytes = Encoding.UTF8.GetBytes(left);
        byte[] rightBytes = Encoding.UTF8.GetBytes(right);
        return leftBytes.Length == rightBytes.Length && CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }

    private static string CollisionFreePath(string path)
    {
        if (!File.Exists(path)) return path;
        string directory = Path.GetDirectoryName(path)!;
        string name = Path.GetFileNameWithoutExtension(path);
        string extension = Path.GetExtension(path);
        for (int counter = 2; ; counter++)
        {
            string candidate = Path.Combine(directory, $"{name} ({counter}){extension}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    private static List<string> ExpandPaths(IReadOnlyList<string> paths)
    {
        List<string> result = [];
        foreach (string path in paths)
        {
            if (Directory.Exists(path)) result.AddRange(Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories));
            else if (File.Exists(path)) result.Add(path);
        }
        return result;
    }

    private static string FindCommonRoot(IEnumerable<string> paths)
    {
        List<string> directories = paths.Select(Path.GetDirectoryName).Where(value => value != null).Select(value => value!).ToList();
        if (directories.Count == 0) return Environment.CurrentDirectory;
        string root = directories[0];
        foreach (string directory in directories.Skip(1))
        {
            while (!directory.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) &&
                   !string.Equals(directory, root, StringComparison.OrdinalIgnoreCase))
            {
                string? parent = Path.GetDirectoryName(root);
                if (string.IsNullOrEmpty(parent) || string.Equals(parent, root, StringComparison.OrdinalIgnoreCase))
                    return Environment.CurrentDirectory;
                root = parent;
            }
        }
        return root;
    }

    private static string MakeRelative(string root, string path)
    {
        string relative = Path.GetRelativePath(root, path).Replace('\\', '/');
        return relative.StartsWith("../") ? Path.GetFileName(path) : relative;
    }

    private static string MimeFor(string path) => Path.GetExtension(path.ToLowerInvariant()) switch
    {
        ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", ".gif" => "image/gif",
        ".webp" => "image/webp", ".pdf" => "application/pdf", ".zip" => "application/zip",
        ".txt" => "text/plain", _ => "application/octet-stream"
    };

    private static byte[]? PreviewFor(string path)
    {
        if (!MimeFor(path).StartsWith("image/")) return null;
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        byte[] bytes = new byte[Math.Min(stream.Length, 32 * 1024)];
        stream.ReadExactly(bytes);
        return bytes;
    }

    private static async Task CreateZipAsync(IEnumerable<string> files, string destination, string root, CancellationToken stopping)
    {
        await using FileStream stream = new(destination, FileMode.Create, FileAccess.Write, FileShare.None, ChunkSize, true);
        using System.IO.Compression.ZipArchive archive = new(stream, System.IO.Compression.ZipArchiveMode.Create);
        foreach (string file in files)
            archive.CreateEntryFromFile(file, MakeRelative(root, file), System.IO.Compression.CompressionLevel.Optimal);
        await stream.FlushAsync(stopping);
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= HandleNetworkChanged;
        SystemEventsPower.Wake -= HandleWake;
        _cleanupTimer.Dispose();
        _stop.Cancel();
        _listener?.Stop();
        try { _acceptTask?.Wait(TimeSpan.FromSeconds(1)); } catch (AggregateException) { }
        _stop.Dispose();
    }

    private sealed class IncomingSession(
        TransferRequest request,
        Dictionary<string, string> tokens,
        string root,
        long receivedBytes,
        long totalBytes)
    {
        public TransferRequest Request { get; } = request;
        public Dictionary<string, string> Tokens { get; } = tokens;
        public string Root { get; } = root;
        public long ReceivedBytes { get; set; } = receivedBytes;
        public long TotalBytes { get; } = totalBytes;
        public DateTimeOffset LastActivity { get; set; } = DateTimeOffset.UtcNow;
    }

    private sealed record HttpRequest(string Method, string Path, string Query, long ContentLength, Dictionary<string, string> Headers);
    private sealed record HttpResponse(int StatusCode, byte[] Body, long ContentLength, string? Fingerprint = null);
}
