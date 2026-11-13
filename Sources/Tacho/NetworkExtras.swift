import AppKit
import Foundation

// MARK: - Apps using the network

/// One app's share of the network right now.
struct NetworkAppUsage: Identifiable, Equatable {
    /// The app bundle's path, or the process name outside any app.
    let id: String
    let name: String
    let bundlePath: String?
    /// Bytes a second.
    var inRate: Double
    var outRate: Double

    var icon: NSImage? { bundlePath.map { IconCache.icon(forFile: $0) } }
}

/// Which apps are moving data, from `nettop`, the per-process counters macOS
/// ships with. Runs only while the network panel is open: each reading is a
/// short-lived process sampling for a second.
@MainActor
final class NetworkApps: ObservableObject {
    static let shared = NetworkApps()

    @Published private(set) var apps: [NetworkAppUsage] = []
    @Published private(set) var reading = false

    private var timer: Timer?
    private var busy = false
    private var watchers = 0

    func start() {
        watchers += 1
        guard timer == nil else { return }
        read()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        // Tolerance lets macOS fold this wakeup in with others.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        guard !busy else { return }
        busy = true
        if apps.isEmpty { reading = true }
        DispatchQueue.global(qos: .utility).async {
            let apps = Self.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.reading = false
                    if apps != self.apps { self.apps = apps }
                }
            }
        }
    }

    /// For `--network-info`.
    nonisolated static func sampleNow() -> [NetworkAppUsage] { sample() }

    /// Two one-second samples in delta mode; the second holds what moved in
    /// that second. Processes are added up into the app they belong to.
    nonisolated private static func sample() -> [NetworkAppUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-d", "-L", "2", "-s", "1", "-x", "-J", "bytes_in,bytes_out"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let lastHeader = lines.lastIndex(where: { $0.hasPrefix(",bytes_in") }) else { return [] }
        var apps: [String: NetworkAppUsage] = [:]
        for line in lines[(lastHeader + 1)...] {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let inBytes = Double(fields[1]), let outBytes = Double(fields[2]),
                  inBytes + outBytes > 0 else { continue }
            // "Google Chrome He.1234": the name is cut short, the pid is whole.
            let label = String(fields[0])
            guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) else { continue }
            let bundle = ProcessRanking.outermostApp(of: pid)
            let name = bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? String(label[..<dot])
            let key = bundle ?? name
            var app = apps[key] ?? NetworkAppUsage(id: key, name: name, bundlePath: bundle, inRate: 0, outRate: 0)
            app.inRate += inBytes
            app.outRate += outBytes
            apps[key] = app
        }
        return Array(apps.values.sorted { $0.inRate + $0.outRate > $1.inRate + $1.outRate }.prefix(5))
    }
}

// MARK: - Speed test

/// A run of `networkQuality`, macOS's own speed test against Apple's
/// servers: download and upload speed, and how responsive the connection
/// stays under load, which is what makes or breaks a video call.
@MainActor
final class SpeedTest: ObservableObject {
    static let shared = SpeedTest()

    struct Result: Equatable {
        /// Bits a second.
        let download: Double
        let upload: Double
        /// Round trips a minute under load (Apple's RPM).
        let responsiveness: Double?
        let date: Date

        /// Enough for a video call: a few megabits each way and a
        /// connection that stays responsive.
        var goodForCalls: Bool {
            download >= 5_000_000 && upload >= 3_000_000 && (responsiveness ?? 1000) >= 300
        }

        var responsivenessLabel: String {
            guard let rpm = responsiveness else { return "—" }
            switch rpm {
            case ..<300: return L("Thấp")
            case ..<1000: return L("Trung bình")
            default: return L("Cao")
            }
        }
    }

    @Published private(set) var running = false
    @Published private(set) var result: Result?
    @Published private(set) var failed = false

    private var process: Process?
    private var cancelled = false

    func run() {
        guard !running else { return }
        running = true
        failed = false
        cancelled = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        // Machine-readable output, and at most 20 seconds.
        process.arguments = ["-c", "-M", "20"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process
        DispatchQueue.global(qos: .utility).async {
            let launched = (try? process.run()) != nil
            let data = launched ? output.fileHandleForReading.readDataToEndOfFile() : Data()
            if launched { process.waitUntilExit() }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.running = false
                    self.process = nil
                    guard !self.cancelled else { return }
                    guard let object,
                          let down = object["dl_throughput"] as? Double,
                          let up = object["ul_throughput"] as? Double else {
                        self.failed = true
                        return
                    }
                    let rpm = (object["responsiveness"] as? Double) ?? (object["dl_responsiveness"] as? Double)
                    self.result = Result(download: down, upload: up, responsiveness: rpm, date: Date())
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    /// "245 Mbps".
    static func speed(_ bits: Double) -> String {
        bits >= 1_000_000_000 ? String(format: "%.1f Gbps", bits / 1_000_000_000)
            : String(format: "%.0f Mbps", bits / 1_000_000)
    }
}

// MARK: - VPN

enum VPN {
    /// Tunnel interfaces with an IPv4 address: a VPN that is up, whether it
    /// carries all traffic or only the company's (split tunnel). macOS keeps
    /// a few `utun` interfaces of its own, but with IPv6 link-local
    /// addresses only, so they do not count.
    static func activeInterfaces() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var names: Set<String> = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard ["utun", "ipsec", "ppp", "gpd", "tun", "tap"].contains(where: { name.hasPrefix($0) }),
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            names.insert(name)
        }
        return names.sorted()
    }
}
