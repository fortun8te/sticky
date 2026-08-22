import CryptoKit
import Foundation
import Security

enum PairingError: LocalizedError {
    case keyGenerationFailed(String)
    case certificateCreationFailed(String)
    case keychainReadFailed(OSStatus, String)
    case keychainWriteFailed(OSStatus, String)
    case identityUnavailable(String)
    case invalidPeerCertificate
    case invalidFingerprint
    case peerNotPaired(deviceID: String)
    case certificateMismatch(deviceID: String)
    case pairingNotStarted
    case pairingExpired
    case pairingAttemptsExhausted
    case invalidPIN

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let detail):
            return "Sticky could not create this device's private key. \(detail)"
        case .certificateCreationFailed(let detail):
            return "Sticky could not create its local TLS certificate. \(detail)"
        case .keychainReadFailed(let status, let item):
            return "Sticky could not read \(item) from the Keychain (status \(status))."
        case .keychainWriteFailed(let status, let item):
            return "Sticky could not save \(item) to the Keychain (status \(status))."
        case .identityUnavailable(let detail):
            return "Sticky's secure identity is unavailable. \(detail)"
        case .invalidPeerCertificate:
            return "The peer presented an invalid TLS certificate."
        case .invalidFingerprint:
            return "The peer certificate fingerprint is malformed."
        case .peerNotPaired(let deviceID):
            return "Device \(deviceID) has not completed pairing."
        case .certificateMismatch(let deviceID):
            return "Device \(deviceID) no longer matches its pinned certificate."
        case .pairingNotStarted:
            return "No pairing request is active."
        case .pairingExpired:
            return "The pairing PIN expired. Start pairing again."
        case .pairingAttemptsExhausted:
            return "Pairing was canceled after too many incorrect PIN attempts."
        case .invalidPIN:
            return "The pairing PIN is incorrect."
        }
    }
}

struct PairingIdentity {
    let deviceID: String
    let certificate: SecCertificate
    let certificateData: Data
    let privateKey: SecKey
    let identity: SecIdentity

    var fingerprint: String {
        Self.fingerprint(of: certificateData)
    }

    static func fingerprint(of certificateData: Data) -> String {
        SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
    }
}

final class PairingService {
    static let shared = PairingService()

    private let lock = NSLock()
    private let keyTag = "com.sticky.pairing.identity.key"
    private let certificateAccount = "device-certificate"
    private let trustService = "com.sticky.pairing.trust"
    private let incomingTokenService = "com.sticky.pairing.token.incoming"
    private let outgoingTokenService = "com.sticky.pairing.token.outgoing"
    private let maximumPINAttempts = 5
    private let pairingLifetime: TimeInterval = 5 * 60

    private var cachedIdentity: PairingIdentity?
    private var pendingPairing: PendingPairing?

    private struct StoredIdentity: Codable {
        let certificate: Data
        let privateKey: Data
        let keyType: String?
    }

    private struct PendingPairing {
        let peerID: String
        let code: String
        let expiresAt: Date
        var attempts = 0
    }

    var deviceID: String {
        do {
            return try getOrCreateIdentity().deviceID
        } catch {
            assertionFailure("Unable to load Sticky identity: \(error.localizedDescription)")
            return ""
        }
    }

    func generatePin() -> String {
        var randomValue: UInt32 = .max
        repeat {
            let status = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &randomValue)
            if status != errSecSuccess {
                return String(format: "%06d", Int.random(in: 0...999_999))
            }
        } while randomValue >= 1_000_000
        return String(format: "%06d", randomValue)
    }

    func beginPairing(peerID: String) throws -> String {
        let pin = generatePin()
        lock.lock()
        defer { lock.unlock() }
        pendingPairing = PendingPairing(
            peerID: peerID,
            code: pin,
            expiresAt: Date().addingTimeInterval(pairingLifetime)
        )
        return pin
    }

    func verifyPin(_ suppliedPin: String, expectedPin: String) throws {
        guard suppliedPin.count == 6, expectedPin.count == 6,
              constantTimeEquals(suppliedPin, expectedPin) else {
            throw PairingError.invalidPIN
        }
    }

    func completePairing(peerID: String, pin: String, certificateData: Data) throws {
        _ = try validatedCertificate(from: certificateData)
        let fingerprint = PairingIdentity.fingerprint(of: certificateData)

        lock.lock()
        guard var pending = pendingPairing, pending.peerID == peerID else {
            lock.unlock()
            throw PairingError.pairingNotStarted
        }
        guard Date() < pending.expiresAt else {
            pendingPairing = nil
            lock.unlock()
            throw PairingError.pairingExpired
        }
        guard constantTimeEquals(pin, pending.code) else {
            pending.attempts += 1
            if pending.attempts >= maximumPINAttempts {
                pendingPairing = nil
                lock.unlock()
                throw PairingError.pairingAttemptsExhausted
            }
            lock.unlock()
            throw PairingError.invalidPIN
        }
        pendingPairing = nil
        lock.unlock()

        try pinPeer(deviceID: peerID, fingerprint: fingerprint)
    }

    func cancelPairing() {
        lock.lock()
        pendingPairing = nil
        lock.unlock()
    }

    func getOrCreateIdentity() throws -> PairingIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIdentity {
            return cachedIdentity
        }

        // A private app-support identity loads without touching the login
        // Keychain, so launching Sticky never asks macOS to import a key.
        if let loaded = try? loadFileIdentity() {
            cachedIdentity = loaded
            return loaded
        }

        let created = try createOpenSSLFileIdentity()
        cachedIdentity = created
        return created
    }

    func isPeerPaired(_ deviceId: String) -> Bool {
        (try? storedFingerprint(for: deviceId)) != nil
    }

    func pairedFingerprint(for deviceId: String) -> String? {
        try? storedFingerprint(for: deviceId)
    }

    func createAuthorizationToken(for deviceId: String) throws -> String {
        try createIncomingAuthorizationToken(for: deviceId)
    }

    func createIncomingAuthorizationToken(for deviceId: String) throws -> String {
        let token = generateAuthorizationToken()
        try storeIncomingAuthorizationToken(token, for: deviceId)
        return token
    }

    func generateAuthorizationToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func authorizationToken(for deviceId: String) -> String? {
        incomingAuthorizationToken(for: deviceId)
    }

    func incomingAuthorizationToken(for deviceId: String) -> String? {
        token(for: deviceId, service: incomingTokenService)
    }

    func outgoingAuthorizationToken(for deviceId: String) -> String? {
        token(for: deviceId, service: outgoingTokenService)
    }

    private func token(for deviceId: String, service: String) -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storeAuthorizationToken(_ token: String, for deviceId: String) throws {
        try storeIncomingAuthorizationToken(token, for: deviceId)
    }

    func storeIncomingAuthorizationToken(_ token: String, for deviceId: String) throws {
        try storeToken(token, for: deviceId, service: incomingTokenService)
    }

    func storeOutgoingAuthorizationToken(_ token: String, for deviceId: String) throws {
        try storeToken(token, for: deviceId, service: outgoingTokenService)
    }

    private func storeToken(_ token: String, for deviceId: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw PairingError.keychainWriteFailed(status, "the pairing token")
            }
        } else if updateStatus != errSecSuccess {
            throw PairingError.keychainWriteFailed(updateStatus, "the pairing token")
        }
    }

    func verifyPeer(deviceID: String, certificateData: Data) throws {
        guard SecCertificateCreateWithData(nil, certificateData as CFData) != nil else {
            throw PairingError.invalidPeerCertificate
        }
        let actualFingerprint = PairingIdentity.fingerprint(of: certificateData)
        guard let expectedFingerprint = try? storedFingerprint(for: deviceID) else {
            throw PairingError.peerNotPaired(deviceID: deviceID)
        }
        guard timingSafeFingerprintEquals(actualFingerprint, expectedFingerprint) else {
            throw PairingError.certificateMismatch(deviceID: deviceID)
        }
    }

    func pinPeer(_ deviceId: String) {
        guard let identity = try? getOrCreateIdentity() else { return }
        try? pinPeer(deviceID: deviceId, fingerprint: identity.fingerprint)
    }

    func pinPeer(deviceID: String, fingerprint: String) throws {
        guard fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw PairingError.invalidFingerprint
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trustService,
            kSecAttrAccount as String: deviceID
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(fingerprint.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw PairingError.keychainWriteFailed(status, "the pinned peer")
            }
        } else if updateStatus != errSecSuccess {
            throw PairingError.keychainWriteFailed(updateStatus, "the pinned peer")
        }
    }

    func unpair(deviceID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trustService,
            kSecAttrAccount as String: deviceID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingError.keychainWriteFailed(status, "the unpinned peer")
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: incomingTokenService,
            kSecAttrAccount as String: deviceID
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: outgoingTokenService,
            kSecAttrAccount as String: deviceID
        ] as CFDictionary)
    }

    func unpairAll() throws {
        for service in [trustService, incomingTokenService, outgoingTokenService] {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PairingError.keychainWriteFailed(status, "the saved pairings")
            }
        }
        cancelPairing()
    }

    private func loadIdentity() throws -> PairingIdentity? {
        if let fileIdentity = try loadFileIdentity() { return fileIdentity }
        var result: AnyObject?
        let certificateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecAttrAccount as String: certificateAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let certificateStatus = SecItemCopyMatching(certificateQuery as CFDictionary, &result)
        guard certificateStatus == errSecSuccess,
              let certificateData = result as? Data else {
            if certificateStatus != errSecItemNotFound {
                throw PairingError.keychainReadFailed(certificateStatus, "the device certificate")
            }
            return nil
        }

        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &result)
        guard keyStatus == errSecSuccess, let privateKeyRef = result else {
            if keyStatus == errSecItemNotFound { return nil }
            throw PairingError.keychainReadFailed(keyStatus, "the device private key")
        }
        return try makeIdentity(certificateData: certificateData, privateKey: privateKeyRef as! SecKey)
    }

    private func loadPKCS12Identity() throws -> PairingIdentity? {
        guard FileManager.default.fileExists(atPath: Self.identityPKCS12URL.path) else { return nil }
        var imported: CFArray?
        let status = SecPKCS12Import(
            try Data(contentsOf: Self.identityPKCS12URL) as CFData,
            [kSecImportExportPassphrase as String: "sticky-local-identity"] as CFDictionary,
            &imported
        )
        guard status == errSecSuccess else {
            try? FileManager.default.removeItem(at: Self.identityPKCS12URL)
            throw PairingError.identityUnavailable("PKCS#12 import failed with status \(status).")
        }
        guard let item = (imported as? [[String: Any]])?.first,
              let identityValue = item[kSecImportItemIdentity as String] else {
            try? FileManager.default.removeItem(at: Self.identityPKCS12URL)
            throw PairingError.identityUnavailable("PKCS#12 import returned no identity.")
        }
        let identity = identityValue as! SecIdentity
        var certificate: SecCertificate?
        var privateKey: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let certificate, let privateKey else {
            throw PairingError.identityUnavailable("The saved TLS identity is incomplete.")
        }
        return try makeIdentity(certificateData: SecCertificateCopyData(certificate) as Data, privateKey: privateKey)
    }

    private func createPKCS12Identity() throws -> PairingIdentity {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticky-identity-\(UUID().uuidString)", isDirectory: true)
        let keyURL = temporaryDirectory.appendingPathComponent("device-key.pem")
        let certificateURL = temporaryDirectory.appendingPathComponent("device-cert.pem")
        let archiveURL = temporaryDirectory.appendingPathComponent("device.p12")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try runOpenSSL([
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyURL.path, "-out", certificateURL.path,
                "-subj", "/CN=Sticky Device", "-days", "3650",
                "-addext", "basicConstraints=critical,CA:FALSE",
                "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
                "-addext", "extendedKeyUsage=serverAuth,clientAuth",
                "-addext", "subjectAltName=DNS:sticky.local,IP:127.0.0.1"
            ])
            try runOpenSSL(["pkcs12", "-export", "-out", archiveURL.path, "-inkey", keyURL.path, "-in", certificateURL.path, "-passout", "pass:sticky-local-identity"])
            let directory = Self.identityPKCS12URL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: archiveURL, to: Self.identityPKCS12URL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.identityPKCS12URL.path)
            guard let identity = try loadPKCS12Identity() else {
                throw PairingError.identityUnavailable("Sticky could not load its newly created TLS identity.")
            }
            return identity
        } catch {
            try? FileManager.default.removeItem(at: Self.identityPKCS12URL)
            if let pairingError = error as? PairingError { throw pairingError }
            throw PairingError.identityUnavailable(error.localizedDescription)
        }
    }

    private func createOpenSSLFileIdentity() throws -> PairingIdentity {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticky-identity-\(UUID().uuidString)", isDirectory: true)
        let keyURL = temporaryDirectory.appendingPathComponent("device-key.pem")
        let keyDERURL = temporaryDirectory.appendingPathComponent("device-key.der")
        let certificateURL = temporaryDirectory.appendingPathComponent("device-cert.pem")
        let certificateDERURL = temporaryDirectory.appendingPathComponent("device-cert.der")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try runOpenSSL([
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyURL.path, "-out", certificateURL.path,
                "-subj", "/CN=Sticky Device", "-days", "3650",
                "-addext", "basicConstraints=critical,CA:FALSE",
                "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
                "-addext", "extendedKeyUsage=serverAuth,clientAuth",
                "-addext", "subjectAltName=DNS:sticky.local,IP:127.0.0.1"
            ])
            try runOpenSSL(["pkey", "-in", keyURL.path, "-outform", "DER", "-out", keyDERURL.path])
            try runOpenSSL(["x509", "-in", certificateURL.path, "-outform", "DER", "-out", certificateDERURL.path])
            let privateKeyData = try Data(contentsOf: keyDERURL)
            let certificateData = try Data(contentsOf: certificateDERURL)
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 2048
            ]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &error) else {
                let detail = error?.takeRetainedValue().localizedDescription ?? "Unknown Security error."
                throw PairingError.identityUnavailable(detail)
            }
            try persistFileIdentity(certificate: certificateData, privateKey: privateKeyData, keyType: "rsa")
            return try makeIdentity(certificateData: certificateData, privateKey: privateKey)
        } catch {
            if let pairingError = error as? PairingError { throw pairingError }
            throw PairingError.identityUnavailable(error.localizedDescription)
        }
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "openssl failed"
            throw PairingError.identityUnavailable(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func createIdentity() throws -> PairingIdentity {
        deleteBrokenIdentityItems()

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrCanSign as String: true,
            // Some ad-hoc/local bundles cannot create a permanent SecKey item.
            // A permission-restricted app-support file below keeps the identity
            // stable without making first launch silently lose LAN transfer.
            kSecAttrIsPermanent as String: false
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "Unknown Security error."
            throw PairingError.keyGenerationFailed(detail)
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let certificateData = SelfSignedCertificateGenerator.generate(
                publicKeyData: publicKeyData,
                privateKey: privateKey
              ) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "Unknown Security error."
            deleteBrokenIdentityItems()
            throw PairingError.certificateCreationFailed(detail)
        }

        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "Unknown Security error."
            throw PairingError.identityUnavailable(detail)
        }
        let directory = Self.identityFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try persistFileIdentity(certificate: certificateData, privateKey: privateKeyData, keyType: "ec")
        } catch {
            throw PairingError.identityUnavailable("Sticky could not store its local secure identity. \(error.localizedDescription)")
        }

        return try makeIdentity(certificateData: certificateData, privateKey: privateKey)
    }

    private func loadFileIdentity() throws -> PairingIdentity? {
        guard FileManager.default.fileExists(atPath: Self.identityFileURL.path) else { return nil }
        do {
            let stored = try JSONDecoder().decode(StoredIdentity.self, from: Data(contentsOf: Self.identityFileURL))
            let keyType = stored.keyType == "rsa" ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: keyType,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: stored.keyType == "rsa" ? 2048 : 256
            ]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateWithData(stored.privateKey as CFData, attributes as CFDictionary, &error) else {
                let detail = error?.takeRetainedValue().localizedDescription ?? "Unknown Security error."
                throw PairingError.identityUnavailable(detail)
            }
            return try makeIdentity(certificateData: stored.certificate, privateKey: privateKey)
        } catch {
            try? FileManager.default.removeItem(at: Self.identityFileURL)
            if let pairingError = error as? PairingError { throw pairingError }
            throw PairingError.identityUnavailable(error.localizedDescription)
        }
    }

    private func migratePKCS12Identity() throws -> PairingIdentity? {
        guard let legacy = try loadPKCS12Identity() else { return nil }
        var error: Unmanaged<CFError>?
        guard let privateKeyData = SecKeyCopyExternalRepresentation(legacy.privateKey, &error) as Data? else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "Unknown Security error."
            throw PairingError.identityUnavailable(detail)
        }
        try persistFileIdentity(certificate: legacy.certificateData, privateKey: privateKeyData, keyType: "rsa")
        try? FileManager.default.removeItem(at: Self.identityPKCS12URL)
        return try loadFileIdentity()
    }

    private func persistFileIdentity(certificate: Data, privateKey: Data, keyType: String) throws {
        let directory = Self.identityFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(StoredIdentity(certificate: certificate, privateKey: privateKey, keyType: keyType))
            .write(to: Self.identityFileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.identityFileURL.path)
    }

    private func makeIdentity(certificateData: Data, privateKey: SecKey) throws -> PairingIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw PairingError.identityUnavailable("The certificate and private key do not match.")
        }
        let publicKeyData = try publicKeyData(for: privateKey)
        let stableIdentifier = SHA256.hash(data: publicKeyData)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return PairingIdentity(
            deviceID: stableIdentifier,
            certificate: certificate,
            certificateData: certificateData,
            privateKey: privateKey,
            identity: identity
        )
    }

    private func publicKeyData(for privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw PairingError.identityUnavailable("The public key could not be derived.")
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "Unknown Security error."
            throw PairingError.identityUnavailable(detail)
        }
        return data
    }

    private func deleteBrokenIdentityItems() {
        try? FileManager.default.removeItem(at: Self.identityPKCS12URL)
        try? FileManager.default.removeItem(at: Self.identityFileURL)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecAttrAccount as String: certificateAccount
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag
        ] as CFDictionary)
    }

    private static var identityFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sticky", isDirectory: true)
            .appendingPathComponent("device-identity.json")
    }

    private static var identityPKCS12URL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sticky", isDirectory: true)
            .appendingPathComponent("device-identity.p12")
    }

    private func storedFingerprint(for deviceID: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trustService,
            kSecAttrAccount as String: deviceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let fingerprint = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound {
                throw PairingError.peerNotPaired(deviceID: deviceID)
            }
            throw PairingError.keychainReadFailed(status, "the pinned peer")
        }
        return fingerprint
    }

    private func validatedCertificate(from data: Data) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw PairingError.invalidPeerCertificate
        }
        return certificate
    }

    private func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        guard leftBytes.count == rightBytes.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<leftBytes.count {
            difference |= leftBytes[index] ^ rightBytes[index]
        }
        return difference == 0
    }

    private func timingSafeFingerprintEquals(_ left: String, _ right: String) -> Bool {
        constantTimeEquals(left.lowercased(), right.lowercased())
    }
}

private enum SelfSignedCertificateGenerator {
    static func generate(publicKeyData: Data, privateKey: SecKey) -> Data? {
        let now = Date()
        let commonName = derUTF8String("Sticky Device")
        let name = derSequence([derSet([derSequence([derOID([2, 5, 4, 3]), commonName])])])
        let algorithm = derSequence([derOID([1, 2, 840, 10045, 4, 3, 2])])
        let spki = derSequence([
            derSequence([
                derOID([1, 2, 840, 10045, 2, 1]),
                derOID([1, 2, 840, 10045, 3, 1, 7])
            ]),
            derBitString(publicKeyData)
        ])
        let basicConstraints = extensionEntry(oid: [2, 5, 29, 19], value: derSequence([]))
        let keyUsage = extensionEntry(oid: [2, 5, 29, 15], value: derBitString(Data([0xa0]), unusedBitCount: 5))
        let extendedUsage = extensionEntry(
            oid: [2, 5, 29, 37],
            value: derSequence([
                derOID([1, 3, 6, 1, 5, 5, 7, 3, 1]),
                derOID([1, 3, 6, 1, 5, 5, 7, 3, 2])
            ])
        )
        let subjectAltName = extensionEntry(
            oid: [2, 5, 29, 17],
            value: derSequence([contextPrimitive(0x82, Data("localhost".utf8))])
        )

        let tbs = derSequence([
            contextConstructed(0xa0, derInteger(Data([0x02]))),
            derInteger(positiveRandomSerial()),
            algorithm,
            name,
            validity(notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(3650 * 24 * 60 * 60)),
            name,
            spki,
            contextConstructed(0xa3, derSequence([basicConstraints, keyUsage, extendedUsage, subjectAltName]))
        ])

        var error: Unmanaged<CFError>?
        guard let rawSignature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &error
        ) as Data?, rawSignature.count == 64 else {
            return nil
        }
        let signature = derSequence([
            derUnsignedInteger(rawSignature.prefix(32)),
            derUnsignedInteger(rawSignature.suffix(32))
        ])
        return derSequence([tbs, algorithm, derBitString(signature)])
    }

    private static func validity(notBefore: Date, notAfter: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return derSequence([
            derUTCTime(formatter.string(from: notBefore)),
            derUTCTime(formatter.string(from: notAfter))
        ])
    }

    private static func extensionEntry(oid: [Int], value: Data) -> Data {
        derSequence([derOID(oid), derOctetString(value)])
    }

    private static func positiveRandomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] &= 0x7f
        if bytes[0] == 0 { bytes[0] = 1 }
        return Data(bytes)
    }
}

private func derTLV(tag: UInt8, payload: Data) -> Data {
    var output = Data([tag])
    let length = payload.count
    if length < 0x80 {
        output.append(UInt8(length))
    } else {
        var lengthBytes = withUnsafeBytes(of: UInt32(length).bigEndian) { Data($0) }
        while let first = lengthBytes.first, first == 0 { lengthBytes.removeFirst() }
        output.append(UInt8(0x80 | lengthBytes.count))
        output.append(lengthBytes)
    }
    output.append(payload)
    return output
}

private func derSequence(_ values: [Data]) -> Data {
    derTLV(tag: 0x30, payload: values.reduce(Data()) { $0 + $1 })
}

private func derSet(_ values: [Data]) -> Data {
    derTLV(tag: 0x31, payload: values.reduce(Data()) { $0 + $1 })
}

private func derInteger(_ value: Data) -> Data {
    var bytes = value
    while let first = bytes.first, first == 0, bytes.count > 1 { bytes.removeFirst() }
    if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
    return derTLV(tag: 0x02, payload: bytes)
}

private func derUnsignedInteger(_ value: Data) -> Data {
    derInteger(value)
}

private func derBitString(_ value: Data, unusedBitCount: UInt8 = 0) -> Data {
    derTLV(tag: 0x03, payload: Data([unusedBitCount]) + value)
}

private func derOctetString(_ value: Data) -> Data {
    derTLV(tag: 0x04, payload: value)
}

private func derUTF8String(_ value: String) -> Data {
    derTLV(tag: 0x0c, payload: Data(value.utf8))
}

private func derUTCTime(_ value: String) -> Data {
    derTLV(tag: 0x17, payload: Data(value.utf8))
}

private func derOID(_ components: [Int]) -> Data {
    var payload = Data([UInt8(components[0] * 40 + components[1])])
    for component in components.dropFirst(2) {
        var encoded: [UInt8] = []
        var remaining = component
        encoded.insert(UInt8(remaining & 0x7f), at: 0)
        remaining >>= 7
        while remaining > 0 {
            encoded.insert(UInt8((remaining & 0x7f) | 0x80), at: 0)
            remaining >>= 7
        }
        payload.append(contentsOf: encoded)
    }
    return derTLV(tag: 0x06, payload: payload)
}

private func contextConstructed(_ tag: UInt8, _ value: Data) -> Data {
    derTLV(tag: tag, payload: value)
}

private func contextPrimitive(_ tag: UInt8, _ value: Data) -> Data {
    derTLV(tag: tag, payload: value)
}
