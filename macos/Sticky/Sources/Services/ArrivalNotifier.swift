import AppKit
import UserNotifications

/// F-12. An arrival is announced on the OS's own notification surface, with the
/// one action that matters. Sticky never grows a window for it.
@MainActor
final class ArrivalNotifier: NSObject {
    private enum Identifier {
        static let category = "sticky.arrival"
        static let openFolder = "sticky.arrival.open-folder"
    }

    private enum Authorization {
        case unknown
        case requesting
        case granted
        case denied
    }

    private var authorization: Authorization = .unknown
    private var isConfigured = false

    /// UNUserNotificationCenter resolves its client through the bundle
    /// identifier and raises an unrecoverable Objective-C exception when there
    /// is none — the case for `swift run` and for the test binary. No Swift
    /// `catch` can intercept that, so the only safe move is never to touch the
    /// framework outside a real .app bundle.
    private static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static let receivedFolder = URL(fileURLWithPath: NSString(string: "~/Downloads/Sticky").expandingTildeInPath)

    /// Called when an incoming transfer finishes. Authorization is requested
    /// here and nowhere else: a menu-bar utility that asks for notification
    /// permission at first launch, before it has ever had anything to say, is
    /// nagging.
    func announceArrival(senderName: String?, itemCount: Int) {
        guard Self.isSupported, itemCount > 0 else { return }
        configureIfNeeded()
        requestAuthorizationIfNeeded { [weak self] granted in
            guard granted else { return }
            self?.post(senderName: senderName, itemCount: itemCount)
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let openFolder = UNNotificationAction(
            identifier: Identifier.openFolder,
            title: "Open Folder",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Identifier.category,
            actions: [openFolder],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        switch authorization {
        case .granted:
            completion(true)
        case .denied:
            // A refusal is final for this run. Asking again on every arrival is
            // the loop this feature must not become.
            completion(false)
        case .requesting:
            // The prompt is already up. This arrival is dropped rather than
            // queued: a banner for a transfer that finished minutes ago is noise.
            completion(false)
        case .unknown:
            authorization = .requesting
            // Sound is left out on purpose: the transfer itself already plays
            // one, and two chimes for one arrival reads as a bug.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.authorization = granted ? .granted : .denied
                    completion(granted)
                }
            }
        }
    }

    private func post(senderName: String?, itemCount: Int) {
        let content = UNMutableNotificationContent()
        let noun = itemCount == 1 ? "file" : "files"
        if let senderName, !senderName.isEmpty {
            content.title = "\(itemCount) \(noun) from \(senderName)"
        } else {
            content.title = "\(itemCount) \(noun) arrived"
        }
        content.body = "Saved to Downloads/Sticky."
        content.categoryIdentifier = Identifier.category

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        // Delivery failures are not worth surfacing: the files are already on
        // disk and the menu bar's "Open received files" still reaches them.
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    fileprivate func revealReceivedFolder() {
        let folder = Self.receivedFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

extension ArrivalNotifier: UNUserNotificationCenterDelegate {
    // nonisolated because the center calls its delegate on its own queue; each
    // body hops back to the main actor before touching AppKit.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Sticky is an accessory app, so it can be "frontmost" while the user is
        // looking at another window. Suppressing the banner here would mean the
        // arrival was announced nowhere at all.
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.actionIdentifier
        Task { @MainActor [weak self] in
            if identifier == Identifier.openFolder || identifier == UNNotificationDefaultActionIdentifier {
                self?.revealReceivedFolder()
            }
            completionHandler()
        }
    }
}
