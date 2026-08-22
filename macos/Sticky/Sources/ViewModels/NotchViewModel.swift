import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NotchViewModel: NSObject, ObservableObject, DropDelegate {
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
    private var hapticService: HapticService?
    private var soundService: SoundService?
    private var transferService: TransferService?
    private var clipboardService: ClipboardService?
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

    func dropEntered(info: DropInfo) {
        guard case .idle = state else { return }
        dropTargeting = true
        hoverTimer?.cancel()
        hoverTimer = nil
        withMotionAnimation(response: 0.22, dampingFraction: 0.85) {
            state = .hover
        }
    }

    func setPointerHover(_ hovering: Bool) {
        guard !isExpanded else { return }
        cancelHoverReset()

        if hovering {
            guard case .idle = state else { return }
            withMotionAnimation(response: 0.22, dampingFraction: 0.85) {
                state = .hover
            }
        } else if case .hover = state {
            // Exit immediately — no grace delay.
            withMotionAnimation(response: 0.24, dampingFraction: 0.88) {
                state = .idle
            }
        }
    }

    func setDropProbe(width: CGFloat) {
        dropProbeWidth = max(width, 1)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTargeting = true
        updateDragMagnetism(at: info.location)
        return DropProposal(operation: .copy)
    }

    private func updateDragMagnetism(at location: CGPoint) {
        let vertical = max(0, min(1, 1 - location.y / 90))
        let centeredHorizontal = 1 - abs((location.x / dropProbeWidth) * 2 - 1)
        dropMagnetism = max(0, min(1, vertical * (0.45 + centeredHorizontal * 0.55)))
        dragAlignment = max(-1, min(1, (location.x / dropProbeWidth) * 2 - 1))
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargeting = false
        withMotionAnimation {
            dropMagnetism = 0
            dragAlignment = 0
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        hapticService?.fire(.lock)

        var loadedURLs = [Int: URL]()
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let loadedURL: URL?
                if let data = item as? Data {
                    loadedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    loadedURL = url
                } else if let nsURL = item as? NSURL {
                    loadedURL = nsURL as URL
                } else {
                    loadedURL = nil
                }

                DispatchQueue.main.async {
                    if let url = loadedURL {
                        loadedURLs[index] = url
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            let urls = loadedURLs.sorted(by: { $0.key < $1.key }).map(\.value)
            self?.handleDroppedFiles(urls)
        }
        return true
    }

    func dropExited(info: DropInfo) {
        dropTargeting = false
        withMotionAnimation {
            dropMagnetism = 0
            dragAlignment = 0
        }
        if case .hover = state {
            forceCollapseIfHovering()
        }
    }

    // MARK: - State transitions

    private func handleDroppedFiles(_ urls: [URL]) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else {
            cancelHoverReset()
            showFailure(reason: "Files are no longer available")
            return
        }

        cancelTransientWork()
        addToShelf(validURLs)

        let previewData = validURLs.first.flatMap { url in
            NSImage(contentsOf: url)?.tiffRepresentation
        }
        withMotionAnimation(response: 0.42, dampingFraction: 0.82) {
            state = .armed(fileCount: validURLs.count, previewImage: previewData)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.beginTransfer(validURLs)
        }
        armedTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
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

        transferGeneration += 1
        let generation = transferGeneration
        activeTransferGeneration = generation

        let fileName = urls.first?.lastPathComponent
        withMotionAnimation(response: 0.45, dampingFraction: 0.85) {
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
                        guard case .transferring = self.state else { return }
                        self.withMotionProgress {
                            self.state = .transferring(progress: progress, fileName: fileName)
                        }
                    }
                }

                guard !Task.isCancelled else {
                    self.resetToIdle()
                    return
                }
                if succeeded {
                    guard self.activeTransferGeneration == generation else { return }
                    self.activeTransferGeneration = nil
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
    @Published var selectedShelfIDs: Set<UUID> = []
    @Published var isSelecting = false
    @Published var clipboardSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(clipboardSyncEnabled, forKey: "sticky.clipboardSync") }
    }
    /// App layer hooks: outgoing sync text + notification that settings changed.
    var clipboardSyncSender: ((String) -> Void)?
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
        peerCount = max(peerCount, available ? 1 : 0)
        if !available { peerCount = 0 }
        if available {
            processPendingQueue()
        }
    }

    func processPendingQueue(force: Bool = false) {
        guard force || Date() >= nextQueueAttemptAt else { return }
        guard peerReachable, !pendingTransfers.isEmpty, !isProcessingPendingQueue else { return }
        let queueMayRun: Bool
        switch state {
        case .idle, .queued:
            queueMayRun = true
        case .hover, .armed, .transferring, .success, .failure, .incomingOffer:
            queueMayRun = false
        }
        guard queueMayRun else { return }

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
        withMotionAnimation(response: 0.45, dampingFraction: 0.85) {
            state = .transferring(progress: 0, fileName: fileName)
        }

        transferTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.activeTransferGeneration == generation else { return }
                    self.isProcessingPendingQueue = false
                    self.activeTransferGeneration = nil
                    self.nextQueueAttemptAt = Date().addingTimeInterval(30)
                    self.scheduleQueueRetry()
                }
            }
            do {
                guard let self else { return }
                let succeeded = try await self.transferService?.sendFiles(urls) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        guard case .transferring = self.state else { return }
                        self.withMotionProgress {
                            self.state = .transferring(progress: progress, fileName: fileName)
                        }
                    }
                } ?? false

                guard !Task.isCancelled else {
                    Task { @MainActor [weak self] in self?.resetToIdle() }
                    return
                }
                if succeeded {
                    await MainActor.run { [weak self] in
                        guard let self, self.activeTransferGeneration == generation else { return }
                        self.removePendingTransfer(id: transfer.id)
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
        let previewData = pendingTransfers.last?.items.first.flatMap { item in
            NSImage(contentsOf: item.url)?.tiffRepresentation
        }
        withMotionAnimation(response: 0.38, dampingFraction: 0.78) {
            state = .queued(fileCount: count, previewImage: previewData)
        }
        hapticService?.fire(.queued)
        soundService?.play(.tick)
        scheduleReset(after: 2.2)
    }

    private func scheduleQueueRetry() {
        queueRetryTimer?.cancel()
        guard !pendingTransfers.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.processPendingQueue()
        }
        queueRetryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func showSuccess(count: Int) {
        withMotionAnimation(response: 0.35, dampingFraction: 0.7) {
            state = .success(fileCount: count)
        }
        hapticService?.fire(.success)
        soundService?.play(.success)
        scheduleReset(after: 1.5)
    }

    private func showFailure(reason: String?) {
        withMotionAnimation(response: 0.3, dampingFraction: 0.6) {
            state = .failure(reason: reason)
        }
        hapticService?.fire(.failure)
        soundService?.play(.failure)
        scheduleReset(after: 2.5)
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
        withMotionAnimation(response: 0.4, dampingFraction: 0.88) {
            state = .idle
        }
    }

    func toggleClipboardSync() {
        clipboardSyncEnabled.toggle()
        onClipboardSyncChanged?(clipboardSyncEnabled)
        noteInteraction()
    }

    func toggleExpanded() {
        if isExpanded {
            collapseExpanded()
        } else {
            withMotionAnimation(response: 0.4, dampingFraction: 0.86) {
                isExpanded = true
            }
            hapticService?.fire(.tick)
        }
    }

    func collapseExpanded() {
        guard isExpanded else { return }
        var tx = Transaction()
        tx.disablesAnimations = reducesMotion
        withTransaction(tx) {
            isExpanded = false
        }
    }

    /// Immediate, timer-free collapse used by the hover watchdog. If macOS
    /// misses mouse-exited, the notch cannot stay open past one watchdog tick.
    func forceCollapseIfHovering() {
        guard case .hover = state else { return }
        dropTargeting = false
        dropMagnetism = 0
        dragAlignment = 0
        cancelHoverReset()
        var tx = Transaction()
        tx.disablesAnimations = reducesMotion
        withTransaction(tx) {
            state = .idle
        }
    }

    func receiveIncomingOffer(senderName: String, fileCount: Int, kind: TransferKind) {
        cancelTransientWork()
        withMotionAnimation(response: 0.38, dampingFraction: 0.78) {
            state = .incomingOffer(senderName: senderName, fileCount: fileCount, kind: kind)
        }
        hapticService?.fire(.lock)
        soundService?.play(.whoosh)
        scheduleReset(after: 4.0)
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

    private func withMotionAnimation(
        response: Double = 0.42,
        dampingFraction: Double = 0.82,
        _ changes: () -> Void
    ) {
        if reducesMotion {
            changes()
            return
        }
        withAnimation(.spring(response: response, dampingFraction: dampingFraction), changes)
    }

    private func withMotionProgress(_ changes: () -> Void) {
        if reducesMotion {
            changes()
            return
        }
        withAnimation(.linear(duration: 0.12), changes)
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

    private func cancelTransientWork() {
        transferGeneration += 1
        armedTimer?.cancel()
        armedTimer = nil
        autoResetTimer?.cancel()
        autoResetTimer = nil
        transferTask?.cancel()
        transferTask = nil
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

    func sendClipboardEntry(_ entry: StickyClipEntry) {
        clipboardSender?(entry.text)
        noteInteraction()
    }
}

// MARK: - Shelf window support

extension NotchViewModel {
    func removeShelfItemPublic(id: UUID) {
        shelfFiles.removeAll { $0.id == id }
    }

    func removePendingTransferPublic(id: UUID) {
        removePendingTransfer(id: id)
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
        shelfFiles.removeAll { selectedShelfIDs.contains($0.id) }
        pendingTransfers = pendingTransfers.filter { !selectedShelfIDs.contains($0.items.first?.id ?? UUID()) }
        selectedShelfIDs.removeAll()
        isSelecting = false
        hapticService?.fire(.tick)
    }

    func showShelf() {
        ShelfWindowController.shared.show(viewModel: self)
    }

    func toggleShelf() {
        ShelfWindowController.shared.toggle(viewModel: self)
    }
}
