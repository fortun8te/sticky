import AppKit
import SwiftUI

/// A normal, closable utility panel that hosts the visible shelf. It never
/// steals focus on launch and can be reopened from the menu bar or notch.
@MainActor
final class ShelfWindowController {
    static let shared = ShelfWindowController()

    private var window: NSWindow?
    private weak var viewModel: NotchViewModel?


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
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Quick Look"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: PreviewListView(urls: urls))
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
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


private struct PreviewListView: View {
    let urls: [URL]

    var body: some View {
        List(urls, id: \.absoluteString) { url in
            VStack(alignment: .leading, spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.headline)
                if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(url.pathExtension.lowercased()),
                   let image = NSImage(contentsOf: url) {
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
