import AppKit
import SwiftUI

/// A normal, closable utility panel that hosts the visible shelf. It never
/// steals focus on launch and can be reopened from the menu bar or notch.
@MainActor
final class ShelfWindowController {
    static let shared = ShelfWindowController()

    private var window: NSWindow?
    private weak var viewModel: NotchViewModel?
    private let quickLook = QuickLookBridge()

    private init() {
        quickLook.controller = self
    }

    func show(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        if window == nil {
            makeWindow(viewModel: viewModel)
        }
        NSApp.activate(ignoringOtherApps: false)
        window?.makeKeyAndOrderFront(nil)
    }

    func toggle(viewModel: NotchViewModel) {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show(viewModel: viewModel)
        }
    }

    func previewURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = QLPreviewPanelController(urls: urls)
        if let win = controller.window { NSApp.runModal(for: win) }
    }

    private func makeWindow(viewModel: NotchViewModel) {
        let hosting = NSHostingView(rootView: ShelfView(viewModel: viewModel))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sticky Shelf"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        self.window = window
    }
}

/// Minimal modal Quick Look host. Esc closes; the runModal keeps it simple and
/// dependency-free for v1 of the visible queue.
@MainActor
final class QLPreviewPanelController: NSWindowController, NSWindowDelegate {
    init(urls: [URL]) {
        let preview = PreviewViewRepresentable(urls: urls)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                              styleMask: [.titled, .closable, .fullScreen],
                              backing: .buffered, defer: false)
        window.title = "Quick Look"
        window.isReleasedWhenClosed = true
        window.contentView = NSHostingView(rootView: preview)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

private struct PreviewViewRepresentable: View {
    let urls: [URL]

    var body: some View {
        List(urls, id: \.absoluteString) { url in
            VStack(alignment: .leading, spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.headline)
                if let image = NSImage(contentsOf: url), ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(url.pathExtension.lowercased()) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 380)
                } else {
                    Label("No inline preview — use Reveal to open in Finder", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
