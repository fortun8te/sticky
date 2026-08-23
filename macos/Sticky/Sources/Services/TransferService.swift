import CryptoKit
import Foundation
import Network
import Security

final class TransferService {
    var onProgress: ((Double) -> Void)?
    var onIncoming: ((String, Int, TransferKind) -> Void)?
    var onIncomingCompleted: ((Int) -> Void)?
    var onClipboardReceived: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let pairing = PairingService.shared
    // Shown by the app while this device is waiting to be paired. It is never
    // transmitted as a discovery field, so only a person who can see this
    // device can authorize the first trust relationship.
    private var pairingPIN = PairingService.shared.generatePin()
    private var pairingPINExpiresAt = Date().addingTimeInterval(5 * 60)
    private var pairingPINAttempts = 0

    var pairingCode: String {
        lock.lock()
        if Date() >= pairingPINExpiresAt { rotatePairingCodeLocked() }
        let code = pairingPIN
        lock.unlock()
        return code
    }

    private struct IncomingSession {
        var sender: SenderInfo
        var files: [StickyFileMeta]
        var text: String?
        var kind: TransferKind
        var lastActivity = Date()
        var uploads: [String: UploadState] = [:]
    }

    private struct UploadState {
        var token: String
        var tempURL: URL
        var destinationURL: URL
        var fileHandle: FileHandle?
        var hasher: SHA256
        var receivedBytes: Int64
        var isComplete = false
    }

    private struct ParsedRequest {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    private let discovery: DiscoveryService
    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "sticky.transfer.server", attributes: .concurrent)
    private var listener: NWListener?
    private var activeSessions: [String: IncomingSession] = [:]
    private var pairedPeers: [String: String] = [:]
    private var pairedTokens: [String: String] = [:]
    private var certificate: SecCertificate?
    private var identity: SecIdentity?
    private var protocolIdentity: sec_identity_t?
    private var timeoutTimer: DispatchSourceTimer?
    private var restartTimer: DispatchSourceTimer?
    private var isRunning = false

    static let destinationRoot = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sticky", isDirectory: true)
    private static let idleTimeout: TimeInterval = 600
    private static let chunkSize = 64 * 1024
    private static let maximumSendAttempts = 3
    private static let maximumIncomingSessions = 3
    private static let maximumIncomingFiles = 100
    private static let maximumIncomingBytes: Int64 = 2 * 1024 * 1024 * 1024

    init(discovery: DiscoveryService) {
        self.discovery = discovery
        start()
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        do {
            let pairingIdentity = try pairing.getOrCreateIdentity()
            let identity = pairingIdentity.identity
            self.identity = identity
            certificate = pairingIdentity.certificate

            let tlsOptions = NWProtocolTLS.Options()
            let protocolIdentity = sec_identity_create(identity)
            self.protocolIdentity = protocolIdentity
            guard let protocolIdentity else { throw TransferError.pairingFailed }
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, protocolIdentity)
            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            guard let port = NWEndpoint.Port(rawValue: 53317),
                  let listener = try? NWListener(using: parameters, on: port) else {
                throw TransferError.listenerFailed
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.reportFailure("Transfer listener failed: \(error)")
                    self?.stop()
                    self?.scheduleRestart(after: 2)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            self.listener = listener
            listener.start(queue: workerQueue)
            scheduleTimeoutTimer()
        } catch {
            reportFailure(error.localizedDescription)
            stop()
        }
    }

    func stop() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        listener?.cancel()
        listener = nil
        timeoutTimer?.cancel()
        timeoutTimer = nil
        restartTimer?.cancel()
        restartTimer = nil
        restartTimer?.cancel()
        restartTimer = nil
        let sessions = activeSessions
        activeSessions.removeAll()
        lock.unlock()

        sessions.values.forEach { session in
            session.uploads.values.forEach { upload in
                try? upload.fileHandle?.close()
                try? FileManager.default.removeItem(at: upload.tempURL)
            }
        }
    }

    func cancel(session: String) {
        removeSession(session)
    }

    // MARK: - Client

    func sendFiles(_ urls: [URL], progress: @escaping (Double) -> Void) async throws -> Bool {
        guard let peer = discovery.peers.first(where: { $0.platform == .win }) ?? discovery.peers.first else {
            throw TransferError.noPeer
        }
        return try await sendFiles(urls, to: peer, progress: progress)
    }

    func sendFiles(_ urls: [URL], to peer: StickyDevice, progress: @escaping (Double) -> Void) async throws -> Bool {

        let entries = try collectFiles(urls)
        guard !entries.isEmpty else { return false }
        let metas = try entries.map { entry -> StickyFileMeta in
            let size = try entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
            return StickyFileMeta(
                id: UUID().uuidString,
                path: entry.relativePath,
                size: size,
                mime: mimeType(for: entry.url.pathExtension),
                previewData: nil
            )
        }
        let request = TransferRequest(
            session: UUID().uuidString,
            sender: SenderInfo(id: discovery.myDevice.id, name: discovery.myDevice.name),
            files: metas,
            text: nil,
            kind: .files
        )

        let (fingerprint, authorizationToken) = try await trustedFingerprint(for: peer)
        let urlSession = makeClientSession(expectedFingerprint: fingerprint)
        defer { urlSession.finishTasksAndInvalidate() }

        do {
            let prepareResponse = try await postJSON(
                PrepareResponse.self,
                request: {
                    var prepareRequest = makeURLRequest(peer, path: "/api/v1/prepare-upload", method: "POST")
                    prepareRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
                    return prepareRequest
                }(),
                body: request,
                session: urlSession
            )
            try Task.checkCancellation()

            let totalBytes = metas.reduce(Int64(0)) { $0 + $1.size }
            var sentBytes: Int64 = 0
            for (index, meta) in metas.enumerated() {
                guard let token = prepareResponse.tokens[meta.id] else {
                    throw TransferError.uploadFailed(meta.path)
                }
                let sourceURL = entries[index].url
                let checksum = try checksum(for: sourceURL)
                let fileBase = sentBytes
                let uploadURL = makeUploadURL(peer, session: request.session, fileID: meta.id, token: token)
            var urlRequest = URLRequest(url: uploadURL)
                urlRequest.httpMethod = "POST"
                urlRequest.timeoutInterval = Self.idleTimeout
                urlRequest.setValue(checksum, forHTTPHeaderField: "X-Sticky-Checksum")
            urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")

                try await withRetry("upload \(meta.path)") {
                    try Task.checkCancellation()

                    if let delegate = urlSession.delegate as? TransferClientDelegate {
                        delegate.progress = { [progress] fraction in
                            let overall = Double(fileBase) + fraction * Double(meta.size)
                            progress(totalBytes > 0 ? overall / Double(totalBytes) : 1)
                        }
                    }
                    let (_, response) = try await urlSession.upload(for: urlRequest, fromFile: sourceURL)
                    try self.validateHTTPResponse(response, expectedStatus: 204)
                }
                sentBytes += meta.size
                try Task.checkCancellation()
            }

            progress(1)
            _ = try await postJSON(
                CompleteResponse.self,
                request: {
                    var completeRequest = makeURLRequest(peer, path: "/api/v1/complete", query: ["session": request.session], method: "POST")
                    completeRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
                    return completeRequest
                }(),
                body: Optional<String>.none,
                session: urlSession
            )
            return true
        } catch {
            await cancelRemote(session: request.session, peer: peer)
            throw error
        }
    }

    private func cancelRemote(session: String, peer: StickyDevice) async {
        let urlSession = makeClientSession(expectedFingerprint: pairing.pairedFingerprint(for: peer.id))
        defer { urlSession.finishTasksAndInvalidate() }
        var request = makeURLRequest(peer, path: "/api/v1/cancel", query: ["session": session], method: "POST")
        if let authorizationToken = pairing.outgoingAuthorizationToken(for: peer.id) {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await urlSession.data(for: request)
    }

    private func trustedFingerprint(for peer: StickyDevice) async throws -> (fingerprint: String, authorizationToken: String) {
        if let fingerprint = pairing.pairedFingerprint(for: peer.id),
           let authorizationToken = pairing.outgoingAuthorizationToken(for: peer.id) {
            return (fingerprint, authorizationToken)
            }
        throw TransferError.pairingRequired(peer.name)
    }

    private func withRetry<T>(_ label: String, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...Self.maximumSendAttempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < Self.maximumSendAttempts, Self.isRetryable(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt - 1)) * 500_000_000))
            }
        }
        throw lastError ?? TransferError.invalidResponse
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed].contains(urlError.code)
        }
        return error is POSIXError
    }

    private static func isValidChecksum(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        lock.lock()
        restartTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.start()
        }
        timer.resume()
        restartTimer = timer
        lock.unlock()
    }

    func sendText(_ text: String, to peer: StickyDevice) async throws {
        let (fingerprint, authorizationToken) = try await trustedFingerprint(for: peer)
        let urlSession = makeClientSession(expectedFingerprint: fingerprint)
        defer { urlSession.finishTasksAndInvalidate() }
        let payload: [String: Any] = [
            "text": text,
            "sender": ["id": discovery.myDevice.id, "name": discovery.myDevice.name],
            "ts": Date().timeIntervalSince1970
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var clipboardRequest = makeURLRequest(peer, path: "/api/v1/clipboard", method: "POST", body: body)
        clipboardRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await urlSession.data(for: clipboardRequest)
        try validateHTTPResponse(response, expectedStatus: 200)
    }

    func pair(peer: StickyDevice, pin: String) async throws {
        let reverseToken = pairing.generateAuthorizationToken()
        let paired = try await withRetry("pairing") {
            try await self.requestPair(peer: peer, pin: pin, reverseToken: reverseToken)
        }
        guard let authorizationToken = paired.authorizationToken else {
            throw TransferError.pairingFailed
        }
        try pairing.pinPeer(deviceID: peer.id, fingerprint: paired.fingerprint)
        try pairing.storeOutgoingAuthorizationToken(authorizationToken, for: peer.id)
        try pairing.storeIncomingAuthorizationToken(reverseToken, for: peer.id)
    }

    func unpairAll() throws {
        try pairing.unpairAll()
        lock.lock()
        pairedPeers.removeAll()
        pairedTokens.removeAll()
        rotatePairingCodeLocked()
        lock.unlock()
    }

    private func requestPair(peer: StickyDevice, pin: String, reverseToken: String) async throws -> (fingerprint: String, authorizationToken: String?) {
        let payload: [String: Any] = [
            "pin": pin,
            "returnToken": reverseToken,
            "fingerprint": serverFingerprint(),
            "device": [
                "id": discovery.myDevice.id,
                "name": discovery.myDevice.name,
                "platform": discovery.myDevice.platform.rawValue,
                "host": discovery.myDevice.host,
                "port": discovery.myDevice.port
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let delegate = TransferClientDelegate()
        delegate.clientIdentity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = Self.idleTimeout
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { urlSession.finishTasksAndInvalidate() }

        let (data, urlResponse) = try await urlSession.data(for: makeURLRequest(peer, path: "/api/v1/pair", method: "POST", body: body))
        try validateHTTPResponse(urlResponse, expectedStatus: 200)
        guard let fingerprint = delegate.lastServerFingerprint else {
            throw TransferError.pairingFailed
        }
        let token = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["token"] as? String }
        return (fingerprint, token)
    }

    private func makeClientSession(expectedFingerprint: String?) -> URLSession {
        let delegate = TransferClientDelegate()
        delegate.expectedServerFingerprint = expectedFingerprint
        delegate.clientIdentity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        configuration.timeoutIntervalForResource = Self.idleTimeout
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func makeURLRequest(_ peer: StickyDevice, path: String, query: [String: String] = [:], method: String, body: Data? = nil) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = peer.host
        components.port = peer.port
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func makeUploadURL(_ peer: StickyDevice, session: String, fileID: String, token: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = peer.host
        components.port = peer.port
        components.path = "/api/v1/upload"
        components.queryItems = [
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "file", value: fileID),
            URLQueryItem(name: "token", value: token)
        ]
        return components.url!
    }

    private func postJSON<Response: Decodable, Body: Encodable>(_ type: Response.Type, request: URLRequest, body: Body?, session: URLSession) async throws -> Response {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = body != nil ? try JSONEncoder().encode(body) : Data("{}".utf8)
        let (data, response) = try await session.upload(for: request, from: payload)
        try validateHTTPResponse(response, expectedStatus: 200)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validateHTTPResponse(_ response: URLResponse, expectedStatus: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw TransferError.invalidResponse }
        guard http.statusCode == expectedStatus || (expectedStatus == 200 && (200..<300).contains(http.statusCode)) else {
            throw TransferError.httpStatus(http.statusCode)
        }
    }

    private func collectFiles(_ urls: [URL]) throws -> [(url: URL, relativePath: String)] {
        var result: [(URL, String)] = []
        for root in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                result.append((root.standardizedFileURL, root.lastPathComponent))
                continue
            }
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let item = enumerator?.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    let relative = item.path.dropFirst(root.path.count + 1)
                    result.append((item.standardizedFileURL, "\(root.lastPathComponent)/\(relative)"))
                }
            }
        }
        return result
    }

    private func checksum(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTPS server

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: workerQueue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 32 * 1024 else {
                self.send(connection, status: 431, body: Data())
                return
            }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                let initialBody = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
                self.route(headerData: headerData, initialBody: initialBody, connection: connection)
                return
            }
            if complete {
                connection.cancel()
                return
            }
            self.receiveHeader(connection, buffer: buffer)
        }
    }

    private func route(headerData: Data, initialBody: Data, connection: NWConnection) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            send(connection, status: 400, body: Data())
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else {
            send(connection, status: 400, body: Data())
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()] =
                String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        let target = requestLine[1]
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let rawPath = targetParts.first ?? target
        let query = parseQuery(targetParts.count > 1 ? targetParts[1] : "")
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0

        switch (requestLine[0], rawPath) {
        case ("GET", "/api/v1/info"):
            handleInfo(connection)
        case ("POST", "/api/v1/pair"), ("POST", "/api/v1/prepare-upload"), ("POST", "/api/v1/clipboard"):
            readBody(connection, initialBody: initialBody, remaining: Int64(contentLength - initialBody.count)) { [weak self] body in
                guard let self else { return }
                let parsed = ParsedRequest(method: requestLine[0], path: rawPath, query: query, headers: headers, body: body)
                self.handleJSONEndpoint(parsed, connection: connection)
            }
        case ("POST", "/api/v1/upload"):
            handleUploadStart(ParsedRequest(method: "POST", path: rawPath, query: query, headers: headers, body: initialBody), contentLength: Int64(contentLength), connection: connection)
        case ("POST", "/api/v1/complete"):
            let parsed = ParsedRequest(method: requestLine[0], path: rawPath, query: query, headers: headers, body: initialBody)
            handleComplete(parsed, connection: connection)
        case ("POST", "/api/v1/cancel"):
            let parsed = ParsedRequest(method: requestLine[0], path: rawPath, query: query, headers: headers, body: initialBody)
            if isAuthorized(parsed, senderID: lockWithLock({ activeSessions[query["session"] ?? ""]?.sender.id })) {
                cancel(session: query["session"] ?? "")
                send(connection, status: 204, body: Data())
            } else {
                send(connection, status: 403, body: Data())
            }
        default:
            send(connection, status: 404, body: Data())
        }
    }

    private func readBody(_ connection: NWConnection, initialBody: Data, remaining: Int64, limit: Int = 1024 * 1024, completion: @escaping (Data) -> Void) {
        var body = initialBody
        guard body.count <= limit else {
            send(connection, status: 413, body: Data())
            return
        }
        guard remaining > 0 else {
            completion(body)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(Int(remaining), 64 * 1024)) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            body.append(data)
            guard body.count <= limit else {
                self.send(connection, status: 413, body: Data())
                return
            }
            if complete {
                completion(body)
            } else {
                self.readBody(connection, initialBody: body, remaining: remaining - Int64(data.count), limit: limit, completion: completion)
            }
        }
    }

    private func handleJSONEndpoint(_ request: ParsedRequest, connection: NWConnection) {
        switch request.path {
        case "/api/v1/pair":
            handlePair(request.body, connection: connection)
        case "/api/v1/prepare-upload":
            handlePrepare(request, connection: connection)
        case "/api/v1/clipboard":
            handleClipboard(request, connection: connection)
        default:
            send(connection, status: 404, body: Data())
        }
    }

    private func handlePair(_ body: Data, connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let pin = object["pin"] as? String,
              let device = object["device"] as? [String: Any],
              let senderID = device["id"] as? String,
              let returnToken = object["returnToken"] as? String,
              let senderFingerprint = object["fingerprint"] as? String,
              Self.isValidChecksum(returnToken),
              Self.isValidChecksum(senderFingerprint),
              consumePairingCode(pin) else {
            send(connection, status: 401, body: Data())
            return
        }
        pairedPeers[senderID] = senderFingerprint
        try? pairing.pinPeer(deviceID: senderID, fingerprint: senderFingerprint)
        try? pairing.storeOutgoingAuthorizationToken(returnToken, for: senderID)
        let authorizationToken = (try? pairing.createIncomingAuthorizationToken(for: senderID)) ?? ""
        if !authorizationToken.isEmpty { pairedTokens[senderID] = authorizationToken }
        send(connection, status: 200, body: infoJSON(extra: [
            "fingerprint": serverFingerprint(),
            "paired": true,
            "token": authorizationToken
        ]))
    }

    private func handleInfo(_ connection: NWConnection) {
        send(connection, status: 200, body: infoJSON(extra: [:]))
    }

    private func isAuthorized(_ request: ParsedRequest, senderID: String?) -> Bool {
        guard let senderID,
              let presented = request.headers["authorization"]?.split(separator: " ", maxSplits: 1).last,
              let token = pairing.incomingAuthorizationToken(for: senderID),
              constantTimeEquals(String(presented), token) else {
            return false
        }
        return true
    }

    private func consumePairingCode(_ supplied: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if Date() >= pairingPINExpiresAt { rotatePairingCodeLocked() }
        guard constantTimeEquals(supplied, pairingPIN) else {
            pairingPINAttempts += 1
            if pairingPINAttempts >= 5 { rotatePairingCodeLocked() }
            return false
        }
        rotatePairingCodeLocked()
        return true
    }

    private func rotatePairingCodeLocked() {
        pairingPIN = pairing.generatePin()
        pairingPINExpiresAt = Date().addingTimeInterval(5 * 60)
        pairingPINAttempts = 0
    }

    private func handlePrepare(_ request: ParsedRequest, connection: NWConnection) {
        guard let transferRequest = try? JSONDecoder().decode(TransferRequest.self, from: request.body),
              isAuthorized(request, senderID: transferRequest.sender.id),
              !lockWithLock({ activeSessions.keys.contains(transferRequest.session) }),
              lockWithLock({ activeSessions.count < Self.maximumIncomingSessions }),
              !transferRequest.files.isEmpty || transferRequest.kind == .clipboard,
              transferRequest.files.count <= Self.maximumIncomingFiles,
              transferRequest.files.map(\.id).count == Set(transferRequest.files.map(\.id)).count,
              transferRequest.files.allSatisfy({ $0.size >= 0 && validRelativePath($0.path) }),
              transferRequest.files.reduce(Int64(0), { partial, file in
                  guard partial <= Self.maximumIncomingBytes - file.size else { return Self.maximumIncomingBytes + 1 }
                  return partial + file.size
              }) <= Self.maximumIncomingBytes else {
            send(connection, status: 400, body: Data())
            return
        }

        var tokens: [String: String] = [:]
        var uploads: [String: UploadState] = [:]
        do {
            try FileManager.default.createDirectory(at: Self.destinationRoot, withIntermediateDirectories: true)
            for file in transferRequest.files {
                let token = UUID().uuidString
                tokens[file.id] = token
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sticky-\(transferRequest.session)-\(file.id)", isDirectory: false)
                try? FileManager.default.removeItem(at: tempURL)
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                uploads[file.id] = UploadState(
                    token: token,
                    tempURL: tempURL,
                    destinationURL: collisionSafeDestination(for: file.path),
                    fileHandle: nil,
                    hasher: SHA256(),
                    receivedBytes: 0
                )
            }
        } catch {
            uploads.values.forEach { try? FileManager.default.removeItem(at: $0.tempURL) }
            send(connection, status: 500, body: Data())
            return
        }

        lock.lock()
        activeSessions[transferRequest.session] = IncomingSession(sender: transferRequest.sender, files: transferRequest.files, text: transferRequest.text, kind: transferRequest.kind, uploads: uploads)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self, transferRequest.kind == .files else { return }
            self.onIncoming?(transferRequest.sender.name, transferRequest.files.count, .files)
        }
        let response = PrepareResponse(session: transferRequest.session, tokens: tokens)
        send(connection, status: 200, body: (try? JSONEncoder().encode(response)) ?? Data())
    }

    private func handleUploadStart(_ request: ParsedRequest, contentLength: Int64, connection: NWConnection) {
        guard let sessionID = request.query["session"],
              let fileID = request.query["file"],
              let token = request.query["token"],
              isAuthorized(request, senderID: lockWithLock({ activeSessions[sessionID]?.sender.id })),
              let fileMeta = lockWithLock({ activeSessions[sessionID]?.files.first { $0.id == fileID } }),
              let upload = lockWithLock({ activeSessions[sessionID]?.uploads[fileID] }),
              upload.token == token,
              contentLength == fileMeta.size,
              let expectedChecksum = request.headers["x-sticky-checksum"],
              Self.isValidChecksum(expectedChecksum) else {
            send(connection, status: 403, body: Data())
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: upload.tempURL)
        } catch {
            send(connection, status: 500, body: Data())
            return
        }
        lock.lock()
        activeSessions[sessionID]?.uploads[fileID]?.fileHandle = handle
        activeSessions[sessionID]?.lastActivity = Date()
        lock.unlock()
        receiveUpload(
            connection: connection,
            sessionID: sessionID,
            fileID: fileID,
            handle: handle,
            hasher: upload.hasher,
            // `initialData` below is the body bytes already received with the
            // HTTP headers. Start the running count at zero so those bytes are
            // counted once, not twice.
            received: 0,
            expected: contentLength,
            initialData: request.body,
            expectedChecksum: request.headers["x-sticky-checksum"]
        )
    }

    private func receiveUpload(connection: NWConnection, sessionID: String, fileID: String, handle: FileHandle, hasher: SHA256, received: Int64, expected: Int64, initialData: Data, expectedChecksum: String?) {
        var hasher = hasher
        let received = received + Int64(initialData.count)
        if !initialData.isEmpty {
            hasher.update(data: initialData)
            handle.write(initialData)
            touch(sessionID)
        }
        guard received <= expected else {
            failUpload(sessionID: sessionID, fileID: fileID, handle: handle)
            send(connection, status: 413, body: Data())
            return
        }
        guard received < expected else {
            finishUpload(
                connection: connection,
                sessionID: sessionID,
                fileID: fileID,
                handle: handle,
                hasher: hasher,
                expectedChecksum: expectedChecksum
            )
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, complete, error in
            guard let self, error == nil else {
                self?.failUpload(sessionID: sessionID, fileID: fileID, handle: handle)
                connection.cancel()
                return
            }
            if let data {
                self.receiveUpload(connection: connection, sessionID: sessionID, fileID: fileID, handle: handle, hasher: hasher, received: received, expected: expected, initialData: data, expectedChecksum: expectedChecksum)
            } else if complete {
                self.failUpload(sessionID: sessionID, fileID: fileID, handle: handle)
            }
        }
    }

    private func finishUpload(connection: NWConnection, sessionID: String, fileID: String, handle: FileHandle, hasher: SHA256, expectedChecksum: String?) {
        try? handle.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var isValid = false
        lock.lock()
        if activeSessions[sessionID]?.uploads[fileID] != nil {
            isValid = expectedChecksum == digest
            if isValid {
                activeSessions[sessionID]?.uploads[fileID]?.fileHandle = nil
                activeSessions[sessionID]?.uploads[fileID]?.isComplete = true
            }
        }
        lock.unlock()
        if isValid {
            touch(sessionID)
            send(connection, status: 204, body: Data())
        } else {
            removeUpload(sessionID: sessionID, fileID: fileID)
            send(connection, status: 422, body: Data())
        }
    }

    private func failUpload(sessionID: String, fileID: String, handle: FileHandle) {
        try? handle.close()
        removeUpload(sessionID: sessionID, fileID: fileID)
    }

    private func removeUpload(sessionID: String, fileID: String) {
        lock.lock()
        let upload = activeSessions[sessionID]?.uploads.removeValue(forKey: fileID)
        lock.unlock()
        try? upload?.fileHandle?.close()
        try? FileManager.default.removeItem(at: upload?.tempURL ?? URL(fileURLWithPath: "/dev/null"))
    }

    private func handleComplete(_ request: ParsedRequest, connection: NWConnection) {
        let sessionID = request.query["session"] ?? ""
        lock.lock()
        guard let session = activeSessions[sessionID],
              isAuthorized(request, senderID: session.sender.id),
              session.files.allSatisfy({ file in
                  guard let upload = session.uploads[file.id] else { return false }
                  return upload.isComplete && upload.fileHandle == nil
              }) else {
            lock.unlock()
            send(connection, status: 409, body: Data())
            return
        }
        activeSessions.removeValue(forKey: sessionID)
        lock.unlock()

        var received: [String] = []
        var failed = false
        for file in session.files {
            guard let upload = session.uploads[file.id] else { continue }
            do {
                let parent = upload.destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                var destination = upload.destinationURL
                if FileManager.default.fileExists(atPath: destination.path) {
                    destination = collisionSafeDestination(for: file.path)
                }
                try FileManager.default.moveItem(at: upload.tempURL, to: destination)
                received.append(destination.path)
            } catch {
                try? FileManager.default.removeItem(at: upload.tempURL)
                failed = true
            }
        }
        if failed {
            send(connection, status: 500, body: Data())
        } else {
            let response = CompleteResponse(received: received)
            send(connection, status: 200, body: (try? JSONEncoder().encode(response)) ?? Data())
            DispatchQueue.main.async { [weak self] in
                self?.onIncomingCompleted?(received.count)
            }
        }
    }

    private func handleClipboard(_ request: ParsedRequest, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = json["text"] as? String,
              let sender = json["sender"] as? [String: Any],
              let senderID = sender["id"] as? String,
              isAuthorized(request, senderID: senderID) else {
            send(connection, status: 403, body: Data())
            return
        }
        let senderName = sender["name"] as? String ?? "Unknown"
        DispatchQueue.main.async { [weak self] in
            self?.onClipboardReceived?(text, senderName)
        }
        send(connection, status: 200, body: Data())
    }

    private func touch(_ sessionID: String) {
        lock.lock()
        activeSessions[sessionID]?.lastActivity = Date()
        lock.unlock()
    }

    private func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        guard left.utf8.count == right.utf8.count else { return false }
        var result: UInt8 = 0
        for pair in zip(left.utf8, right.utf8) { result |= pair.0 ^ pair.1 }
        return result == 0
    }

    private func removeSession(_ sessionID: String) {
        lock.lock()
        let session = activeSessions.removeValue(forKey: sessionID)
        lock.unlock()
        session?.uploads.values.forEach { upload in
            try? upload.fileHandle?.close()
            try? FileManager.default.removeItem(at: upload.tempURL)
        }
    }

    private func scheduleTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-Self.idleTimeout)
            let expired = self.lockWithLock {
                self.activeSessions.filter { $0.value.lastActivity < cutoff }.keys
            }
            expired.forEach(self.removeSession)
        }
        timer.resume()
        timeoutTimer = timer
    }


    /// §8: sanitize incoming filenames — reserved Windows names, illegal
    /// characters, trailing dots/spaces, Unicode NFC. Applied before any
    /// collision handling.
    static func sanitizedFileName(_ raw: String) -> String {
        var name = raw.precomposedStringWithCanonicalMapping
        let illegal = CharacterSet(charactersIn: "/\\:\u{0}*?\"<>|")
        name.unicodeScalars.removeAll { illegal.contains($0) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let reserved = ["CON","PRN","AUX","NUL",
                        "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
                        "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9"]
        if reserved.contains(stem.uppercased()) {
            name = "_\(stem).\(ext)"
        }
        return name.isEmpty ? "file" : name
    }

    private func collisionSafeDestination(for relativePath: String) -> URL {
        var components = relativePath.split(separator: "/").map(String.init)
        if let last = components.last {
            components[components.count - 1] = Self.sanitizedFileName(last)
        }
        var current = Self.destinationRoot
        for component in components.dropLast() {
            current = uniqueChild(current, name: component, extensionName: nil, isDirectory: true)
        }
        let filename = components.last ?? UUID().uuidString
        return uniqueChild(current, name: filename, extensionName: (filename as NSString).pathExtension, isDirectory: false)
    }

    private func uniqueChild(_ parent: URL, name: String, extensionName: String?, isDirectory: Bool) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let extensionName = extensionName ?? candidate.pathExtension
            let stem = (name as NSString).deletingPathExtension
            let suffix = " (\(counter))"
            let newName = extensionName.isEmpty ? stem + suffix : "\(stem)\(suffix).\(extensionName)"
            candidate = parent.appendingPathComponent(newName, isDirectory: isDirectory)
            counter += 1
        }
        return candidate
    }

    private func validRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    private func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            result[key] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return result
    }

    private func infoJSON(extra: [String: Any]) -> Data {
        var info: [String: Any] = [
            "id": discovery.myDevice.id,
            "name": discovery.myDevice.name,
            "platform": discovery.myDevice.platform.rawValue,
            "ver": "1.0"
        ]
        info.merge(extra) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
    }

    private func serverFingerprint() -> String {
        guard let certificate, let der = SecCertificateCopyData(certificate) as Data? else { return "" }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private func send(_ connection: NWConnection, status: Int, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 422: reason = "Unprocessable Entity"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Internal Server Error"
        }
        var response = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        if status != 204 { response += "Content-Length: \(body.count)\r\n" }
        response += "\r\n"
        var output = Data(response.utf8)
        if status != 204 { output.append(body) }
        connection.send(content: output, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reportFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }

    private func lockWithLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    // MARK: - Self-signed TLS identity

    private static func createIdentity() throws -> SecIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: "sticky.transfer.server.key.\(UUID().uuidString)"
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TransferError.pairingFailed
        }
        let certificateDER = try createCertificate(privateKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw TransferError.pairingFailed
        }
        return identity
    }

    private static func createCertificate(privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw TransferError.pairingFailed
        }
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let notBefore = utcTime(now)
        let notAfter = utcTime(calendar.date(byAdding: .year, value: 8, to: now) ?? now)
        let commonName = ASN1Value.tagged(0x0c, Data("Sticky".utf8))
        let name = ASN1Value.sequence([ASN1Value.sequence([ASN1Value.sequence([ASN1Value.oid([2, 5, 4, 3]), commonName])])])
        let algorithm = ASN1Value.sequence([ASN1Value.oid([1, 2, 840, 10045, 4, 3, 2])])
        let spkiAlgorithm = ASN1Value.sequence([ASN1Value.oid([1, 2, 840, 10045, 2, 1]), ASN1Value.oid([1, 2, 840, 10045, 3, 1, 7])])
        let spki = ASN1Value.sequence([spkiAlgorithm, ASN1Value.bitString(publicKeyData)])
        let serialBytes = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let tbs = ASN1Value.sequence([
            ASN1Value.explicit(0, ASN1Value.integer(Data([2]))),
            ASN1Value.integer(positiveInteger(serialBytes)),
            algorithm,
            name,
            ASN1Value.sequence([ASN1Value.utcTime(notBefore), ASN1Value.utcTime(notAfter)]),
            name,
            spki
        ])
        let tbsData = tbs.encoded
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbsData as CFData, &error) as Data?,
              let signatureDER = ecdsaSignature(from: signature) else {
            throw TransferError.pairingFailed
        }
        return ASN1Value.sequence([tbs, algorithm, ASN1Value.bitString(signatureDER)]).encoded
    }

    private static func utcTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func ecdsaSignature(from raw: Data) -> Data? {
        guard raw.count == 64 else { return nil }
        let r = positiveInteger(raw.prefix(32))
        let s = positiveInteger(raw.suffix(32))
        return ASN1Value.sequence([ASN1Value.integer(r), ASN1Value.integer(s)]).encoded
    }

    private static func positiveInteger(_ input: Data) -> Data {
        var bytes = Array(input.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data(bytes)
    }
}

private indirect enum ASN1Value {
    case sequence([ASN1Value])
    case integer(Data)
    case oid([Int])
    case bitString(Data)
    case utcTime(String)
    case tagged(UInt8, Data)
    case explicit(UInt8, ASN1Value)

    var encoded: Data {
        switch self {
        case .sequence(let values):
            return tlv(0x30, values.reduce(Data()) { $0 + $1.encoded })
        case .integer(let data):
            return tlv(0x02, data)
        case .oid(let numbers):
            var payload = Data([UInt8(numbers[0] * 40 + numbers[1])])
            for number in numbers.dropFirst(2) {
                var value = number
                var encoded: [UInt8] = []
                encoded.append(UInt8(value & 0x7f))
                value /= 128
                while value > 0 {
                    encoded.append(UInt8(value & 0x7f | 0x80))
                    value /= 128
                }
                payload.append(contentsOf: encoded.reversed())
            }
            return tlv(0x06, payload)
        case .bitString(let data):
            return tlv(0x03, Data([0]) + data)
        case .utcTime(let value):
            return tlv(0x17, Data(value.utf8))
        case .tagged(let tag, let data):
            return tlv(tag, data)
        case .explicit(let number, let value):
            return tlv(0xa0 | number, value.encoded)
        }
    }

    private func tlv(_ tag: UInt8, _ payload: Data) -> Data {
        var length = Data()
        if payload.count < 128 {
            length.append(UInt8(payload.count))
        } else {
            var count = payload.count
            var bytes: [UInt8] = []
            while count > 0 {
                bytes.append(UInt8(count & 0xff))
                count >>= 8
            }
            length.append(UInt8(0x80 | bytes.count))
            length.append(contentsOf: bytes.reversed())
        }
        return Data([tag]) + length + payload
    }
}

private final class TransferClientDelegate: NSObject, URLSessionDataDelegate {
    var expectedServerFingerprint: String?
    var lastServerFingerprint: String?
    var clientIdentity: SecIdentity?
    var progress: ((Double) -> Void)?

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            guard let clientIdentity else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(identity: clientIdentity, certificates: nil, persistence: .forSession))
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let der = SecCertificateCopyData(certificate) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        lastServerFingerprint = fingerprint
        if let expected = expectedServerFingerprint, fingerprint != expected {
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

enum TransferError: LocalizedError {
    case noPeer
    case uploadFailed(String)
    case pairingFailed
    case pairingRequired(String)
    case listenerFailed
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noPeer: return "No nearby Sticky device found."
        case .uploadFailed(let path): return "Upload failed for \(path)."
        case .pairingFailed: return "Pairing failed."
        case .pairingRequired(let name): return "Pair \(name) first using its six-digit Sticky code."
        case .listenerFailed: return "Could not start the transfer listener."
        case .invalidResponse: return "The transfer peer returned an invalid response."
        case .httpStatus(let status): return "The transfer peer returned HTTP \(status)."
        }
    }
}

func mimeType(for ext: String) -> String? {
    switch ext.lowercased() {
    case "png": return "image/png"; case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"; case "pdf": return "application/pdf"
    case "txt": return "text/plain"; case "mp4": return "video/mp4"
    case "zip": return "application/zip"; case "heic": return "image/heic"
    case "json": return "application/json"; case "csv": return "text/csv"
    default: return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
