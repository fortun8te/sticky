import SwiftUI
import AppKit

/// Everything Sticky is holding, on one surface.
///
/// Files on top, text below. There used to be a Shelf tab and a Slot tab, and
/// nobody could answer which one a pasted line belonged in — the question only
/// existed because the app had asked it. One surface, no choice to make.
struct DrawerView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            FileTray(viewModel: viewModel)
            ComposeField(viewModel: viewModel)
            if !viewModel.clipboardHistory.isEmpty {
                RecentClips(viewModel: viewModel)
            }
            Spacer(minLength: 0)
                .layoutPriority(-1)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.m)
    }
}

// MARK: - Compose

/// Type or paste straight into the drawer. Focused the moment the panel opens,
/// so the fast path is: click the notch, type, Return.
private struct ComposeField: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "text.cursor")
                .font(DS.Type_.symbol(11, matching: .medium))
                .foregroundStyle(DS.Colors.textTertiary)

            TextField("Type or paste — Return sends it", text: $text)
                .textFieldStyle(.plain)
                .font(DS.Type_.body(12))
                .foregroundStyle(DS.Colors.textPrimary)
                .focused($focused)
                .onSubmit(send)

            Button { viewModel.pasteIntoDrawer() } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(DS.Type_.symbol(11, matching: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Paste whatever is on the clipboard")

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(DS.Type_.symbol(11, matching: .semibold))
                    .foregroundStyle(DS.Colors.onControl)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(trimmed.isEmpty ? DS.Colors.surfaceHover : DS.Colors.control))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(DS.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                        .strokeBorder(
                            focused ? DS.Colors.control.opacity(0.6) : DS.Colors.hairline,
                            lineWidth: focused ? 1 : 0.5
                        )
                )
        )
        .onAppear { focused = true }
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        viewModel.putText(trimmed)
        text = ""
    }
}

// MARK: - Recent clips

/// The last few things that went through as text, as compact chips. Not a
/// history browser — a way to fire the same thing again without retyping it.
private struct RecentClips: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs + 2) {
                ForEach(viewModel.clipboardHistory.prefix(8)) { entry in
                    ClipChip(
                        entry: entry,
                        onSend: { viewModel.sendClipboardEntry(entry) },
                        onRemove: { viewModel.deleteClipboardEntry(entry) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 30)
    }
}

private struct ClipChip: View {
    let entry: StickyClipEntry
    let onSend: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.xs + 1) {
            Image(systemName: "text.alignleft")
                .font(DS.Type_.symbol(10, matching: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
            Text(preview)
                .font(DS.Type_.caption())
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(1)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(DS.Type_.symbol(9, matching: .semibold))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(Capsule().fill(hovering ? DS.Colors.surfaceHover : DS.Colors.surface))
        .contentShape(Capsule())
        .onTapGesture(perform: onSend)
        .onHover { hovering = $0 }
        .animation(DS.Motion.hoverTint, value: hovering)
        .help(entry.text)
    }

    private var preview: String {
        let flat = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 26 ? String(flat.prefix(26)) + "…" : flat
    }
}
