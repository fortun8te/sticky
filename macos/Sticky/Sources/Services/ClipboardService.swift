import AppKit
import Combine
import CryptoKit
import Foundation

final class ClipboardService: ObservableObject {
    @Published var history: [StickyClipEntry] = []
    @Published var stickySlot: StickyClipEntry?
    @Published var lastError: String?

    private let maxEntries = 20

    init() {
        loadHistory()
        // Versions before the private-portal redesign copied ordinary system
        // clipboard contents into this file. Remove that legacy cache once so
        // no past password-manager or dictation text remains in Sticky.
        if !UserDefaults.standard.bool(forKey: "sticky.privateClipboardPortal.v2") {
            clearHistory()
            UserDefaults.standard.set(true, forKey: "sticky.privateClipboardPortal.v2")
        }
    }

    // Sticky is an app-owned clipboard portal. It never observes the system
    // clipboard, so password managers, dictation tools, and other clipboard
    // apps stay entirely outside its history.
    func start(onTextPushed: @escaping (String) -> Void = { _ in }) {}

    func stop() {}

    func addToHistory(_ entry: StickyClipEntry) {
        insert(entry, sender: entry.sender)
    }

    func receiveRemote(text: String, senderName: String) {
        let entry = StickyClipEntry(id: UUID(), text: text, timestamp: Date(), sender: senderName)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let storedEntry = self.insert(entry, sender: senderName)
            self.stickySlot = storedEntry
        }
    }

    @discardableResult
    func writeSticky(text: String) -> StickyClipEntry {
        let entry = StickyClipEntry(id: UUID(), text: text, timestamp: Date(), sender: nil)
        let stored = insert(entry, sender: nil)
        stickySlot = stored
        return stored
    }

    func promoteToSystemClipboard(_ entry: StickyClipEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let promoted = pasteboard.setString(entry.text, forType: .string)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !promoted {
                self.lastError = "macOS rejected the clipboard promotion."
            }
            self.stickySlot = entry
        }
    }

    func delete(_ entry: StickyClipEntry) {
        history.removeAll { $0.id == entry.id }
        if stickySlot?.id == entry.id {
            stickySlot = history.first
        }
        persist()
    }

    func clearHistory() {
        history.removeAll()
        stickySlot = nil
        persist()
    }

    @discardableResult
    private func insert(
        _ candidate: StickyClipEntry,
        sender: String?,
        completion: ((StickyClipEntry) -> Void)? = nil
    ) -> StickyClipEntry {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")

        if let existingIndex = history.firstIndex(where: { $0.id == candidate.id }) {
            history.remove(at: existingIndex)
            history.insert(candidate, at: 0)
            persist()
            completion?(candidate)
            return candidate
        }

        let fingerprint = Self.fingerprint(for: candidate.text)
        if let duplicateIndex = history.firstIndex(where: {
            Self.fingerprint(for: $0.text) == fingerprint
        }) {
            let existing = history[duplicateIndex]
            let refreshed = StickyClipEntry(
                id: existing.id,
                text: existing.text,
                timestamp: candidate.timestamp,
                sender: sender
            )
            history.remove(at: duplicateIndex)
            history.insert(refreshed, at: 0)
            persist()
            completion?(refreshed)
            return refreshed
        }

        history.insert(candidate, at: 0)
        if history.count > maxEntries {
            history.removeLast(history.count - maxEntries)
        }
        persist()
        completion?(candidate)
        return candidate
    }

    private func loadHistory() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            history = try JSONDecoder().decode([StickyClipEntry].self, from: data)
            if history.count > maxEntries {
                history.removeLast(history.count - maxEntries)
            }
            stickySlot = history.first
        } catch {
            let backupURL = url.deletingPathExtension()
                .appendingPathExtension("corrupted-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: url, to: backupURL)
                lastError = "Saved clipboard history was damaged; it was moved aside."
            } catch {
                lastError = "Saved clipboard history could not be loaded."
            }
        }
    }

    private func persist() {
        do {
            let directory = Self.storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history)
            try data.write(to: Self.storageURL, options: [.atomic])
            lastError = nil
        } catch {
            lastError = "Clipboard history could not be saved."
        }
    }

    private static func fingerprint(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static var storageURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("Sticky", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }
}
