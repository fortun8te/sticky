import AppKit
import SwiftUI

/// Quick Look for shelf items.
///
/// This class used to own a second, free-standing shelf window duplicating the
/// notch panel. That surface is gone — there is one shelf and it lives in the
/// notch. What remains is a transient preview window, opened on demand and
/// closed by the user, which is the one case where a real window is warranted.
@MainActor
final class ShelfWindowController {
    static let shared = ShelfWindowController()

    private init() {}

    func previewURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreviewListView(urls: urls))
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct PreviewListView: View {
    let urls: [URL]

    var body: some View {
        List(urls, id: \.absoluteString) { url in
            VStack(alignment: .leading, spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.headline)
                if ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains(url.pathExtension.lowercased()),
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
