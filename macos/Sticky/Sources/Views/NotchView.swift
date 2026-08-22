import SwiftUI

struct NotchView: View {
    @StateObject var viewModel: NotchViewModel
    @Environment(\.notchGeometry) private var geometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var failureProgress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.001))
                .frame(width: interactionSize.width, height: interactionSize.height)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], delegate: viewModel)
                .onHover { hovering in
                    viewModel.setPointerHover(hovering)
                }

            island
                .allowsHitTesting(false)
        }
        .frame(width: max(geometry.rect.width + 40, 220), alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var displayState: NotchState {
        viewModel.state
    }

    private var island: some View {
        let dimensions = islandDimensions
        let size = CGSize(width: dimensions.width + 12, height: dimensions.height)

        return TimelineView(
            .animation(minimumInterval: 1 / 30, paused: reduceMotion || warpIntensity < 0.03)
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
        switch displayState {
        case .idle:
            return 0
        case .hover:
            return 0
        case .armed:
            return 0.34
        case .transferring:
            return 0.54
        case .queued:
            return 0.24
        case .success:
            return 0.28
        case .failure:
            return 0
        case .incomingOffer:
            return 0.44
        }
    }

    private func warpPhase(for date: Date) -> CGFloat {
        guard !reduceMotion else { return 0.35 }
        let period = 1.35
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return CGFloat(elapsed / period)
    }

    private var idleHintOpacity: CGFloat {
        viewModel.shelfFiles.isEmpty && viewModel.pendingTransfers.isEmpty ? 0.0 : 1.0
    }

    private var islandDimensions: (width: CGFloat, height: CGFloat, cornerRadius: CGFloat, shadowOpacity: Double, shadowRadius: CGFloat) {
        let width = max(geometry.rect.width, 120)
        let baseHeight = max(geometry.rect.height, 22)
        let pull = viewModel.dropMagnetism

        switch displayState {
        case .idle:
            return (width, baseHeight, 11, 0, 0)
        case .hover:
            return (width + 16, baseHeight + 22 + pull * 4, 17, 0.34 + pull * 0.06, 15)
        case .armed:
            return (width + 34, baseHeight + 34, 20, 0.44, 20)
        case .transferring:
            return (width + 46, baseHeight + 38, 22, 0.48, 22)
        case .queued:
            return (width + 34, baseHeight + 32, 20, 0.40, 18)
        case .success:
            return (width + 22, baseHeight + 26, 19, 0.36, 16)
        case .failure:
            return (width + 42, baseHeight + 34, 20, 0.40, 18)
        case .incomingOffer:
            return (width + 50, baseHeight + 36, 22, 0.46, 20)
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
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.stickyAmber.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .modifier(BreathingDot(reduceMotion: reduceMotion))
                Text("Sticky")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .kerning(0.6)
            }
            .opacity(idleHintOpacity)
        case .hover:
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stickyAmber)
                    .modifier(ArmedPullSymbol(reduceMotion: reduceMotion))
                Text("Drop to send")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
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
                    .foregroundStyle(Color.stickyAmber.opacity(0.9))
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
                    .foregroundStyle(Color.stickyAmber)
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
                                    .init(color: Color.stickyCream, location: 0),
                                    .init(color: Color.stickyAmber, location: 0.5),
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
                .foregroundStyle(Color.stickyAmber.opacity(0.88))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) item\(count == 1 ? "" : "s") waiting for the PC")
    }

    private func successContent(count: Int) -> some View {
        HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.stickyCream)
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
                .foregroundStyle(Color.stickyAmber.opacity(0.92))
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
                    .foregroundStyle(Color.stickyAmber)
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
                                ? Color.stickyAmber.opacity(0.34 * fade)
                                : Color.stickyCream.opacity(0.38 * fade)
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
                            colors: [.clear, .white.opacity(0.45), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: geo.size.height * 2)
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
