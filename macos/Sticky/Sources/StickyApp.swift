import SwiftUI
import Combine

@main
struct StickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedViewModel: NotchViewModel?

    private var notchController: NotchWindowController?
    private let viewModel = NotchViewModel()
    private var discoveryService: DiscoveryService?
    private var transferService: TransferService?
    private var clipboardService: ClipboardService?
    private var controlService: ControlService?
    private let hapticService = HapticService()
    private let soundService = SoundService()
    private var statusItem: NSStatusItem?
    private var peerSubscription: AnyCancellable?
    private var servicesAreRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.sharedViewModel = viewModel
        startServices()
        installInterface()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        chooseFilesToSend()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServices()
    }

    private func startServices() {
        guard !servicesAreRunning else { return }

        let discovery = DiscoveryService(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        let transfer = TransferService(discovery: discovery)
        let clipboard = ClipboardService()

        discoveryService = discovery
        transferService = transfer
        clipboardService = clipboard
        controlService = ControlService(discovery: discovery, transfer: transfer, clipboard: clipboard)
        controlService?.start()
        transfer.onFailure = { [weak self] message in
            Task { @MainActor in self?.controlService?.recordNativeError(message) }
        }
        peerSubscription = discovery.$peers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                guard let self else { return }
                let available = !peers.isEmpty
                self.viewModel.updatePeerAvailability(available)
                self.refreshPeerCount()
            }

        viewModel.configure(
            haptics: hapticService,
            sounds: soundService,
            transfer: transfer,
            clipboard: clipboard,
            clipboardSender: { [weak self] text in
                Task { @MainActor [weak self] in
                    await self?.sendClipboard(text)
                }
            },
            pairingCode: transfer.pairingCode,
            pairingCodeProvider: { [weak transfer] in transfer?.pairingCode ?? "------" },
            pairingAction: { [weak self] in self?.showPairingDialog() },
            unpairAllAction: { [weak self] in self?.forgetPairedDevices() }
        )
        soundService.prepare()

        transfer.onIncoming = { [weak self] sender, count, kind in
            Task { @MainActor [weak self] in
                self?.viewModel.receiveIncomingOffer(senderName: sender, fileCount: count, kind: kind)
            }
        }

        transfer.onClipboardReceived = { [weak self] text, senderName in
            Task { @MainActor [weak self] in
                self?.viewModel.receiveRemoteClipboard(text, senderName: senderName)
            }
        }

        transfer.onIncomingCompleted = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.viewModel.receiveIncomingCompleted(count: count)
            }
        }

        // Monitoring only records local text in Sticky's private history. Sending
        // is an explicit paper-plane action in that history, never a background
        // copy of the system clipboard.
        clipboard.start(onTextPushed: { _ in })

        servicesAreRunning = true
    }

    private func stopServices() {
        guard servicesAreRunning else { return }
        viewModel.prepareForQuit()
        clipboardService?.stop()
        controlService?.stop()
        controlService = nil
        transferService?.stop()
        discoveryService?.stop()
        peerSubscription?.cancel()
        peerSubscription = nil
        servicesAreRunning = false
    }

    private func installInterface() {
        notchController = NotchWindowController(viewModel: viewModel)
        notchController?.install()
        installMenuBarItemIfNeeded()
    }

    private func installMenuBarItemIfNeeded() {
        // Sticky is one app with two entrances: the native notch and a normal,
        // dependable menu-bar item. The icon is never a second process/window.
        if statusItem == nil {
            setupMenu()
        }
        NSApp.servicesProvider = ServicesProvider()
        NSUpdateDynamicServices()
    }

    private func setupMenu() {
        let menu = NSMenu()

        let sendItem = NSMenuItem(title: "Send files…", action: #selector(chooseFilesToSend), keyEquivalent: "s")
        sendItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(sendItem)

        let peersItem = NSMenuItem(title: "No devices nearby", action: nil, keyEquivalent: "")
        peersItem.isEnabled = false
        peersItem.tag = MenuAction.peerCount.rawValue
        menu.addItem(peersItem)

        let pendingItem = NSMenuItem(title: "No pending transfers", action: nil, keyEquivalent: "")
        pendingItem.isEnabled = false
        pendingItem.tag = MenuAction.pendingCount.rawValue
        menu.addItem(pendingItem)

        menu.addItem(NSMenuItem(title: "Send pending now", action: #selector(sendPendingTransfers), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Clear pending queue", action: #selector(clearPendingTransfers), keyEquivalent: ""))
        let shelfItem = NSMenuItem(title: "Show Shelf…", action: #selector(showShelf), keyEquivalent: "e")
        shelfItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(shelfItem)
        menu.addItem(NSMenuItem(title: "Send copied text", action: #selector(sendCopiedText), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Open received files", action: #selector(openReceivedFiles), keyEquivalent: "o"))

        if let code = transferService?.pairingCode {
            let codeItem = NSMenuItem(title: "This Mac's pairing code: \(code)", action: nil, keyEquivalent: "")
            codeItem.isEnabled = false
            codeItem.tag = MenuAction.pairingCode.rawValue
            menu.addItem(codeItem)
        }
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Pair a device…", action: #selector(showPairingDialog), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sticky", action: #selector(quit), keyEquivalent: "q"))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let dropArea = StatusBarDropArea(frame: .zero)
            dropArea.onFilesDropped = { [weak self] urls in
                Task { @MainActor [weak self] in
                    self?.viewModel.sendFiles(urls)
                }
            }
            dropArea.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dropArea)
            NSLayoutConstraint.activate([
                dropArea.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                dropArea.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                dropArea.topAnchor.constraint(equalTo: button.topAnchor),
                dropArea.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            button.image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle", accessibilityDescription: "Sticky — drag files here or click for menu")
        }
        statusItem?.menu = menu
        refreshPeerCount()
        viewModel.updatePeerAvailability(!(discoveryService?.peers.isEmpty ?? true))
    }

    private func refreshPeerCount() {
        guard let menu = statusItem?.menu,
              let item = menu.items.first(where: { $0.tag == MenuAction.peerCount.rawValue }) else { return }
        let count = discoveryService?.peers.count ?? 0
        item.title = count == 0 ? "No devices nearby" : "\(count) device\(count == 1 ? "" : "s") nearby"
    }

    private func sendClipboard(_ text: String) async {
        guard let peer = discoveryService?.peers.first, let transfer = transferService else {
            // A normal local copy should remain quiet when the other machine is
            // asleep or away. Sticky still keeps it in its private history.
            return
        }
        do {
            try await transfer.sendText(text, to: peer)
        } catch {
            viewModel.reportClipboardSendError(error.localizedDescription)
        }
    }

    @objc private func handleWake() {
        discoveryService?.announce()
    }

    @objc private func handleScreenChange() {
        notchController?.rebuild()
        installMenuBarItemIfNeeded()
    }

    @objc private func chooseFilesToSend() {
        let picker = NSOpenPanel()
        picker.title = "Send with Sticky"
        picker.prompt = "Send"
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.begin { [weak self] response in
            guard response == .OK else { return }
            self?.viewModel.sendFiles(picker.urls)
        }
    }

    @objc private func showShelf() {
        viewModel.showShelf()
    }

    @objc private func sendPendingTransfers() {
        viewModel.processPendingQueue(force: true)
    }

    @objc private func clearPendingTransfers() {
        viewModel.clearPendingTransfers()
    }

    @objc private func sendCopiedText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showPairingResult(title: "Nothing to send", message: "Copy some text first, then choose Send copied text.")
            return
        }
        Task { @MainActor [weak self] in
            await self?.sendClipboard(text)
        }
    }

    @objc private func openReceivedFiles() {
        let folder = URL(fileURLWithPath: NSString(string: "~/Downloads/Sticky").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func showPairingDialog() {
        guard let transfer = transferService else { return }
        let peers = discoveryService?.peers ?? []
        guard !peers.isEmpty else {
            showPairingResult(title: "No device nearby", message: "Open Sticky on the other computer and make sure both devices are on the same private Wi-Fi.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Pair a Sticky device"
        alert.informativeText = "Enter the six-digit code currently shown on the other computer. The code is only used once to establish trust."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8

        let peerPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28), pullsDown: false)
        peerPicker.addItems(withTitles: peers.map { "\($0.name) (\($0.platform.rawValue))" })
        accessory.addArrangedSubview(peerPicker)

        let codeField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        codeField.placeholderString = "Six-digit code"
        codeField.maximumNumberOfLines = 1
        accessory.addArrangedSubview(codeField)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            showPairingResult(title: "Invalid code", message: "Enter the six digits shown in Sticky on the other computer.")
            return
        }
        let peer = peers[min(peerPicker.indexOfSelectedItem, peers.count - 1)]
        Task { @MainActor [weak self] in
            do {
                try await transfer.pair(peer: peer, pin: code)
                self?.showPairingResult(title: "Paired", message: "\(peer.name) is now trusted. You can send files and clipboard items normally.")
            } catch {
                self?.showPairingResult(title: "Couldn’t pair", message: error.localizedDescription)
            }
        }
    }

    private func showPairingResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func forgetPairedDevices() {
        guard let transfer = transferService else { return }
        let alert = NSAlert()
        alert.messageText = "Forget paired devices?"
        alert.informativeText = "Sticky will stop trusting every device on this Mac. You’ll need to pair again before sending or receiving."
        alert.addButton(withTitle: "Forget devices")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try transfer.unpairAll()
            showPairingResult(title: "Devices forgotten", message: "Pair again from the Shelf when you’re ready.")
        } catch {
            showPairingResult(title: "Couldn’t forget devices", message: error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let codeItem = menu.items.first(where: { $0.tag == MenuAction.pairingCode.rawValue }) {
            codeItem.title = "This Mac's pairing code: \(transferService?.pairingCode ?? "------")"
        }
        refreshPeerCount()
        refreshPendingQueue(in: menu)
    }

    private func refreshPendingQueue(in menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.tag == MenuAction.pendingCount.rawValue }) else { return }
        let count = viewModel.pendingTransfers.reduce(0) { $0 + $1.items.count }
        item.title = count == 0 ? "No pending transfers" : "\(count) item\(count == 1 ? "" : "s") waiting for PC"
        item.isEnabled = count > 0
    }
}

private enum MenuAction: Int {
    case peerCount = 1
    case pairingCode = 2
    case pendingCount = 3
}

final class StatusBarDropArea: NSView {
    var onFilesDropped: (([URL]) -> Void)?

    private var isDragActive = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep ordinary clicks on the native status-item button while still
        // giving this transparent area full ownership of file drag sessions.
        isDragActive ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        isDragActive = true
        (superview as? NSStatusBarButton)?.contentTintColor = accepted ? .stickyAccent : nil
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragActive = false
        (superview as? NSStatusBarButton)?.contentTintColor = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }

        onFilesDropped?(urls)
        (superview as? NSStatusBarButton)?.contentTintColor = nil
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDragActive = false
    }
}


/// Finder "right-click → Send with Sticky" integration. macOS discovers this
/// through the app's Services menu; the handler accepts any selected files.
@objc final class ServicesProvider: NSObject {
    @objc func sendFilesFromFinder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            AppDelegate.sharedViewModel?.sendFiles(urls)
        }
    }
}
