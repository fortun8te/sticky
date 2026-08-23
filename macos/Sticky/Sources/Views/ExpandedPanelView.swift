import SwiftUI
import AppKit

/// The notch, opened up. One panel, two tabs: what's waiting to move (Shelf)
/// and what's shared as text (Slot).
struct ExpandedPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.notchGeometry) private var geometry
    @State private var activeTab: PanelTab = .shelf

    enum PanelTab: String, CaseIterable {
        case shelf, slot
        var title: String { self == .shelf ? "Shelf" : "Slot" }
        var icon: String { self == .shelf ? "tray.full" : "text.cursor" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.Space.l)
                // Plan §3.2.6: content begins at notchHeight + 10, derived from
                // the measured cutout — never a hardcoded number.
                .padding(.top, geometry.rect.height + DS.Space.cameraClearance)
                .padding(.bottom, DS.Space.m)

            tabPicker
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.m)

            Rectangle()
                .fill(DS.Colors.hairline)
                .frame(height: 1)

            Group {
                switch activeTab {
                case .shelf: ShelfContentView(viewModel: viewModel)
                case .slot:
                    if let clipboard = viewModel.clipboardService {
                        SlotClipboardView(
                            clipboard: clipboard,
                            onSend: { viewModel.sendClip($0) },
                            onFeedback: { viewModel.noteInteraction() }
                        )
                    } else {
                        SlotView(viewModel: viewModel)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: NotchLayout.expandedHeight, alignment: .top)
        // Plan §10.2: the surface that touches the bezel is flat #000.
        .background(DS.Colors.notchBody)
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
        HStack(spacing: DS.Space.m) {
            Text("Sticky")
                .font(DS.Type_.title(15))
                .foregroundStyle(.white)
                .fixedSize()

            peerChip

            Spacer(minLength: DS.Space.s)

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

    // MARK: Tabs

    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button { activeTab = tab } label: {
                    HStack(spacing: DS.Space.xs + 1) {
                        Image(systemName: tab.icon)
                            .font(DS.Type_.symbol(11, matching: .semibold))
                        Text(tab.title)
                            .font(DS.Type_.title(11.5))
                        if tab == .shelf, waitingCount > 0 {
                            Text("\(waitingCount)")
                                .font(DS.Type_.title(11))
                                .monospacedDigit()
                                .foregroundStyle(DS.Colors.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DS.Colors.surfaceHover))
                        }
                    }
                    .foregroundStyle(activeTab == tab ? Color.white : DS.Colors.textTertiary)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.xs + 2)
                    .background(Capsule().fill(activeTab == tab ? DS.Colors.surfaceHover : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(3)
        .background(Capsule().fill(DS.Colors.surface))
    }

    private var waitingCount: Int {
        viewModel.shelfFiles.count + viewModel.pendingTransfers.count
    }
}

// MARK: - Shelf

/// Plan §10.9, taken from the Nook Tray reference: a dashed inset container
/// holding one horizontal row of file chips, with a small action row beneath.
/// Not a vertical list of full-width rows — the tray shape is what makes it
/// read instantly as "things go here".
struct ShelfContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    /// Chips sit in a single row. No wrapping, no grid.
    private let visibleChipLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            tray

            if !viewModel.shelfFiles.isEmpty {
                actionRow
            }

            if !viewModel.pendingTransfers.isEmpty || !viewModel.clipboardHistory.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xs + 2) {
                        if !viewModel.pendingTransfers.isEmpty {
                            sectionHeader("Waiting for PC", count: viewModel.pendingTransfers.count)
                            ForEach(viewModel.pendingTransfers) { transfer in
                                CompactRow(
                                    icon: "clock",
                                    title: transfer.items.count == 1
                                        ? transfer.items[0].url.lastPathComponent
                                        : "\(transfer.items.count) items",
                                    subtitle: transfer.attempts == 0 ? "Queued" : "Retried \(transfer.attempts)×",
                                    sizeURLs: transfer.items.map(\.url),
                                    actionIcon: "arrow.clockwise",
                                    onAction: { viewModel.processPendingQueue(force: true) },
                                    onRemove: { viewModel.removePendingTransferPublic(id: transfer.id) }
                                )
                            }
                        }

                        if !viewModel.clipboardHistory.isEmpty {
                            sectionHeader("Clips", count: viewModel.clipboardHistory.count)
                            ForEach(viewModel.clipboardHistory.prefix(5)) { entry in
                                CompactRow(
                                    icon: "text.alignleft",
                                    title: clipPreview(entry.text),
                                    subtitle: nil,
                                    actionIcon: "paperplane.fill",
                                    onAction: { viewModel.sendClipboardEntry(entry) },
                                    onRemove: { viewModel.deleteClipboardEntry(entry) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, DS.Space.m)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.m)
    }

    /// The dashed inset container: the affordance that says "put things here"
    /// without a word of copy.
    private var tray: some View {
        VStack(spacing: 0) {
            if viewModel.shelfFiles.isEmpty {
                emptyTray
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.m) {
                        ForEach(viewModel.shelfFiles.prefix(visibleChipLimit)) { item in
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
                        if overflowCount > 0 {
                            overflowChip
                        }
                    }
                    .padding(DS.Space.m)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(DS.Colors.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(
                    DS.Colors.hairlineStrong,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .padding(.horizontal, DS.Space.l)
    }

    private var overflowCount: Int {
        max(viewModel.shelfFiles.count - visibleChipLimit, 0)
    }

    private var overflowChip: some View {
        Text("+\(overflowCount)")
            .font(DS.Type_.title(13))
            .monospacedDigit()
            .foregroundStyle(DS.Colors.textSecondary)
            .frame(width: 52, height: 92)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(DS.Colors.surface)
            )
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

    /// A small floating action row: round buttons, evenly spaced, one job each.
    private var actionRow: some View {
        HStack(spacing: DS.Space.s) {
            if viewModel.isSelecting && !viewModel.selectedShelfIDs.isEmpty {
                trayAction("Delete \(viewModel.selectedShelfIDs.count)", icon: "trash", prominent: true) {
                    viewModel.deleteSelected()
                }
                trayAction("Cancel", icon: "xmark", prominent: false) {
                    viewModel.cancelSelection()
                }
            } else {
                trayAction(
                    viewModel.shelfFiles.count == 1 ? "Send" : "Send all",
                    icon: "paperplane.fill",
                    prominent: true
                ) {
                    viewModel.sendFiles(viewModel.shelfFiles.map(\.url))
                }
                trayAction("Select", icon: "checklist", prominent: false) {
                    viewModel.enterSelectionMode()
                }
                trayAction("Clear", icon: "xmark", prominent: false) {
                    viewModel.clearShelf()
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.l)
    }

    private func trayAction(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
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

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: DS.Space.xs + 2) {
            Text(title.uppercased())
                .font(DS.Type_.title(11))
                .kerning(0.5)
                .foregroundStyle(DS.Colors.textTertiary)
            Text("\(count)")
                .font(DS.Type_.body(11))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.textFaint)
            Spacer()
        }
        .padding(.top, DS.Space.xs)
    }

    private func clipPreview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 70 ? String(flat.prefix(70)) + "…" : flat
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
        VStack(spacing: DS.Space.xs + 2) {
            FileThumbnail(
                url: url,
                side: 40,
                cornerRadius: DS.Radius.concentric(in: DS.Radius.chip, inset: 3)
            )
            .frame(maxHeight: .infinity)

            VStack(spacing: 1) {
                Text(url.lastPathComponent)
                    .font(DS.Type_.caption())
                    .foregroundStyle(selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FileFacts(urls: [url])
                    .font(DS.Type_.caption())
                    .foregroundStyle(DS.Colors.textFaint)
                    .lineLimit(1)
            }
            .frame(width: 64)
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, DS.Space.xs + 1)
        .frame(width: 78, height: 92)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(isHot ? DS.Colors.surfaceHover : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(
                    selected ? DS.Colors.control : DS.Colors.control.opacity(isHot ? 0.55 : 0.28),
                    lineWidth: selected ? 1.2 : 0.75
                )
        )
        .overlay(alignment: .topTrailing) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(DS.Type_.symbol(13, matching: .semibold))
                    .foregroundStyle(selected ? DS.Colors.control : DS.Colors.textTertiary)
                    .padding(3)
            } else if isHot {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Type_.symbol(13, matching: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Remove")
            }
        }
        // Plan F-4: grab the file and pull it into Finder, Mail, anywhere.
        // The handle sits over the whole chip, so it also carries the tap and
        // the right-click menu — SwiftUI's own gestures never see them.
        .filePromiseDraggable(
            url,
            onHoverChange: { dragHovering = $0 },
            onClick: onTap,
            // Right-click rather than more buttons: the chip stays a chip, and
            // the rarer actions live where macOS users already look.
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
