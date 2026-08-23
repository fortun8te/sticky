import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO

// MARK: - The model

/// What a clip actually *is*.
///
/// Sticky's clipboard is not a string box. A paragraph copied out of Pages, a
/// screenshot and a file each carry something that makes them useful, and a
/// portal that flattens all three to `String` throws that away at the door.
enum StickyClipKind: String, Codable {
    case text
    case richText
    case image
    case file
}

/// One clip in Sticky's own clipboard.
///
/// Deliberately a value type with no live pasteboard handle: a clip is a
/// snapshot taken at an explicit moment, not a window onto whatever the system
/// pasteboard happens to hold now.
struct StickyClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: StickyClipKind
    let createdAt: Date
    /// Which machine it arrived from. `nil` means this Mac.
    let sender: String?
    /// A pinned clip is never evicted by the size cap.
    var pinned: Bool
    /// One flattened line, built once at capture so no view re-derives it.
    let preview: String
    /// Bytes, only where the number means something to a person.
    let byteSize: Int?

    /// The plain-text fallback.
    ///
    /// Real content for `.text` and `.richText`. For `.image` and `.file` it is
    /// a *label* — never content — so a text-only caller (the v1 wire format,
    /// the control API) cannot silently ship the wrong thing.
    let plainText: String?
    let rtfData: Data?
    let htmlString: String?
    /// Image bytes live beside the index, not inside it — see `blobURL`.
    let imageBlobName: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let filePaths: [String]
    /// Content identity. Two clips with the same fingerprint are the same clip.
    let fingerprint: String

    var fileURLs: [URL] { filePaths.map { URL(fileURLWithPath: $0) } }

    var pixelSize: CGSize? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    /// True when the clip's own content can travel over the v1 text channel.
    /// An image's label is not its content, which is why this is not just
    /// `plainText != nil`.
    var carriesText: Bool { kind == .text || kind == .richText }

    /// Plan §10.5: one glyph per kind, nothing decorative.
    var symbolName: String {
        switch kind {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var kindLabel: String {
        switch kind {
        case .text: return "Text"
        case .richText: return "Formatted text"
        case .image: return "Image"
        case .file: return filePaths.count > 1 ? "\(filePaths.count) files" : "File"
        }
    }
}

extension StickyClipItem {
    /// The shape the rest of the app already speaks. Same `id`, so a legacy
    /// call (`delete(entry:)`, `promoteToSystemClipboard(entry:)`) still
    /// resolves back to the typed clip it came from.
    var legacyEntry: StickyClipEntry {
        StickyClipEntry(id: id, text: plainText ?? preview, timestamp: createdAt, sender: sender)
    }
}

/// What sending a clip to the PC actually consists of. The service decides;
/// the app layer, which owns the peer and the queue, performs it.
enum StickyClipSendPayload {
    case text(String)
    case files([URL])
}

// MARK: - The service

/// Sticky's private clipboard.
///
/// It lives *alongside* `NSPasteboard.general` and never replaces it. Nothing
/// here polls, and nothing here writes to the system pasteboard unless a
/// person asked for exactly that — `takeFromSystemClipboard()` in, and
/// `copyToSystemClipboard(_:)` out. Both are one-shot, both are user-initiated.
///
/// All mutating members must be called on the main thread: the published state
/// drives SwiftUI directly, and `receiveRemote` is the one entry point that
/// hops for you because it is called from the network queue.
final class ClipboardService: ObservableObject {
    /// The private clipboard itself, newest first.
    @Published private(set) var items: [StickyClipItem] = []
    /// The clip the portal is currently holding — the last one taken, received
    /// or handed back out. It is a spotlight on the history, not a second store.
    @Published private(set) var stickyItem: StickyClipItem?
    @Published var lastError: String?

    /// 50 clips.
    ///
    /// Chosen against two ceilings rather than picked for roundness. Human: the
    /// list is scanned, not searched, and past ~50 rows nobody scrolls — they
    /// re-copy. Machine: 50 index entries stay a sub-100 KB JSON file that can
    /// be rewritten synchronously on every insert without a visible hitch,
    /// because the heavy payload (images) is out in blobs. Pinned clips sit
    /// outside the cap; a pin is the user saying "this one does not age out".
    private let maxEntries = 50

    /// Guards on what may be held. Text and RTF live inline in the index, so
    /// they are the ones that could bloat it.
    private static let maxInlineTextBytes = 512 * 1024
    private static let maxImageBytes = 32 * 1024 * 1024
    private static let maxFilePaths = 32

    /// Markers other apps use to say "do not sync/store this": password
    /// managers mark copies concealed, and transient/auto-generated copies are
    /// never meant to leave the machine. Honoured on the explicit take path
    /// too — the user asking for a clip is not the password manager agreeing.
    private static let optOutTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    private static let portalV2Key = "sticky.privateClipboardPortal.v2"

    init() {
        // Versions before the private-portal redesign copied ordinary system
        // clipboard contents into the old file. That content was never Sticky's
        // to keep, so it is discarded rather than migrated; only a history that
        // was already private-portal content is carried forward.
        let legacyIsPortalContent = UserDefaults.standard.bool(forKey: Self.portalV2Key)
        load(importingLegacy: legacyIsPortalContent)
        UserDefaults.standard.set(true, forKey: Self.portalV2Key)
    }

    // MARK: Legacy bridge
    //
    // `StickyClipEntry` is a flat text row and lives in NotchViewModel. It stays
    // the app's lingua franca; these two derive it from the typed store so no
    // existing call site had to move.

    var history: [StickyClipEntry] { items.map(\.legacyEntry) }
    var stickySlot: StickyClipEntry? { stickyItem?.legacyEntry }

    /// Resolve a flat row back to the typed clip it was derived from, so a
    /// legacy call site can reach the flavours the row does not carry.
    func item(for entry: StickyClipEntry) -> StickyClipItem? {
        items.first { $0.id == entry.id }
    }

    /// Sticky is an app-owned clipboard portal. It never observes the system
    /// clipboard, so password managers, dictation tools, and other clipboard
    /// apps stay entirely outside its history. Kept as no-ops because the app
    /// layer still calls them on launch and teardown.
    func start(onTextPushed: @escaping (String) -> Void = { _ in }) {}

    func stop() {}

    // MARK: Explicit movement in

    /// Read `NSPasteboard.general` once, right now, because someone asked.
    ///
    /// Captures the richest representation present rather than `.string`: a
    /// Finder copy comes in as files, a screenshot as PNG, a Pages selection as
    /// RTF/HTML *with* its plain-text fallback.
    @discardableResult
    func takeFromSystemClipboard() -> StickyClipItem? {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")
        let pasteboard = NSPasteboard.general

        let declaredTypes = pasteboard.types?.map(\.rawValue) ?? []
        guard !declaredTypes.contains(where: { Self.optOutTypes.contains($0) }) else {
            lastError = "That copy is marked private by the app that made it."
            return nil
        }

        guard let capture = capture(from: pasteboard) else {
            lastError = "Nothing on the clipboard that Sticky can hold."
            return nil
        }

        // The blob has to exist before the item that references it does,
        // otherwise a crash between the two leaves a row that can never draw.
        if let payload = capture.imagePayload, let name = capture.item.imageBlobName {
            guard writeBlob(payload, named: name) else {
                lastError = "The image could not be saved to Sticky's clipboard."
                return nil
            }
        }

        let stored = insert(capture.item)
        stickyItem = stored
        lastError = nil
        return stored
    }

    /// A clip arriving from the paired machine. Called off the main thread by
    /// the transfer layer, so it hops itself.
    func receiveRemote(text: String, senderName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let item = Self.textItem(text: text, sender: senderName)
            self.stickyItem = self.insert(item)
        }
    }

    /// A local text clip written straight into the portal (the Slot, the
    /// control API). Never touches the system pasteboard.
    @discardableResult
    func writeSticky(text: String) -> StickyClipEntry {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")
        let stored = insert(Self.textItem(text: text, sender: nil))
        stickyItem = stored
        return stored.legacyEntry
    }

    func addToHistory(_ entry: StickyClipEntry) {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")
        insert(Self.textItem(text: entry.text, sender: entry.sender, id: entry.id, createdAt: entry.timestamp))
    }

    // MARK: Explicit movement out

    /// Hand a clip back to `NSPasteboard.general`, restoring every flavour it
    /// was captured with. This is the only place Sticky writes to the system
    /// pasteboard, and only ever because someone clicked.
    @discardableResult
    func copyToSystemClipboard(_ item: StickyClipItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var written = false
        switch item.kind {
        case .file:
            let existing = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            written = !existing.isEmpty && pasteboard.writeObjects(existing as [NSURL])

        case .image:
            if let data = imageData(for: item) {
                let entry = NSPasteboardItem()
                entry.setData(data, forType: .png)
                // Plenty of older editors still ask for TIFF first and take
                // nothing if it is absent.
                if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
                    entry.setData(tiff, forType: .tiff)
                }
                written = pasteboard.writeObjects([entry])
            }

        case .text, .richText:
            let entry = NSPasteboardItem()
            // Richest first: a receiving app takes the first type it recognises,
            // so Pages has to meet RTF before it meets the plain fallback, while
            // a plain text field still finds `.string` further down the same item.
            if let rtf = item.rtfData { entry.setData(rtf, forType: .rtf) }
            if let html = item.htmlString { entry.setString(html, forType: .html) }
            if let text = item.plainText { entry.setString(text, forType: .string) }
            written = pasteboard.writeObjects([entry])
        }

        onMain { [weak self] in
            guard let self else { return }
            if written {
                self.stickyItem = item
                self.lastError = nil
            } else {
                self.lastError = "macOS would not accept that clip."
            }
        }
        return written
    }

    /// Legacy entry point. Resolves back to the typed clip so a formatted clip
    /// keeps its formatting even when the caller only had a text row.
    func promoteToSystemClipboard(_ entry: StickyClipEntry) {
        if let item = items.first(where: { $0.id == entry.id }) {
            copyToSystemClipboard(item)
            return
        }

        // An entry we no longer hold — a caller's own copy. Its text is all
        // there is to give back.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let promoted = pasteboard.setString(entry.text, forType: .string)
        onMain { [weak self] in
            guard let self else { return }
            if !promoted { self.lastError = "macOS rejected the clipboard promotion." }
        }
    }

    /// What the app layer should actually send for this clip. The service knows
    /// the shape; the app layer owns the peer, the queue and the failure UI.
    func sendPayload(for item: StickyClipItem) -> StickyClipSendPayload? {
        switch item.kind {
        case .text, .richText:
            // v1 wire format carries plain text only — the RTF/HTML flavours
            // stay on this machine until the envelope can describe them.
            guard let text = item.plainText, !text.isEmpty else { return nil }
            return .text(text)

        case .image:
            guard let url = exportForSending(item) else { return nil }
            return .files([url])

        case .file:
            let existing = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            return existing.isEmpty ? nil : .files(existing)
        }
    }

    // MARK: History management

    func togglePin(_ item: StickyClipItem) {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        if stickyItem?.id == item.id { stickyItem = items[index] }
        evictIfNeeded()
        persist()
    }

    func delete(_ item: StickyClipItem) {
        delete(id: item.id)
    }

    func delete(_ entry: StickyClipEntry) {
        delete(id: entry.id)
    }

    private func delete(id: UUID) {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")
        items.removeAll { $0.id == id }
        if stickyItem?.id == id { stickyItem = items.first }
        persist()
    }

    /// Clears everything, pinned included: it is a destructive action the user
    /// asked for by name, and a "Clear" that quietly leaves rows behind is worse
    /// than one that does what it says.
    func clearHistory() {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")
        items.removeAll()
        stickyItem = nil
        persist()
    }

    // MARK: Image payloads

    func imageURL(for item: StickyClipItem) -> URL? {
        guard let name = item.imageBlobName else { return nil }
        let url = Self.blobDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func imageData(for item: StickyClipItem) -> Data? {
        guard let url = imageURL(for: item) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// A thumbnail without decoding the full image — a 40-megapixel screenshot
    /// must not be unpacked at full size to fill a 34 pt square (same rule the
    /// shelf's `ThumbnailService` follows).
    static func thumbnail(atPath path: String, side: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(side, 1) * 2)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Stage an image clip as a real file so it can travel the existing file
    /// channel. Staged in the temp directory, not the blob store, because the
    /// send path may outlive the clip.
    private func exportForSending(_ item: StickyClipItem) -> URL? {
        guard let data = imageData(for: item) else { return nil }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Sticky-clips", isDirectory: true)
        let url = directory.appendingPathComponent("\(item.id.uuidString).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            onMain { [weak self] in self?.lastError = "The image could not be prepared for sending." }
            return nil
        }
    }

    // MARK: Capture

    private struct Capture {
        let item: StickyClipItem
        let imagePayload: Data?
    }

    private func capture(from pasteboard: NSPasteboard) -> Capture? {
        let now = Date()

        // Files first: a Finder copy also carries an icon image, and the icon is
        // not what the user copied.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let paths = urls.prefix(Self.maxFilePaths).map(\.path)
            let total = paths.reduce(into: 0) { running, path in
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
                running += values?.fileSize ?? 0
            }
            let name = paths.count == 1
                ? URL(fileURLWithPath: paths[0]).lastPathComponent
                : "\(paths.count) files"
            let item = StickyClipItem(
                id: UUID(),
                kind: .file,
                createdAt: now,
                sender: nil,
                pinned: false,
                preview: name,
                byteSize: total > 0 ? total : nil,
                plainText: paths.joined(separator: "\n"),
                rtfData: nil,
                htmlString: nil,
                imageBlobName: nil,
                pixelWidth: nil,
                pixelHeight: nil,
                filePaths: paths,
                fingerprint: Self.fingerprint(kind: .file, payload: Data(paths.sorted().joined(separator: "\u{1F}").utf8))
            )
            return Capture(item: item, imagePayload: nil)
        }

        if let png = Self.pngData(from: pasteboard) {
            guard png.count <= Self.maxImageBytes else {
                lastError = "That image is too large for Sticky's clipboard."
                return nil
            }
            let representation = NSBitmapImageRep(data: png)
            let width = representation?.pixelsWide
            let height = representation?.pixelsHigh
            let dimensions = (width.map(String.init) ?? "?") + " × " + (height.map(String.init) ?? "?")
            let id = UUID()
            let item = StickyClipItem(
                id: id,
                kind: .image,
                createdAt: now,
                sender: nil,
                pinned: false,
                preview: "Image \(dimensions)",
                byteSize: png.count,
                // A label, not content: nothing may mistake this for the image.
                plainText: nil,
                rtfData: nil,
                htmlString: nil,
                imageBlobName: "\(id.uuidString).png",
                pixelWidth: width,
                pixelHeight: height,
                filePaths: [],
                fingerprint: Self.fingerprint(kind: .image, payload: png)
            )
            return Capture(item: item, imagePayload: png)
        }

        let rtf = pasteboard.data(forType: .rtf)
        let html = pasteboard.string(forType: .html)
        var plain = pasteboard.string(forType: .string)

        // An RTF-only copy still needs a fallback, or pasting it into a plain
        // text field later would produce nothing.
        if plain == nil, let rtf, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            plain = attributed.string
        }

        guard let text = plain, !text.isEmpty else { return nil }
        guard Data(text.utf8).count <= Self.maxInlineTextBytes else {
            lastError = "That text is too large for Sticky's clipboard."
            return nil
        }

        // Oversized markup is dropped rather than refused: the plain fallback is
        // still a perfectly good clip, and the index stays small.
        let keptRTF = rtf.flatMap { $0.count <= Self.maxInlineTextBytes ? $0 : nil }
        let keptHTML = html.flatMap { Data($0.utf8).count <= Self.maxInlineTextBytes ? $0 : nil }
        let isRich = keptRTF != nil || keptHTML != nil

        var payload = Data(text.utf8)
        if let keptRTF { payload.append(keptRTF) }
        if let keptHTML { payload.append(Data(keptHTML.utf8)) }

        let item = StickyClipItem(
            id: UUID(),
            kind: isRich ? .richText : .text,
            createdAt: now,
            sender: nil,
            pinned: false,
            preview: Self.preview(for: text),
            byteSize: payload.count,
            plainText: text,
            rtfData: keptRTF,
            htmlString: keptHTML,
            imageBlobName: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            filePaths: [],
            fingerprint: Self.fingerprint(kind: isRich ? .richText : .text, payload: payload)
        )
        return Capture(item: item, imagePayload: nil)
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        // Normalise everything else to PNG so the store has one image format and
        // the Windows side one thing to decode.
        if let tiff = pasteboard.data(forType: .tiff),
           let representation = NSBitmapImageRep(data: tiff) {
            return representation.representation(using: .png, properties: [:])
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let representation = NSBitmapImageRep(data: tiff) {
            return representation.representation(using: .png, properties: [:])
        }
        return nil
    }

    private static func textItem(
        text: String,
        sender: String?,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> StickyClipItem {
        StickyClipItem(
            id: id,
            kind: .text,
            createdAt: createdAt,
            sender: sender,
            pinned: false,
            preview: preview(for: text),
            byteSize: Data(text.utf8).count,
            plainText: text,
            rtfData: nil,
            htmlString: nil,
            imageBlobName: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            filePaths: [],
            fingerprint: fingerprint(kind: .text, payload: Data(text.utf8))
        )
    }

    /// A preview reads from the front, so it loses its tail. Newlines collapse:
    /// a row is one line high and a wrapped snippet would push the list around.
    private static func preview(for text: String, limit: Int = 90) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    // MARK: Insertion

    @discardableResult
    private func insert(_ candidate: StickyClipItem) -> StickyClipItem {
        assert(Thread.isMainThread, "Clipboard state must be updated on the main thread")

        if let existingIndex = items.firstIndex(where: { $0.id == candidate.id }) {
            items.remove(at: existingIndex)
            items.insert(candidate, at: 0)
            persist()
            return candidate
        }

        // Same content twice is one clip that moved back to the top, not two
        // rows. A pin already on it survives — the user pinned the content.
        if let duplicateIndex = items.firstIndex(where: { $0.fingerprint == candidate.fingerprint }) {
            let existing = items[duplicateIndex]
            let refreshed = StickyClipItem(
                id: existing.id,
                kind: candidate.kind,
                createdAt: candidate.createdAt,
                sender: candidate.sender ?? existing.sender,
                pinned: existing.pinned,
                preview: candidate.preview,
                byteSize: candidate.byteSize,
                plainText: candidate.plainText,
                rtfData: candidate.rtfData,
                htmlString: candidate.htmlString,
                // Keep the blob that is already on disk; the freshly written one
                // is unreferenced and `persist()` prunes it.
                imageBlobName: existing.imageBlobName ?? candidate.imageBlobName,
                pixelWidth: candidate.pixelWidth,
                pixelHeight: candidate.pixelHeight,
                filePaths: candidate.filePaths,
                fingerprint: candidate.fingerprint
            )
            items.remove(at: duplicateIndex)
            items.insert(refreshed, at: 0)
            persist()
            return refreshed
        }

        items.insert(candidate, at: 0)
        evictIfNeeded()
        persist()
        return candidate
    }

    /// Evicts oldest-first and skips pinned clips. If every clip is pinned the
    /// list is allowed to exceed the cap: dropping something the user explicitly
    /// held on to would be the worse failure.
    private func evictIfNeeded() {
        var overflow = items.count - maxEntries
        guard overflow > 0 else { return }
        for index in items.indices.reversed() where overflow > 0 {
            guard !items[index].pinned else { continue }
            items.remove(at: index)
            overflow -= 1
        }
    }

    // MARK: Persistence

    private struct StoredHistory: Codable {
        let version: Int
        let items: [StickyClipItem]
    }

    private static let storeVersion = 3

    private func load(importingLegacy: Bool) {
        let url = Self.storageURL

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let stored = try JSONDecoder().decode(StoredHistory.self, from: Data(contentsOf: url))
                // A row whose blob went missing (interrupted write, hand-cleared
                // cache) can never draw itself, so it is not restored.
                items = stored.items.filter { item in
                    guard let name = item.imageBlobName else { return true }
                    return FileManager.default.fileExists(
                        atPath: Self.blobDirectory.appendingPathComponent(name).path
                    )
                }
                evictIfNeeded()
                stickyItem = items.first
            } catch {
                quarantine(url)
            }
        } else if importingLegacy {
            importLegacyHistory()
        }

        // The legacy file is superseded either way; leaving a plaintext copy of
        // past clips on disk would be the one thing this rewrite is against.
        try? FileManager.default.removeItem(at: Self.legacyStorageURL)
    }

    private func importLegacyHistory() {
        let url = Self.legacyStorageURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([StickyClipEntry].self, from: data) else { return }

        items = entries.map {
            Self.textItem(text: $0.text, sender: $0.sender, id: $0.id, createdAt: $0.timestamp)
        }
        evictIfNeeded()
        stickyItem = items.first
        persist()
    }

    private func quarantine(_ url: URL) {
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("corrupted-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: url, to: backupURL)
            lastError = "Saved clipboard history was damaged; it was moved aside."
        } catch {
            lastError = "Saved clipboard history could not be loaded."
        }
    }

    private func persist() {
        do {
            let directory = Self.storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoredHistory(version: Self.storeVersion, items: items))
            try data.write(to: Self.storageURL, options: [.atomic])
            // History can hold whatever the user copied, so it stays readable by
            // this account only. An atomic write replaces the inode, so the mode
            // has to be re-applied after every save. The folder keeps its execute
            // bit — without it nothing inside could be opened again.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storageURL.path)
            lastError = nil
        } catch {
            lastError = "Clipboard history could not be saved."
        }
        pruneBlobs()
    }

    /// Blobs are owned by the index. Anything the index no longer names is an
    /// evicted, deleted or deduplicated image, and it goes now rather than
    /// living on as an orphaned copy of something the user deleted.
    private func pruneBlobs() {
        let directory = Self.blobDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let referenced = Set(items.compactMap(\.imageBlobName))
        for name in names where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func writeBlob(_ data: Data, named name: String) -> Bool {
        let directory = Self.blobDirectory
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func fingerprint(kind: StickyClipKind, payload: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: payload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var supportDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport.appendingPathComponent("Sticky", isDirectory: true)
    }

    private static var storageURL: URL {
        supportDirectory.appendingPathComponent("clipboard-items.json")
    }

    /// The flat text-only file written by every build before this one.
    private static var legacyStorageURL: URL {
        supportDirectory.appendingPathComponent("clipboard-history.json")
    }

    private static var blobDirectory: URL {
        supportDirectory.appendingPathComponent("clipboard-blobs", isDirectory: true)
    }
}
