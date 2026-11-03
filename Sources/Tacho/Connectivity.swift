import Foundation
import Network
import Darwin

enum ConnectivityStatus {
    case pending   // checking, or an interface is up but not yet proven to reach out
    case online
    case offline
}

struct ConnectivitySample {
    var status: ConnectivityStatus = .pending
    var publicIP = ""
    var localIP = ""
    var interfaceName = ""
    var interfaceKind = ""
    var lastChecked: Date?

    /// Traffic leaving through a tunnel means the public IP belongs to the VPN
    /// exit, not the local ISP — worth saying plainly.
    var isTunnelled: Bool {
        ["utun", "ipsec", "ppp", "gpd"].contains { interfaceName.hasPrefix($0) }
    }

    /// `interfaceKind` is stored untranslated (as its Vietnamese key) and
    /// translated here, so switching language relabels it straight away.
    var routeDescription: String {
        let kind = L(interfaceKind)
        guard !interfaceName.isEmpty else { return kind }
        if isTunnelled {
            return kind.isEmpty
                ? "VPN (\(interfaceName))"
                : L("VPN (%@) qua %@", interfaceName, kind)
        }
        return kind.isEmpty ? interfaceName : "\(kind) (\(interfaceName))"
    }
}

/// Two layers: `NWPathMonitor` notices a cable or Wi-Fi dropping instantly, but
/// a usable route is not the same as reaching the internet (captive portals,
/// dead uplinks), so a small HTTP probe confirms it.
///
/// The probe and the public-IP lookup contact an external host —
/// `https://1.1.1.1/cdn-cgi/trace`, Cloudflare's own endpoint. That request is
/// what reveals the public IP; there is no way to learn it without asking
/// someone outside the network.
@MainActor
final class ConnectivityMonitor {

    private(set) var sample = ConnectivitySample()
    var onChange: ((ConnectivitySample) -> Void)?

    /// How often to re-probe while everything looks healthy.
    private let probeInterval: TimeInterval = 60
    private let probeURL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!

    /// A cancelled `NWPathMonitor` cannot be started again, so each `start()`
    /// gets a fresh one.
    private var monitor: NWPathMonitor?
    var isRunning: Bool { monitor != nil }
    private let monitorQueue = DispatchQueue(label: "tacho.connectivity")
    private var timer: Timer?
    private var probing = false
    /// Bumped by `stop()`, so a probe still in flight cannot report back
    /// after the user has switched the check off.
    private var generation = 0

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.pathChanged(path) }
        }
        monitor.start(queue: monitorQueue)
        self.monitor = monitor

        let timer = Timer(timeInterval: probeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        probe()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        timer?.invalidate()
        timer = nil
        generation += 1
        probing = false
        sample = ConnectivitySample()
    }

    /// Called when the popover opens, so a stale reading refreshes on demand.
    func refreshIfStale(after seconds: TimeInterval = 20) {
        guard monitor != nil else { return }
        guard let last = sample.lastChecked else {
            probe()
            return
        }
        if Date().timeIntervalSince(last) > seconds { probe() }
    }

    // MARK: Path

    private func pathChanged(_ path: NWPath) {
        guard monitor != nil else { return }   // an update queued before stop()
        sample.interfaceKind = Self.describe(path)
        if let interface = path.availableInterfaces.first {
            sample.interfaceName = interface.name
        }

        if path.status == .satisfied {
            // A route exists; the probe decides whether it actually reaches out.
            if sample.status != .online { sample.status = .pending }
            publish()
            probe()
        } else {
            sample.status = .offline
            sample.publicIP = ""
            sample.lastChecked = Date()
            publish()
        }
    }

    private static func describe(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if path.usesInterfaceType(.cellular) { return "Di động" }
        if path.usesInterfaceType(.loopback) { return "Loopback" }
        if path.usesInterfaceType(.other) { return "Khác" }
        return ""
    }

    // MARK: Probe

    private func probe() {
        guard monitor != nil, !probing else { return }
        probing = true

        if sample.status != .online { sample.status = .pending }
        sample.localIP = Self.primaryLocalIPv4()
        publish()

        var request = URLRequest(url: probeURL)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpMethod = "GET"

        let generation = self.generation
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ip = data.flatMap { Self.parseIP(from: $0) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.probing = false
                self.sample.lastChecked = Date()
                if code == 200 {
                    self.sample.status = .online
                    if let ip { self.sample.publicIP = ip }
                } else {
                    self.sample.status = .offline
                    self.sample.publicIP = ""
                }
                self.publish()
            }
        }.resume()
    }

    /// The trace endpoint answers with `key=value` lines; `ip=` is ours.
    private static func parseIP(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("ip=") {
            return String(line.dropFirst(3))
        }
        return nil
    }

    private func publish() {
        onChange?(sample)
    }

    // MARK: Local address

    /// IPv4 of the first real interface, skipping loopback and VPN tunnels.
    static func primaryLocalIPv4() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
        defer { freeifaddrs(ifaddr) }

        var result = ""
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let p = pointer {
            defer { pointer = p.pointee.ifa_next }
            let name = String(cString: p.pointee.ifa_name)
            guard !name.hasPrefix("lo"), !name.hasPrefix("utun"), !name.hasPrefix("awdl") else { continue }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(p.pointee.ifa_addr.pointee.sa_len)
            if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
                if name.hasPrefix("en") { return result }
            }
        }
        return result
    }
}
