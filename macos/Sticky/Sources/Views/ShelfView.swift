import SwiftUI
import AppKit

/// The visible face of Sticky's shelf: queued files, waiting transfers, and
/// recent clips. Rows stay calm until hovered, then offer direct actions.
struct ShelfView: View {
    @ObservedObject var viewModel: NotchViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !viewModel.shelfFiles.isEmpty {
                    section(title: "On the shelf", subtitle: "\(viewModel.shelfFiles.count) item\(viewModel.shelfFiles.count == 1 ? "" : "s")") {
                        ForEach(viewModel.shelfFiles) { item in
                            FileRow(
                                url: item.url,
                                subtitle: "Ready to send",
                                accent: Color.stickyAccent,
                                primaryAction: (icon: "paperplane.fill", label: "Send", handler: { viewModel.sendFiles([item.url]) }),
                                secondaryActions: [
                                    RowAction(icon: "eye", label: "Quick Look", handler: { ShelfWindowController.shared.previewURLs([item.url]) }),
                                    RowAction(icon: "folder", label: "Reveal", handler: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }),
                                    RowAction(icon: "trash", label: "Remove", handler: { viewModel.removeShelfItemPublic(id: item.id) }, role: .destructive)
                                ]
                            )
                        }

                        Button("Clear shelf") {
                            viewModel.clearShelf()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                if !viewModel.pendingTransfers.isEmpty {
                    section(title: "Waiting for your PC", subtitle: "These retry automatically") {
                        ForEach(viewModel.pendingTransfers) { transfer in
                            FileRow(
                                url: transfer.items.first?.url ?? URL(fileURLWithPath: "/"),
                                titleOverride: transfer.items.count == 1 ? transfer.items[0].url.lastPathComponent : "\(transfer.items.count) items",
                                subtitle: transfer.attempts == 0 ? "Queued" : "Retried \(transfer.attempts)× · kept safe",
                                accent: Color.stickyIvory.opacity(0.8),
                                primaryAction: (icon: "arrow.clockwise", label: "Retry all", handler: { viewModel.processPendingQueue(force: true) }),
                                secondaryActions: [
                                    RowAction(icon: "trash", label: "Drop from queue", handler: { viewModel.removePendingTransferPublic(id: transfer.id) }, role: .destructive)
                                ],
                                hideThumbnailIfMissing: true
                            )
                        }
                    }
                }

                if !viewModel.clipboardHistory.isEmpty {
                    section(title: "Clips", subtitle: "Your private history — nothing auto-sends") {
                        ForEach(viewModel.clipboardHistory.prefix(12)) { entry in
                            ClipRow(entry: entry,
                                    isCurrent: viewModel.stickySlot?.id == entry.id,
                                    onSend: { viewModel.sendClipboardEntry(entry) })
                        }
                    }
                }

                if viewModel.shelfFiles.isEmpty && viewModel.pendingTransfers.isEmpty && viewModel.clipboardHistory.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Drag files onto the notch")
                            .font(.headline)
                        Text("They'll wait here — even offline — until your PC appears.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 46)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 320, idealHeight: 460)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func section<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
    }
}

private struct RowAction {
    enum Role { case normal, destructive }
    let icon: String
    let label: String
    let handler: () -> Void
    var role: Role = .normal
}

private struct FileRow: View {
    let url: URL
    var titleOverride: String?
    let subtitle: String
    let accent: Color
    let primaryAction: (icon: String, label: String, handler: () -> Void)
    let secondaryActions: [RowAction]
    var hideThumbnailIfMissing = false

    @State private var hovering = false

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        HStack(spacing: 12) {
            thumb
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleOverride ?? url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if hovering {
                HStack(spacing: 6) {
                    ForEach(Array(secondaryActions.enumerated()), id: \.offset) { _, action in
                        rowButton(action)
                    }
                    Button(action: primaryAction.handler) {
                        Label(primaryAction.label, systemImage: primaryAction.icon)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .help(primaryAction.label)
                }
                .transition(.opacity)
            } else {
                Image(systemName: primaryAction.icon)
                    .foregroundStyle(accent)
                    .font(.system(size: 15, weight: .semibold))
                    .transition(.opacity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0.03)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    @ViewBuilder
    private var thumb: some View {
        if !exists && hideThumbnailIfMissing {
            Image(systemName: "questionmark.folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
        } else if let image = NSImage(contentsOf: url), url.pathExtension.lowercased().matchesAny(of: ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"]) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 36, height: 36)
                .frame(width: 42, height: 42)
        }
    }

    private func rowButton(_ action: RowAction) -> some View {
        Button(action: action.handler) {
            Label(action.label, systemImage: action.icon)
                .labelStyle(.iconOnly)
                .foregroundStyle(action.role == .destructive ? Color.red : Color.primary.opacity(0.75))
        }
        .buttonStyle(.plain)
        .padding(6)
        .background(Circle().fill(Color.primary.opacity(0.08)))
        .help(action.label)
    }
}

private struct ClipRow: View {
    let entry: StickyClipEntry
    let isCurrent: Bool
    let onSend: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isCurrent ? Color.stickyAccent : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(clipPreview)
                    .font(.system(size: 12, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(isCurrent ? "Current slot" : relativeDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hovering {
                Button(action: onSend) {
                    Label("Send clip", systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stickyAccent)
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0.03)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    private var clipPreview: String {
        let preview = entry.text.replacingOccurrences(of: "\n", with: " ")
        return preview.count > 160 ? String(preview.prefix(160)) + "…" : preview
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.timestamp, relativeTo: Date())
    }
}

extension String {
    func matchesAny(of options: [String]) -> Bool {
        options.contains(self)
    }
}
