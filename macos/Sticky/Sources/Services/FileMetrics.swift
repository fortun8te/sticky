import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// File sizes, resolved off the main thread and cached.
///
/// Same discipline as the thumbnails: a `resourceValues` call is filesystem
/// I/O, and doing it inside a SwiftUI body means hitting the disk on every
/// re-render — for every row, every frame.
actor FileMetrics {
    static let shared = FileMetrics()

    private struct Key: Hashable {
        let path: String
        let modified: Date?
    }

    private var cache: [Key: Int64] = [:]
    private var order: [Key] = []
    private let cacheLimit = 400

    private init() {}

    /// Total bytes across a batch. Returns nil if nothing could be measured, so
    /// callers can omit the label rather than print a confident "Zero bytes".
    func totalSize(of urls: [URL]) -> Int64? {
        var total: Int64 = 0
        var measured = false
        for url in urls {
            guard let size = size(of: url) else { continue }
            total += size
            measured = true
        }
        return measured ? total : nil
    }

    private func size(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let key = Key(path: url.path, modified: values?.contentModificationDate)
        if let cached = cache[key] { return cached }

        let resolved: Int64?
        if values?.isDirectory == true {
            resolved = directorySize(of: url)
        } else if let bytes = values?.fileSize {
            resolved = Int64(bytes)
        } else if let allocated = values?.totalFileAllocatedSize {
            resolved = Int64(allocated)
        } else {
            resolved = nil
        }

        guard let resolved else { return nil }
        store(resolved, for: key)
        return resolved
    }

    /// A dropped folder should report what it will actually cost to send.
    private func directorySize(of url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var total: Int64 = 0
        // Bounded: a deep tree must not stall the shelf for a subtitle.
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited > 5_000 { break }
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let bytes = values?.fileSize else { continue }
            total += Int64(bytes)
        }
        return total
    }

    private func store(_ size: Int64, for key: Key) {
        if cache[key] == nil {
            order.append(key)
            while order.count > cacheLimit { cache.removeValue(forKey: order.removeFirst()) }
        }
        cache[key] = size
    }

    /// A short, human name for what the file IS — "PDF", "PNG image", "Folder".
    ///
    /// The extension alone is not an answer for anyone who doesn't already
    /// know it, and the full localized description ("Portable Document
    /// Format document") is far too long for a chip, so this takes the
    /// system's description and trims it to its useful head.
    nonisolated static func kind(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return "Folder" }

        if let type = values?.contentType {
            if let description = type.localizedDescription, !description.isEmpty {
                return shorten(description)
            }
        }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }

    private nonisolated static func shorten(_ description: String) -> String {
        // "Portable Document Format document" -> "PDF document" is not derivable
        // generically, so prefer a short leading acronym when the system gives
        // one, and otherwise cap the length rather than truncate mid-word.
        let words = description.split(separator: " ").map(String.init)
        if let first = words.first, first.count <= 5, first == first.uppercased(), first.rangeOfCharacter(from: .letters) != nil {
            return words.count > 1 ? "\(first) \(words[1])" : first
        }
        guard description.count > 22, words.count > 2 else {
            return description.prefix(1).uppercased() + description.dropFirst()
        }
        let trimmed = words.prefix(2).joined(separator: " ")
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// Finder's own phrasing, so a size in Sticky reads the same as the size the
    /// user just saw in the file they dragged.
    nonisolated static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

/// What a file is, and how big — resolved off the main thread, and rendered
/// only once known so a row never flickers between a placeholder and a number.
struct FileFacts: View {
    let urls: [URL]
    /// A status word that leads the line, e.g. "Queued".
    var prefix: String?
    /// Whether to name the file kind. Off for rows where the title already
    /// carries the extension and the space is tight.
    var showsKind = true

    @State private var label: String?

    var body: some View {
        Group {
            if let label {
                Text(label)
            } else if let prefix {
                Text(prefix)
            }
        }
        .task(id: urls.map(\.path).joined(separator: "\u{1F}")) {
            label = await Self.describe(urls: urls, prefix: prefix, showsKind: showsKind)
        }
    }

    private static func describe(urls: [URL], prefix: String?, showsKind: Bool) async -> String? {
        let bytes = await FileMetrics.shared.totalSize(of: urls)
        var parts: [String] = []
        if let prefix { parts.append(prefix) }
        if showsKind {
            if urls.count == 1, let url = urls.first {
                parts.append(FileMetrics.kind(of: url))
            } else if urls.count > 1 {
                parts.append("\(urls.count) items")
            }
        }
        if let bytes { parts.append(FileMetrics.format(bytes)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}