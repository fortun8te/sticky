import AppKit
import SwiftUI

/// Sticky's private clipboard, as a list.
///
/// It shows what Sticky is holding — not what the Mac is holding. Everything
/// that crosses between the two is a button here: "Take from clipboard" pulls
/// once, the per-row copy pushes once. Nothing on this screen happens on its own.
struct SlotClipboardView: View {
    @ObservedObject var clipboard: ClipboardService

    /// Sending belongs to the panel: it owns the peer, the queue and the
    /// failure state. A row only reports which clip the user pointed at.
    var onSend: (StickyClipItem) -> Void
    /// Optional tick for the haptics/sound layer, which this view does not own.
    var onFeedback: (() -> Void)?

    init(
        clipboard: ClipboardService,
        onSend: @escaping (StickyClipItem) -> Void,
        onFeedback: (() -> Void)? = nil
    ) {
        self.clipboard = clipboard
        self.onSend = onSend
        self.onFeedback = onFeedback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            actionRow

            if let error = clipboard.lastError {
                errorLine(error)
            }

            if clipboard.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Top actions

    private var actionRow: some View {
        HStack(spacing: DS.Space.s) {
            pill("Take from clipboard", icon: "square.and.arrow.down", prominent: true) {
                if clipboard.takeFromSystemClipboard() != nil { onFeedback?() }
            }
            .help("Copy what's on this Mac's clipboard into Sticky, once")

            Spacer(minLength: DS.Space.s)

            if !clipboard.items.isEmpty {
                Text("\(clipboard.items.count)")
                    .font(DS.Type_.caption())
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.textTertiary)

                pill("Clear", icon: "xmark", prominent: false) {
                    clipboard.clearHistory()
                    onFeedback?()
                }
                .help("Empty Sticky's clipboard — the Mac's own clipboard is untouched")
            }
        }
    }

    private func pill(
        _ title: String,
        icon: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs + 1) {
                Image(systemName: icon)
                    .font(DS.Type_.symbol(11, matching: .semibold))
                Text(title)
                    .font(DS.Type_.title(11))
            }
            .foregroundStyle(prominent ? Color.black : DS.Colors.textSecondary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs + 2)
            .background(Capsule().fill(prominent ? DS.Colors.amber : DS.Colors.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Errors are a line of text, not an alert: nothing here is worth stealing
    /// a click for, and tapping it is how it goes away.
    private func errorLine(_ message: String) -> some View {
        Button {
            clipboard.lastError = nil
        } label: {
            HStack(spacing: DS.Space.xs + 1) {
                Image(systemName: "exclamationmark.circle")
                    .font(DS.Type_.symbol(11, matching: .regular))
                Text(message)
                    .font(DS.Type_.caption())
                    .lineLimit(2)
            }
            .foregroundStyle(DS.Colors.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xs + 2) {
                ForEach(clipboard.items) { item in
                    ClipRow(
                        item: item,
                        imagePath: clipboard.imageURL(for: item)?.path,
                        onSend: {
                            onSend(item)
                            onFeedback?()
                        },
                        onCopy: {
                            clipboard.copyToSystemClipboard(item)
                            onFeedback?()
                        },
                        onPin: { clipboard.togglePin(item) },
                        onDelete: { clipboard.delete(item) }
                    )
                }
            }
            .padding(.bottom, DS.Space.xs)
        }
        .scrollIndicators(.never)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.xs + 2) {
            Image(systemName: "doc.on.clipboard")
                .font(DS.Type_.symbol(20, matching: .light))
                .foregroundStyle(DS.Colors.textFaint)
            Text("Sticky's clipboard is empty")
                .font(DS.Type_.body(12))
                .foregroundStyle(DS.Colors.textSecondary)
            Text("It's separate from the Mac's own clipboard — nothing lands here unless you put it here.")
                .font(DS.Type_.caption())
                .foregroundStyle(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.Space.l)
    }
}

// MARK: - One clip

private struct ClipRow: View {
    let item: StickyClipItem
    let imagePath: String?
    let onSend: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var thumbnail: NSImage?

    private let glyphSide: CGFloat = 30

    var body: some View {
        HStack(spacing: DS.Space.m) {
            glyph

            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(DS.Type_.body(11))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(subtitle)
                    .font(DS.Type_.caption())
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: DS.Space.s)

            HStack(spacing: DS.Space.xs) {
                rowButton("paperplane.fill", tint: DS.Colors.amber, help: "Send to PC", action: onSend)
                rowButton("doc.on.doc", tint: DS.Colors.warmWhite, help: "Copy to this Mac's clipboard", action: onCopy)
                rowButton(
                    item.pinned ? "pin.fill" : "pin",
                    tint: item.pinned ? DS.Colors.amber : DS.Colors.warmWhite,
                    help: item.pinned ? "Unpin" : "Pin so it isn't dropped",
                    action: onPin
                )
                rowButton("trash", tint: DS.Colors.destructive, help: "Delete", action: onDelete)
            }
            // Pinned rows keep their state legible without a hover: the pin is
            // information, not just a control.
            .opacity(hovering || item.pinned ? 1 : 0.5)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(hovering ? DS.Colors.surfaceHover : DS.Colors.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.hoverTint, value: hovering)
        .task(id: imagePath) { await loadThumbnail() }
    }

    @ViewBuilder
    private var glyph: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: glyphSide, height: glyphSide)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: DS.Radius.concentric(in: DS.Radius.row, inset: DS.Space.xs),
                        style: .continuous
                    )
                )
        } else {
            Image(systemName: item.symbolName)
                .font(DS.Type_.symbol(12, matching: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: glyphSide, height: glyphSide)
        }
    }

    private func rowButton(
        _ symbol: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.Type_.symbol(11, matching: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Kind, then size, then age, then where it came from — narrowing from what
    /// it is to where it's been, and every part omitted when it would be noise.
    private var subtitle: String {
        var parts: [String] = [item.kindLabel]
        if let bytes = item.byteSize, bytes > 0 {
            parts.append(FileMetrics.format(Int64(bytes)))
        }
        parts.append(Self.age(of: item.createdAt))
        if let sender = item.sender {
            parts.append("from \(sender)")
        }
        return parts.joined(separator: " · ")
    }

    /// Compact by design: a clipboard row is scanned, and "3 minutes ago" is
    /// three words where "3m" is the same fact.
    private static func age(of date: Date) -> String {
        let seconds = max(Date().timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    private func loadThumbnail() async {
        guard let imagePath else {
            thumbnail = nil
            return
        }
        let side = glyphSide
        // Off the main thread: decoding even a downsampled screenshot inside a
        // SwiftUI body is how the shelf used to stutter.
        thumbnail = await Task.detached(priority: .userInitiated) {
            ClipboardService.thumbnail(atPath: imagePath, side: side)
        }.value
    }
}
