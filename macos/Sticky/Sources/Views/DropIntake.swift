import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Errors

enum DropIntakeError: LocalizedError {
    case nothingUsable
    case stagingUnavailable(String)
    case promiseFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingUsable:              return "Nothing droppable in that drag"
        case .stagingUnavailable(let r):  return "Couldn't make room for the drop · \(r)"
        case .promiseFailed(let r):       return "The sender never delivered the file · \(r)"
        }
    }
}

// MARK: - Promise receipt

/// One in-flight `NSFilePromiseReceiver` fulfilment.
///
/// `receivePromisedFiles` is fired synchronously from `performDragOperation`
/// (the dragging pasteboard is only valid there) and returns at once; the bytes
/// land later on `queue`. Awaiting `value` blocks a Task, never the main thread.
final class PromiseReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [URL] = []
    private var failure: Error?
    private var outstanding: Int
    private var waiter: CheckedContinuation<[URL], Error>?
    private var settled = false

    init(receiver: NSFilePromiseReceiver, destination: URL, queue: OperationQueue) {
        // One receiver can promise several files; `fileNames` is how many
        // callbacks to expect, since the API has no completion of its own.
        outstanding = max(receiver.fileNames.count, 1)
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { [weak self] url, error in
            self?.record(url: url, error: error)
        }
    }

    var value: [URL] {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if settled {
                    let outcome = result()
                    lock.unlock()
                    continuation.resume(with: outcome)
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func record(url: URL, error: Error?) {
        lock.lock()
        if let error { failure = failure ?? error } else { received.append(url) }
        outstanding -= 1
        guard !settled, outstanding <= 0 || failure != nil else {
            lock.unlock()
            return
        }
        settled = true
        let outcome = result()
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(with: outcome)
    }

    /// Caller holds `lock`.
    private func result() -> Result<[URL], Error> {
        if let failure { return .failure(DropIntakeError.promiseFailed(failure.localizedDescription)) }
        return .success(received)
    }
}

// MARK: - In-flight drop

/// A drag that has been read off the pasteboard and is on its way to disk.
final class InFlightDrop: @unchecked Sendable {
    fileprivate enum Source {
        case existing(URL)
        case promise(PromiseReceipt)
        case imageData(Data, UTType, String)
        case text(String, String)
    }

    private let sources: [Source]
    private let staging: URL?

    fileprivate init(sources: [Source], staging: URL?) {
        self.sources = sources
        self.staging = staging
    }

    /// Resolves every source to a real file. Runs entirely off the main actor.
    func finish() async throws -> [URL] {
        var urls: [URL] = []
        var firstFailure: Error?

        for source in sources {
            do {
                switch source {
                case .existing(let url):
                    urls.append(url)
                case .promise(let receipt):
                    urls.append(contentsOf: try await receipt.value)
                case .imageData(let data, let type, let name):
                    guard let staging else { throw DropIntakeError.nothingUsable }
                    urls.append(try DropIntake.writeImage(data, type: type, name: name, into: staging))
                case .text(let text, let name):
                    guard let staging else { throw DropIntakeError.nothingUsable }
                    urls.append(try DropIntake.writeText(text, name: name, into: staging))
                }
            } catch {
                firstFailure = firstFailure ?? error
            }
        }

        if urls.isEmpty {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            throw firstFailure ?? DropIntakeError.nothingUsable
        }
        return urls
    }

    func discard() {
        guard let staging else { return }
        try? FileManager.default.removeItem(at: staging)
    }
}

// MARK: - Intake

enum DropIntake {
    /// Everything here touches the dragging pasteboard, so it must run
    /// synchronously inside `performDragOperation`.
    @MainActor
    static func begin(_ info: NSDraggingInfo, in view: NSView) throws -> InFlightDrop {
        var byIndex: [Int: InFlightDrop.Source] = [:]
        var receivers: [Int: NSFilePromiseReceiver] = [:]

        info.enumerateDraggingItems(
            options: [],
            for: view,
            classes: [NSFilePromiseReceiver.self, NSURL.self],
            searchOptions: [.urlReadingFileURLsOnly: true]
        ) { item, index, _ in
            switch item.item {
            case let receiver as NSFilePromiseReceiver: receivers[index] = receiver
            case let url as NSURL:                      byIndex[index] = .existing(url as URL)
            default:                                    break
            }
        }

        // Real file URLs are used where they lie; only promises and raw
        // pasteboard bytes need somewhere to land.
        let needsStaging = !receivers.isEmpty || byIndex.isEmpty
        let staging = needsStaging ? try stagingDirectory() : nil

        if let staging, !receivers.isEmpty {
            let queue = receiveQueue()
            for (index, receiver) in receivers {
                byIndex[index] = .promise(PromiseReceipt(receiver: receiver, destination: staging, queue: queue))
            }
        }

        if byIndex.isEmpty, let staging {
            if let raw = rawPayload(from: info.draggingPasteboard) {
                byIndex[0] = raw
            } else {
                try? FileManager.default.removeItem(at: staging)
                throw DropIntakeError.nothingUsable
            }
        }

        guard !byIndex.isEmpty else { throw DropIntakeError.nothingUsable }
        purgeStaleStagedDrops()
        return InFlightDrop(sources: byIndex.sorted { $0.key < $1.key }.map(\.value), staging: staging)
    }

    /// Dragging an image out of a browser, or a run of selected text: no URL,
    /// no promise, just bytes we have to name ourselves.
    private static func rawPayload(from pasteboard: NSPasteboard) -> InFlightDrop.Source? {
        let name = suggestedName(from: pasteboard)
        if let data = pasteboard.data(forType: .png) {
            return .imageData(data, .png, name ?? "Dropped image")
        }
        if let data = pasteboard.data(forType: .tiff) {
            return .imageData(data, .tiff, name ?? "Dropped image")
        }
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text, name ?? firstLineName(of: text))
        }
        return nil
    }

    private static func suggestedName(from pasteboard: NSPasteboard) -> String? {
        if let title = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name")), !title.isEmpty {
            return sanitised(title)
        }
        guard let string = pasteboard.string(forType: .URL), let url = URL(string: string) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : sanitised(stem)
    }

    private static func firstLineName(of text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return sanitised(line.isEmpty ? "Dropped text" : String(line.prefix(40)))
    }

    private static func sanitised(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Dropped item" : cleaned
    }

    fileprivate static func writeImage(_ data: Data, type: UTType, name: String, into directory: URL) throws -> URL {
        // TIFF off the pasteboard is enormous and awkward on the PC side —
        // re-encode to PNG, which is what the user thinks they dragged anyway.
        var payload = data
        var ext = type.preferredFilenameExtension ?? "png"
        if type == .tiff, let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            payload = png
            ext = "png"
        }
        let target = uniqueURL(name: name, ext: ext, in: directory)
        try payload.write(to: target, options: .atomic)
        return target
    }

    fileprivate static func writeText(_ text: String, name: String, into directory: URL) throws -> URL {
        let target = uniqueURL(name: name, ext: "txt", in: directory)
        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    private static func uniqueURL(name: String, ext: String, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(name).appendingPathExtension(ext)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        return directory
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))")
            .appendingPathExtension(ext)
    }

    private static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("StickyDroppedItems", isDirectory: true)

    private static func stagingDirectory() throws -> URL {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DropIntakeError.stagingUnavailable(error.localizedDescription)
        }
        return directory
    }

    private static func receiveQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.sticky.file-promise-intake"
        queue.qualityOfService = .userInitiated
        return queue
    }

    /// Staged files can't be deleted the moment the shelf takes them — the
    /// shelf may hold them for hours waiting for the PC. They are swept by age.
    static func purgeStaleStagedDrops(olderThan age: TimeInterval = 24 * 60 * 60) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

// MARK: - The sensor view

/// The notch's one live surface: hover, click and drag.
///
/// This is a plain AppKit view rather than SwiftUI's `.onDrop` for two measured
/// reasons. First, `NSFilePromiseReceiver` is only reachable through
/// `NSDraggingInfo`, and without it every drag from the screenshot thumbnail,
/// Photos, Mail or a browser is silently swallowed. Second, SwiftUI's `.onDrop`
/// needs a `Color.black.opacity(0.001)` fill to receive drags at all — a truly
/// clear view gets nothing, verified on this OS.
final class NotchSensorView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragMove: ((CGPoint) -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: ((NSDraggingInfo, NSView) -> Bool)?
    /// ⌥-click sends whatever is on the clipboard straight to the PC, so text
    /// never requires opening the shelf. A modifier on a mouse event is not
    /// keyboard capture — the app still never becomes key at idle.
    var onOptionTap: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// A sub-rect of this view that means something other than "open the
    /// shelf". Nil whenever no such action is on offer.
    var actionRegion: (() -> CGRect?)?
    var onActionTap: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    /// SwiftUI measures from the top-left; matching that keeps the existing
    /// drop-magnetism maths unchanged.
    override var isFlipped: Bool { true }

    /// The panel never becomes key on hover, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let acceptedTypes: [NSPasteboard.PasteboardType] = {
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }
        types.append(contentsOf: [.fileURL, .png, .tiff, .string, .URL])
        return types
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(NotchSensorView.acceptedTypes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    /// Swallowed so the panel cannot start a window drag underneath us.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.modifierFlags.contains(.option) {
            onOptionTap?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let region = actionRegion?(), region.contains(point) {
            onActionTap?()
            return
        }
        onTap?()
    }

    /// Right-click is the discoverable path to the same actions — nobody finds
    /// a modifier click on their own.
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        onDragEnter?()
        onDragMove?(convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        onDragMove?(convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canAccept(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender, self) ?? false
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.canReadObject(
            forClasses: [NSFilePromiseReceiver.self, NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) { return true }
        return pasteboard.availableType(from: [.png, .tiff, .string]) != nil
    }
}
