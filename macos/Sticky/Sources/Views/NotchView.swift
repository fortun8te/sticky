import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @StateObject var viewModel: NotchViewModel
    @Environment(\.notchGeometry) private var geometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var failureProgress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            if viewModel.isExpanded {
                ExpandedPanel(viewModel: viewModel)
                    .frame(height: expandedHeight)
                    .zIndex(1)
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: interactionSize.width, height: interactionSize.height + 26)
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], delegate: viewModel)
                    .onTapGesture {
                        viewModel.toggleExpanded()
                    }
                    .onHover { hovering in
                        viewModel.setPointerHover(hovering)
                    }

                island
                    .allowsHitTesting(false)
            }
        }
        .frame(
            width: viewModel.isExpanded ? nil : interactionSize.width,
            height: viewModel.isExpanded ? nil : interactionSize.height + 26,
            alignment: .top
        )
        .ignoresSafeArea()
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.reducesMotion = newValue
        }
        .onAppear {
            viewModel.reducesMotion = reduceMotion
            viewModel.setDropProbe(
                width: NotchLayout.interactiveSize(
                    notchWidth: geometry.rect.width,
                    notchHeight: geometry.rect.height
                ).width
            )
        }
        .onChange(of: geometry.rect.width) { _, newValue in
            viewModel.setDropProbe(
                width: NotchLayout.interactiveSize(
                    notchWidth: newValue,
                    notchHeight: geometry.rect.height
                ).width
            )
        }
        .onChange(of: displayState) { _, newState in
            guard case .failure = newState else {
                var resetTransaction = Transaction()
                resetTransaction.disablesAnimations = true
                withTransaction(resetTransaction) {
                    failureProgress = 0
                }
                return
            }

            guard !reduceMotion else { return }
            failureProgress = 0
            withAnimation(.timingCurve(0.32, 0, 0.24, 1, duration: 0.58)) {
                failureProgress = 1
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var expandedHeight: CGFloat { 340 }

    private var displayState: NotchState {
        viewModel.state
    }

    private var island: some View {
        let dimensions = islandDimensions
        let size = CGSize(width: dimensions.width + 12, height: dimensions.height)

        return TimelineView(
            .animation(minimumInterval: 1 / 30, paused: reduceMotion)
        ) { context in
            let phase = warpPhase(for: context.date)
            let intensity = warpIntensity
            let cameraRect = geometry.isVirtual ? nil : CGRect(
                x: (size.width - geometry.rect.width) / 2,
                y: 0,
                width: geometry.rect.width,
                height: min(geometry.rect.height, size.height)
            )
            let shell = NameDropWarpShape(
                phase: phase,
                intensity: intensity,
                cameraRect: cameraRect
            )

            shell
                .fill(
                    Color.black.opacity(geometry.isVirtual && displayState == .idle ? 0 : 1),
                    style: FillStyle(eoFill: true)
                )
                .frame(width: size.width, height: size.height)
                .offset(x: displayState == .hover ? viewModel.dragAlignment * 4 : 0)
                .overlay {
                    ZStack {
                        NameDropGlow(
                            phase: phase,
                            intensity: intensity,
                            reduceMotion: reduceMotion
                        )
                        .frame(width: size.width, height: size.height)

                        VStack(spacing: 0) {
                            if !geometry.isVirtual {
                                Color.clear
                                    .frame(height: max(geometry.rect.height, 22))
                                    .allowsHitTesting(false)
                            }

                            ZStack {
                                if let filamentDirection {
                                    FilamentHandoff(direction: filamentDirection, reduceMotion: reduceMotion)
                                        .frame(height: 22)
                                        .allowsHitTesting(false)
                                }

                                islandContent
                                    .padding(.horizontal, 15)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipShape(shell)
                }
                .shadow(
                    color: .black.opacity(dimensions.shadowOpacity),
                    radius: dimensions.shadowRadius,
                    y: 5
                )
                .modifier(RestrainedShake(progress: failureProgress))
        }
    }

    private var interactionSize: CGSize {
        NotchLayout.interactiveSize(
            notchWidth: geometry.rect.width,
            notchHeight: geometry.rect.height
        )
    }

    private var warpIntensity: CGFloat {
        if viewModel.isExpanded { return 0.18 }
        // Idle keeps a whisper of life — the notch breathes instead of dying.
        let idleBase: CGFloat = reduceMotion ? 0 : 0.10
        switch displayState {
        case .idle:
            return idleBase
        case .hover:
            return 0.26          // visible ripple answers the cursor
        case .armed:
            return 0.40
        case .transferring:
            return 0.85          // full flare while sending
        case .queued:
            return 0.24
        case .success:
            return 0.32
        case .failure:
            return 0
        case .incomingOffer:
            return 0.50
        }
    }

    private func warpPhase(for date: Date) -> CGFloat {
        guard !reduceMotion else { return 0.35 }
        let active = displayState != .idle
        let period: Double = active ? 1.5 : 3.8   // slow breath at rest, quick pulse on action
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        // Cosine loop: smooth 0→1→0, never snaps back to zero
        return CGFloat(0.5 - 0.5 * cos(2 * .pi * elapsed / period))
    }

    private var islandDimensions: (width: CGFloat, height: CGFloat, cornerRadius: CGFloat, shadowOpacity: Double, shadowRadius: CGFloat) {
        let width = max(geometry.rect.width, 120)
        let baseHeight = max(geometry.rect.height, 22)
        let pull = viewModel.dropMagnetism

        switch displayState {
        case .idle:
            return (width, baseHeight, 11, 0, 0)
        case .hover:
            return (width + 16, baseHeight + 22 + pull * 4, 17, 0.20 + pull * 0.04, 10)
        case .armed:
            return (width + 34, baseHeight + 34, 20, 0.26, 13)
        case .transferring:
            return (width + 46, baseHeight + 38, 22, 0.30, 15)
        case .queued:
            return (width + 34, baseHeight + 32, 20, 0.24, 12)
        case .success:
            return (width + 22, baseHeight + 26, 19, 0.22, 11)
        case .failure:
            return (width + 42, baseHeight + 34, 20, 0.24, 12)
        case .incomingOffer:
            return (width + 50, baseHeight + 36, 22, 0.28, 13)
        }
    }

    private var filamentDirection: FilamentDirection? {
        switch displayState {
        case .armed, .transferring:
            return .sending
        case .incomingOffer:
            return .receiving
        default:
            return nil
        }
    }

    @ViewBuilder
    private var islandContent: some View {
        switch displayState {
        case .idle:
            Color.clear
        case .hover:
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                Text("Send to PC")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        case .armed(let count, let previewData):
            armedContent(count: count, previewData: previewData)
        case .transferring(let progress, let fileName):
            transferContent(progress: progress, fileName: fileName)
        case .queued(let count, let previewData):
            queuedContent(count: count, previewData: previewData)
        case .success(let count):
            successContent(count: count)
        case .failure(let reason):
            failureContent(reason: reason)
        case .incomingOffer(let senderName, let count, let kind):
            incomingContent(senderName: senderName, count: count, kind: kind)
        }
    }

    private func armedContent(count: Int, previewData: Data?) -> some View {
        HStack(spacing: 10) {
            previewView(for: previewData)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("Ready to send")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.stickyAccent.opacity(0.9))
                    .modifier(ArmedPullSymbol(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private func previewView(for data: Data?) -> some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func transferContent(progress: Double, fileName: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.stickyAccent)
                    .accessibilityHidden(true)

                Text(fileName ?? "Sending")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                Text("\(Int(progress.clamped(to: 0...1)) * 100)%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.1))

                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.stickyIvory, location: 0),
                                    .init(color: Color.stickyAccent, location: 0.5),
                                    .init(color: Color(red: 1.0, green: 0.55, blue: 0.35), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .modifier(ShimmerFill(active: !reduceMotion && progress < 1))
                        .frame(width: max(proxy.size.width * progress.clamped(to: 0...1), 4))
                }
            }
            .frame(height: 4)
            .animation(reduceMotion ? nil : .linear(duration: 0.18), value: progress)
        }
    }

    private func queuedContent(count: Int, previewData: Data?) -> some View {
        HStack(spacing: 10) {
            previewView(for: previewData)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) item\(count == 1 ? "" : "s") queued")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("Will send when PC appears")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.stickyAccent.opacity(0.88))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) item\(count == 1 ? "" : "s") waiting for the PC")
    }

    private func successContent(count: Int) -> some View {
        HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.stickyIvory)
                .modifier(SuccessCheckSymbol(reduceMotion: reduceMotion, trigger: count))
                .accessibilityHidden(true)

            Text(count == 1 ? "Sent" : "\(count) items sent")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func failureContent(reason: String?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.stickyAccent.opacity(0.92))
                .accessibilityHidden(true)

            Text(reason?.isEmpty == false ? reason! : "Transfer failed")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func incomingContent(senderName: String, count: Int, kind: TransferKind) -> some View {
        HStack(spacing: 10) {
                Image(systemName: kind == .files ? "arrow.down.circle.fill" : "text.bubble.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.stickyAccent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(senderName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kind == .files ? "Receiving \(count) item\(count == 1 ? "" : "s")" : "Receiving message")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.78))
        }
        .padding(.vertical, 2)
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Receiving \(count) incoming \(kind == .files ? "items" : "messages") from \(senderName)")
    }

    private var accessibilityLabel: String {
        switch displayState {
        case .idle:
            return "Sticky notch, drop files to send"
        case .hover:
            return "Ready to receive files"
        case .armed(let count, _):
            return "Holding \(count) items ready to send"
        case .transferring(let progress, let fileName):
            let name = fileName ?? "files"
            return "Sending \(name), \(Int(progress.clamped(to: 0...1)) * 100) percent complete"
        case .queued(let count, _):
            return "\(count) item\(count == 1 ? "" : "s") queued until the PC is available"
        case .success(let count):
            return count == 1 ? "Item sent" : "\(count) items sent"
        case .failure(let reason):
            return "Transfer failed\(reason?.isEmpty == false ? ", \(reason!)" : "")"
        case .incomingOffer(_, let count, let kind):
            return "Receiving \(count) \(kind == .files ? "items" : "messages")"
        }
    }

}

/// Geometry used by DynamicNotchKit and boring.notch: small concave top
/// shoulders hug the hardware while independent bottom radii animate the bloom.
private struct NativeNotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private enum FilamentDirection {
    case sending
    case receiving
}

private struct FilamentHandoff: View {
    let direction: FilamentDirection
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Canvas { canvasContext, size in
                let trackRect = CGRect(
                    x: size.width * 0.08,
                    y: size.height / 2 - 1,
                    width: size.width * 0.84,
                    height: 2
                )
                let track = Path(roundedRect: trackRect, cornerRadius: 1)
                canvasContext.fill(track, with: .color(.white.opacity(0.07)))

                let elapsed = context.date.timeIntervalSinceReferenceDate
                let cycleDuration = 1.7
                let pulseCount = 3

                for index in 0..<pulseCount {
                    var fraction = (elapsed / cycleDuration + Double(index) / Double(pulseCount))
                        .truncatingRemainder(dividingBy: 1)
                    if direction == .receiving {
                        fraction = 1 - fraction
                    }

                    let x = trackRect.minX + trackRect.width * fraction
                    let fade = sin(fraction * .pi)
                    let pulseRect = CGRect(x: x - 5, y: trackRect.midY - 2.25, width: 10, height: 4.5)
                    let pulse = Path(roundedRect: pulseRect, cornerRadius: 2.25)

                    canvasContext.addFilter(.blur(radius: 2.5))
                    canvasContext.fill(
                        pulse,
                        with: .color(
                            direction == .sending
                                ? Color.stickyAccent.opacity(0.34 * fade)
                                : Color.stickyIvory.opacity(0.38 * fade)
                        )
                    )
                    canvasContext.addFilter(.blur(radius: 0.4))
                    canvasContext.fill(pulse, with: .color(.white.opacity(0.52 * fade)))
                }
            }
        }
        .mask(
            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RestrainedShake: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        let decayedOffset = progress == 0 || progress >= 1 ? 0 : sin(progress * .pi * 4) * 3.5 * (1 - progress)
        return content.offset(x: decayedOffset)
    }
}

private struct ShimmerFill: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.20), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: geo.size.height * 1.2)
                        .offset(y: phase * geo.size.height * 3)
                        .blendMode(.plusLighter)
                    }
                    .clipped()
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        } else {
            content
        }
    }
}

private struct BreathingDot: ViewModifier {
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .scaleEffect(1.0)
                .modifier(BreathingLoop())
        }
    }
}

private struct BreathingLoop: ViewModifier {
    @State private var up = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(up ? 1.25 : 0.9)
            .opacity(up ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
    }
}

private struct ArmedPullSymbol: ViewModifier {
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.pulse, isActive: true)
        }
    }
}

private struct SuccessCheckSymbol: ViewModifier {
    let reduceMotion: Bool
    let trigger: Int

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce, value: trigger)
        }
    }
}

// MARK: - Expanded panel (shelf integrated into the notch)

/// The notch, opened up: shelf, queue, clips, and quick actions live here.
/// No separate window — everything happens inside the same panel that hugs
/// the hardware notch.
struct ExpandedPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var activeTab: PanelTab = .shelf

    enum PanelTab { case shelf, slot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 34) // clear the hardware notch band
                .padding(.bottom, 10)

            tabPicker

            Divider()
                .overlay(Color.white.opacity(0.08))

            if activeTab == .slot {
                SlotView(viewModel: viewModel)
            } else if viewModel.isSelecting && !viewModel.selectedShelfIDs.isEmpty {
                selectionBar
                ShelfContentView(viewModel: viewModel)
            } else {
                ShelfContentView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.985))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
        .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            tabButton("Shelf", icon: "tray.full", tab: .shelf)
            tabButton("Slot", icon: "clipboard", tab: .slot)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func tabButton(_ title: String, icon: String, tab: PanelTab) -> some View {
        Button {
            activeTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(activeTab == tab ? Color.white : Color.white.opacity(0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(activeTab == tab ? Color.white.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(viewModel.selectedShelfIDs.count) selected")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Button {
                viewModel.deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.75)))
            }
            .buttonStyle(.plain)

            Button("Cancel") { viewModel.cancelSelection() }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.stickyAccent)

            Text("Sticky")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()

            if viewModel.peerCount > 0 {
                Circle()
                    .fill(Color(red: 0.30, green: 0.85, blue: 0.45))
                    .frame(width: 6, height: 6)
                Text(viewModel.peerName ?? "PC")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("no PC nearby")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 8)

            Button {
                if viewModel.isSelecting { viewModel.cancelSelection() } else { viewModel.enterSelectionMode() }
            } label: {
                Image(systemName: viewModel.isSelecting ? "xmark.circle" : "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(viewModel.isSelecting ? Color.stickyAccent : Color.white.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                viewModel.toggleClipboardSync()
            } label: {
                Image(systemName: viewModel.clipboardSyncEnabled ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.clipboardSyncEnabled ? Color.stickyAccent : Color.white.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Clipboard sync between Mac and PC")

            Button {
                viewModel.collapseExpanded()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var peerLabel: String {
        viewModel.peerCount > 0 ? "\(viewModel.peerCount) nearby" : "no PC nearby"
    }
}

/// Reusable content list shared by the expanded notch. Extracted from
/// ShelfView so both entry points stay in sync.
struct ShelfContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !viewModel.shelfFiles.isEmpty {
                    sectionHeader("Shelf", detail: "\(viewModel.shelfFiles.count)")
                    ForEach(viewModel.shelfFiles) { item in
                        NotchFileRow(viewModel: viewModel, item: item, url: item.url,
                                     subtitle: "Ready to send",
                                     sendTitle: "Send") {
                            viewModel.sendFiles([item.url])
                        } onRemove: {
                            viewModel.removeShelfItemPublic(id: item.id)
                        }
                    }

                    if !viewModel.pendingTransfers.isEmpty {
                        sectionHeader("Waiting for PC", detail: "\(viewModel.pendingTransfers.count)")
                        ForEach(viewModel.pendingTransfers) { transfer in
                            NotchFileRow(viewModel: viewModel, item: nil, url: transfer.items.first?.url ?? URL(fileURLWithPath: "/"),
                                         subtitle: transfer.attempts == 0 ? "Queued" : "Retry \(transfer.attempts)",
                                         sendTitle: "Send all",
                                         titleOverride: "\(transfer.items.count) item\(transfer.items.count == 1 ? "" : "s")",
                                         missingOK: true) {
                                viewModel.processPendingQueue(force: true)
                            } onRemove: {
                                viewModel.removePendingTransferPublic(id: transfer.id)
                            }
                        }
                    }

                    if !viewModel.clipboardHistory.isEmpty {
                        sectionHeader("Clips", detail: nil)
                        ForEach(Array(viewModel.clipboardHistory.prefix(6).enumerated()), id: \.element.id) { _, entry in
                            NotchClipRow(entry: entry,
                                         isCurrent: viewModel.stickySlot?.id == entry.id) {
                                viewModel.sendClipboardEntry(entry)
                            }
                        }
                    }
                } else if viewModel.pendingTransfers.isEmpty && viewModel.clipboardHistory.isEmpty {
                    emptyState
                } else {
                    if !viewModel.pendingTransfers.isEmpty {
                        sectionHeader("Waiting for PC", detail: "\(viewModel.pendingTransfers.count)")
                        ForEach(viewModel.pendingTransfers) { transfer in
                            NotchFileRow(viewModel: viewModel, item: nil, url: transfer.items.first?.url ?? URL(fileURLWithPath: "/"),
                                         subtitle: transfer.attempts == 0 ? "Queued" : "Retry \(transfer.attempts)",
                                         sendTitle: "Send all",
                                         titleOverride: titleForCount(transfer.items.count),
                                         missingOK: true) {
                                viewModel.processPendingQueue(force: true)
                            } onRemove: {
                                viewModel.removePendingTransferPublic(id: transfer.id)
                            }
                        }
                    }

                    if !viewModel.clipboardHistory.isEmpty {
                        sectionHeader("Clips", detail: nil)
                        ForEach(viewModel.clipboardHistory.prefix(6)) { entry in
                            NotchClipRow(entry: entry,
                                         isCurrent: viewModel.stickySlot?.id == entry.id) {
                                viewModel.sendClipboardEntry(entry)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
    }

    private func titleForCount(_ n: Int) -> String {
        n == 1 ? "1 item" : "\(n) items"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("Drag files onto the notch")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            Text("They wait here until your PC is around.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
                .kerning(0.18)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
            }
            Spacer()
        }
        .padding(.bottom, -4)
    }
}

private struct NotchFileRow: View {
    @ObservedObject var viewModel: NotchViewModel
    let item: StickyShelfItem?
    let url: URL
    let subtitle: String
    let sendTitle: String
    var titleOverride: String?
    var missingOK = false
    let onSend: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        HStack(spacing: 10) {
            thumb
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(titleOverride ?? url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                rowButton("paperplane.fill", tint: Color.stickyAccent, action: onSend)
                rowButton("trash", tint: Color.white.opacity(0.45), action: onRemove)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(rowShell)
        .scaleEffect(hovering ? 1.015 : 1.0)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
        .overlay(alignment: .leading) {
            if let item, viewModel.isSelecting || !viewModel.selectedShelfIDs.isEmpty {
                Button {
                    viewModel.toggleSelection(for: item.id)
                } label: {
                    Image(systemName: viewModel.selectedShelfIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(viewModel.selectedShelfIDs.contains(item.id) ? Color.stickyAccent : Color.white.opacity(0.35))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: -2)
            }
        }
    }

    /// Double-bezel: outer hairline tray, inner raised core with a top highlight.
    private var rowShell: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.14 : 0.08), lineWidth: 0.5)
            )
            .overlay(
                // inset top highlight — machined-glass look
                LinearGradient(
                    colors: [Color.white.opacity(hovering ? 0.10 : 0.06), .clear],
                    startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(0.5)
            )
    }

    @ViewBuilder
    private var thumb: some View {
        let ext = url.pathExtension.lowercased()
        if !exists, !missingOK {
            placeholderThumb(icon: "questionmark.folder")
        } else if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext),
                  let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            placeholderThumb(icon: nil, fileIcon: NSWorkspace.shared.icon(forFile: url.path))
        }
    }

    private func placeholderThumb(icon: String? = nil, fileIcon: NSImage? = nil) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07))
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            } else if let fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            }
        }
    }

    private func rowButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(tint.opacity(0.10))
                        .overlay(Circle().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct NotchClipRow: View {
    let entry: StickyClipEntry
    let isCurrent: Bool
    let onSend: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? Color.stickyAccent : Color.white.opacity(0.4))

            Text(previewText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.stickyAccent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.stickyAccent.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.14 : 0.08), lineWidth: 0.5)))
        .scaleEffect(hovering ? 1.015 : 1.0)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
    }

    private var previewText: String {
        let flat = entry.text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
    }
}

/// Corner rounding on selected corners only (the top stays flush with the screen).


/// The Slot: a live pocket between machines. One editor, one toolbar.
struct SlotView: View {
    @ObservedObject var viewModel: NotchViewModel
    @FocusState private var editorFocused: Bool

    private var hasContent: Bool { !viewModel.slotText.isEmpty || viewModel.slotImage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = viewModel.slotImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            }

            ZStack(alignment: .topLeading) {
                if !hasContent {
                    Text("Type or paste — it syncs to your PC.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.28))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { viewModel.slotText },
                    set: { viewModel.writeSlot(text: $0) }
                ))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: hasContent ? 170 : 72)
                .padding(5)
                .focused($editorFocused)
            }
            .background(slotShell)

            HStack(spacing: 7) {
                slotPill("Paste", icon: "doc.on.clipboard", primary: true) {
                    viewModel.pasteIntoSlot()
                }
                if hasContent {
                    slotPill("Copy", icon: "doc.on.doc", primary: false) {
                        viewModel.copySlotToPasteboard()
                    }
                    slotPill("Clear", icon: "xmark", primary: false, tint: .white) {
                        viewModel.slotText = ""
                        viewModel.slotImage = nil
                    }
                }

                Spacer()

                Circle()
                    .fill(viewModel.clipboardSyncEnabled
                          ? Color(red: 0.30, green: 0.85, blue: 0.45)
                          : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
                    .help(viewModel.clipboardSyncEnabled ? "Syncing to PC" : "Sync off — toggle with ⇄ above")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private func slotPill(_ title: String, icon: String, primary: Bool, tint: Color = Color.stickyAccent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(primary ? Color.black : Color.white.opacity(0.75))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(primary ? tint : Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(primary ? 0 : 0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var slotShell: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
