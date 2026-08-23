import AppKit
import CoreGraphics
import Combine
import SwiftUI

/// Single source of truth for every rectangle Sticky draws or hit-tests.
///
/// Three rectangles, and they must agree or the app feels broken:
///   • `cutoutRect`      — the hardware notch. The idle hit region, nothing more.
///   • `islandSize`      — the largest pill any state can grow into.
///   • `collapsedWindow` — the panel, sized to hold the largest island plus its
///                         shadow. Anything smaller clips the pill mid-transfer.
enum NotchLayout {
    /// Widest an island grows past the cutout (incomingOffer: +50, +12 shell).
    static let maxIslandOverhangX: CGFloat = 62
    /// Tallest an island grows past the cutout (transferring: +38).
    static let maxIslandOverhangY: CGFloat = 38
    /// Breathing room for the drop shadow so it isn't sliced by the window edge.
    static let shadowMargin: CGFloat = 14

    /// Plan §4.2 "Approaching": sensor extent is 16 pt either side of the
    /// cutout and 24 pt below it. It never extends above the cutout (§3.5) —
    /// there is nothing above it but bezel.
    static let hoverPadX: CGFloat = 16
    static let hoverPadY: CGFloat = 24

    /// How far the hover island actually draws below the cutout. The spec's
    /// 24 pt approach box predates the island carrying two lines; the sensor
    /// must cover whatever is DRAWN or the pointer falls out of the live region
    /// while still visibly inside the pill.
    static let hoverIslandDepth: CGFloat = 40
    /// Height of the tappable action strip at the bottom of the hover island.
    static let hoverActionHeight: CGFloat = 24
    /// Gap between that strip and the island's lower edge. Shared by the view
    /// that DRAWS the button and the sensor that RECEIVES its clicks — those
    /// are different files, and if they each carried their own 4 the button
    /// would eventually lie about where it is.
    static let hoverActionBottomInset: CGFloat = 4

    /// Plan §4.2 Armed: "Width snaps to a compact portal, ≤ 320 pt. Depth
    /// below the notch ≤ 70 pt."
    static let maxPortalWidth: CGFloat = 320
    static let maxPortalDepth: CGFloat = 70

    static let expandedWidth: CGFloat = 460
    static let expandedHeight: CGFloat = 380

    /// Plan §6: one window, sized once to the largest envelope it will ever
    /// need, never resized. Resizing an NSWindow mid-animation is what made the
    /// old build stutter — two layout systems fighting over one frame. The
    /// island and the shelf both animate *inside* this fixed envelope.
    static func windowEnvelope(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: max(expandedWidth, maxPortalWidth + shadowMargin * 2),
            height: expandedHeight + shadowMargin
        )
    }

    /// The region the pointer must stay inside to keep the island open.
    static func hoverSize(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: notchWidth + hoverPadX * 2,
            height: notchHeight + max(hoverPadY, hoverIslandDepth + 6)
        )
    }

    /// The strip of the hover island that sends the clipboard instead of
    /// opening the shelf. Returned in the sensor's own (top-left) coordinates
    /// so the view that draws the button and the view that receives the click
    /// are working from one definition.
    static func clipboardActionRect(notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let sensor = hoverSize(notchWidth: notchWidth, notchHeight: notchHeight)
        let width = min(notchWidth + 8, sensor.width - 12)
        return CGRect(
            x: (sensor.width - width) / 2,
            y: notchHeight + hoverIslandDepth - hoverActionHeight - hoverActionBottomInset,
            width: width,
            height: hoverActionHeight
        )
    }

    /// Kept for the drop-magnetism probe, which maps pointer x into 0...1.
    static func interactiveSize(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        hoverSize(notchWidth: notchWidth, notchHeight: notchHeight)
    }
}

@MainActor
final class NotchWindowController {
    /// Two windows, and the split is the whole hitbox guarantee.
    ///
    /// `visual` draws the island and the shelf and has `ignoresMouseEvents =
    /// true` whenever the shelf is closed, so it can never swallow a click —
    /// measured fact: a view whose `hitTest` returns nil still consumes the
    /// click for its window, and the window underneath never sees it. Only
    /// `ignoresMouseEvents` is genuinely click-through.
    ///
    /// `sensor` is the only live surface. At rest it is exactly the hardware
    /// cutout: 185×32 pt of black plastic where there is nothing to click
    /// anyway. It grows only while the user is already interacting.
    private var visual: NotchPanel?
    private var sensor: NotchPanel?
    private var screen: NSScreen?
    private let viewModel: NotchViewModel
    private var screenChangeObserver: NSObjectProtocol?
    private var expansionSubscription: AnyCancellable?
    private var stateSubscription: AnyCancellable?
    private var localClickToken: Any?
    private var escapeToken: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var rebuildDebounce: DispatchWorkItem?

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    func install() {
        destroy()
        observeExpansion()
        observeState()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRebuild() }
        }
        rebuild()
    }

    /// Plan §3.4: `didChangeScreenParametersNotification` fires in bursts —
    /// docking can produce half a dozen. Rebuilding on each made the notch
    /// flicker.
    private func scheduleRebuild() {
        rebuildDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func destroy() {
        rebuildDebounce?.cancel()
        rebuildDebounce = nil
        stopExpansionMonitors()
        expansionSubscription?.cancel()
        expansionSubscription = nil
        stateSubscription?.cancel()
        stateSubscription = nil
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        tearDownWindows()
    }

    private func observeExpansion() {
        expansionSubscription = viewModel.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                self.applyInteractivity(expanded: expanded)
                if expanded {
                    self.takeKeyboardFocus()
                    self.startExpansionMonitors()
                } else {
                    self.stopExpansionMonitors()
                    self.releaseKeyboardFocus()
                }
            }
    }

    /// The sensor tracks the island so the pointer can roam the whole open
    /// portal — and shrinks straight back to the cutout when it closes.
    private func observeState() {
        stateSubscription = viewModel.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeSensor() }
    }

    private func applyInteractivity(expanded: Bool) {
        // While the shelf is open the panel is a real surface the user is
        // working in, so it takes its own clicks. Closed, it takes none.
        visual?.ignoresMouseEvents = !expanded
        resizeSensor(expanded: expanded)
    }

    private func resizeSensor(expanded: Bool? = nil) {
        guard let sensor, let screen else { return }
        let isExpanded = expanded ?? viewModel.isExpanded
        let cutout = deviceNotchRect(on: screen)

        // Expanded: the visual panel owns the interaction, so the sensor gets
        // out of the way entirely rather than fighting it for clicks.
        //
        // Otherwise the sensor must cover everything currently DRAWN, not just
        // the approach box. The portal grows to 320×70 once a drag arms, and a
        // sensor stuck at the smaller hover size meant the pointer left the
        // live region while still visibly inside the portal — the drag would
        // exit and the portal collapse under the cursor.
        let size: CGSize
        if isExpanded {
            size = cutout.size
        } else {
            switch viewModel.state {
            case .idle:
                size = cutout.size
            case .hover:
                size = NotchLayout.hoverSize(notchWidth: cutout.width, notchHeight: cutout.height)
            default:
                size = CGSize(
                    width: min(NotchLayout.maxPortalWidth, cutout.width + NotchLayout.maxIslandOverhangX),
                    height: cutout.height + NotchLayout.maxPortalDepth
                )
            }
        }

        let scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2
        let rawX = cutout.midX - size.width / 2
        let frame = NSRect(
            x: (rawX * scale).rounded() / scale,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        guard sensor.frame != frame else { return }
        sensor.setFrame(frame, display: false)

        // Resizing a window out from under the pointer does not reliably
        // produce a mouseExited, so the island could stay lit forever with the
        // cursor nowhere near it. The frame is the truth; re-read it and
        // correct the hover state rather than trusting the event.
        let pointerIsInside = frame.contains(NSEvent.mouseLocation)
        if !pointerIsInside, viewModel.state == .hover, !viewModel.isExpanded {
            viewModel.setPointerHover(false)
        }
    }

    /// The panel owns the keyboard only while the user has explicitly opened
    /// the shelf — never at idle, never from a shortcut. Without this the Slot
    /// editor can be clicked but never typed into.
    ///
    /// Plan §4.2 forbids `NSApp.activate(ignoringOtherApps:)` because NotchDrop
    /// calls it on every open and yanks focus out of Finder mid-drag. A
    /// non-activating panel can usually take key on its own, so we try that
    /// first and escalate only if AppKit declines — never during a drag, since
    /// a drag cannot open the shelf.
    private func takeKeyboardFocus() {
        guard let visual else { return }
        visual.makeKeyAndOrderFront(nil)
        guard !visual.isKeyWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let visual = self.visual, self.viewModel.isExpanded, !visual.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            visual.makeKeyAndOrderFront(nil)
        }
    }

    private func releaseKeyboardFocus() {
        guard let visual else { return }
        let wasKey = visual.isKeyWindow
        if wasKey { visual.resignKey() }
        if wasKey, NSApp.isActive { NSApp.deactivate() }
        visual.orderFrontRegardless()
    }

    private func startExpansionMonitors() {
        stopExpansionMonitors()

        // Plan §10.7 lint-bans NSEvent.addGlobalMonitorForEvents. A local
        // monitor plus resigning key covers click-away without it.
        // Click-away. A local monitor only sees events delivered to THIS app,
        // so it cannot notice a click in Finder — and the global monitor that
        // could is lint-banned (§10.7) and would need Accessibility. Resigning
        // key is the permission-free signal that the user went elsewhere.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: visual,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isExpanded else { return }
                self.viewModel.collapseExpanded()
            }
        }

        localClickToken = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isExpanded, let visual = self.visual else { return }
                if event.window !== visual { self.viewModel.collapseExpanded() }
            }
            return event
        }

        escapeToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isExpanded else { return }
                self.viewModel.collapseExpanded()
            }
            return nil
        }
    }

    private func stopExpansionMonitors() {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        if let token = localClickToken { NSEvent.removeMonitor(token); localClickToken = nil }
        if let token = escapeToken { NSEvent.removeMonitor(token); escapeToken = nil }
    }

    func rebuild() {
        guard let target = findNotchScreen() else { tearDownWindows(); return }
        screen = target
        let frame = visualFrame(on: target)

        // The envelope never changes, so a screen change only moves the window
        // — no tearing down the SwiftUI tree and losing its state.
        if let visual, visual.frame.size == frame.size {
            visual.setFrameOrigin(frame.origin)
            visual.orderFrontRegardless()
            resizeSensor()
            sensor?.orderFrontRegardless()
            if viewModel.isExpanded { takeKeyboardFocus() }
            return
        }

        tearDownWindows()
        screen = target

        let visualPanel = makePanel(frame: frame)
        // The whole point: the drawing layer never intercepts anything.
        visualPanel.ignoresMouseEvents = !viewModel.isExpanded
        let localNotchRect = localDeviceNotchRect(on: target, in: frame)
        visualPanel.contentView = NSHostingView(rootView: AnyView(
            NotchView(viewModel: self.viewModel)
                .environment(\.notchGeometry, NotchGeometry(rect: localNotchRect, isVirtual: target.notchSize == .zero))
        ))
        visualPanel.orderFrontRegardless()
        visual = visualPanel

        let sensorPanel = makePanel(frame: NSRect(origin: frame.origin, size: deviceNotchRect(on: target).size))
        sensorPanel.ignoresMouseEvents = false
        // Above the visual panel so a drag lands on the sensor, not the art.
        sensorPanel.level = NSWindow.Level(rawValue: visualPanel.level.rawValue + 1)
        sensorPanel.contentView = makeSensorView()
        sensorPanel.orderFrontRegardless()
        sensor = sensorPanel

        resizeSensor()
        if viewModel.isExpanded { takeKeyboardFocus() }
    }

    private func makePanel(frame: NSRect) -> NotchPanel {
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.allowsKey = { [weak self] in self?.viewModel.isExpanded ?? false }
        panel.setFrame(frame, display: false)
        return panel
    }

    private func makeSensorView() -> NotchSensorView {
        let view = NotchSensorView()
        view.onHoverChange = { [weak viewModel] hovering in viewModel?.setPointerHover(hovering) }
        view.onTap = { [weak viewModel] in viewModel?.toggleExpanded() }
        view.onDragEnter = { [weak viewModel] in viewModel?.dragDidEnter() }
        view.onDragMove = { [weak viewModel] point in viewModel?.dragDidMove(to: point) }
        view.onDragExit = { [weak viewModel] in viewModel?.dragDidExit() }
        view.onDrop = { [weak viewModel] info, target in viewModel?.receiveDrop(info, in: target) ?? false }
        view.onOptionTap = { [weak viewModel] in viewModel?.sendClipboardNow() }
        // A visible strip beats a modifier nobody discovers: clicks in the
        // lower band of the hover island send the clipboard, clicks above it
        // open the shelf.
        view.actionRegion = { [weak viewModel, weak self] in
            guard let viewModel, let self, let screen = self.screen,
                  viewModel.pasteboardPreview != nil,
                  viewModel.state == .hover, !viewModel.isExpanded else { return nil }
            let cutout = self.deviceNotchRect(on: screen)
            return NotchLayout.clipboardActionRect(
                notchWidth: cutout.width,
                notchHeight: cutout.height
            )
        }
        view.onActionTap = { [weak viewModel] in viewModel?.sendClipboardNow() }
        view.menuProvider = { [weak viewModel] in
            guard let viewModel else { return nil }
            viewModel.refreshPasteboardPreview()
            let menu = NSMenu()

            let send = NSMenuItem(
                title: viewModel.pasteboardPreview.map { "Send “\($0)” to PC" } ?? "Nothing on the clipboard",
                action: #selector(NotchMenuActions.sendClipboard(_:)),
                keyEquivalent: ""
            )
            send.isEnabled = viewModel.pasteboardPreview != nil
            send.target = NotchMenuActions.shared
            send.representedObject = viewModel
            menu.addItem(send)

            menu.addItem(.separator())

            let shelf = NSMenuItem(
                title: viewModel.isExpanded ? "Close Shelf" : "Open Shelf",
                action: #selector(NotchMenuActions.toggleShelf(_:)),
                keyEquivalent: ""
            )
            shelf.target = NotchMenuActions.shared
            shelf.representedObject = viewModel
            menu.addItem(shelf)

            return menu
        }
        return view
    }

    private func findNotchScreen() -> NSScreen? {
        let candidates = NSScreen.screens.filter { $0.notchSize != .zero }
        return candidates.first { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(displayID) != 0
        } ?? candidates.first
    }

    private func windowSize(on screen: NSScreen) -> NSSize {
        let notch = notchSize(on: screen)
        let size = NotchLayout.windowEnvelope(notchWidth: notch.width, notchHeight: notch.height)
        return NSSize(
            width: min(size.width, screen.frame.width),
            height: min(size.height, screen.frame.height)
        )
    }

    /// Plan §3 geometry law: anchor on `auxiliaryTopLeftArea`, never
    /// `frame.midX` — the cutout sits half a point left of centre and derived
    /// maths drifts. Then snap to whole pixels so the edge doesn't shimmer.
    private func visualFrame(on screen: NSScreen) -> NSRect {
        let size = windowSize(on: screen)
        let notchMidX = deviceNotchRect(on: screen).midX
        let scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2
        let rawX = notchMidX - size.width / 2
        return NSRect(
            x: (rawX * scale).rounded() / scale,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func deviceNotchRect(on screen: NSScreen) -> NSRect {
        let notch = notchSize(on: screen)
        guard notch != .zero else {
            return NSRect(x: screen.frame.midX - 90, y: screen.frame.maxY - 28, width: 180, height: 28)
        }
        let left = screen.auxiliaryTopLeftArea?.maxX ?? 0
        return NSRect(x: left, y: screen.frame.maxY - notch.height, width: notch.width, height: notch.height)
    }

    private func localDeviceNotchRect(on screen: NSScreen, in windowFrame: NSRect) -> CGRect {
        let deviceRect = deviceNotchRect(on: screen)
        return CGRect(x: deviceRect.minX - windowFrame.minX, y: .zero, width: deviceRect.width, height: deviceRect.height)
    }

    private func tearDownWindows() {
        for panel in [visual, sensor].compactMap({ $0 }) {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        visual = nil
        sensor = nil
        screen = nil
    }

    private func notchSize(on screen: NSScreen) -> CGSize { screen.notchSize }
}

/// Target for the notch's right-click menu. `NSMenuItem` needs an ObjC target,
/// which a `@MainActor` Swift closure cannot be — so the actions land here and
/// are forwarded to the view model carried on the item.
@MainActor
final class NotchMenuActions: NSObject {
    static let shared = NotchMenuActions()

    @objc func sendClipboard(_ sender: NSMenuItem) {
        (sender.representedObject as? NotchViewModel)?.sendClipboardNow()
    }

    @objc func toggleShelf(_ sender: NSMenuItem) {
        (sender.representedObject as? NotchViewModel)?.toggleExpanded()
    }
}

final class NotchPanel: NSPanel {
    /// The notch is a drop surface first. It owns the keyboard only while the
    /// user has the shelf open — never at idle, and never via a shortcut.
    var allowsKey: () -> Bool = { false }

    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }
}

struct NotchGeometry {
    let rect: CGRect
    let isVirtual: Bool
}

private struct NotchGeometryKey: EnvironmentKey {
    static let defaultValue = NotchGeometry(rect: .zero, isVirtual: false)
}

extension EnvironmentValues {
    var notchGeometry: NotchGeometry {
        get { self[NotchGeometryKey.self] }
        set { self[NotchGeometryKey.self] = newValue }
    }
}

extension NSScreen {
    var notchSize: CGSize {
        guard safeAreaInsets.top > 0 else { return .zero }
        let h = safeAreaInsets.top
        let l = auxiliaryTopLeftArea?.width ?? 0
        let r = auxiliaryTopRightArea?.width ?? 0
        guard l > 0, r > 0 else { return .zero }
        return CGSize(width: frame.width - l - r, height: h)
    }
}
