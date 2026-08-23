import SwiftUI

/// Every colour, radius, spacing step and spring in one file.
///
/// Plan §10.7 makes this a lint rule: a literal colour, corner radius or spring
/// constant in a view file is a build failure. The reason is not tidiness — it
/// is that the old build drifted into nine different spring pairs and two
/// accent colours, and no one could answer "what does this app look like?"
enum DS {

    // MARK: Colour
    //
    // Plan §15.1: warm white into gold. "No pink, purple or blue anywhere."
    // NameDrop's glow is warm monochrome; a blue accent would make a file
    // transfer read as a system alert. Apple publishes no hex — #FFF6E5 →
    // #FFC178 is our synthesis, labelled as such.
    enum Colors {
        /// Plan §10.2: the notch body is flat #000 because it touches physical
        /// black bezel. A "premium" near-black reads as a grey rectangle glued
        /// to the hardware.
        static let notchBody = Color.black

        /// The warm end of the ramp — highlights, checkmarks, bright edges.
        static let warmWhite = Color(red: 1.0, green: 0.965, blue: 0.898)   // #FFF6E5
        /// The gold end — the spill, the progress fill, the live indicator.
        static let amber = Color(red: 1.0, green: 0.757, blue: 0.471)       // #FFC178

        static let ramp = Gradient(colors: [warmWhite, amber])

        /// Interactive controls follow the user's System Settings accent, the
        /// way every other Mac button does — a control that ignores it looks
        /// like it belongs to a different operating system.
        ///
        /// Ambient light (the glow, the send ripple) deliberately does NOT use
        /// this: that isn't chrome, it's the NameDrop-family warm glow, and a
        /// pink system accent must not turn the notch pink.
        static let control = Color(nsColor: .controlAccentColor)
        /// Text and glyphs sitting on `control`. macOS draws white on the
        /// accent for default buttons; matching that keeps contrast correct
        /// whichever accent the user picked.
        static let onControl = Color.white

        /// Text tiers. Nothing here is pure white: on flat #000 it vibrates.
        static let textPrimary = Color.white.opacity(0.92)
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.40)
        static let textFaint = Color.white.opacity(0.26)

        /// Surfaces inside the expanded panel.
        static let surface = Color.white.opacity(0.045)
        static let surfaceHover = Color.white.opacity(0.08)
        static let hairline = Color.white.opacity(0.08)
        static let hairlineStrong = Color.white.opacity(0.14)

        /// Plan §10.6 bans a second accent, and for ordinary controls that
        /// holds — "destructive" is weight and wording. The one exception is
        /// the remove badge on a shelf chip: every Mac user reads a red circle
        /// there and nothing else, and a delete nobody finds is worse than a
        /// second hue. System red, so it tracks the OS rather than inventing.
        static let destructive = Color.white.opacity(0.85)
        static let destructiveBadge = Color(nsColor: .systemRed)

        /// A glow must never fade to `.clear` — that interpolates through grey
        /// and leaves a visible fringe (§10.8). Fade to the same hue at zero.
        static func fade(_ color: Color) -> Color { color.opacity(0) }
    }

    // MARK: Type
    //
    // Plan §10.4: system font throughout; 11 pt is the floor for readable UI
    // text and nothing in the portal goes below it.
    enum Type_ {
        static let floor: CGFloat = 11

        static func title(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
        static func body(_ size: CGFloat = 12) -> Font { .system(size: max(size, floor), weight: .medium, design: .rounded) }
        static func caption(_ size: CGFloat = 11) -> Font { .system(size: max(size, floor), weight: .regular, design: .rounded) }
        /// Plan §10.5: a symbol's weight matches the text beside it.
        static func symbol(_ size: CGFloat, matching weight: Font.Weight) -> Font { .system(size: size, weight: weight) }
    }

    // MARK: Metrics
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 7
        static let m: CGFloat = 11
        static let l: CGFloat = 16
        static let xl: CGFloat = 22

        /// Plan §3.2.6: content begins at notchHeight + 10, never flush against
        /// the cutout.
        static let cameraClearance: CGFloat = 10
    }

    enum Radius {
        /// Plan §3.3: the silhouette's radii animate closed → open.
        static let notchTopClosed: CGFloat = 6
        static let notchTopOpen: CGFloat = 15
        static let notchBottomClosed: CGFloat = 14
        static let notchBottomOpen: CGFloat = 20

        static let chip: CGFloat = 12
        static let row: CGFloat = 11
        static let panel: CGFloat = 22

        /// Plan §10.3: a nested radius is outer − padding, never eyeballed.
        static func concentric(in outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(outer - inset, 0)
        }
    }

    // MARK: Motion
    //
    // Plan §4.3: springs, not curves — springs are interruptible and
    // velocity-continuous. And asymmetric: opening is springy, closing is
    // smooth with no bounce, because a bouncing close reads as indecision.
    enum Motion {
        static let openResponse = 0.42
        static let openDamping = 0.80
        static let closeResponse = 0.32
        static let closeDamping = 1.0

        static let open = Animation.spring(response: openResponse, dampingFraction: openDamping)
        static let close = Animation.spring(response: closeResponse, dampingFraction: closeDamping)
        /// Plan §4.3: Reduce Motion turns springs into 150 ms fades — it does
        /// not change geometry, content or haptics.
        static let reduced = Animation.easeInOut(duration: 0.15)

        /// Opening the shelf out of the notch. Apple's tuned curves rather than
        /// a hand-rolled spring: `snappy` front-loads the movement so the panel
        /// leaves the cutout decisively, and the small bounce reads as the
        /// notch stretching rather than a window fading in. Closing gets no
        /// bounce at all — a panel that wobbles shut reads as indecision.
        static let panelOpen = Animation.snappy(duration: 0.34, extraBounce: 0.12)
        static let panelClose = Animation.smooth(duration: 0.24)

        static let progress = Animation.linear(duration: 0.18)
        static let hoverTint = Animation.easeOut(duration: 0.14)

        /// The lock pulse when a drag arms: 40–70 ms to ~1.05× (§4.2).
        static let lockPulseDuration = 0.06
        static let lockPulseScale: CGFloat = 1.05

        static func springy(_ growing: Bool, reduceMotion: Bool) -> Animation {
            if reduceMotion { return reduced }
            return growing ? open : close
        }
    }

    // MARK: Dwell times (plan §4.2)
    enum Dwell {
        static let success: TimeInterval = 0.9
        static let failure: TimeInterval = 2.5
        static let incoming: TimeInterval = 4.0
        static let queued: TimeInterval = 2.2
        /// A jittery hand shouldn't flicker the portal shut (§4.2 Moving away).
        static let dragOutGrace: TimeInterval = 0.10
        /// No large percentage counter until a transfer has earned one (§4.2).
        static let percentageAfter: TimeInterval = 2.0
    }

    // MARK: Pixel snapping
    //
    // Plan §3.2.5: any value that reaches a path is rounded to a whole PIXEL,
    // not a whole point. On a 2× display a half-point edge is a real half-pixel
    // and it shimmers as the shape animates.
    static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value.rounded() }
        return (value * scale).rounded() / scale
    }
}

/// The desktop, blurred, behind the panel.
///
/// Plan §10.2 draws the line precisely: the surface that TOUCHES the bezel is
/// flat #000 — a material there reads as a grey rectangle glued to black
/// hardware — but the panel that genuinely floats over the desktop is allowed
/// to be a material. So the top of the shelf stays opaque and only the lower
/// edge, which is over wallpaper rather than bezel, becomes glass.
struct DesktopGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension DS {
    /// Opaque where it meets the hardware, genuinely translucent where it
    /// doesn't. The first pass bottomed out at 62% black, which is a rumour of
    /// glass rather than glass — you could not see the desktop through it.
    ///
    /// The top ~38% stays flat #000 because that band is against the physical
    /// bezel (§10.2); past that it opens up fast and ends near a third, so the
    /// wallpaper reads clearly through the lower edge.
    static var panelVeil: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.34),
                .init(color: .black.opacity(0.78), location: 0.58),
                .init(color: .black.opacity(0.42), location: 0.80),
                .init(color: .black.opacity(0.14), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// The token names the rest of the app already imports. Retinted to the warm
// ramp rather than renamed, so every call site moves at once.
extension Color {
    /// Plan §15.1 is explicit that there is no accent colour: this is the gold
    /// end of the one warm ramp, not a hue with a meaning of its own.
    static let stickyAccent = DS.Colors.amber
    static let stickyIvory = DS.Colors.warmWhite
}

extension NSColor {
    static let stickyAccent = NSColor(red: 1.0, green: 0.757, blue: 0.471, alpha: 1)
}
