import Foundation
import Network
import Security

/// Private, loopback-only control plane used by the local MCP bridge. This is
/// intentionally separate from Sticky's TLS LAN transport: no peer, file, or
/// clipboard endpoint is exposed to the network through this listener.
@MainActor
final class ControlService {
    private static let port: UInt16 = 53318
    private static let maxBodyBytes = 1_048_576
    private static let maxHistory = 100
    private static let maxTransfers = 100

    private let discovery: DiscoveryService
    private let transfer: TransferService
    private let clipboard: ClipboardService
    private let controlToken: String
    private var listener: NWListener?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var records: [String: ControlTransfer] = [:]
    private var errors: [ControlError] = []

    private struct ControlTransfer {
        let id: String
        let kind: String
        let peer: StickyDevice
        let files: [URL]
        let text: String?
        let createdAt: Date
        var updatedAt: Date
        var state = "queued"
        var bytesTransferred: Int64 = 0
        var totalBytes: Int64 = 0
        var error: String?
        var completedAt: Date?
    }

    private struct ControlError {
        let id = UUID().uuidString
        let message: String
        let transferID: String?
        let createdAt = Date()
    }

    init(discovery: DiscoveryService, transfer: TransferService, clipboard: ClipboardService) {
        self.discovery = discovery
        self.transfer = transfer
        self.clipboard = clipboard
        self.controlToken = Self.loadOrCreateControlToken()
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: parameters) else {
            recordError("Sticky's local Codex bridge could not start.", transferID: nil)
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in self?.recordError("Sticky's local Codex bridge stopped unexpectedly.", transferID: nil) }
            }
        }
        self.listener = listener
        listener.start(queue: DispatchQueue(label: "sticky.control.loopback"))
    }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        listener?.cancel()
        listener = nil
    }

    private nonisolated func receive(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "sticky.control.connection"))
        receiveBody(connection, buffered: Data())
    }

    private nonisolated func receiveBody(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard error == nil, let data else {
                self?.send(connection, status: 400, body: ["error": "invalid request"])
                return
            }
            let requestData = buffered + data
            guard requestData.count <= 1_114_112 else {
                self?.send(connection, status: 413, body: ["error": "request too large"])
                return
            }
            guard let self else { return }
            if self.hasCompleteRequest(requestData) {
                Task { @MainActor [weak self] in
                    self?.handle(data: requestData, connection: connection)
                }
            } else {
                self.receiveBody(connection, buffered: requestData)
            }
        }
    }

    private nonisolated func hasCompleteRequest(_ data: Data) -> Bool {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<marker.lowerBound], encoding: .utf8) else { return false }
        let contentLength = header.components(separatedBy: "\r\n").dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[safe: 1]?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        return data.distance(from: marker.upperBound, to: data.endIndex) >= contentLength
    }

    private func handle(data: Data, connection: NWConnection) {
        guard let request = parseRequest(data) else {
            send(connection, status: 400, body: ["error": "invalid request"])
            return
        }
        guard let presentedToken = request.headers["x-sticky-control-token"],
              constantTimeEquals(presentedToken, controlToken) else {
            send(connection, status: 401, body: ["error": "unauthorized"])
            return
        }
        let components = request.target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = components[0]
        let query = components.count > 1 ? queryValues(components[1]) : [:]
        guard path.hasPrefix("/api/v1/control") else {
            send(connection, status: 404, body: ["error": "not found"])
            return
        }
        let endpoint = String(path.dropFirst("/api/v1/control".count))
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]

        switch (request.method, endpoint) {
        case ("GET", "/status"):
            send(connection, body: localDeviceJSON())
        case ("GET", "/peers"):
            send(connection, body: discovery.peers.map(peerJSON))
        case ("POST", "/send"):
            handleSend(body, connection: connection)
        case ("GET", "/transfers"):
            send(connection, body: records.values.sorted { $0.updatedAt > $1.updatedAt }.map(transferJSON))
        case ("GET", let endpoint) where endpoint.hasPrefix("/transfers/"):
            let id = String(endpoint.dropFirst("/transfers/".count))
            guard let record = records[id] else { send(connection, status: 404, body: ["error": "transfer not found"]); return }
            send(connection, body: transferJSON(record))
        case ("POST", let endpoint) where endpoint.hasSuffix("/cancel") && endpoint.hasPrefix("/transfers/"):
            let id = String(endpoint.dropFirst("/transfers/".count).dropLast("/cancel".count))
            cancelTransfer(id, connection: connection)
        case ("GET", "/clipboard"):
            send(connection, body: clipboardJSON())
        case ("PUT", "/clipboard"):
            guard let text = body["text"] as? String, validText(text) else {
                send(connection, status: 400, body: ["error": "text must be plain non-empty UTF-8"]); return
            }
            _ = clipboard.writeSticky(text: text)
            send(connection, body: clipboardJSON())
        case ("GET", "/errors"):
            send(connection, body: errors.map(errorJSON))
        case ("DELETE", "/errors"):
            let count = errors.count
            errors.removeAll()
            send(connection, body: ["cleared": count])
        default:
            send(connection, status: 404, body: ["error": "not found", "query": query])
        }
    }

    private func handleSend(_ body: [String: Any], connection: NWConnection) {
        guard let kind = body["kind"] as? String, ["files", "text"].contains(kind) else {
            send(connection, status: 400, body: ["error": "kind must be files or text"]); return
        }
        let peerID = body["peerId"] as? String
        let peer = peerID.flatMap { id in discovery.peers.first { $0.id == id } } ?? (peerID == nil ? discovery.peers.first : nil)
        guard let peer else {
            send(connection, status: 409, body: ["error": "no nearby Sticky device"]); return
        }
        let files: [URL]
        let text: String?
        if kind == "files" {
            guard let rawFiles = body["files"] as? [[String: Any]], !rawFiles.isEmpty else {
                send(connection, status: 400, body: ["error": "files are required"]); return
            }
            files = rawFiles.compactMap { $0["path"] as? String }.map(URL.init(fileURLWithPath:))
            let totalBytes = files.reduce(Int64(0)) { total, file in
                total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
            }
            guard files.count == rawFiles.count,
                  files.count <= 100,
                  totalBytes <= 2 * 1024 * 1024 * 1024,
                  files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) && !$0.hasDirectoryPath }) else {
                send(connection, status: 400, body: ["error": "send up to 100 regular files totaling 2 GB"]); return
            }
            text = nil
        } else {
            guard let value = body["text"] as? String, validText(value) else {
                send(connection, status: 400, body: ["error": "text must be plain non-empty UTF-8"]); return
            }
            files = []
            text = value
        }
        let now = Date()
        let id = UUID().uuidString
        var record = ControlTransfer(id: id, kind: kind, peer: peer, files: files, text: text, createdAt: now, updatedAt: now)
        record.totalBytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
        records[id] = record
        pruneRecords()
        tasks[id] = Task { [weak self] in
            await self?.runTransfer(id: id)
        }
        send(connection, status: 202, body: ["transferId": id])
    }

    private func runTransfer(id: String) async {
        guard var record = records[id] else { return }
        record.state = "sending"
        record.updatedAt = Date()
        records[id] = record
        do {
            if record.kind == "files" {
                _ = try await transfer.sendFiles(record.files, to: record.peer) { [weak self] fraction in
                    Task { @MainActor in
                        guard var current = self?.records[id] else { return }
                        current.bytesTransferred = Int64(Double(current.totalBytes) * fraction)
                        current.updatedAt = Date()
                        self?.records[id] = current
                    }
                }
            } else if let text = record.text {
                try await transfer.sendText(text, to: record.peer)
            }
            guard var completed = records[id], completed.state != "cancelled" else { return }
            completed.state = "completed"
            completed.bytesTransferred = completed.totalBytes
            completed.updatedAt = Date()
            completed.completedAt = completed.updatedAt
            records[id] = completed
        } catch is CancellationError {
            guard var cancelled = records[id] else { return }
            cancelled.state = "cancelled"
            cancelled.updatedAt = Date()
            records[id] = cancelled
        } catch {
            guard var failed = records[id] else { return }
            failed.state = "failed"
            failed.error = error.localizedDescription
            failed.updatedAt = Date()
            records[id] = failed
            recordError(error.localizedDescription, transferID: id)
        }
        tasks[id] = nil
    }

    private func cancelTransfer(_ id: String, connection: NWConnection) {
        guard var record = records[id] else { send(connection, status: 404, body: ["error": "transfer not found"]); return }
        guard ["queued", "sending"].contains(record.state) else { send(connection, status: 409, body: transferJSON(record)); return }
        tasks[id]?.cancel()
        record.state = "cancelled"
        record.updatedAt = Date()
        records[id] = record
        send(connection, body: transferJSON(record))
    }

    private func recordError(_ message: String, transferID: String?) {
        errors.insert(ControlError(message: message, transferID: transferID), at: 0)
        if errors.count > Self.maxHistory { errors.removeLast(errors.count - Self.maxHistory) }
    }

    private func pruneRecords() {
        guard records.count > Self.maxTransfers else { return }
        let removable = records.values
            .filter { !["queued", "sending"].contains($0.state) }
            .sorted { $0.updatedAt < $1.updatedAt }
        for record in removable.prefix(records.count - Self.maxTransfers) {
            records[record.id] = nil
        }
    }

    func recordNativeError(_ message: String) {
        recordError(message, transferID: nil)
    }

    private func localDeviceJSON() -> [String: Any] {
        ["id": discovery.myDevice.id, "name": discovery.myDevice.name, "platform": discovery.myDevice.platform.rawValue, "ver": "1.0"]
    }

    private func peerJSON(_ peer: StickyDevice) -> [String: Any] {
        ["id": peer.id, "name": peer.name, "platform": peer.platform.rawValue, "ver": "1.0", "host": peer.host, "port": peer.port, "lastSeen": iso(peer.lastSeen)]
    }

    private func transferJSON(_ record: ControlTransfer) -> [String: Any] {
        var result: [String: Any] = ["id": record.id, "kind": record.kind, "direction": "send", "state": record.state, "peerId": record.peer.id, "peerName": record.peer.name, "bytesTransferred": record.bytesTransferred, "totalBytes": record.totalBytes, "createdAt": iso(record.createdAt), "updatedAt": iso(record.updatedAt)]
        if !record.files.isEmpty {
            result["files"] = record.files.map { ["path": $0.path, "name": $0.lastPathComponent] }
        }
        if let text = record.text { result["textPreview"] = String(text.prefix(160)) }
        if let error = record.error { result["error"] = error }
        if let completedAt = record.completedAt { result["completedAt"] = iso(completedAt) }
        return result
    }

    private func clipboardJSON() -> [String: Any] {
        ["current": clipboard.stickySlot.map(clipJSON) ?? NSNull(), "history": clipboard.history.map(clipJSON)]
    }

    private func clipJSON(_ entry: StickyClipEntry) -> [String: Any] {
        var result: [String: Any] = ["id": entry.id.uuidString, "text": entry.text, "createdAt": iso(entry.timestamp)]
        if let sender = entry.sender { result["senderName"] = sender }
        return result
    }

    private func errorJSON(_ error: ControlError) -> [String: Any] {
        var result: [String: Any] = ["id": error.id, "message": error.message, "createdAt": iso(error.createdAt)]
        if let transferID = error.transferID { result["transferId"] = transferID }
        return result
    }

    private func validText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 800_000 && !text.contains("\0") && !text.unicodeScalars.contains { $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13 }
    }

    private func iso(_ date: Date) -> String { date.ISO8601Format() }

    private func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let leftData = Data(left.utf8)
        let rightData = Data(right.utf8)
        guard leftData.count == rightData.count else { return false }
        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(leftData, rightData) { difference |= leftByte ^ rightByte }
        return difference == 0
    }

    private static func loadOrCreateControlToken() -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sticky", isDirectory: true)
        let url = directory.appendingPathComponent("control-token")
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count == 64,
           existing.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(token.utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The listener will still require this launch's token; the bridge
            // launcher reports a clear setup error until storage is writable.
        }
        return token
    }

    private func parseRequest(_ data: Data) -> (method: String, target: String, headers: [String: String], body: Data)? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<marker.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first?.split(separator: " "), first.count >= 2 else { return nil }
        var requestHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            // Keep the first occurrence. Repeated headers are never needed by
            // this compact local protocol and must not crash the app.
            let key = parts[0].lowercased()
            if requestHeaders[key] == nil {
                requestHeaders[key] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let contentLength = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[safe: 1]?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let bodyStart = marker.upperBound
        let body = Data(data[bodyStart...])
        guard contentLength == body.count, body.count <= Self.maxBodyBytes else { return nil }
        return (String(first[0]), String(first[1]), requestHeaders, body)
    }

    private func queryValues(_ raw: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: raw.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { return nil }
            return (key, parts.count > 1 ? parts[1].removingPercentEncoding ?? "" : "")
        })
    }

    private nonisolated func send(_ connection: NWConnection, status: Int = 200, body: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        let reason = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : status == 409 ? "Conflict" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
