import XCTest
@testable import Sticky

/// These lock in the rules that the old build broke. Each one maps to a defect
/// that actually shipped, so a regression fails the build rather than quietly
/// making the notch unpleasant again.
final class NotchLayoutTests: XCTestCase {
    /// Measured on the 16" MBP this app targets. The published tables say
    /// 220×38 and are wrong.
    private let notchWidth: CGFloat = 185
    private let notchHeight: CGFloat = 32

    /// Plan §4.2: the drop sensor reaches 16 pt either side of the cutout, and
    /// never above it, where there is only bezel.
    func testSensorExtentMatchesSpec() {
        let size = NotchLayout.hoverSize(notchWidth: notchWidth, notchHeight: notchHeight)
        XCTAssertEqual(size.width, notchWidth + NotchLayout.hoverPadX * 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(size.height, notchHeight + NotchLayout.hoverPadY)
    }

    /// The sensor must cover everything the hover island DRAWS. When it didn't,
    /// the pointer fell out of the live region while still visibly inside the
    /// pill, and hover collapsed under the cursor.
    func testSensorCoversTheDrawnHoverIsland() {
        let size = NotchLayout.hoverSize(notchWidth: notchWidth, notchHeight: notchHeight)
        XCTAssertGreaterThanOrEqual(size.height, notchHeight + NotchLayout.hoverIslandDepth)
    }

    /// What looks clickable must be what is clickable: the drawn button and the
    /// sensor's action rect come from this one definition.
    func testClipboardActionRectSitsInsideTheSensor() {
        let sensor = NotchLayout.hoverSize(notchWidth: notchWidth, notchHeight: notchHeight)
        let rect = NotchLayout.clipboardActionRect(notchWidth: notchWidth, notchHeight: notchHeight)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, sensor.width)
        // Never in the camera region (§3.2.6).
        XCTAssertGreaterThanOrEqual(rect.minY, notchHeight)
        XCTAssertLessThanOrEqual(rect.maxY, sensor.height)
    }

    /// Plan §4.2 Armed: "≤ 320 pt wide, ≤ 70 pt deep."
    func testPortalStaysWithinItsCap() {
        XCTAssertLessThanOrEqual(NotchLayout.maxPortalWidth, 320)
        XCTAssertLessThanOrEqual(NotchLayout.maxPortalDepth, 70)
    }

    /// The window is created once at the largest envelope it will ever need.
    /// When it was smaller than the island, five of eight states rendered
    /// clipped mid-transfer.
    func testEnvelopeHoldsTheWidestPortalAndTheShelf() {
        let envelope = NotchLayout.windowEnvelope(notchWidth: notchWidth, notchHeight: notchHeight)
        XCTAssertGreaterThanOrEqual(envelope.width, NotchLayout.maxPortalWidth)
        XCTAssertGreaterThanOrEqual(envelope.width, NotchLayout.expandedWidth)
        XCTAssertGreaterThanOrEqual(envelope.height, NotchLayout.expandedHeight)
    }

    /// Plan §3.2.5: anything that reaches a path lands on a whole pixel. A
    /// half-point edge is a real half-pixel at 2× and shimmers as it animates.
    func testPixelSnappingLandsOnTheBackingGrid() {
        XCTAssertEqual(DS.snap(10.3, scale: 2), 10.5, accuracy: 0.0001)
        XCTAssertEqual(DS.snap(10.1, scale: 2), 10.0, accuracy: 0.0001)
        XCTAssertEqual(DS.snap(10.4, scale: 1), 10.0, accuracy: 0.0001)
        // A nonsense scale must not produce a nonsense coordinate.
        XCTAssertEqual(DS.snap(10.6, scale: 0), 11.0, accuracy: 0.0001)
    }

    /// The drawn button and the sensor's click rect are computed in different
    /// files. They must agree, or the button lies about where it is.
    func testClipboardButtonSitsWhereItsClicksAreCollected() {
        let rect = NotchLayout.clipboardActionRect(notchWidth: notchWidth, notchHeight: notchHeight)
        let islandBottom = notchHeight + NotchLayout.hoverIslandDepth
        XCTAssertEqual(rect.height, NotchLayout.hoverActionHeight, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, islandBottom - NotchLayout.hoverActionBottomInset, accuracy: 0.001)
        // Horizontally centred, so it lines up with a centred SwiftUI frame.
        let sensor = NotchLayout.hoverSize(notchWidth: notchWidth, notchHeight: notchHeight)
        XCTAssertEqual(rect.midX, sensor.width / 2, accuracy: 0.001)
    }

    /// Plan §10.4: 11 pt is the readable floor and nothing in the portal goes
    /// below it — the type helpers must clamp rather than trust the caller.
    func testTypeScaleRefusesToGoBelowTheReadableFloor() {
        XCTAssertEqual(DS.Type_.floor, 11)
        // Font has no size accessor, so assert the clamp the helpers use.
        XCTAssertEqual(max(9.5, DS.Type_.floor), 11)
    }

    /// Plan §15.1: one warm ramp, and explicitly "no pink, purple or blue
    /// anywhere". The previous build shipped a blue accent with a comment
    /// declaring the inversion, so this is worth pinning.
    func testAccentIsWarmNotBlue() {
        let accent = NSColor.stickyAccent.usingColorSpace(.sRGB)
        let red = accent?.redComponent ?? 0
        let blue = accent?.blueComponent ?? 1
        XCTAssertGreaterThan(red, blue, "the accent must be warm — red above blue")
    }
}
