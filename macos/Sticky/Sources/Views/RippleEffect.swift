import SwiftUI

/// A soft lower-edge displacement inspired by Apple's NameDrop transition.
///
/// The camera housing and concave shoulders stay anchored while the visible
/// lower edge flexes in one continuous wave. This is intentionally not a
/// metaball, droplet, or set of stroked rings.
struct NameDropWarpShape: Shape {
    var phase: CGFloat
    var intensity: CGFloat
    var cameraRect: CGRect?

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(phase, intensity) }
        set {
            phase = newValue.first
            intensity = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let topRadius = CGFloat(6)
        let bottomRadius = CGFloat(18)
        // Radial origin slightly off-centre (NameDrop's ring is organic, not
        // symmetric) + a trailing second harmonic so both edges don't move
        // in perfect sync.
        let center = CGPoint(x: rect.midX - rect.width * 0.06, y: rect.maxY)
        let maxReach = hypot(rect.width / 2, rect.height)
        let waveRadius = maxReach * (0.10 + phase * 0.85)
        let spread = rect.width * 0.11   // crisp ring, not a broad bump
        let amplitude = rect.height * 0.42 * intensity

        func displacement(at point: CGPoint) -> CGFloat {
            let d = hypot(point.x - center.x, point.y - center.y)
            let primary = exp(-pow((d - waveRadius) / spread, 2))
            // Trailing harmonic at 0.6× radius, 40% strength — breaks symmetry.
            let trail = exp(-pow((d - waveRadius * 0.6) / (spread * 1.4), 2))
            return amplitude * (primary + 0.4 * trail * phase)
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(
            to: CGPoint(
                x: rect.minX + topRadius,
                y: rect.maxY - bottomRadius
            )
        )
        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topRadius + bottomRadius,
                y: rect.maxY + displacement(at: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY))
            ),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )

        let sampleCount = max(48, Int(rect.width / 3))
        let straightEnd = rect.maxX - topRadius - bottomRadius
        for index in 1...sampleCount {
            let progress = CGFloat(index) / CGFloat(sampleCount)
            let x = rect.minX + topRadius + bottomRadius + (straightEnd - (rect.minX + topRadius + bottomRadius)) * progress
            let point = CGPoint(x: x, y: rect.maxY)
            path.addLine(to: CGPoint(x: point.x, y: point.y + displacement(at: point)))
        }

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(
                x: rect.maxX - topRadius,
                y: rect.maxY + displacement(at: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
            )
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}

struct NameDropGlow: View {
    let phase: CGFloat
    let intensity: CGFloat
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            guard intensity > 0.01, !reduceMotion else { return }

            let origin = CGPoint(x: size.width / 2 - size.width * 0.06, y: size.height)
            let maxReach = hypot(size.width / 2, size.height)

            // Ambient bloom near the origin
            context.addFilter(.blur(radius: size.width * 0.06))
            context.blendMode = .plusLighter

            let ambientRadius = size.width * 0.55
            let ambientRect = CGRect(
                x: origin.x - ambientRadius, y: origin.y - ambientRadius,
                width: ambientRadius * 2, height: ambientRadius * 2
            )
            context.fill(
                Path(ellipseIn: ambientRect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Color.stickyIvory.opacity(0.16 * intensity), location: 0),
                        .init(color: Color.stickyAccent.opacity(0.08 * intensity), location: 0.4),
                        .init(color: .clear, location: 1)
                    ]),
                    center: origin,
                    startRadius: 0,
                    endRadius: ambientRadius
                )
            )

            // The traveling NameDrop ring — bright edge riding the wavefront
            let ringRadius = maxReach * (0.10 + phase * 0.85)
            let band = size.width * 0.12
            context.fill(
                Path(ellipseIn: CGRect(
                    x: origin.x - ringRadius - band, y: origin.y - ringRadius - band,
                    width: (ringRadius + band) * 2, height: (ringRadius + band) * 2
                )),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.stickyAccent.opacity(0.34 * intensity), location: 1),
                        .init(color: .clear, location: 1)
                    ]),
                    center: origin,
                    startRadius: ringRadius * 0.82,
                    endRadius: ringRadius + band
                )
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct RippleEffect: ViewModifier {
    var progress: Double
    var center: CGPoint = CGPoint(x: 0.5, y: 0.0)
    var reduceMotion = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    NameDropGlow(
                        phase: progress.truncatingRemainder(dividingBy: 1),
                        intensity: progress,
                        reduceMotion: reduceMotion
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .position(
                        x: geo.size.width * center.x,
                        y: geo.size.height * center.y
                    )
                }
            )
    }
}

extension View {
    func rippleEffect(progress: Double, center: CGPoint = CGPoint(x: 0.5, y: 0.0), reduceMotion: Bool = false) -> some View {
        modifier(RippleEffect(progress: progress, center: center, reduceMotion: reduceMotion))
    }
}

extension Color {
    /// Apple-utility blue (Finder/AirDrop family) — calm, not warning-yellow.
    static let stickyAccent = Color(red: 0.35, green: 0.62, blue: 1.0)
    /// Soft cool-white for highlights instead of warm cream.
    static let stickyIvory = Color(red: 0.92, green: 0.96, blue: 1.0)
}

extension NSColor {
    static let stickyAccent = NSColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1)
}
