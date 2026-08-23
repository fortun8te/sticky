import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Thumbnails for shelf rows, off the main thread and cached.
///
/// The rows used to call `NSImage(contentsOf:)` straight from a SwiftUI body,
/// which decodes the whole file — a 40-megapixel photo, a 200 MB PSD — at full
/// resolution to fill a 30 pt square, on the main thread, on every re-render.
/// That is why the shelf stuttered. QuickLook renders at the size we ask for,
/// understands far more file types than `NSImage` does, and reuses previews the
/// system has already generated.
actor ThumbnailService {
    static let shared = ThumbnailService()

    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let side: Int
    }

    private var cache: [Key: NSImage] = [:]
    private var order: [Key] = []
    /// Bounded so a long session on a big shelf cannot grow without limit.
    private let cacheLimit = 240

    private init() {}

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = Key(
            path: url.path,
            modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            side: Int(side.rounded())
        )
        if let cached = cache[key] { return cached }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: max(scale, 1),
            representationTypes: .thumbnail
        )

        let generated: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }

        // No representation is normal for plenty of types; fall back to the
        // file's Finder icon rather than leaving a hole in the row.
        guard let image = generated ?? workspaceIcon(for: url) else { return nil }
        store(image, for: key)
        return image
    }

    private nonisolated func workspaceIcon(for url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func store(_ image: NSImage, for key: Key) {
        if cache[key] == nil {
            order.append(key)
            while order.count > cacheLimit {
                cache.removeValue(forKey: order.removeFirst())
            }
        }
        cache[key] = image
    }

    func forget(_ url: URL) {
        let stale = order.filter { $0.path == url.path }
        for key in stale { cache.removeValue(forKey: key) }
        order.removeAll { $0.path == url.path }
    }
}

/// A file thumbnail that never blocks the main thread. Shows a neutral tile
/// until QuickLook answers, then fades in.
struct FileThumbnail: View {
    let url: URL
    var side: CGFloat = 30
    var cornerRadius: CGFloat = 7
    /// A queued transfer legitimately points at a file that may be gone.
    var missingIsExpected = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if missing, !missingIsExpected {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: side * 0.38))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: side * 0.38, weight: .light))
                    .foregroundStyle(.white.opacity(0.26))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: url.path) {
            image = nil
            let path = url.path
            let onDisk = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
            missing = !onDisk
            guard onDisk else { return }
            image = await ThumbnailService.shared.thumbnail(for: url, side: side, scale: displayScale)
        }
    }
}
