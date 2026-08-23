import SwiftUI

/// The notch silhouette: concave top shoulders that hug the hardware, rounded
/// bottom corners, and a bottom edge that can swell or carry a one-shot ripple.
///
/// Four inputs. Both radii animate (plan §3.3 — closed 6/14 → open 15/20), and
/// the two displacement terms are zero at rest:
///   • `bloom`  — a symmetric swell of the lower edge; the steady-state pull.
///   • `ripple` — a single wavefront travelling out from centre, dead at 1.
///                Fired on an event, never looped.
///
/// At rest the path is the plain cutout. That matters: the old build ran a
/// cosine loop forever, so the bottom edge was permanently and asymmetrically
/// morphing, and the app burned ~11% CPU redrawing a shape nobody asked to move.
/// The notch silhouette: concave top shoulders that hug the hardware and
/// rounded bottom corners, both radii animating as it opens.
///
/// There is deliberately no edge deformation. Earlier versions warped the
/// bottom edge with a travelling wave, and it read as exactly what it was —
/// a rubbery blob stuck to the hardware. The notch is a machined cutout; it
/// changes size, it does not ripple. Light is the only thing that moves.
struct NotchShellShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Backing scale, so every point that reaches the path lands on a whole
    /// pixel (plan §3.2.5) — a half-point edge is a real half-pixel at 2× and
    /// shimmers as the shape animates.
    var scale: CGFloat = 2

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let topRadius = min(self.topRadius, rect.width / 4)
        let bottomRadius = min(self.bottomRadius, rect.height / 2, rect.width / 4)
        let leftEdge = rect.minX + topRadius
        let rightEdge = rect.maxX - topRadius

        func snap(_ value: CGFloat) -> CGFloat { DS.snap(value, scale: scale) }

        var path = Path()
        // Top-left concave shoulder, growing out of the bezel.
        path.move(to: CGPoint(x: snap(rect.minX), y: snap(rect.minY)))
        path.addQuadCurve(
            to: CGPoint(x: snap(leftEdge), y: snap(rect.minY + topRadius)),
            control: CGPoint(x: snap(leftEdge), y: snap(rect.minY))
        )
        path.addLine(to: CGPoint(x: snap(leftEdge), y: snap(rect.maxY - bottomRadius)))
        path.addQuadCurve(
            to: CGPoint(x: snap(leftEdge + bottomRadius), y: snap(rect.maxY)),
            control: CGPoint(x: snap(leftEdge), y: snap(rect.maxY))
        )
        path.addLine(to: CGPoint(x: snap(rightEdge - bottomRadius), y: snap(rect.maxY)))
        path.addQuadCurve(
            to: CGPoint(x: snap(rightEdge), y: snap(rect.maxY - bottomRadius)),
            control: CGPoint(x: snap(rightEdge), y: snap(rect.maxY))
        )
        path.addLine(to: CGPoint(x: snap(rightEdge), y: snap(rect.minY + topRadius)))
        path.addQuadCurve(
            to: CGPoint(x: snap(rect.maxX), y: snap(rect.minY)),
            control: CGPoint(x: snap(rightEdge), y: snap(rect.minY))
        )
        path.closeSubpath()
        return path
    }
}

/// A single expanding halo below the cutout. Draws nothing at rest, so idle
/// costs zero — and never composites light over the camera band (§3.2.6).
struct NotchRippleGlow: View {
    let bloom: CGFloat
    let ripple: CGFloat
    /// Height of the physical cutout. Everything here is drawn below it.
    let cameraClearance: CGFloat

    var body: some View {
        Canvas { context, size in
            guard bloom > 0.01 || (ripple > 0 && ripple < 1) else { return }

            let origin = CGPoint(x: size.width / 2, y: size.height)
            context.blendMode = .plusLighter

            if bloom > 0.01 {
                let radius = size.width * 0.45
                context.addFilter(.blur(radius: size.width * 0.05))
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: origin.x - radius, y: origin.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: DS.Colors.amber.opacity(0.20 * bloom), location: 0),
                            // Fading to `.clear` interpolates through grey and
                            // leaves a visible fringe (§10.8) — fade the hue.
                            .init(color: DS.Colors.fade(DS.Colors.amber), location: 1)
                        ]),
                        center: origin, startRadius: 0, endRadius: radius
                    )
                )
            }

            guard ripple > 0, ripple < 1 else { return }
            let radius = size.width * 0.55 * ripple
            let decay = (1 - ripple) * (1 - ripple)
            context.addFilter(.blur(radius: 2))
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: origin.x - radius, y: origin.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(DS.Colors.warmWhite.opacity(0.42 * decay)),
                lineWidth: max(size.width * 0.028, 2)
            )
        }
        // Nothing luminous may cross into the camera region.
        .padding(.top, cameraClearance)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
