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
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let waveRadius = rect.width * (0.16 + phase * 0.72)
        let spread = rect.width * 0.28
        let amplitude = rect.height * 0.34 * intensity

        func displacement(at point: CGPoint) -> CGFloat {
            let distance = abs(point.x - center.x)
            let ring = exp(-pow((distance - waveRadius) / spread, 2))
            return amplitude * ring
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

            let origin = CGPoint(x: size.width / 2, y: size.height)
            let maximumRadius = max(size.width, size.height) * 1.15

            context.addFilter(.blur(radius: size.width * 0.08))
            context.blendMode = .plusLighter

            let glowRect = CGRect(
                x: origin.x - maximumRadius,
                y: origin.y - maximumRadius,
                width: maximumRadius * 2,
                height: maximumRadius * 2
            )
            context.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Color.stickyCream.opacity(0.46 * intensity), location: 0),
                        .init(color: Color.stickyAmber.opacity(0.18 * intensity), location: 0.32),
                        .init(color: .clear, location: 1)
                    ]),
                    center: origin,
                    startRadius: 0,
                    endRadius: maximumRadius
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
    static let stickyCream = Color(red: 1.0, green: 0.965, blue: 0.898)
    static let stickyAmber = Color(red: 1.0, green: 0.757, blue: 0.471)
}

extension NSColor {
    static let stickyAmber = NSColor(red: 1.0, green: 0.757, blue: 0.471, alpha: 1)
}
