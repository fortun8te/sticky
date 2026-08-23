import AppKit
import Foundation

/// One successful send, remembered only so it can be repeated.
struct RecentSend: Codable, Equatable {
    enum Payload: Codable, Equatable {
        case files(paths: [String])
        case text(String)
    }

    let payload: Payload
    let sentAt: Date

    /// Two sends of the same files, or of the same text, are the same recent —
    /// re-sending must move an entry rather than fill the list with copies.
    var identity: String {
        switch payload {
        case .files(let paths):
            return "files:" + paths.sorted().joined(separator: "\u{1F}")
        case .text(let text):
            return "text:" + text
        }
    }

    var menuTitle: String {
        switch payload {
        case .files(let paths):
            guard let first = paths.first else { return "Empty send" }
            let name = RecentSend.middleTruncated(URL(fileURLWithPath: first).lastPathComponent)
            guard paths.count > 1 else { return name }
            return "\(name) and \(paths.count - 1) more"
        case .text(let text):
            return "“\(RecentSend.tailTruncated(text))”"
        }
    }

    /// Middle, not tail: the extension and the disambiguating end of a filename
    /// are the parts that identify it, which is why Finder truncates this way
    /// too (§10.4).
    private static func middleTruncated(_ name: String, limit: Int = 34) -> String {
        guard name.count > limit else { return name }
        let headCount = (limit - 1) / 2
        let tailCount = limit - 1 - headCount
        return String(name.prefix(headCount)) + "…" + String(name.suffix(tailCount))
    }

    /// A text snippet reads from the front, so it loses its tail instead.
    private static func tailTruncated(_ text: String, limit: Int = 34) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }
}

/// F-7. The last five successful sends, offered back from the menu bar. It is a
/// bounded list and nothing else: no window, no shelf, no visible surface of
/// its own.
@MainActor
final class RecentsStore {
    static let capacity = 5

    private let defaultsKey = "sticky.recents.v1"
    private let defaults: UserDefaults
    private var entries: [RecentSend]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([RecentSend].self, from: data) {
            entries = Array(decoded.prefix(Self.capacity))
        } else {
            entries = []
        }
    }

    /// Pruning happens on read rather than on write, because a file can be
    /// moved or deleted at any moment between the send and the next time the
    /// menu opens. A dead entry is dropped for good the first time it is
    /// noticed, so a re-send is never offered for a file that isn't there.
    func currentEntries() -> [RecentSend] {
        let live = entries.filter(Self.isStillSendable)
        if live.count != entries.count {
            entries = live
            persist()
        }
        return live
    }

    func recordFiles(_ urls: [URL]) {
        let paths = urls.map(\.path)
        guard !paths.isEmpty else { return }
        insert(RecentSend(payload: .files(paths: paths), sentAt: Date()))
    }

    func recordText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        insert(RecentSend(payload: .text(trimmed), sentAt: Date()))
    }

    func forget(_ entry: RecentSend) {
        let identity = entry.identity
        guard entries.contains(where: { $0.identity == identity }) else { return }
        entries.removeAll { $0.identity == identity }
        persist()
    }

    private func insert(_ entry: RecentSend) {
        let identity = entry.identity
        entries.removeAll { $0.identity == identity }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity {
            entries = Array(entries.prefix(Self.capacity))
        }
        persist()
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        defaults.set(encoded, forKey: defaultsKey)
    }

    private static func isStillSendable(_ entry: RecentSend) -> Bool {
        switch entry.payload {
        case .text:
            return true
        case .files(let paths):
            // All or nothing: half a batch is not the send the user is asking
            // to repeat.
            return !paths.isEmpty && paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
        }
    }
}
