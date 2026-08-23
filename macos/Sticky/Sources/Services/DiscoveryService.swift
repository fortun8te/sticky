import CryptoKit
import Darwin
import AppKit
import Foundation
import Network

final class DiscoveryService: NSObject, ObservableObject {
    @Published private(set) var peers: [StickyDevice] = []
    @Published private(set) var lastError: String?

    // `myDevice` is read from other queues — TransferService answers GET /info
    // on its own worker queue — while `refreshLocalAddress()` rewrites it on
    // `discoveryQueue` every 10s. Assigning a whole struct is not atomic, so a
    // reader could observe a half-written value (over-release of `name`/`host`).
    // The storage is private and every access goes through `stateLock`; the
    // public property name keeps working for readers in other files.
    private var localDevice: StickyDevice
    private(set) var myDevice: StickyDevice {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return localDevice
        }
        set {
            stateLock.lock()
            localDevice = newValue
            stateLock.unlock()
        }
    }

    static let serviceType = "_sticky._tcp."
    static let port: UInt16 = 53317

    /// A peer is dropped after this long without any refresh.
    private static let peerTimeout: TimeInterval = 30
    /// Peers quieter than this are re-resolved over mDNS before they expire.
    private static let peerRefreshAge: TimeInterval = 20
    /// Delay before retrying a UDP bind that failed (port still held, etc.).
    private static let udpRebindDelay: TimeInterval = 5
    /// Shared prefix of every socket-level discovery error, so a later success
    /// can clear exactly the banners it is responsible for.
    private static let udpErrorPrefix = "UDP discovery"

    private let stateLock = NSLock()
    private var peerRecords: [String: StickyDevice] = [:]
    private var pendingConnections: [NWConnection] = []

    private let discoveryQueue = DispatchQueue(label: "sticky.discovery")
    private var udpListener: NWListener?
    private var pathMonitor = NWPathMonitor()
    private var advertiser: NetService?
    private var browser: NetServiceBrowser?
    private var resolvingServices: [String: NetService] = [:]
    private var monitoredServices: [String: NetService] = [:]
    private var serviceIDs: [String: String] = [:]
    private var resolveTimeouts: [String: DispatchWorkItem] = [:]
    private var udpRebindScheduled = false
    private var reportedConflicts: [String: String] = [:]
    private var announceTimer: Timer?
    private var expiryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isRunning = false

    // Windows broadcasts a deliberately small announcement without `host` or
    // `lastSeen`. Decode that wire format separately, then use the UDP source
    // address as the canonical address for both platforms.
    private struct Announcement: Decodable {
        let id: String
        let name: String?
        let platform: String?
        let host: String?
        let port: Int?
    }

    init(name: String = ProcessInfo.processInfo.hostName) {
        let storedID = UserDefaults.standard.string(forKey: "sticky.deviceID")
        let deviceID = storedID ?? {
            let id = UUID().uuidString.prefix(8).lowercased()
            UserDefaults.standard.set(String(id), forKey: "sticky.deviceID")
            return String(id)
        }()

        localDevice = StickyDevice(
            id: deviceID,
            name: name,
            platform: .mac,
            host: Self.localIPv4Address() ?? "",
            port: Int(Self.port)
        )
        super.init()
        start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        startUDPListener()
        startPathMonitor()
        refreshNetworkServices()

        announceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.discoveryQueue.async { self?.announce() }
        }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.removeExpiredPeers()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAfterNetworkChange()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        announceTimer?.invalidate()
        expiryTimer?.invalidate()
        announceTimer = nil
        expiryTimer = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        pathMonitor.cancel()
        stopNetworkServices()

        discoveryQueue.async { [weak self] in
            guard let self else { return }
            self.pendingConnections.forEach { $0.cancel() }
            self.pendingConnections.removeAll()
            self.udpListener?.cancel()
            self.udpListener = nil
        }

        stateLock.lock()
        peerRecords.removeAll()
        stateLock.unlock()
        publishPeers()
    }

    func announce() {
        guard isRunning else { return }
        refreshLocalAddress()

        guard let payload = try? JSONEncoder().encode(myDevice) else {
            setLastError("Could not encode discovery announcement.")
            return
        }

        let targets = Self.broadcastTargets()
        for target in (targets.isEmpty ? ["255.255.255.255"] : targets) {
            send(payload, to: target)
        }
    }

    private func send(_ payload: Data, to target: String) {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(
            to: NWEndpoint.hostPort(host: NWEndpoint.Host(target), port: port),
            using: parameters
        )
        discoveryQueue.async { [weak self] in
            guard let self, self.isRunning else {
                connection.cancel()
                return
            }
            self.pendingConnections.append(connection)
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.setLastError("UDP announcement failed on \(target).")
                    connection.cancel()
                }
            }
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.setLastError("UDP announcement failed on \(target).")
                }
                connection.cancel()
                self?.pendingConnections.removeAll { $0 === connection }
            })
            connection.start(queue: self.discoveryQueue)
        }
    }

    /// Binds the discovery socket. Safe to call from any queue and at any time:
    /// the work is serialized onto `discoveryQueue`, where `udpListener` is also
    /// torn down, and it is a no-op while a listener is already bound.
    private func startUDPListener() {
        discoveryQueue.async { [weak self] in
            self?.bindUDPListener()
        }
    }

    private func bindUDPListener() {
        guard isRunning, udpListener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: parameters, on: port) else {
            // Relaunching while the previous process still owns the port used to
            // kill discovery for the whole session: the Mac kept announcing but
            // never received, so the peer list stayed empty. Retry instead.
            setLastError("UDP discovery port \(Self.port) is unavailable. Retrying…")
            scheduleUDPRebind()
            return
        }

        udpListener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveAnnouncement(connection)
        }
        // Without a state handler a listener that fails after binding (interface
        // torn down, port stolen on wake) dies silently and is never replaced.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // A successful bind clears the "port unavailable" banner left by
                // an earlier attempt so the UI does not show a stale failure.
                self.clearLastError(withPrefix: Self.udpErrorPrefix)
            case .failed(let error):
                self.setLastError("UDP discovery listener failed: \(error.localizedDescription)")
                self.clearUDPListener(listener, cancel: true)
                self.scheduleUDPRebind()
            case .cancelled:
                self.clearUDPListener(listener, cancel: false)
            default:
                break
            }
        }
        listener.start(queue: discoveryQueue)
    }

    /// Drops `listener` only if it is still the live one, so a late callback from
    /// an already-replaced listener cannot cancel its successor.
    private func clearUDPListener(_ listener: NWListener, cancel: Bool) {
        discoveryQueue.async { [weak self] in
            guard let self, self.udpListener === listener else { return }
            if cancel {
                listener.cancel()
            }
            self.udpListener = nil
        }
    }

    private func scheduleUDPRebind() {
        guard isRunning, !udpRebindScheduled else { return }
        udpRebindScheduled = true
        discoveryQueue.asyncAfter(deadline: .now() + Self.udpRebindDelay) { [weak self] in
            guard let self else { return }
            self.udpRebindScheduled = false
            self.bindUDPListener()
        }
    }

    private func receiveAnnouncement(_ connection: NWConnection) {
        connection.start(queue: discoveryQueue)
        connection.receiveMessage { [weak self] data, _, _, error in
            defer { connection.cancel() }
            guard let self, self.isRunning, let data, error == nil,
                  let announcement = try? JSONDecoder().decode(Announcement.self, from: data),
                  let platform = announcement.platform.flatMap(StickyPlatform.init(rawValue:)),
                  !announcement.id.isEmpty else { return }

            let device = StickyDevice(
                id: announcement.id,
                name: announcement.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? announcement.name!
                    : "Unknown device",
                platform: platform,
                // The UDP source is the only trustworthy address. An attacker
                // could otherwise advertise a trusted ID with a chosen host.
                host: Self.remoteHost(from: connection.endpoint) ?? "",
                port: announcement.port ?? Int(Self.port),
                lastSeen: Date()
            )
            DispatchQueue.main.async {
                self.upsertPeer(device)
            }
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            self?.refreshAfterNetworkChange()
        }
        pathMonitor.start(queue: discoveryQueue)
    }

    private func refreshAfterNetworkChange() {
        discoveryQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            // A path change is the best moment to recover a socket that never
            // bound (or died): the interface that blocked it may now be gone.
            self.bindUDPListener()
            DispatchQueue.main.async {
                self.refreshNetworkServices()
            }
            self.announce()
        }
    }

    private func refreshNetworkServices() {
        stopNetworkServices()
        // Re-bind here too: on the wake path this runs even when the socket was
        // never successfully created at launch.
        startUDPListener()
        startAdvertising()
        startBrowsing()
        discoveryQueue.async { [weak self] in
            self?.announce()
        }
    }

    private func startAdvertising() {
        let service = NetService(domain: "", type: Self.serviceType, name: myDevice.name, port: Int32(Self.port))
        let txt: [String: Data] = [
            "id": Data(myDevice.id.utf8),
            "name": Data(myDevice.name.utf8),
            "platform": Data(StickyPlatform.mac.rawValue.utf8),
            "ver": Data("1.0".utf8)
        ]
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.schedule(in: RunLoop.main, forMode: .default)
        service.publish()
        advertiser = service
    }

    private func startBrowsing() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.schedule(in: RunLoop.main, forMode: .default)
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        self.browser = browser
    }

    private func stopNetworkServices() {
        resolvingServices.values.forEach { $0.stop() }
        resolvingServices.removeAll()
        monitoredServices.values.forEach {
            $0.stopMonitoring()
            $0.delegate = nil
            $0.stop()
        }
        monitoredServices.removeAll()
        resolveTimeouts.values.forEach { $0.cancel() }
        resolveTimeouts.removeAll()
        serviceIDs.removeAll()

        advertiser?.delegate = nil
        advertiser?.stop()
        advertiser?.remove(from: .main, forMode: .default)
        advertiser = nil

        browser?.delegate = nil
        browser?.stop()
        browser?.remove(from: .main, forMode: .default)
        browser = nil
    }

    private func resolve(_ service: NetService) {
        guard resolvingServices[service.name] == nil else {
            if let id = serviceIDs[service.name], var device = peer(for: id) {
                device.lastSeen = Date()
                upsertPeer(device)
            }
            return
        }

        // A browsed NetService has no delegate of its own, so without this none
        // of the resolve callbacks below are ever delivered.
        service.delegate = self
        resolvingServices[service.name] = service
        service.resolve(withTimeout: 8)

        let timeout = DispatchWorkItem { [weak self, name = service.name] in
            self?.finishResolution(serviceName: name)
        }
        resolveTimeouts[service.name] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func finishResolution(serviceName: String) {
        finishResolution(serviceName: serviceName, stopService: true)
    }

    /// `stopService: false` leaves a successfully resolved service running:
    /// `stop()` would also cancel the TXT-record monitoring started for it.
    private func finishResolution(serviceName: String, stopService: Bool) {
        if stopService {
            resolvingServices[serviceName]?.stop()
        }
        resolvingServices[serviceName] = nil
        resolveTimeouts[serviceName]?.cancel()
        resolveTimeouts[serviceName] = nil
    }

    /// Keeps a resolved service alive and watching its TXT record. Without this
    /// `didUpdateTXTRecord` never fires, so an mDNS-discovered peer had nothing
    /// refreshing it and disappeared 30s after it was first seen.
    private func monitorTXTRecord(of service: NetService) {
        if let existing = monitoredServices[service.name], existing !== service {
            stopMonitoring(serviceName: service.name)
        }
        service.delegate = self
        monitoredServices[service.name] = service
        service.startMonitoring()
    }

    private func stopMonitoring(serviceName: String) {
        guard let service = monitoredServices.removeValue(forKey: serviceName) else { return }
        service.stopMonitoring()
        service.delegate = nil
        service.stop()
    }

    /// Re-resolves the Bonjour services behind `ids` so their records are renewed
    /// before the expiry cutoff drops them. `didFind` fires once per appearance,
    /// so a peer that never left is otherwise never resolved again — on networks
    /// where mDNS works but directed UDP is filtered that meant the peer vanished
    /// after 30s and only came back on a network change or restart.
    private func reresolveKnownServices(for ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for (name, id) in serviceIDs where ids.contains(id) {
            guard resolvingServices[name] == nil else { continue }
            resolve(NetService(domain: "local.", type: Self.serviceType, name: name))
        }
    }

    private func upsertPeer(_ incoming: StickyDevice) {
        guard !incoming.id.isEmpty, !isSelf(incoming) else { return }
        guard !isSpoofedUpdate(incoming) else { return }

        stateLock.lock()
        peerRecords[incoming.id] = incoming
        stateLock.unlock()
        publishPeers()
    }

    /// Announcements are unauthenticated: any LAN host can claim a paired peer's
    /// ID and move its address, which makes every pinned-TLS send fail with an
    /// opaque error. A live paired record therefore keeps its address; if the
    /// real peer genuinely changed IP its old record simply stops being refreshed
    /// and expires, after which the new address is accepted normally.
    /// Is this announcement really us coming back around?
    ///
    /// The device id alone is not enough. A previous install, a development
    /// build, or a copy run from a different bundle keeps its own id in its own
    /// defaults domain, so it announces as a stranger — and the app then
    /// believes a PC is nearby, sends to itself, and every transfer fails with
    /// an opaque retry. An announcement whose source address is one of our own
    /// is us, whatever id it claims.
    private func isSelf(_ incoming: StickyDevice) -> Bool {
        if incoming.id == myDevice.id { return true }

        if !incoming.host.isEmpty {
            var host = incoming.host.lowercased()
            if let percent = host.firstIndex(of: "%") { host = String(host[host.startIndex..<percent]) }
            if Self.localAddresses().contains(host) { return true }
        }

        // Backstop for a stale identity reaching us over mDNS, where the
        // resolved address may be an interface we don't enumerate. Same machine
        // name and same platform is us. The cost if two genuinely different
        // Macs share a name is that they can't pair with each other; the cost
        // of getting it wrong the other way is every transfer failing silently.
        return incoming.platform == myDevice.platform
            && incoming.name.caseInsensitiveCompare(myDevice.name) == .orderedSame
    }

    private func isSpoofedUpdate(_ incoming: StickyDevice) -> Bool {
        guard let existing = peer(for: incoming.id),
              !existing.host.isEmpty,
              existing.host != incoming.host,
              existing.lastSeen >= Date().addingTimeInterval(-Self.peerTimeout),
              PairingService.shared.isPeerPaired(incoming.id)
        else { return false }

        stateLock.lock()
        let alreadyReported = reportedConflicts[incoming.id] == incoming.host
        reportedConflicts[incoming.id] = incoming.host
        stateLock.unlock()

        if !alreadyReported {
            // Reported once per (device, claimed address) so a hostile announcer
            // repeating every 10s cannot flood the error banner.
            setLastError("Ignored an unverified address change for paired device \(existing.name).")
        }
        return true
    }

    private func peer(for id: String) -> StickyDevice? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return peerRecords[id]
    }

    private func removeExpiredPeers() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.peerTimeout)
        let refreshCutoff = now.addingTimeInterval(-Self.peerRefreshAge)

        stateLock.lock()
        let before = peerRecords.count
        let stale = Set(
            peerRecords.values
                .filter { $0.lastSeen < refreshCutoff && $0.lastSeen >= cutoff }
                .map(\.id)
        )
        peerRecords = peerRecords.filter { $0.value.lastSeen >= cutoff }
        let changed = peerRecords.count != before
        // Forget conflict reports for peers that are gone, so a later genuine
        // address change is surfaced instead of being silently suppressed.
        reportedConflicts = reportedConflicts.filter { peerRecords[$0.key] != nil }
        stateLock.unlock()

        // Give quiet peers a chance to renew themselves over mDNS before the
        // cutoff evicts them.
        reresolveKnownServices(for: stale)

        if changed {
            publishPeers()
        }
    }

    private func publishPeers() {
        stateLock.lock()
        let snapshot = Array(peerRecords.values)
        stateLock.unlock()

        if Thread.isMainThread {
            peers = snapshot.sorted { $0.name < $1.name }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.peers = snapshot.sorted { $0.name < $1.name }
            }
        }
    }

    private func refreshLocalAddress() {
        // Read one consistent snapshot rather than re-reading the guarded
        // property field by field while another queue may be writing it.
        let current = myDevice
        guard let address = Self.localIPv4Address(), address != current.host else { return }
        myDevice = StickyDevice(
            id: current.id,
            name: current.name,
            platform: current.platform,
            host: address,
            port: current.port,
            lastSeen: current.lastSeen
        )
    }

    /// Every IPv4 address this machine currently holds — Wi-Fi, Ethernet, and
    /// the virtual interfaces VMs and containers add.
    static func localAddresses() -> Set<String> {
        var addresses: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return addresses }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = pointer.pointee.ifa_addr else { continue }
            let family = raw.pointee.sa_family
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

            if family == UInt8(AF_INET) {
                var storage = sockaddr_in()
                memcpy(&storage, raw, MemoryLayout<sockaddr_in>.size)
                var addr = storage.sin_addr
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { continue }
            } else if family == UInt8(AF_INET6) {
                var storage = sockaddr_in6()
                memcpy(&storage, raw, MemoryLayout<sockaddr_in6>.size)
                var addr = storage.sin6_addr
                guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { continue }
            } else {
                continue
            }

            // Bonjour hands back scoped addresses like fe80::1%en0; compare on
            // the address alone so the scope suffix can't defeat the match.
            var text = String(cString: buffer)
            if let percent = text.firstIndex(of: "%") { text = String(text[text.startIndex..<percent]) }
            if !text.isEmpty, text != "127.0.0.1", text != "::1" { addresses.insert(text.lowercased()) }
        }
        return addresses
    }

    private func setLastError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = message
        }
    }

    private func clearLastError(withPrefix prefix: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastError?.hasPrefix(prefix) == true else { return }
            self.lastError = nil
        }
    }

    private static func broadcastTargets() -> [String] {
        var targets: [String] = []
        var interfaceAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddress) == 0 else { return targets }
        defer { freeifaddrs(interfaceAddress) }

        var current = interfaceAddress
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let sockaddr = item.pointee.ifa_addr, sockaddr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_BROADCAST == IFF_BROADCAST,
                  let destination = item.pointee.ifa_dstaddr
            else { continue }

            if let address = ipv4String(destination) {
                targets.append(address)
            }
        }

        return targets
    }

    private static func localIPv4Address() -> String? {
        var interfaceAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddress) == 0 else { return nil }
        defer { freeifaddrs(interfaceAddress) }

        var fallback: String?
        var current = interfaceAddress
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let sockaddr = item.pointee.ifa_addr,
                  sockaddr.pointee.sa_family == sa_family_t(AF_INET),
                  let name = item.pointee.ifa_name.flatMap({ String(validatingUTF8: $0) }),
                  !name.hasPrefix("lo")
            else { continue }

            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_RUNNING == IFF_RUNNING,
                  let address = ipv4String(sockaddr)
            else { continue }

            if name.hasPrefix("en") {
                return address
            }
            fallback = fallback ?? address
        }
        return fallback
    }

    private static func ipv4String(_ sockaddr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = withUnsafePointer(to: sockaddr.pointee) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                withUnsafePointer(to: address.pointee.sin_addr) { addressBytes in
                    addressBytes.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<in_addr>.size) { bytes in
                        inet_ntop(AF_INET, bytes, &buffer, socklen_t(INET_ADDRSTRLEN))
                    }
                }
            }
        }
        guard result != nil else { return nil }
        return String(validatingUTF8: buffer)
    }

    private static func remoteHost(from endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        let value = "\(host)"
        return value.split(separator: "%").first.map(String.init)
    }
}

extension DiscoveryService: NetServiceDelegate, NetServiceBrowserDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        lastError = nil
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        lastError = "Bonjour advertising failed: \(sender.name)."
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolve(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        finishResolution(serviceName: service.name)
        stopMonitoring(serviceName: service.name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        lastError = "Bonjour browsing failed."
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        guard let id = Self.deviceID(fromTXT: data), id == serviceIDs[sender.name],
              var device = peer(for: id) else { return }
        device.lastSeen = Date()
        upsertPeer(device)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // Clear the resolve bookkeeping without stopping the service: it is
        // handed to TXT-record monitoring below, and `stop()` would kill that.
        finishResolution(serviceName: sender.name, stopService: false)
        guard let address = Self.ipv4Address(from: sender.addresses) else {
            sender.stop()
            return
        }

        let textRecordID = sender.txtRecordData().flatMap(Self.deviceID(fromTXT:))
        let id = textRecordID ?? Self.stableID(forServiceName: sender.name)
        serviceIDs[sender.name] = id
        monitorTXTRecord(of: sender)

        let device = StickyDevice(
            id: id,
            name: sender.txtRecordData().flatMap(Self.deviceName(fromTXT:)) ?? sender.name,
            platform: sender.txtRecordData().flatMap(Self.devicePlatform(fromTXT:)) ?? .mac,
            host: address,
            port: sender.port > 0 ? sender.port : Int(Self.port)
        )
        upsertPeer(device)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finishResolution(serviceName: sender.name)
    }
}

private extension DiscoveryService {
    static func deviceID(fromTXT data: Data) -> String? {
        stringValue("id", fromTXT: data)
    }

    static func deviceName(fromTXT data: Data) -> String? {
        stringValue("name", fromTXT: data)
    }

    static func devicePlatform(fromTXT data: Data) -> StickyPlatform? {
        stringValue("platform", fromTXT: data).flatMap(StickyPlatform.init(rawValue:))
    }

    static func stringValue(_ key: String, fromTXT data: Data) -> String? {
        guard let properties = try? PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: nil
        ) as? [String: Data], let value = properties[key] else { return nil }
        return String(data: value, encoding: .utf8)
    }

    static func stableID(forServiceName name: String) -> String {
        String(SHA256.hash(data: Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    static func ipv4Address(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for data in addresses {
            let address = data.withUnsafeBytes { buffer -> sockaddr_in? in
                guard buffer.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                return buffer.bindMemory(to: sockaddr_in.self).first
            }
            guard let address, Int32(address.sin_family) == AF_INET else { continue }

            var mutableAddress = address
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let result = withUnsafePointer(to: &mutableAddress.sin_addr) { bytes in
                bytes.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<in_addr>.size) { pointer in
                    inet_ntop(AF_INET, pointer, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
            }
            if result != nil, let value = String(validatingUTF8: buffer) {
                return value
            }
        }
        return nil
    }
}
