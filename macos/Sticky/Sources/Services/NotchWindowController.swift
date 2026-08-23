import AppKit
import CoreGraphics
import Combine
import SwiftUI

enum NotchLayout {
    static let compactExtension: CGFloat = 34
    static let interactivePadX: CGFloat = 16   // plan §4: 16pt either side
    static let interactivePadY: CGFloat = 24   // plan §4: 24pt below the cutout

    static func interactiveSize(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: notchWidth + interactivePadX * 2,
            height: notchHeight + interactivePadY * 2
        )
    }
}

@MainActor
final class NotchWindowController {
    private var window: NSWindow?
    private var screen: NSScreen?
    private let viewModel: NotchViewModel
    private var screenChangeObserver: NSObjectProtocol?
    private var stateSubscription: AnyCancellable?
    private var expansionSubscription: AnyCancellable?
    private var clickAwayToken: Any?
    private var localClickToken: Any?
    private var escapeToken: Any?
    private static let windowPadding = CGSize(width: 48, height: 0)
    private static let expandedHeight: CGFloat = 340

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    func install() {
        destroy()
        observeHoverState()
        observeExpansion()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuild()
            }
        }
        rebuild()
    }

    func destroy() {
        stopExpansionMonitors()
        expansionSubscription?.cancel()
        expansionSubscription = nil
        stateSubscription?.cancel()
        stateSubscription = nil

        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }

        window?.orderOut(nil)
        window = nil
        screen = nil
    }

    private func observeHoverState() {
        stateSubscription?.cancel()
        stateSubscription = nil
        // No polling watchdog. The old one re-checked every 0.12 s and could
        // collapse a valid hover, producing rapid open/close flicker while the
        // cursor sat on the notch. SwiftUI onHover handles enter/exit directly.
    }

    private func observeExpansion() {
        expansionSubscription?.cancel()
        expansionSubscription = viewModel.$isExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                self.resizePanel(expanded: expanded)
                if expanded {
                    self.startExpansionMonitors()
                } else {
                    self.stopExpansionMonitors()
                }
            }
    }

    /// Grows the panel downward while keeping its top edge glued to the screen
    /// top — the boring.notch-style expansion.
    private func resizePanel(expanded: Bool) {
        guard let window, let screen else { return }
        var frame = window.frame
        let targetHeight: CGFloat = expanded
            ? Self.expandedHeight
            : windowSize(on: screen).height   // same math as build — no drift
        frame.size.height = targetHeight
        frame.origin.y = screen.frame.maxY - targetHeight
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.setFrame(frame, display: true)
        }
    }

    private func startExpansionMonitors() {
        stopExpansionMonitors()

        // Any click outside the panel collapses it — standard popover behavior.
        clickAwayToken = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isExpanded, let window = self.window else { return }
                if !window.frame.contains(NSEvent.mouseLocation) {
                    self.viewModel.collapseExpanded()
                }
            }
        }

        // Own windows (Shelf etc.) don't reach the global monitor.
        localClickToken = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isExpanded, let window = self.window else { return }
                if event.window !== window {
                    self.viewModel.collapseExpanded()
                }
            }
            return event
        }

        escapeToken = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isExpanded else { return }
                if event.keyCode == 53 { // Escape
                    self.viewModel.collapseExpanded()
                }
            }
            return event
        }
    }

    private func stopExpansionMonitors() {
        if let token = clickAwayToken { NSEvent.removeMonitor(token); clickAwayToken = nil }
        if let token = localClickToken { NSEvent.removeMonitor(token); localClickToken = nil }
        if let token = escapeToken { NSEvent.removeMonitor(token); escapeToken = nil }
    }


    func rebuild() {
        tearDownWindow()
        guard let target = findNotchScreen() else { return }
        screen = target

        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: windowSize(on: target)),
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
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setFrame(notchFrame(on: target), display: false)

        let localNotchRect = localDeviceNotchRect(on: target, in: panel.frame)
        let hosting = NotchHostingView(rootView: AnyView(
            NotchView(viewModel: self.viewModel)
                .environment(\.notchGeometry, NotchGeometry(rect: localNotchRect, isVirtual: target.notchSize == .zero))
        ))
        hosting.interactiveFrameProvider = { [weak self] bounds in
            self?.interactiveBounds(for: localNotchRect, in: bounds) ?? .zero
        }
        hosting.isExpandedActive = { [weak self] in
            self?.viewModel.isExpanded ?? false
        }
        panel.contentView = hosting
        window = panel
        panel.orderFrontRegardless()
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
        // Window == the interactive area exactly (tap rect incl. bloom strip).
        let width = max(notch.width + NotchLayout.interactivePadX * 2, 220)
        let height = max(notch.height + NotchLayout.interactivePadY + 26, 96)
        return NSSize(
            width: min(width, screen.frame.width),
            height: min(height, screen.frame.height)
        )
    }

    private func notchFrame(on screen: NSScreen) -> NSRect {
        let size = windowSize(on: screen)
        let notchMidX = deviceNotchRect(on: screen).midX
        return NSRect(
            x: notchMidX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func deviceNotchRect(on screen: NSScreen) -> NSRect {
        let notch = notchSize(on: screen)
        guard notch != .zero else {
            // A transparent, centred interaction target lets Sticky remain useful
            // on external displays without pretending there is hardware there.
            return NSRect(x: screen.frame.midX - 90, y: screen.frame.maxY - 28, width: 180, height: 28)
        }
        let left = screen.auxiliaryTopLeftArea?.maxX ?? 0
        return NSRect(
            x: left,
            y: screen.frame.maxY - notch.height,
            width: notch.width,
            height: notch.height
        )
    }

    private func localDeviceNotchRect(on screen: NSScreen, in windowFrame: NSRect) -> CGRect {
        let deviceRect = deviceNotchRect(on: screen)
        return CGRect(
            x: deviceRect.minX - windowFrame.minX,
            y: .zero,
            width: deviceRect.width,
            height: deviceRect.height
        )
    }

    private func interactiveBounds(for notchRect: CGRect, in bounds: NSRect) -> NSRect {
        let size = NotchLayout.interactiveSize(
            notchWidth: notchRect.width,
            notchHeight: notchRect.height
        )

        let width = min(bounds.width, size.width)
        let height = min(bounds.height, size.height)
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.maxY - height,
            width: width,
            height: height
        )
    }

    private func tearDownWindow() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        screen = nil
    }

    private func notchSize(on screen: NSScreen) -> CGSize {
        screen.notchSize
    }

    private func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(displayID) != 0
    }

}

final class NotchPanel: NSPanel {
    // The notch is a drop surface and click target; it never owns the keyboard
    // or menu bar. Buttons inside still work because NSPanel delivers clicks
    // even when it can't become key.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
    }
}

private final class NotchHostingView: NSHostingView<AnyView> {
    fileprivate var interactiveFrameProvider: ((NSRect) -> NSRect)?
    fileprivate var isExpandedActive: (() -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // When expanded, the whole panel is interactive — buttons, rows, scroll.
        if isExpandedActive?() == true { return super.hitTest(point) ?? self }

        // Collapsed: allow the notch area PLUS the bloom strip below it,
        // matching the SwiftUI contentShape exactly (interactiveSize + 26).
        if let provider = interactiveFrameProvider {
            var frame = provider(bounds)
            frame.size.height += 26
            if frame.contains(convert(point, from: nil)) {
                return super.hitTest(point) ?? self
            }
            return nil
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
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
