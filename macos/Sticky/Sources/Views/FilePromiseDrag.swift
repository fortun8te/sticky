import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Vends the shelf's files to whoever the user drags them onto (plan F-4).
///
/// A promise rather than a plain file URL because the receiver — Finder, Mail,
/// an upload field — decides where the file lands and when it is needed.
final class ShelfFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    /// `NSFilePromiseProvider` does not retain its delegate, and the row that
    /// started the drag may be gone before the copy runs. One shared, stateless
    /// delegate outlives every drag; the file to copy rides in `userInfo`.
    static let shared = ShelfFilePromiseDelegate()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.sticky.file-promise-out"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private override init() { super.init() }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider.userInfo as? URL)?.lastPathComponent ?? "Sticky item"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let source = filePromiseProvider.userInfo as? URL else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        do {
            // The destination is created for us and copyItem refuses to
            // overwrite — clear it first or every second drop fails.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// The copy runs here, so a large file never blocks the main thread while
    /// the drop animation is still playing.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

/// Transparent grab handle that turns a press-and-move into a real drag out.
final class FilePromiseDragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var preview: NSImage?
    var onHoverChange: ((Bool) -> Void)?
    /// A press that never became a drag is still a click, and this view is on
    /// top of the whole chip — so it has to hand back what it didn't use, or
    /// tapping a chip silently does nothing.
    var onClick: (() -> Void)?
    var menuItems: [(title: String, destructive: Bool, action: () -> Void)] = []

    private var pressOrigin: NSPoint?
    private var didDrag = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// Sticky's panel is non-activating, so a drag has to be able to start
    /// while the app is not frontmost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// No file, no handle: the view stops hit-testing and the row behaves
    /// exactly as it would without it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        url == nil ? nil : super.hitTest(point)
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

    override func mouseDown(with event: NSEvent) {
        pressOrigin = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil; didDrag = false }
        guard !didDrag, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// SwiftUI's `.contextMenu` never sees the right-click either, so the menu
    /// is built here from the same actions the chip declares.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for item in menuItems {
            if item.title == "-" {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = MenuAction(run: item.action)
            menu.addItem(entry)
        }
        return menu
    }

    private final class MenuAction {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url, let origin = pressOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        // Under the threshold this is still a click, not a drag.
        guard hypot(current.x - origin.x, current.y - origin.y) > 3 else { return }
        pressOrigin = nil
        didDrag = true

        let fileType = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: ShelfFilePromiseDelegate.shared)
        provider.userInfo = url

        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: preview ?? NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

struct FilePromiseDragHandle: NSViewRepresentable {
    let url: URL?
    var preview: NSImage?
    var onHoverChange: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var menuItems: [(title: String, destructive: Bool, action: () -> Void)] = []

    func makeNSView(context: Context) -> FilePromiseDragSourceView {
        let view = FilePromiseDragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragSourceView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: FilePromiseDragSourceView) {
        view.url = url
        view.preview = preview
        view.onHoverChange = { hovering in onHoverChange(hovering) }
        view.onClick = { onClick() }
        view.menuItems = menuItems
    }
}

extension View {
    /// Makes this view the grab handle for dragging `url` out of Sticky.
    func filePromiseDraggable(
        _ url: URL?,
        preview: NSImage? = nil,
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        onClick: @escaping () -> Void = {},
        menuItems: [(title: String, destructive: Bool, action: () -> Void)] = []
    ) -> some View {
        overlay(FilePromiseDragHandle(
            url: url,
            preview: preview,
            onHoverChange: onHoverChange,
            onClick: onClick,
            menuItems: menuItems
        ))
    }
}
