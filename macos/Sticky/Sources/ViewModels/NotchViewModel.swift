import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NotchViewModel: NSObject, ObservableObject {
    @Published var state: NotchState = .idle
    @Published var isExpanded = false
    @Published var dropTargeting = false
    @Published var shelfFiles: [StickyShelfItem] = [] {
        didSet { persistShelfIfNeeded() }
    }
    @Published var clipboardHistory: [StickyClipEntry] = []
    @Published var stickySlot: StickyClipEntry?
    @Published private(set) var dropMagnetism: CGFloat = 0
    @Published private(set) var dragAlignment: CGFloat = 0
    @Published private(set) var pendingTransfers: [PendingTransfer] = [] {
        didSet { persistPendingTransfersIfNeeded() }
    }
    var reducesMotion = false {
        didSet { guard reducesMotion != oldValue else { return }; dropMagnetism = 0; dragAlignment = 0 }
    }

    private var hoverTimer: DispatchWorkItem?
    private var armedTimer: DispatchWorkItem?
    private var autoResetTimer: DispatchWorkItem?
    private var transferTask: Task<Void, Never>?
    private var transferGeneration = 0
    private var activeTransferGeneration: Int?
    /// The files the in-flight transfer owns. Without this, cancelling a
    /// transfer to start another one abandoned the first batch silently: not
    /// sent, not queued, no error — just gone.
    private var activeBatch: [URL] = []
    /// The batch waiting on the armed timer, for the same reason.
    private var armedBatch: [URL] = []
    /// Set while a transfer is running so progress can be gated on generation
    /// rather than on the state already being `.transferring`.
    private var transferStartedAt: Date?
    private var hapticService: HapticService?
    private var soundService: SoundService?
    private var transferService: TransferService?
    private(set) var clipboardService: ClipboardService?
    private var clipboardSender: ((String) -> Void)?
    private var pairingAction: (() -> Void)?
    private var unpairAllAction: (() -> Void)?
    private var pairingCodeProvider: (() -> String)?
    private var fallbackPairingCode = "------"
    var pairingCode: String { pairingCodeProvider?() ?? fallbackPairingCode }
    private var clipboardSubscription: AnyCancellable?
    private let shelfDefaultsKey = "sticky.shelfItems"
    private let pendingDefaultsKey = "sticky.pendingTransfers.v1"
    private var isRestoringShelf = false
    private var isRestoringPendingTransfers = false
    private var isProcessingPendingQueue = false
    private var peerReachable = false
    private var nextQueueAttemptAt = Date.distantPast
    private var queueRetryTimer: DispatchWorkItem?
    private var dropProbeWidth: CGFloat = 220
    private var dropProbeHeight: CGFloat = 50

    override init() {
        clipboardSyncEnabled = UserDefaults.standard.bool(forKey: "sticky.clipboardSync")
        slotText = ""
        super.init()
        slotText = UserDefaults.standard.string(forKey: "sticky.slot.text") ?? ""
        if let data = UserDefaults.standard.data(forKey: "sticky.slot.image") {
            slotImage = NSImage(data: data)
        }
        restoreShelf()
        restorePendingTransfers()
    }

    func configure(haptics: HapticService, transfer: TransferService) {
        configure(haptics: haptics, sounds: nil, transfer: transfer, clipboard: nil, clipboardSender: { _ in })
    }

    func configure(
        haptics: HapticService,
        sounds: SoundService?,
        transfer: TransferService,
        clipboard: ClipboardService?,
        clipboardSender: @escaping (String) -> Void,
        pairingCode: String = "------",
        pairingCodeProvider: @escaping () -> String = { "------" },
        pairingAction: @escaping () -> Void = {},
        unpairAllAction: @escaping () -> Void = {}
    ) {
        hapticService = haptics
        soundService = sounds
        transferService = transfer
        self.clipboardSender = clipboardSender
        fallbackPairingCode = pairingCode
        self.pairingCodeProvider = pairingCodeProvider
        self.pairingAction = pairingAction
        self.unpairAllAction = unpairAllAction
        attachClipboard(clipboard)
    }

    private func attachClipboard(_ service: ClipboardService?) {
        clipboardSubscription?.cancel()
        clipboardService = service
        guard let service else { return }
        syncClipboard(from: service)
        clipboardSubscription = service.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncClipboard(from: service)
            }
    }

    private func syncClipboard(from service: ClipboardService) {
        clipboardHistory = service.history
        stickySlot = service.stickySlot ?? stickySlot
    }

    // MARK: - DropDelegate

    func dragDidEnter() {
        guard case .idle = state else { return }
        dropTargeting = true
        hoverTimer?.cancel()
        hoverTimer = nil
        withMotionAnimation(.opening) {
            state = .hover
        }
    }

    private var pointerIsOver = false

    /// Pasteboard types that other apps use to say "this is a secret, don't
    /// keep it" — a password manager marks its clipboard this way.
    private static let concealedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    ]

    func refreshPasteboardPreview() {
        let pasteboard = NSPasteboard.general
        let present = Set(pasteboard.types ?? [])
        guard present.isDisjoint(with: Self.concealedTypes),
              let text = pasteboard.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            pasteboardPreview = nil
            return
        }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        pasteboardPreview = flat.count > 28 ? String(flat.prefix(28)) + "…" : flat
    }

    /// What the notch button announces. Names the KIND, never the contents —
    /// the bezel is the most public strip of the screen.
    var pasteboardKindLabel: String {
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return "Image copied" }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return "Files copied"
        }
        return "Text copied"
    }

    var pasteboardGlyph: String {
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return "photo" }
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return "doc.on.doc"
        }
        return "text.alignleft"
    }

    /// Weight, not contents — the same reason the label names a kind.
    var pasteboardSizeLabel: String {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard) {
            let size = image.size
            return "\(Int(size.width)) × \(Int(size.height))"
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        }
        guard let text = pasteboard.string(forType: .string) else { return "Ready to send" }
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return characters == 1 ? "1 character" : "\(characters) characters"
    }

    /// One click, no shelf: send what's on the clipboard to the PC and keep a
    /// copy in Sticky's own clipboard history.
    func sendClipboardNow() {
        refreshPasteboardPreview()
        let pasteboard = NSPasteboard.general
        guard pasteboardPreview != nil,
              let text = pasteboard.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            showFailure(reason: "Nothing on the clipboard")
            return
        }
        // Kept in Sticky's own clipboard either way — that is the point of it
        // being a separate clipboard.
        addStickyClipboardText(text)
        hapticService?.fire(.lock)

        // Don't claim a send that cannot happen. The optimistic version
        // flashed "Sent" at a user with no PC on the network.
        guard peerReachable else {
            showFailure(reason: "No PC nearby · kept in clipboard")
            return
        }
        clipboardSender?(text)
        showSuccess(count: 1)
    }

    func setPointerHover(_ hovering: Bool) {
        pointerIsOver = hovering
        if hovering { refreshPasteboardPreview() }
        guard !isExpanded else { return }
        cancelHoverReset()

        if hovering {
            guard case .idle = state else { return }
            withMotionAnimation(.opening) {
                state = .hover
            }
        } else if case .hover = state {
            withMotionAnimation(.closing) {
                state = .idle
            }
        }
    }

    /// Plan §4.2 Armed: show the filename, middle-truncated — or "4 files".
    @Published private(set) var armedTitle: String?
    /// The file the portal previews. A URL rather than pre-rendered image data
    /// so the portal can use the same QuickLook path as the shelf chips —
    /// decoding a full-resolution TIFF to fill a 28 pt tile both stalled the
    /// drop and produced a hard centre crop.
    @Published private(set) var armedPreviewURL: URL?
    /// A peek at what an ⌥-click would send, refreshed when the pointer
    /// arrives. Read on demand — nothing polls the pasteboard for this.
    @Published private(set) var pasteboardPreview: String?
    /// Seconds left before an armed drop sends itself. Nil when nothing is
    /// counting down.
    @Published private(set) var sendCountdown: Int?
    private var countdownTimer: Timer?
    /// Plan F-1 says a drop is a send; this is the few seconds in which you can
    /// say "actually, just hold it" without having to undo a transfer.
    static let keepWindow: TimeInterval = 4
    /// Plan §4.2 Sending: no large percentage counter unless the transfer
    /// exceeds two seconds.
    @Published private(set) var transferIsLong = false
    private var longTransferTimer: DispatchWorkItem?

    func setDropProbe(width: CGFloat, height: CGFloat) {
        dropProbeWidth = max(width, 1)
        dropProbeHeight = max(height, 1)
    }

    func dragDidMove(to point: CGPoint) {
        dropTargeting = true
        updateDragMagnetism(at: point)
    }

    private func updateDragMagnetism(at location: CGPoint) {
        let vertical = max(0, min(1, 1 - location.y / dropProbeHeight))
        let centeredHorizontal = 1 - abs((location.x / dropProbeWidth) * 2 - 1)
        dropMagnetism = max(0, min(1, vertical * (0.45 + centeredHorizontal * 0.55)))
        dragAlignment = max(-1, min(1, (location.x / dropProbeWidth) * 2 - 1))
    }

    /// Everything that reads the dragging pasteboard happens before this
    /// returns — after that the pasteboard is not ours. Promised files arrive
    /// later, on their own queue.
    func receiveDrop(_ info: NSDraggingInfo, in view: NSView) -> Bool {
        dropTargeting = false
        withMotionAnimation {
            dropMagnetism = 0
            dragAlignment = 0
        }

        let drop: InFlightDrop
        do {
            drop = try DropIntake.begin(info, in: view)
        } catch {
            showFailure(reason: error.localizedDescription)
            return false
        }
        hapticService?.fire(.lock)

        Task { [weak self] in
            do {
                let urls = try await drop.finish()
                self?.handleDroppedFiles(urls)
            } catch {
                drop.discard()
                self?.showFailure(reason: error.localizedDescription)
            }
        }
        return true
    }

    func dragDidExit() {
        dropTargeting = false
        withMotionAnimation {
            dropMagnetism = 0
            dragAlignment = 0
        }
        // Plan §4.2 "Moving away": 100 ms grace before closing.
        scheduleHoverCollapse()
    }

    private func scheduleHoverCollapse() {
        cancelHoverReset()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsOver else { return }
            self.forceCollapseIfHovering()
        }
        hoverTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Dwell.dragOutGrace, execute: work)
    }

    // MARK: - State transitions

    private func handleDroppedFiles(_ urls: [URL]) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else {
            cancelHoverReset()
            showFailure(reason: "Files are no longer available")
            return
        }

        // Plan F-6: a transfer in flight accepts more files dropped onto it.
        // Merge rather than replace — the old code cancelled the first batch
        // and left it in limbo.
        let carriedOver = cancelTransientWork(preservingBatch: false)
        let merged = carriedOver + validURLs.filter { url in
            !carriedOver.contains { $0.path == url.path }
        }
        addToShelf(validURLs)

        let previewData = validURLs.first.flatMap { url in
            NSImage(contentsOf: url)?.tiffRepresentation
        }
        armedTitle = merged.count == 1 ? merged[0].lastPathComponent : "\(merged.count) files"
        armedPreviewURL = merged.first

        // A drop always heads for the PC — that is what dropping means here —
        // but never instantly. The countdown is the whole disambiguation: you
        // don't choose a destination before acting, you get a moment to say
        // "hold this instead" after. Do nothing and it sends.
        armedBatch = merged
        withMotionAnimation(.opening) {
            state = .armed(fileCount: merged.count, previewImage: previewData)
        }
        startSendCountdown()
    }

    /// Does the hover island have anything to show? Drives its depth, so an
    /// empty drawer gets a shallow lip rather than a tall empty box.
    var hoverHasContent: Bool {
        pasteboardPreview != nil || !shelfFiles.isEmpty || !pendingTransfers.isEmpty
    }

    /// The first few things in the drawer, for the wordless hover preview.
    var hoverPreviewURLs: [URL] {
        let queued = pendingTransfers.flatMap { $0.items.map(\.url) }
        return Array((shelfFiles.map(\.url) + queued).prefix(4))
    }

    var canKeepArmedBatch: Bool { !armedBatch.isEmpty }

    private func startSendCountdown() {
        cancelSendCountdown()
        guard !armedBatch.isEmpty else { return }
        sendCountdown = Int(Self.keepWindow)

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, let remaining = self.sendCountdown else { timer.invalidate(); return }
                if remaining <= 1 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    self.sendCountdown = nil
                    let batch = self.armedBatch
                    self.armedBatch = []
                    guard !batch.isEmpty else { return }
                    self.beginTransfer(batch)
                } else {
                    self.sendCountdown = remaining - 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func cancelSendCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        sendCountdown = nil
    }

    /// "Keep" — hold the batch in the drawer instead of sending it now. The
    /// files are already on the shelf, so this only has to stop the clock.
    func keepArmedBatch() {
        guard !armedBatch.isEmpty else { return }
        cancelSendCountdown()
        armedBatch = []
        hapticService?.fire(.tick)
        resetToIdle()
    }

    private func cancelHoverReset() {
        hoverTimer?.cancel()
        hoverTimer = nil
    }

    private func beginTransfer(_ urls: [URL]) {
        guard let transferService else {
            showFailure(reason: "Transfer service is unavailable")
            return
        }

        // A reset timer left over from a preceding success/failure would
        // otherwise fire mid-upload and permanently kill the progress UI.
        cancelTransientTimers()
        transferGeneration += 1
        let generation = transferGeneration
        activeTransferGeneration = generation
        activeBatch = urls
        armedBatch = []
        beginLongTransferWatch()

        let fileName = urls.first?.lastPathComponent
        withMotionAnimation(.opening) {
            state = .transferring(progress: 0, fileName: fileName)
        }
        soundService?.play(.whoosh)
        hapticService?.fire(.transferStart)

        transferTask = Task { [weak self] in
            do {
                guard let self else { return }
                let succeeded = try await transferService.sendFiles(urls) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.withMotionProgress {
                            self.state = .transferring(progress: progress, fileName: fileName)
                        }
                    }
                }

                guard !Task.isCancelled else {
                    guard self.activeTransferGeneration == generation else { return }
                    self.activeTransferGeneration = nil
                    self.resetToIdle()
                    return
                }
                if succeeded {
                    guard self.activeTransferGeneration == generation else { return }
                    self.activeTransferGeneration = nil
                    self.onSendSucceeded?(urls)
                    self.showSuccess(count: urls.count)
                } else {
                    guard self.activeTransferGeneration == generation else { return }
                    self.activeTransferGeneration = nil
                    self.queueForLater(urls, reason: "Transfer failed")
                }
        } catch is CancellationError {
                guard let self else { return }
                guard self.activeTransferGeneration == generation else { return }
                self.activeTransferGeneration = nil
                self.resetToIdle()
            } catch TransferError.noPeer {
                guard let self else { return }
                guard self.activeTransferGeneration == generation else { return }
                self.activeTransferGeneration = nil
                self.queueForLater(urls, reason: "PC offline")
            } catch {
                guard let self else { return }
                guard self.activeTransferGeneration == generation else { return }
                self.activeTransferGeneration = nil
                self.showFailure(reason: error.localizedDescription)
            }
        }
    }

    @Published private(set) var peerCount: Int = 0
    @Published var peerName: String?
    @Published var selectedShelfIDs: Set<UUID> = []
    @Published var isSelecting = false
    @Published var clipboardSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(clipboardSyncEnabled, forKey: "sticky.clipboardSync") }
    }
    /// App layer hooks: outgoing sync text + notification that settings changed.
    var clipboardSyncSender: ((String) -> Void)?
    /// Fires when a batch has actually landed on the peer. The app layer uses
    /// it for the Recents menu; without it the only signal was `state`, which
    /// an interleaved incoming transfer can forge.
    var onSendSucceeded: (([URL]) -> Void)?
    var onClipboardSyncChanged: ((Bool) -> Void)?

    // MARK: - The Slot (manual clipboard pocket)
    @Published var slotText: String {
        didSet { UserDefaults.standard.set(slotText, forKey: "sticky.slot.text") }
    }
    @Published var slotImage: NSImage? {
        didSet { persistSlotImage() }
    }
    private var suppressSlotSync = false

    func writeSlot(text: String) {
        guard text != slotText else { return }
        suppressSlotSync = true
        slotText = text
        suppressSlotSync = false
        clipboardSyncSender?(text)
        hapticService?.fire(.tick)
    }

    func writeSlot(image: NSImage) {
        slotImage = image
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            UserDefaults.standard.set(png, forKey: "sticky.slot.image")
        }
        hapticService?.fire(.tick)
    }

    func pasteIntoSlot() {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb) {
            writeSlot(image: img)
            return
        }
        if let str = pb.string(forType: .string), !str.isEmpty {
            writeSlot(text: str)
        }
    }

    func clearSlot() {
        slotText = ""
        slotImage = nil
        UserDefaults.standard.removeObject(forKey: "sticky.slot.image")
        hapticService?.fire(.tick)
    }

    /// Push the Slot's text to the paired PC on demand, independent of whether
    /// background clipboard sync is switched on.
    func sendSlotToPeer() {
        let text = slotText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        clipboardSender?(text)
        noteInteraction()
    }

    func copySlotToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let img = slotImage {
            pb.writeObjects([img])
        } else if !slotText.isEmpty {
            pb.setString(slotText, forType: .string)
        }
    }

    func receiveRemoteSlot(text: String) {
        guard text != slotText else { return }
        suppressSlotSync = true
        slotText = text
        suppressSlotSync = false
    }

    private func persistSlotImage() {
        guard !suppressSlotSync else { return }
        guard let image = slotImage else {
            UserDefaults.standard.removeObject(forKey: "sticky.slot.image")
            return
        }
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            UserDefaults.standard.set(png, forKey: "sticky.slot.image")
        }
    }

    func updatePeerAvailability(_ available: Bool) {
        peerReachable = available
        peerCount = available ? 1 : 0
        if !available { peerName = nil }
        if available {
            processPendingQueue()
        }
    }

    func processPendingQueue(force: Bool = false) {
        guard force || Date() >= nextQueueAttemptAt else { return }
        guard peerReachable, !pendingTransfers.isEmpty, !isProcessingPendingQueue else {
            if !pendingTransfers.isEmpty && !isProcessingPendingQueue { scheduleQueueRetry() }
            return
        }
        let queueMayRun: Bool
        switch state {
        case .idle, .queued:
            queueMayRun = true
        case .hover, .armed, .transferring, .success, .failure, .incomingOffer:
            queueMayRun = false
        }
        guard queueMayRun else {
            // Busy showing something else — come back shortly rather than
            // waiting for a signal that may never arrive.
            scheduleQueueRetry(after: 3)
            return
        }

        var transfer = pendingTransfers[0]
        let urls = transfer.items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            removePendingTransfer(id: transfer.id)
            processPendingQueue()
            return
        }
        if urls.count != transfer.items.count {
            transfer.items = urls.map(StickyShelfItem.init(url:))
        }

        isProcessingPendingQueue = true
        transferGeneration += 1
        let generation = transferGeneration
        activeTransferGeneration = generation
        cancelTransientTimers()
        let fileName = urls.first?.lastPathComponent
        withMotionAnimation(.opening) {
            state = .transferring(progress: 0, fileName: fileName)
        }

        transferTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Unconditional: this latch is what lets the queue run
                    // again. Guarding it on the generation meant any drop that
                    // superseded this transfer wedged the queue permanently —
                    // "Retry all" included.
                    self.isProcessingPendingQueue = false
                    if self.activeTransferGeneration == generation {
                        self.activeTransferGeneration = nil
                    }
                    self.scheduleQueueRetry()
                }
            }
            do {
                guard let self else { return }
                let succeeded = try await self.transferService?.sendFiles(urls) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.withMotionProgress {
                            self.state = .transferring(progress: progress, fileName: fileName)
                        }
                    }
                } ?? false

                guard !Task.isCancelled else {
                    // Guarded like every other branch: without this, a queue
                    // task cancelled by a newer drop reset the island to idle
                    // while the newer transfer was still uploading.
                    await MainActor.run { [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.resetToIdle()
                    }
                    return
                }
                if succeeded {
                    await MainActor.run { [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.removePendingTransfer(id: transfer.id)
                        self.onSendSucceeded?(urls)
                        self.showSuccess(count: urls.count)
                    }
                } else {
                    await MainActor.run { [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.retainPendingTransfer(transfer, reason: "PC offline")
                    }
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.activeTransferGeneration == generation else { return }
                    self.retainPendingTransfer(transfer, reason: "Sending paused")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.activeTransferGeneration == generation else { return }
                    self.retainPendingTransfer(transfer, reason: error.localizedDescription)
                }
            }
        }
    }

    private func queueForLater(_ urls: [URL], reason: String) {
        enqueuePendingTransfer(urls)
        // The file now lives in "Waiting for PC" — don't keep a ghost copy in
        // the shelf making it look like nothing happened.
        let paths = Set(urls.map { $0.path })
        shelfFiles.removeAll { paths.contains($0.url.path) }
        selectedShelfIDs.removeAll()
        showQueued(count: urls.count, reason: reason)
    }

    private func enqueuePendingTransfer(_ urls: [URL]) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else { return }
        let existingPaths = Set(pendingTransfers.flatMap { $0.items.map(\.url.path) })
        let newItems = validURLs.filter { !existingPaths.contains($0.path) }.map(StickyShelfItem.init(url:))
        guard !newItems.isEmpty else { return }
        pendingTransfers.append(PendingTransfer(items: newItems))
    }

    private func retainPendingTransfer(_ transfer: PendingTransfer, reason: String) {
        var transfer = transfer
        transfer.attempts += 1
        if let index = pendingTransfers.firstIndex(where: { $0.id == transfer.id }) {
            pendingTransfers[index] = transfer
        }
        showFailure(reason: "\(reason) · kept in queue")
    }

    private func removePendingTransfer(id: UUID) {
        pendingTransfers.removeAll { $0.id == id }
    }

    /// Cancelling from the shelf must stop the wire, not just hide the row.
    /// Removing the in-flight item used to leave the send running, so the file
    /// the user just cancelled still landed on the PC — and was reported sent.
    func cancelPendingTransfer(id: UUID) {
        let wasInFlight = isProcessingPendingQueue && pendingTransfers.first?.id == id
        removePendingTransfer(id: id)
        guard wasInFlight else { return }
        cancelTransientWork(preservingBatch: false)
        isProcessingPendingQueue = false
        resetToIdle()
    }

    func clearPendingTransfers() {
        transferTask?.cancel()
        transferTask = nil
        activeTransferGeneration = nil
        isProcessingPendingQueue = false
        queueRetryTimer?.cancel()
        queueRetryTimer = nil
        pendingTransfers.removeAll()
        if case .transferring = state {
            resetToIdle()
        }
    }

    private func showQueued(count: Int, reason: String) {
        armedPreviewURL = pendingTransfers.last?.items.first?.url ?? armedPreviewURL
        let previewData = pendingTransfers.last?.items.first.flatMap { item in
            NSImage(contentsOf: item.url)?.tiffRepresentation
        }
        withMotionAnimation(.opening) {
            state = .queued(fileCount: count, previewImage: previewData)
        }
        hapticService?.fire(.queued)
        soundService?.play(.tick)
        scheduleReset(after: DS.Dwell.queued)
    }

    /// Re-arms the queue. Called from every early return as well as from the
    /// transfer defer: the old code scheduled a retry only from inside the
    /// transfer task, so a tick that bailed early (peer busy, pointer resting
    /// on the notch) stranded the rest of the queue until a manual retry.
    private func scheduleQueueRetry(after interval: TimeInterval = 30) {
        queueRetryTimer?.cancel()
        guard !pendingTransfers.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.processPendingQueue()
        }
        queueRetryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func showSuccess(count: Int) {
        withMotionAnimation(.opening) {
            state = .success(fileCount: count)
        }
        hapticService?.fire(.success)
        soundService?.play(.success)
        scheduleReset(after: DS.Dwell.success)
    }

    private func showFailure(reason: String?) {
        withMotionAnimation(.opening) {
            state = .failure(reason: reason)
        }
        hapticService?.fire(.failure)
        soundService?.play(.failure)
        scheduleReset(after: DS.Dwell.failure)
    }

    private func scheduleReset(after interval: TimeInterval) {
        autoResetTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.resetToIdle()
        }
        autoResetTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    func cancelActiveTransfer() {
        transferGeneration += 1
        transferTask?.cancel()
        transferTask = nil
        activeTransferGeneration = nil
        cancelTransientTimers()
        if state != .idle {
            resetToIdle()
            hapticService?.fire(.tick)
            soundService?.play(.tick)
        }
    }

    func resetToIdle() {
        armedTitle = nil
        cancelSendCountdown()
        armedPreviewURL = nil
        cancelLongTransferWatch()
        withMotionAnimation(.closing) {
            state = .idle
        }
        // If the cursor never moved during the transient state, macOS won't
        // re-fire onHover — restore hover directly so the island isn't dead.
        if pointerIsOver, !isExpanded {
            DispatchQueue.main.async { [weak self] in
                guard let self, case .idle = self.state, self.pointerIsOver, !self.isExpanded else { return }
                self.withMotionAnimation(.opening) {
                    self.state = .hover
                }
            }
        }
    }

    func toggleClipboardSync() {
        clipboardSyncEnabled.toggle()
        onClipboardSyncChanged?(clipboardSyncEnabled)
        noteInteraction()
    }

    private var lastCollapseAt = Date.distantPast

    func toggleExpanded() {
        // Click-away collapse can be immediately followed by the same click
        // landing on the collapsed island — don't reopen from that one event.
        guard Date().timeIntervalSince(lastCollapseAt) > 0.25 else { return }
        if isExpanded {
            collapseExpanded()
        } else {
            withMotionAnimation(.opening) {
                isExpanded = true
            }
            hapticService?.fire(.tick)
        }
    }

    func collapseExpanded() {
        guard isExpanded else { return }
        lastCollapseAt = Date()
        // The view that owns `.onHover` is destroyed while expanded, so no
        // exit event is ever delivered. Without this the island stays in
        // `.hover` forever and keeps claiming the enlarged hit region.
        if !pointerIsOver, case .hover = state {
            forceCollapseIfHovering()
        }
        withMotionAnimation(.closing) { isExpanded = false }
    }

    /// Immediate, timer-free collapse used by the hover watchdog. If macOS
    /// misses mouse-exited, the notch cannot stay open past one watchdog tick.
    func forceCollapseIfHovering() {
        guard case .hover = state else { return }
        dropTargeting = false
        dropMagnetism = 0
        dragAlignment = 0
        cancelHoverReset()
        withMotionAnimation(.closing) { state = .idle }
    }

    func receiveIncomingOffer(senderName: String, fileCount: Int, kind: TransferKind) {
        cancelTransientWork()
        withMotionAnimation(.opening) {
            state = .incomingOffer(senderName: senderName, fileCount: fileCount, kind: kind)
        }
        hapticService?.fire(.lock)
        soundService?.play(.whoosh)
        scheduleReset(after: DS.Dwell.incoming)
    }

    func receiveRemoteClipboard(_ text: String, senderName: String) {
        clipboardService?.receiveRemote(text: text, senderName: senderName)
        hapticService?.fire(.tick)
        soundService?.play(.tick)
    }

    func receiveIncomingCompleted(count: Int) {
        showSuccess(count: count)
    }

    func reportClipboardSendError(_ reason: String) {
        guard case .idle = state else { return }
        showFailure(reason: "Clipboard not sent: \(reason)")
    }


    func requestPairing() {
        pairingAction?()
    }

    func requestUnpairAll() {
        unpairAllAction?()
    }

    func noteInteraction() {
        hapticService?.fire(.tick)
    }

    enum MotionDirection { case opening, closing }

    /// Plan §4.3: springs live in one file, and motion is asymmetric — opening
    /// is springy, closing is smooth with no bounce, because a bouncing close
    /// reads as indecision. Reduce Motion becomes a 150 ms fade, NOT an instant
    /// cut: the spec is explicit that geometry, content and haptics stay
    /// identical and only the spring is substituted.
    private func withMotionAnimation(_ direction: MotionDirection = .opening, _ changes: () -> Void) {
        if reducesMotion {
            withAnimation(DS.Motion.reduced, changes)
            return
        }
        withAnimation(direction == .opening ? DS.Motion.open : DS.Motion.close, changes)
    }

    private func withMotionProgress(_ changes: () -> Void) {
        withAnimation(reducesMotion ? DS.Motion.reduced : DS.Motion.progress, changes)
    }

    func addToShelf(_ urls: [URL]) {
        let existingPaths = Set(shelfFiles.map { $0.url.path })
        let newItems = urls
            .filter { !existingPaths.contains($0.path) }
            .map(StickyShelfItem.init(url:))
        guard !newItems.isEmpty else { return }
        shelfFiles.append(contentsOf: newItems)
    }

    func sendFiles(_ urls: [URL]) {
        handleDroppedFiles(urls)
    }

    private func persistShelfIfNeeded() {
        guard !isRestoringShelf else { return }
        let encoded = (try? JSONEncoder().encode(shelfFiles)) ?? Data()
        UserDefaults.standard.set(encoded, forKey: shelfDefaultsKey)
    }

    private func restoreShelf() {
        guard let data = UserDefaults.standard.data(forKey: shelfDefaultsKey) else { return }
        isRestoringShelf = true
        defer { isRestoringShelf = false }
        shelfFiles = (try? JSONDecoder().decode([StickyShelfItem].self, from: data)) ?? []
    }

    private func persistPendingTransfersIfNeeded() {
        guard !isRestoringPendingTransfers else { return }
        let encoded = (try? JSONEncoder().encode(pendingTransfers)) ?? Data()
        UserDefaults.standard.set(encoded, forKey: pendingDefaultsKey)
    }

    private func restorePendingTransfers() {
        guard let data = UserDefaults.standard.data(forKey: pendingDefaultsKey) else { return }
        isRestoringPendingTransfers = true
        defer { isRestoringPendingTransfers = false }
        pendingTransfers = (try? JSONDecoder().decode([PendingTransfer].self, from: data)) ?? []
    }

    /// Abandons whatever transient work is in flight — and, crucially, does
    /// not lose the files it was carrying.
    ///
    /// The old version bumped `transferGeneration` but left
    /// `activeTransferGeneration` alone, and every guard in this file compares
    /// against the latter. So cancelled work still mutated state (an incoming
    /// offer could be erased by the transfer it interrupted), while the batch
    /// that was cancelled vanished: not sent, not queued, no error.
    @discardableResult
    private func cancelTransientWork(preservingBatch: Bool = true) -> [URL] {
        let abandoned = activeBatch + armedBatch
        transferGeneration += 1
        activeTransferGeneration = nil
        activeBatch = []
        armedBatch = []
        cancelLongTransferWatch()
        armedTimer?.cancel()
        armedTimer = nil
        autoResetTimer?.cancel()
        autoResetTimer = nil
        transferTask?.cancel()
        transferTask = nil
        if preservingBatch, !abandoned.isEmpty {
            enqueuePendingTransfer(abandoned)
        }
        return abandoned
    }

    private func beginLongTransferWatch() {
        cancelLongTransferWatch()
        transferStartedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .transferring = self.state else { return }
            self.transferIsLong = true
        }
        longTransferTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Dwell.percentageAfter, execute: work)
    }

    private func cancelLongTransferWatch() {
        longTransferTimer?.cancel()
        longTransferTimer = nil
        transferStartedAt = nil
        transferIsLong = false
    }

    private func cancelTransientTimers() {
        armedTimer?.cancel()
        armedTimer = nil
        autoResetTimer?.cancel()
        autoResetTimer = nil
    }

    func prepareForQuit() {
        transferGeneration += 1
        queueRetryTimer?.cancel()
        queueRetryTimer = nil
        activeTransferGeneration = nil
        cancelTransientWork()
        resetToIdle()
    }
}

struct PendingTransfer: Identifiable, Codable {
    let id: UUID
    var items: [StickyShelfItem]
    let createdAt: Date
    var attempts: Int

    init(id: UUID = UUID(), items: [StickyShelfItem], createdAt: Date = Date(), attempts: Int = 0) {
        self.id = id
        self.items = items
        self.createdAt = createdAt
        self.attempts = attempts
    }
}

struct StickyShelfItem: Identifiable, Codable {
    let id: UUID
    let url: URL
    private let bookmarkData: Data?

    init(url: URL) {
        id = UUID()
        self.url = url
        bookmarkData = try? url.bookmarkData()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case bookmarkData
        case path
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        bookmarkData = try values.decodeIfPresent(Data.self, forKey: .bookmarkData)

        if let bookmarkData {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                url = resolved
                return
            }
        }

        let path = try values.decode(String.self, forKey: .path)
        url = URL(fileURLWithPath: path)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try values.encode(url.path, forKey: .path)
    }

    var name: String { url.lastPathComponent }

    var isImage: Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    var previewImage: NSImage? {
        guard isImage else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct StickyClipEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let sender: String?
}

extension NotchViewModel {
    func promoteToSystemClipboard(entry: StickyClipEntry) {
        if let clipboardService {
            clipboardService.promoteToSystemClipboard(entry)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        stickySlot = entry
    }

    func deleteClipboardEntry(_ entry: StickyClipEntry) {
        clipboardService?.delete(entry)
        if clipboardService == nil {
            clipboardHistory.removeAll { $0.id == entry.id }
            if stickySlot?.id == entry.id {
                stickySlot = clipboardHistory.first
            }
        }
    }

    func clearClipboardHistory() {
        clipboardService?.clearHistory()
        if clipboardService == nil {
            clipboardHistory.removeAll()
            stickySlot = nil
        }
    }

    func addStickyClipboardText(_ text: String) {
        guard !text.isEmpty else { return }
        let entry = clipboardService?.writeSticky(text: text)
            ?? StickyClipEntry(id: UUID(), text: text, timestamp: Date(), sender: nil)
        if clipboardService == nil {
            clipboardHistory.insert(entry, at: 0)
            stickySlot = entry
        }
        noteInteraction()
    }

    /// Send a clip in whatever form it actually is. Going through the typed
    /// item matters: an image row's `text` is a label like "Image 1024 × 768",
    /// and the legacy path would have cheerfully sent that string.
    func sendClipboardEntry(_ entry: StickyClipEntry) {
        if let item = clipboardService?.item(for: entry) {
            sendClip(item)
            return
        }
        clipboardSender?(entry.text)
        noteInteraction()
    }

    /// Put a line of text into the drawer. Everything that lands in the drawer
    /// heads for the PC — that is what the drawer IS — but it is always kept
    /// locally first, so nothing is lost when the PC is away.
    func putText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addStickyClipboardText(trimmed)
        guard peerReachable else {
            showFailure(reason: "No PC nearby · kept in Sticky")
            return
        }
        clipboardSender?(trimmed)
        showSuccess(count: 1)
    }

    /// Explicit paste — the drawer never reads the system clipboard on its own.
    func pasteIntoDrawer() {
        let pasteboard = NSPasteboard.general
        let present = Set(pasteboard.types ?? [])
        guard present.isDisjoint(with: Self.concealedTypes) else {
            showFailure(reason: "That clipboard item is marked private")
            return
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            handleDroppedFiles(urls)
            return
        }
        if let image = NSImage(pasteboard: pasteboard) {
            writeSlot(image: image)
            noteInteraction()
            return
        }
        if let text = pasteboard.string(forType: .string) {
            putText(text)
        }
    }

    func sendClip(_ item: StickyClipItem) {
        guard let payload = clipboardService?.sendPayload(for: item) else {
            showFailure(reason: "That clip can't be sent yet")
            return
        }
        switch payload {
        case .text(let text):
            guard peerReachable else {
                showFailure(reason: "No PC nearby · kept in clipboard")
                return
            }
            clipboardSender?(text)
            showSuccess(count: 1)
        case .files(let urls):
            sendFiles(urls)
        }
        noteInteraction()
    }
}

// MARK: - Shelf window support

extension NotchViewModel {
    func removeShelfItemPublic(id: UUID) {
        shelfFiles.removeAll { $0.id == id }
    }

    func removePendingTransferPublic(id: UUID) {
        cancelPendingTransfer(id: id)
    }

    func clearShelf() {
        shelfFiles.removeAll()
        selectedShelfIDs.removeAll()
    }

    func toggleSelection(for id: UUID) {
        if selectedShelfIDs.contains(id) {
            selectedShelfIDs.remove(id)
        } else {
            selectedShelfIDs.insert(id)
        }
    }

    func enterSelectionMode() {
        isSelecting = true
    }

    func cancelSelection() {
        isSelecting = false
        selectedShelfIDs.removeAll()
    }

    func deleteSelected() {
        // Selection only ever covers shelf items; pending transfers have their
        // own remove button. The old code filtered the queue against a fresh
        // UUID(), which matched nothing and read as a silent no-op.
        shelfFiles.removeAll { selectedShelfIDs.contains($0.id) }
        selectedShelfIDs.removeAll()
        isSelecting = false
        hapticService?.fire(.tick)
    }

    /// There is one shelf, and it lives in the notch.
    ///
    /// This used to open a second, free-floating window with its own styling
    /// and its own copy of every row — two shelves that could disagree, and a
    /// persistent window the plan rules out. The menu item now opens the same
    /// surface the notch does.
    func showShelf() {
        guard !isExpanded else { return }
        toggleExpanded()
    }

    func toggleShelf() {
        toggleExpanded()
    }
}
