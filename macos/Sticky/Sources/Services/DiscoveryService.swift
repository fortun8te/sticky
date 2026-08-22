import CryptoKit
import Darwin
import AppKit
import Foundation
import Network

final class DiscoveryService: NSObject, ObservableObject {
    @Published private(set) var peers: [StickyDevice] = []
    @Published private(set) var lastError: String?

    private(set) var myDevice: StickyDevice

    static let serviceType = "_sticky._tcp."
    static let port: UInt16 = 53317

    private let stateLock = NSLock()
    private var peerRecords: [String: StickyDevice] = [:]
    private var pendingConnections: [NWConnection] = []

    private let discoveryQueue = DispatchQueue(label: "sticky.discovery")
    private var udpListener: NWListener?
    private var pathMonitor = NWPathMonitor()
    private var advertiser: NetService?
    private var browser: NetServiceBrowser?
    private var resolvingServices: [String: NetService] = [:]
    private var serviceIDs: [String: String] = [:]
    private var resolveTimeouts: [String: DispatchWorkItem] = [:]
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

        myDevice = StickyDevice(
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

    private func startUDPListener() {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: parameters, on: port) else {
            setLastError("UDP discovery port \(Self.port) is unavailable.")
            return
        }

        udpListener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveAnnouncement(connection)
        }
        listener.start(queue: discoveryQueue)
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
            DispatchQueue.main.async {
                self.refreshNetworkServices()
            }
            self.announce()
        }
    }

    private func refreshNetworkServices() {
        stopNetworkServices()
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

        resolvingServices[service.name] = service
        service.resolve(withTimeout: 8)

        let timeout = DispatchWorkItem { [weak self, name = service.name] in
            self?.finishResolution(serviceName: name)
        }
        resolveTimeouts[service.name] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func finishResolution(serviceName: String) {
        resolvingServices[serviceName]?.stop()
        resolvingServices[serviceName] = nil
        resolveTimeouts[serviceName]?.cancel()
        resolveTimeouts[serviceName] = nil
    }

    private func upsertPeer(_ incoming: StickyDevice) {
        guard incoming.id != myDevice.id, !incoming.id.isEmpty else { return }

        stateLock.lock()
        peerRecords[incoming.id] = incoming
        stateLock.unlock()
        publishPeers()
    }

    private func peer(for id: String) -> StickyDevice? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return peerRecords[id]
    }

    private func removeExpiredPeers() {
        let cutoff = Date().addingTimeInterval(-30)
        stateLock.lock()
        let before = peerRecords.count
        peerRecords = peerRecords.filter { $0.value.lastSeen >= cutoff }
        let changed = peerRecords.count != before
        stateLock.unlock()

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
        guard let address = Self.localIPv4Address(), address != myDevice.host else { return }
        myDevice = StickyDevice(
            id: myDevice.id,
            name: myDevice.name,
            platform: myDevice.platform,
            host: address,
            port: myDevice.port,
            lastSeen: myDevice.lastSeen
        )
    }

    private func setLastError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = message
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
        defer { finishResolution(serviceName: sender.name) }
        guard let address = Self.ipv4Address(from: sender.addresses) else { return }

        let textRecordID = sender.txtRecordData().flatMap(Self.deviceID(fromTXT:))
        let id = textRecordID ?? Self.stableID(forServiceName: sender.name)
        serviceIDs[sender.name] = id

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
