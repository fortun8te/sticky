import SwiftUI
import AppKit

/// The notch, opened up. One panel, two tabs: what's waiting to move (Shelf)
/// and what's shared as text (Slot).
struct ExpandedPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.notchGeometry) private var geometry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.Space.l)
                // Plan §3.2.6: content begins at notchHeight + 10, derived from
                // the measured cutout — never a hardcoded number.
                .padding(.top, geometry.rect.height + DS.Space.cameraClearance)
                .padding(.bottom, DS.Space.s)

            Rectangle()
                .fill(DS.Colors.hairline)
                .frame(height: 1)

            // Files above, text below, both always visible. The tab bar this
            // replaces made you choose a container before you had a thought —
            // and nobody could say which container a pasted line belonged in.
            DrawerView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: NotchLayout.expandedHeight, alignment: .top)
        .background(
            ZStack {
                DesktopGlass()
                DS.panelVeil
            }
        )
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: DS.Radius.panel,
                bottomTrailingRadius: DS.Radius.panel,
                style: .continuous
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                bottomLeadingRadius: DS.Radius.panel,
                bottomTrailingRadius: DS.Radius.panel,
                style: .continuous
            )
            .strokeBorder(DS.Colors.hairline, lineWidth: 0.5)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text("Sticky")
                .font(DS.Type_.title(15))
                .foregroundStyle(.white)
                .fixedSize()

            peerChip

            Spacer(minLength: DS.Space.s)

            if !viewModel.shelfFiles.isEmpty {
                headerButton(icon: "paperplane.fill", active: true, help: "Send everything now") {
                    viewModel.sendFiles(viewModel.shelfFiles.map(\.url))
                }
            }

            headerButton(icon: "xmark", active: false, help: "Close") {
                viewModel.collapseExpanded()
            }
        }
    }

    private var peerChip: some View {
        HStack(spacing: DS.Space.xs + 1) {
            Circle()
                .fill(viewModel.peerCount > 0 ? DS.Colors.control : DS.Colors.textFaint)
                .frame(width: 5, height: 5)
            Text(viewModel.peerCount > 0 ? (viewModel.peerName ?? "PC") : "No PC nearby")
                .font(DS.Type_.body(11))
                .foregroundStyle(viewModel.peerCount > 0 ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Colors.surface))
        .layoutPriority(-1)
    }

    private func headerButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DS.Type_.symbol(11, matching: .semibold))
                .foregroundStyle(active ? DS.Colors.control : DS.Colors.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(DS.Colors.surface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var waitingCount: Int {
        viewModel.shelfFiles.count + viewModel.pendingTransfers.count
    }
}

// MARK: - Shelf

/// Plan §10.9, taken from the Nook Tray reference: a dashed inset container
/// holding one horizontal row of file chips. Not a vertical list of full-width
/// rows — the tray shape is what makes it read instantly as "things go here".
struct FileTray: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            tray

            if !viewModel.pendingTransfers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xs + 2) {
                        ForEach(viewModel.pendingTransfers) { transfer in
                            CompactRow(
                                icon: "clock",
                                title: transfer.items.count == 1
                                    ? transfer.items[0].url.lastPathComponent
                                    : "\(transfer.items.count) items",
                                subtitle: transfer.attempts == 0 ? "Waiting for PC" : "Retried \(transfer.attempts)×",
                                sizeURLs: transfer.items.map(\.url),
                                actionIcon: "arrow.clockwise",
                                onAction: { viewModel.processPendingQueue(force: true) },
                                onRemove: { viewModel.removePendingTransferPublic(id: transfer.id) }
                            )
                        }
                    }
                }
                // A ScrollView takes every point it is offered, so with one row
                // it opened a hole between the tray and the compose field.
                // Height follows the rows, capped at three.
                .frame(height: min(CGFloat(viewModel.pendingTransfers.count) * 48, 144))
            }
        }
    }

    /// The dashed inset container: the affordance that says "put things here"
    /// without a word of copy. Dash weight taken from NotchDrop's tray — a 1pt
    /// hairline reads as a border, a 4pt/10pt dash reads as a *place*.
    private var tray: some View {
        VStack(spacing: 0) {
            if viewModel.shelfFiles.isEmpty {
                emptyTray
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(viewModel.shelfFiles) { item in
                            FileChip(
                                url: item.url,
                                selected: viewModel.selectedShelfIDs.contains(item.id),
                                selecting: viewModel.isSelecting,
                                onTap: {
                                    if viewModel.isSelecting {
                                        viewModel.toggleSelection(for: item.id)
                                    } else {
                                        viewModel.sendFiles([item.url])
                                    }
                                },
                                onSend: { viewModel.sendFiles([item.url]) },
                                onRemove: { viewModel.removeShelfItemPublic(id: item.id) }
                            )
                        }
                    }
                    .padding(DS.Space.m)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(DS.Colors.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(
                    DS.Colors.hairline,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
        .padding(.horizontal, DS.Space.l)
    }

    private var emptyTray: some View {
        VStack(spacing: DS.Space.xs + 2) {
            Image(systemName: "tray.and.arrow.down")
                .font(DS.Type_.symbol(20, matching: .light))
                .foregroundStyle(DS.Colors.textFaint)
            Text("Drag files onto the notch")
                .font(DS.Type_.body(12))
                .foregroundStyle(DS.Colors.textSecondary)
            Text("They wait here until your PC is around.")
                .font(DS.Type_.caption())
                .foregroundStyle(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xl)
    }

}

// MARK: - Chip

/// Plan §10.9: a rounded square, glyph or preview centred in the upper area,
/// filename beneath at the 11 pt readable floor, middle-truncated, with a
/// single hairline in the one accent from the warm ramp.
private struct FileChip: View {
    let url: URL
    let selected: Bool
    let selecting: Bool
    let onTap: () -> Void
    let onSend: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var dragHovering = false

    private var isHot: Bool { hovering || dragHovering }

    var body: some View {
        VStack(spacing: DS.Space.xs + 1) {
            // Aspect-FIT, not fill: a wide screenshot centre-cropped into a
            // square tells you nothing about which screenshot it is.
            FileThumbnail(
                url: url,
                side: 46,
                cornerRadius: DS.Radius.concentric(in: DS.Radius.chip, inset: 3),
                contentMode: .fit
            )

            Text(url.lastPathComponent)
                .font(DS.Type_.caption())
                .foregroundStyle(selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 56)

            FileFacts(urls: [url], showsKind: false)
                .font(DS.Type_.caption())
                .foregroundStyle(DS.Colors.textFaint)
                .lineLimit(1)
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, DS.Space.xs + 1)
        .frame(width: 66)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(isHot ? DS.Colors.surfaceHover : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(
                    selected ? DS.Colors.control : DS.Colors.hairline,
                    lineWidth: selected ? 1.2 : 0.75
                )
        )
        .overlay(alignment: .topTrailing) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(DS.Type_.symbol(14, matching: .semibold))
                    .foregroundStyle(selected ? DS.Colors.control : DS.Colors.textTertiary)
                    .background(Circle().fill(DS.Colors.notchBody))
                    .offset(x: 5, y: -5)
            } else if isHot {
                // Always on hover, never behind a held modifier. NotchDrop
                // hides this behind Option and nobody finds it.
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Type_.symbol(16, matching: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, DS.Colors.destructiveBadge)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Remove from shelf")
            }
        }
        // Plan F-4: grab the file and pull it into Finder, Mail, anywhere. The
        // handle covers the chip, so it carries the tap and the menu too.
        .filePromiseDraggable(
            url,
            onHoverChange: { dragHovering = $0 },
            onClick: onTap,
            menuItems: [
                (title: "Quick Look", destructive: false,
                 action: { ShelfWindowController.shared.previewURLs([url]) }),
                (title: "Reveal in Finder", destructive: false,
                 action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                (title: "-", destructive: false, action: {}),
                (title: "Send now", destructive: false, action: onSend),
                (title: "Remove from shelf", destructive: true, action: onRemove)
            ]
        )
        .onHover { hovering = $0 }
        .animation(DS.Motion.hoverTint, value: isHot)
        .help(url.lastPathComponent)
    }
}

// MARK: - Compact row

private struct CompactRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    var sizeURLs: [URL] = []
    let actionIcon: String
    let onAction: () -> Void
    let onRemove: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(DS.Type_.symbol(11, matching: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Type_.body(11))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !sizeURLs.isEmpty {
                    FileFacts(urls: sizeURLs, prefix: subtitle)
                        .font(DS.Type_.caption())
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(1)
                } else if let subtitle {
                    Text(subtitle)
                        .font(DS.Type_.caption())
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.s)

            HStack(spacing: DS.Space.xs) {
                rowButton(actionIcon, tint: DS.Colors.control, action: onAction)
                if let onRemove {
                    rowButton("trash", tint: DS.Colors.destructive, action: onRemove)
                }
            }
            .opacity(hovering ? 1 : 0.5)
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
    }

    private func rowButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.Type_.symbol(11, matching: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slot

/// A live pocket of text shared between machines. Typing works here because the
/// panel is allowed to become key while it is expanded — and only then.
struct SlotView: View {
    @ObservedObject var viewModel: NotchViewModel
    @FocusState private var editorFocused: Bool

    private var hasContent: Bool { !viewModel.slotText.isEmpty || viewModel.slotImage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let image = viewModel.slotImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 84, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                            .strokeBorder(DS.Colors.hairline, lineWidth: 0.5)
                    )
            }

            ZStack(alignment: .topLeading) {
                if viewModel.slotText.isEmpty {
                    Text("Type or paste — it syncs to your PC.")
                        .font(DS.Type_.body(12))
                        .foregroundStyle(DS.Colors.textFaint)
                        .padding(.horizontal, DS.Space.m)
                        .padding(.vertical, DS.Space.m)
                        .allowsHitTesting(false)
                }

                TextEditor(text: Binding(
                    get: { viewModel.slotText },
                    set: { viewModel.writeSlot(text: $0) }
                ))
                .font(DS.Type_.body(12))
                .foregroundStyle(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs + 2)
                .focused($editorFocused)
            }
            .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .fill(DS.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                            .strokeBorder(
                                editorFocused ? DS.Colors.control.opacity(0.55) : DS.Colors.hairline,
                                lineWidth: editorFocused ? 1 : 0.5
                            )
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { editorFocused = true }

            HStack(spacing: DS.Space.s) {
                slotPill("Paste", icon: "doc.on.clipboard", prominent: true) {
                    viewModel.pasteIntoSlot()
                }
                if hasContent {
                    slotPill("Send", icon: "paperplane.fill", prominent: false) {
                        viewModel.sendSlotToPeer()
                    }
                    slotPill("Copy", icon: "doc.on.doc", prominent: false) {
                        viewModel.copySlotToPasteboard()
                    }
                    slotPill("Clear", icon: "xmark", prominent: false) {
                        viewModel.clearSlot()
                    }
                }

                Spacer()

                HStack(spacing: DS.Space.xs + 1) {
                    Circle()
                        .fill(viewModel.clipboardSyncEnabled ? DS.Colors.control : DS.Colors.textFaint)
                        .frame(width: 5, height: 5)
                    Text(viewModel.clipboardSyncEnabled ? "Syncing" : "Sync off")
                        .font(DS.Type_.caption())
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .onAppear { editorFocused = true }
    }

    private func slotPill(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
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
            .background(Capsule().fill(prominent ? DS.Colors.control : DS.Colors.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
