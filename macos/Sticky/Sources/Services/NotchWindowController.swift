import AppKit
import CoreGraphics
import Combine
import SwiftUI

enum NotchLayout {
    static let compactExtension: CGFloat = 34

    static func interactiveSize(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: notchWidth + 32,
            height: notchHeight + 24
        )
    }
}

@MainActor
final class NotchWindowController {
    private var window: NSWindow?
    private var screen: NSScreen?
    private let viewModel: NotchViewModel
    private var screenChangeObserver: NSObjectProtocol?
    private var hoverWatchdog: Timer?
    private var stateSubscription: AnyCancellable?
    private static let windowPadding = CGSize(width: 80, height: 76)

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    func install() {
        destroy()
        observeHoverState()
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
        stopHoverWatchdog()
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
        stateSubscription = viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }

                if case .hover = state {
                    self.startHoverWatchdog()
                } else {
                    self.stopHoverWatchdog()
                }
            }
    }

    private func startHoverWatchdog() {
        hoverWatchdog?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.validatePointerStillInside()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverWatchdog = timer
    }

    private func stopHoverWatchdog() {
        hoverWatchdog?.invalidate()
        hoverWatchdog = nil
    }

    private func validatePointerStillInside() {
        guard let window,
              case .hover = viewModel.state,
              let hostingView = window.contentView as? NotchHostingView,
              let provider = hostingView.interactiveFrameProvider
        else {
            return
        }

        let viewFrame = provider(hostingView.bounds)
        let globalFrame = NSRect(
            x: window.frame.minX + viewFrame.minX,
            y: window.frame.minY + viewFrame.minY,
            width: viewFrame.width,
            height: viewFrame.height
        )

        // Crossing to a display above/below can skip SwiftUI's mouse-exited
        // callback. The cursor location is the source of truth here, and the
        // collapse is immediate — never dependent on a follow-up timer.
        if globalFrame.contains(NSEvent.mouseLocation) == false {
            viewModel.forceCollapseIfHovering()
        }
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrame(notchFrame(on: target), display: false)

        let localNotchRect = localDeviceNotchRect(on: target, in: panel.frame)
        let hosting = NotchHostingView(rootView: AnyView(
            NotchView(viewModel: self.viewModel)
                .environment(\.notchGeometry, NotchGeometry(rect: localNotchRect, isVirtual: target.notchSize == .zero))
        ))
        hosting.interactiveFrameProvider = { [weak self] bounds in
            self?.interactiveBounds(for: localNotchRect, in: bounds) ?? .zero
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
        let width = max(notch.width + Self.windowPadding.width, 260)
        let height = max(notch.height + Self.windowPadding.height, 108)
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
    // The notch is a drop surface, never a keyboard-owning app window.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NotchHostingView: NSHostingView<AnyView> {
    fileprivate var interactiveFrameProvider: ((NSRect) -> NSRect)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveFrameProvider,
              interactiveFrameProvider(bounds).contains(convert(point, from: nil)) else {
            return nil
        }
        // Transparent SwiftUI roots can return nil even when visible controls are
        // inside the interactive frame. The hosting view remains the safe event
        // receiver so first-click and text focus work reliably.
        return super.hitTest(point) ?? self
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
