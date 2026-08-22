using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace StickyWin;

public sealed class PairingService : IDisposable
{
    private static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Sticky");
    private static readonly string CertificatePath = Path.Combine(DataDirectory, "device.pfx");
    private static readonly string PinsPath = Path.Combine(DataDirectory, "pins.json");
    private static readonly string IncomingTokensPath = Path.Combine(DataDirectory, "incoming-tokens.bin");
    private static readonly string OutgoingTokensPath = Path.Combine(DataDirectory, "outgoing-tokens.bin");

    private readonly Dictionary<string, string> _pins;
    private readonly Dictionary<string, string> _incomingTokens;
    private readonly Dictionary<string, string> _outgoingTokens;
    private readonly object _sync = new();
    private X509Certificate2? _certificate;

    public PairingService()
    {
        Directory.CreateDirectory(DataDirectory);
        _pins = LoadPins();
        _incomingTokens = LoadTokens(IncomingTokensPath);
        _outgoingTokens = LoadTokens(OutgoingTokensPath);
    }

    public string GeneratePin() => Random.Shared.Next(100000, 999999).ToString();

    public X509Certificate2 GetOrCreateCertificate()
    {
        if (_certificate != null) return _certificate;
        if (File.Exists(CertificatePath))
        {
            _certificate = new X509Certificate2(CertificatePath, string.Empty);
            return _certificate;
        }

        using ECDsa key = ECDsa.Create(ECCurve.NamedCurves.nistP384);
        CertificateRequest request = new("CN=Sticky", key, HashAlgorithmName.SHA256);
        X509Certificate2 certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
        byte[] exported = certificate.Export(X509ContentType.Pfx);
        File.WriteAllBytes(CertificatePath, exported);
        _certificate = new X509Certificate2(exported, string.Empty);
        return _certificate;
    }

    public string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();

    public bool IsPinned(string deviceId, string fingerprint) =>
        GetPinnedFingerprint(deviceId) is { } stored &&
        string.Equals(stored, fingerprint, StringComparison.OrdinalIgnoreCase);

    public string? GetPinnedFingerprint(string deviceId)
    {
        lock (_sync)
        {
            return _pins.TryGetValue(deviceId, out string? fingerprint) ? fingerprint : null;
        }
    }

    public void PinPeer(string deviceId, string fingerprint)
    {
        lock (_sync) _pins[deviceId] = fingerprint;
        Dictionary<string, string> snapshot;
        lock (_sync) snapshot = new(_pins);
        File.WriteAllText(PinsPath, JsonSerializer.Serialize(snapshot));
    }

    public string GenerateToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    public string CreateIncomingToken(string deviceId)
    {
        string token = GenerateToken();
        SetIncomingToken(deviceId, token);
        return token;
    }

    public string? GetOutgoingToken(string deviceId)
    {
        lock (_sync) return _outgoingTokens.TryGetValue(deviceId, out string? token) ? token : null;
    }

    public void SetOutgoingToken(string deviceId, string token) => SetTokenInternal(_outgoingTokens, OutgoingTokensPath, deviceId, token);

    public void SetIncomingToken(string deviceId, string token) => SetTokenInternal(_incomingTokens, IncomingTokensPath, deviceId, token);

    public bool IsValidIncomingToken(string deviceId, string? presentedToken)
    {
        if (presentedToken is not { Length: 64 } || !presentedToken.All(char.IsAsciiHexDigit)) return false;
        lock (_sync)
        {
            try
            {
                return _incomingTokens.TryGetValue(deviceId, out string? expected) &&
                       CryptographicOperations.FixedTimeEquals(
                           Convert.FromHexString(expected),
                           Convert.FromHexString(presentedToken));
            }
            catch (FormatException)
            {
                return false;
            }
        }
    }

    private void SetTokenInternal(Dictionary<string, string> store, string path, string deviceId, string token)
    {
        lock (_sync) store[deviceId] = token;
        Dictionary<string, string> snapshot;
        lock (_sync) snapshot = new(store);
        byte[] plaintext = JsonSerializer.SerializeToUtf8Bytes(snapshot);
        File.WriteAllBytes(path, ProtectedData.Protect(plaintext, null, DataProtectionScope.CurrentUser));
    }

    public void UnpairAll()
    {
        lock (_sync) _pins.Clear();
        lock (_sync) _incomingTokens.Clear();
        lock (_sync) _outgoingTokens.Clear();
        if (File.Exists(PinsPath)) File.Delete(PinsPath);
        if (File.Exists(IncomingTokensPath)) File.Delete(IncomingTokensPath);
        if (File.Exists(OutgoingTokensPath)) File.Delete(OutgoingTokensPath);
    }

    private static Dictionary<string, string> LoadPins()
    {
        if (!File.Exists(PinsPath)) return [];
        return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(PinsPath)) ?? [];
    }

    private static Dictionary<string, string> LoadTokens(string path)
    {
        if (!File.Exists(path)) return [];
        try
        {
            byte[] plaintext = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(plaintext) ?? [];
        }
        catch (CryptographicException)
        {
            return [];
        }
    }

    public void Dispose() => _certificate?.Dispose();
}
