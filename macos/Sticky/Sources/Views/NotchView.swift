import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @StateObject var viewModel: NotchViewModel
    @Environment(\.notchGeometry) private var geometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var failureProgress: CGFloat = 0
    /// 1 means spent. A ripple fires by snapping to 0 and animating back — it
    /// never loops, so the notch is perfectly still at rest.
    @State private var ripple: CGFloat = 1
    /// Plan §4.2: a 40–70 ms pulse to ~1.05× when a drag locks on.
    @State private var lockPulse: CGFloat = 1
    @State private var wasIdle = true
    /// 0 = the panel is still the notch, 1 = fully open. Everything about the
    /// opening is derived from this one value so the shape, the corner radii
    /// and the content all arrive together.
    @State private var openProgress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            // Purely decorative. Hover, click and drop all belong to the sensor
            // panel, which is exactly the cutout at rest — this layer never
            // intercepts anything.
            if openProgress < 1 {
                island
                    .opacity(1 - openProgress * 2.2)   // gone by the time the panel has real size
            }

            if openProgress > 0.0001 {
                expandedLayer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onChange(of: viewModel.isExpanded) { _, expanded in
            withAnimation(reduceMotion ? DS.Motion.reduced : (expanded ? DS.Motion.panelOpen : DS.Motion.panelClose)) {
                openProgress = expanded ? 1 : 0
            }
        }
        .onChange(of: reduceMotion) { _, newValue in viewModel.reducesMotion = newValue }
        .onAppear {
            viewModel.reducesMotion = reduceMotion
            publishDropProbe()
        }
        .onChange(of: geometry.rect.width) { _, _ in publishDropProbe() }
        .onChange(of: displayState) { _, newState in handleStateChange(newState) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Geometry

    private var cutout: CGSize {
        CGSize(width: geometry.rect.width, height: geometry.rect.height)
    }

    /// Plan §3.2.6: content begins at notchHeight + 10 pt. Nothing — text,
    /// icon, border or light — ever enters the camera band.
    private var cameraBand: CGFloat { cutout.height + DS.Space.cameraClearance }

    private func publishDropProbe() {
        let size = NotchLayout.hoverSize(notchWidth: cutout.width, notchHeight: cutout.height)
        viewModel.setDropProbe(width: size.width, height: size.height)
    }

    private var displayState: NotchState { viewModel.state }

    private func handleStateChange(_ newState: NotchState) {
        let nowIdle = newState == .idle
        defer { wasIdle = nowIdle }

        guard !reduceMotion else { return }

        if case .failure = newState {
            failureProgress = 0
            withAnimation(.timingCurve(0.32, 0, 0.24, 1, duration: 0.58)) { failureProgress = 1 }
        } else if failureProgress != 0 {
            snap { failureProgress = 0 }
        }

        if newState.firesRipple {
            snap { ripple = 0 }
            withAnimation(.easeOut(duration: 0.62)) { ripple = 1 }
        }

        // The lock pulse belongs to arming only — never repeated while hovering.
        if case .armed = newState {
            withAnimation(.easeOut(duration: DS.Motion.lockPulseDuration)) {
                lockPulse = DS.Motion.lockPulseScale
            }
            withAnimation(.easeIn(duration: DS.Motion.lockPulseDuration).delay(DS.Motion.lockPulseDuration)) {
                lockPulse = 1
            }
        }
    }

    private func snap(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    // MARK: - Opening out of the notch

    /// The panel is laid out once at full size and revealed through a mask that
    /// starts as the cutout and grows into the panel. Masking rather than
    /// resizing matters: the content never relayouts mid-animation, so nothing
    /// reflows or jitters, and the shape reads as the notch itself stretching
    /// open rather than a window appearing on top of it.
    private var expandedLayer: some View {
        let p = openProgress
        let width = lerp(cutout.width, NotchLayout.expandedWidth, p)
        let height = lerp(cutout.height, NotchLayout.expandedHeight, p)
        // The corners open from the cutout's own radius to the panel's.
        let radius = lerp(DS.Radius.notchBottomClosed, DS.Radius.panel, p)

        return ExpandedPanel(viewModel: viewModel)
            .frame(width: NotchLayout.expandedWidth, height: NotchLayout.expandedHeight)
            // Content arrives once there is somewhere to put it, so text never
            // appears squeezed into a notch-sized sliver.
            .opacity(Double(((p - 0.22) / 0.45).clamped(to: 0...1)))
            .mask(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: radius,
                    bottomTrailingRadius: radius,
                    style: .continuous
                )
                .frame(width: width, height: height)
                .frame(
                    width: NotchLayout.expandedWidth,
                    height: NotchLayout.expandedHeight,
                    alignment: .top
                )
            )
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }

    // MARK: - The island

    private var island: some View {
        let shape = islandShape
        let shell = NotchShellShape(
            topRadius: shape.topRadius,
            bottomRadius: shape.bottomRadius,
            scale: displayScale
        )
        // Growing is springy, collapsing is smooth — a bouncing close reads as
        // indecision (plan §4.3).
        let growing = wasIdle || displayState != .idle
        let motion = DS.Motion.springy(growing, reduceMotion: reduceMotion)

        return shell
            .fill(DS.Colors.notchBody.opacity(geometry.isVirtual && displayState == .idle ? 0 : 1))
            .frame(width: shape.width, height: shape.height)
            .overlay {
                ZStack {
                    NotchRippleGlow(bloom: glow, ripple: ripple, cameraClearance: cutout.height)
                        .frame(width: shape.width, height: shape.height)

                    VStack(spacing: 0) {
                        Color.clear.frame(height: cameraBand)
                        ZStack {
                            if let filamentDirection {
                                FilamentHandoff(direction: filamentDirection, reduceMotion: reduceMotion)
                                    .frame(height: 20)
                            }
                            islandContent
                                .padding(.horizontal, DS.Space.l)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(shell)
            }
            // Clipped to below the cutout: nothing soft may meet the bezel (§10.2).
            .shadow(color: .black.opacity(shape.shadowOpacity), radius: shape.shadowRadius, y: 4)
            .scaleEffect(reduceMotion ? 1 : lockPulse)
            .modifier(RestrainedShake(progress: failureProgress))
            .animation(motion, value: displayState)
            .animation(motion, value: viewModel.dropMagnetism)
    }

    /// Ambient light under the cutout. Zero at idle — at rest the notch is the
    /// notch: an unmoving cutout that emits nothing.
    private var glow: CGFloat {
        switch displayState {
        case .idle:          return 0
        case .hover:         return 0.28 + viewModel.dropMagnetism * 0.32
        case .armed:         return 0.65
        case .transferring:  return 0.55
        case .queued:        return 0.40
        case .success:       return 0.45
        case .failure:       return 0
        case .incomingOffer: return 0.60
        }
    }

    /// Plan §4.2: the portal is compact — never wider than 320 pt, never deeper
    /// than 70 pt below the notch.
    private struct IslandShape {
        var width: CGFloat
        var height: CGFloat
        var topRadius: CGFloat
        var bottomRadius: CGFloat
        var shadowOpacity: Double
        var shadowRadius: CGFloat
    }

    private var islandShape: IslandShape {
        let w = cutout.width
        let h = cutout.height
        let pull = viewModel.dropMagnetism

        func portal(_ extraWidth: CGFloat, _ extraHeight: CGFloat, shadow: Double, blur: CGFloat) -> IslandShape {
            IslandShape(
                width: min(w + extraWidth, NotchLayout.maxPortalWidth),
                height: h + min(extraHeight, NotchLayout.maxPortalDepth),
                topRadius: DS.Radius.notchTopOpen,
                bottomRadius: DS.Radius.notchBottomOpen,
                shadowOpacity: shadow,
                shadowRadius: blur
            )
        }

        switch displayState {
        case .idle:
            // Exactly the cutout: at rest Sticky draws zero visible pixels.
            return IslandShape(
                width: w, height: h,
                topRadius: DS.Radius.notchTopClosed,
                bottomRadius: DS.Radius.notchBottomClosed,
                shadowOpacity: 0, shadowRadius: 0
            )
        case .hover:
            return IslandShape(
                width: w + 24 + pull * 6,
                height: h + NotchLayout.hoverIslandDepth + pull * 4,
                topRadius: DS.Radius.notchTopOpen,
                bottomRadius: DS.Radius.notchBottomOpen,
                shadowOpacity: 0.18 + pull * 0.04,
                shadowRadius: 9
            )
        case .armed:         return portal(96, 34, shadow: 0.26, blur: 13)
        case .transferring:  return portal(110, 36, shadow: 0.28, blur: 14)
        case .queued:        return portal(96, 32, shadow: 0.24, blur: 12)
        case .success:       return portal(58, 26, shadow: 0.22, blur: 11)
        case .failure:       return portal(104, 32, shadow: 0.24, blur: 12)
        case .incomingOffer: return portal(115, 36, shadow: 0.26, blur: 13)
        }
    }

    private var filamentDirection: FilamentDirection? {
        switch displayState {
        case .armed, .transferring: return .sending
        case .incomingOffer:        return .receiving
        default:                    return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var islandContent: some View {
        switch displayState {
        case .idle:
            Color.clear
        case .hover:
            hoverContent
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

    /// Hover is an invitation, not a form. The Slot editor lives in the
    /// expanded panel, where the window is allowed to own the keyboard.
    /// The notch grows DOWN, not sideways. A pill stretched wide enough to fit
    /// a sentence stops reading as the notch; a second line keeps the silhouette
    /// close to the hardware and matches how the Dynamic Island behaves.
    /// No "Drop to send" label: the notch is already a drop target and the
    /// shape says so. What's left is either one button or one quiet hint.
    private var hoverContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if viewModel.pasteboardPreview != nil {
                // Drawn to match the sensor's action rect exactly, so what
                // looks clickable is what is clickable.
                clipboardButton
                    .frame(
                        width: NotchLayout.clipboardActionRect(
                            notchWidth: cutout.width,
                            notchHeight: cutout.height
                        ).width,
                        height: NotchLayout.hoverActionHeight
                    )
                    .padding(.bottom, NotchLayout.hoverActionBottomInset)
            } else {
                Text(shelfHint)
                    .font(DS.Type_.caption())
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize()
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Says what it DOES, never what you copied.
    ///
    /// It used to print the clipboard's contents on the bezel — the most
    /// visible strip of the screen, in every screen share, to everyone behind
    /// you. Copying is a private act; the preview belongs inside the shelf,
    /// which you have to deliberately open.
    private var clipboardButton: some View {
        HStack(spacing: DS.Space.xs + 1) {
            Image(systemName: "doc.on.clipboard")
                .font(DS.Type_.symbol(10, matching: .semibold))
            Text(viewModel.pasteboardKindLabel)
                .font(DS.Type_.title(11))
                .lineLimit(1)
        }
        .foregroundStyle(DS.Colors.onControl)
        .padding(.horizontal, DS.Space.m)
        .frame(maxWidth: .infinity)
        .frame(height: NotchLayout.hoverActionHeight)
        // Concentric: the island's bottom radius less this button's inset.
        .background(
            RoundedRectangle(
                cornerRadius: DS.Radius.concentric(in: DS.Radius.notchBottomOpen, inset: 4),
                style: .continuous
            )
            .fill(DS.Colors.control)
        )
    }

    /// One hint at a time, most actionable first: if there is text ready to go,
    /// say how to send it; otherwise report the queue; otherwise invite a click.
    private var shelfHint: String {
        if viewModel.pasteboardPreview != nil { return "⌥click sends text" }
        let waiting = viewModel.shelfFiles.count + viewModel.pendingTransfers.count
        return waiting > 0 ? "\(waiting) waiting" : "click to open"
    }

    /// Plan §4.2 Armed: the filename, middle-truncated — or "4 files" — under
    /// the label "Release to send to PC".
    private func armedContent(count: Int, previewData: Data?) -> some View {
        HStack(spacing: DS.Space.m) {
            previewView(for: previewData)
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.armedTitle ?? "\(count) files")
                    .font(DS.Type_.title(12))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Release to send to PC")
                    .font(DS.Type_.caption())
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            Image(systemName: "arrow.up.circle.fill")
                .font(DS.Type_.symbol(17, matching: .semibold))
                .foregroundStyle(DS.Colors.control)
        }
    }

    /// Same QuickLook tile the shelf chips use, so a dropped file looks the
    /// same wherever it appears — and costs nothing on the main thread.
    @ViewBuilder
    private func previewView(for data: Data?) -> some View {
        let radius = DS.Radius.concentric(in: DS.Radius.chip, inset: 2)
        if let url = viewModel.armedPreviewURL {
            FileThumbnail(url: url, side: 28, cornerRadius: radius, missingIsExpected: true)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(DS.Colors.hairlineStrong, lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.fill")
                .font(DS.Type_.symbol(14, matching: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func transferContent(progress: Double, fileName: String?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(DS.Type_.symbol(13, matching: .medium))
                    .foregroundStyle(DS.Colors.control)
                    .accessibilityHidden(true)
                Text(fileName ?? "Sending")
                    .font(DS.Type_.body(11))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.xs)
                // No large percentage counter until the transfer has earned one.
                if viewModel.transferIsLong {
                    Text("\(percentText(progress))%")
                        .font(DS.Type_.body(11))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.textTertiary)
                        .transition(.opacity)
                } else if let peer = viewModel.peerName {
                    Text(peer)
                        .font(DS.Type_.caption())
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.surface)
                    Capsule()
                        .fill(LinearGradient(gradient: DS.Colors.ramp, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(proxy.size.width * progress.clamped(to: 0...1), 3))
                }
            }
            .frame(height: 3)
            .animation(reduceMotion ? DS.Motion.reduced : DS.Motion.progress, value: progress)
        }
    }

    private func queuedContent(count: Int, previewData: Data?) -> some View {
        HStack(spacing: DS.Space.m) {
            previewView(for: previewData)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "1 item queued" : "\(count) items queued")
                    .font(DS.Type_.title(12))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text("Waiting for your PC")
                    .font(DS.Type_.caption())
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            Image(systemName: "clock")
                .font(DS.Type_.symbol(15, matching: .medium))
                .foregroundStyle(DS.Colors.control)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) item\(count == 1 ? "" : "s") waiting for the PC")
    }

    private func successContent(count: Int) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "checkmark.circle.fill")
                .font(DS.Type_.symbol(16, matching: .semibold))
                .foregroundStyle(DS.Colors.warmWhite)
                .modifier(SuccessCheckSymbol(reduceMotion: reduceMotion, trigger: count))
                .accessibilityHidden(true)
            Text(count == 1 ? "Sent" : "\(count) items sent")
                .font(DS.Type_.title(12))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// Plan §4.2 Failure: a specific reason, never "Something went wrong."
    private func failureContent(reason: String?) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Type_.symbol(13, matching: .medium))
                .foregroundStyle(DS.Colors.control)
                .accessibilityHidden(true)
            Text(reason?.isEmpty == false ? reason! : "PC did not answer")
                .font(DS.Type_.body(11))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func incomingContent(senderName: String, count: Int, kind: TransferKind) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: kind == .files ? "arrow.down.circle.fill" : "text.bubble.fill")
                .font(DS.Type_.symbol(17, matching: .semibold))
                .foregroundStyle(DS.Colors.control)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(senderName)
                    .font(DS.Type_.title(12))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kind == .files
                     ? (count == 1 ? "Receiving 1 item" : "Receiving \(count) items")
                     : "Receiving message")
                    .font(DS.Type_.caption())
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            ProgressView()
                .controlSize(.small)
                .tint(DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Receiving \(count) incoming \(kind == .files ? "items" : "messages") from \(senderName)")
    }

    private func percentText(_ progress: Double) -> Int {
        Int((progress.clamped(to: 0...1) * 100).rounded())
    }

    private var accessibilityLabel: String {
        switch displayState {
        case .idle:
            return "Sticky notch, drop files to send"
        case .hover:
            return "Ready to receive files"
        case .armed(let count, _):
            return "Holding \(count) items, release to send"
        case .transferring(let progress, let fileName):
            return "Sending \(fileName ?? "files"), \(percentText(progress)) percent complete"
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

private extension NotchState {
    /// Which transitions deserve a single outward wavefront.
    var firesRipple: Bool {
        switch self {
        case .armed, .success, .incomingOffer: return true
        default: return false
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

enum FilamentDirection {
    case sending
    case receiving
}

struct FilamentHandoff: View {
    let direction: FilamentDirection
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Canvas { canvasContext, size in
                let trackRect = CGRect(
                    x: size.width * 0.08, y: size.height / 2 - 1,
                    width: size.width * 0.84, height: 2
                )
                canvasContext.fill(Path(roundedRect: trackRect, cornerRadius: 1), with: .color(DS.Colors.surface))

                let elapsed = context.date.timeIntervalSinceReferenceDate
                let cycleDuration = 1.7
                let pulseCount = 3

                for index in 0..<pulseCount {
                    var fraction = (elapsed / cycleDuration + Double(index) / Double(pulseCount))
                        .truncatingRemainder(dividingBy: 1)
                    if direction == .receiving { fraction = 1 - fraction }

                    let x = trackRect.minX + trackRect.width * fraction
                    let fade = sin(fraction * .pi)
                    let pulse = Path(roundedRect: CGRect(x: x - 5, y: trackRect.midY - 2, width: 10, height: 4), cornerRadius: 2)

                    canvasContext.addFilter(.blur(radius: 2.5))
                    canvasContext.fill(pulse, with: .color(DS.Colors.control.opacity(0.38 * fade)))
                    canvasContext.addFilter(.blur(radius: 0.4))
                    canvasContext.fill(pulse, with: .color(DS.Colors.warmWhite.opacity(0.52 * fade)))
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: DS.Colors.fade(.white), location: 0),
                    .init(color: .white, location: 0.18),
                    .init(color: .white, location: 0.82),
                    .init(color: DS.Colors.fade(.white), location: 1)
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct RestrainedShake: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        let decayed = progress == 0 || progress >= 1 ? 0 : sin(progress * .pi * 4) * 3.5 * (1 - progress)
        return content.offset(x: decayed)
    }
}

struct SuccessCheckSymbol: ViewModifier {
    let reduceMotion: Bool
    let trigger: Int

    func body(content: Content) -> some View {
        if reduceMotion { content } else { content.symbolEffect(.bounce, value: trigger) }
    }
}
