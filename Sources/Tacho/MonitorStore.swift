import Foundation
import Combine

@MainActor
final class MonitorStore: ObservableObject {

    @Published private(set) var info = SystemInfo()
    @Published private(set) var cpu = CPUSample()
    @Published private(set) var memory = MemorySample()
    @Published private(set) var disk = DiskIOSample()
    @Published private(set) var volumes: [VolumeSample] = []
    @Published private(set) var network = NetworkSample()
    @Published private(set) var processes: [ProcessSample] = []
    @Published private(set) var connectivity = ConnectivitySample()
    @Published private(set) var swapHistory: [Double] = []
    @Published private(set) var gpu = GPUSample()
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var fans: [FanSample] = []
    /// One series per fan, each as a share of that fan's range.
    @Published private(set) var fanHistory: [[Double]] = []
    @Published private(set) var temperature = TemperatureSample()
    @Published private(set) var temperatureHistory: [Double] = []
    @Published private(set) var drives: [DriveSample] = []
    @Published private(set) var battery = BatterySample()

    /// Rolling history for the sparklines, newest last.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var pressureHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var netInHistory: [Double] = []
    @Published private(set) var netOutHistory: [Double] = []

    /// Called after every sample so the menu bar readouts can redraw. They are
    /// AppKit views, which SwiftUI does not refresh on its own.
    var onSample: (() -> Void)?

    @Published var section: MonitorSection? = .overview

    @Published var interval: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(interval, forKey: Self.intervalKey)
            restartTimer()
        }
    }

    private static let intervalKey = "sampling.interval"

    static let historyLength = 90

    let connectivityMonitor = ConnectivityMonitor()
    private let collector = MetricsCollector()
    private let queue = DispatchQueue(label: "tacho.sampling", qos: .utility)
    private var timer: Timer?
    private var tick = 0

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        if [0.5, 1.0, 2.0, 5.0].contains(stored) { interval = stored }

        info = collector.systemInfo()
        _ = collector.cpu()      // prime the tick deltas
        _ = collector.diskIO()
        _ = collector.network()
        // Volumes, drives and the battery arrive with the first sample, off the
        // main thread: the battery reading runs system_profiler, which takes
        // about a second and would otherwise stall launch.

        connectivityMonitor.onChange = { [weak self] sample in
            guard let self else { return }
            self.connectivity = sample
            self.onSample?()
        }
        // Deliberately not started here: the probe is the app's only outbound
        // request, so it waits for the setting to turn it on.
        restartTimer()
    }

    func start() { restartTimer() }

    /// Turning this off stops every outbound request and clears the reading.
    func setConnectivityEnabled(_ enabled: Bool) {
        if enabled {
            connectivityMonitor.start()
        } else {
            connectivityMonitor.stop()
            connectivity = ConnectivitySample(status: .pending)
            onSample?()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        tick += 1
        // Spawning ps is the most expensive part of a sample, and only the
        // Processes tab shows the result.
        let wantsProcesses = section == .processes && (tick % 3 == 1 || processes.isEmpty)
        let wantsVolumes = tick % 30 == 1
        // Die temperature and fan speed drift over seconds; each of the ~35
        // SMC keys is a kernel round trip, so they are read every third tick.
        let wantsThermal = tick % 3 == 1
        // Drive hardware never changes unless something is plugged in, and the
        // battery gauge only moves slowly.
        let wantsDrives = tick % 30 == 1
        let wantsBattery = tick % 5 == 1
        let collector = self.collector

        queue.async {
            let cpu = collector.cpu()
            let memory = collector.memory()
            let gpu = collector.gpu()
            let fans = wantsThermal ? collector.fans() : nil
            let temperature = wantsThermal ? collector.temperature() : nil
            let disk = collector.diskIO()
            let network = collector.network()
            let processes = wantsProcesses ? collector.topProcesses() : nil
            let volumes = wantsVolumes ? collector.volumes() : nil
            let drives = wantsDrives ? collector.drives() : nil
            let battery = wantsBattery ? collector.battery() : nil
            let uptime = ProcessInfo.processInfo.systemUptime

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cpu = cpu
                self.memory = memory
                self.gpu = gpu
                if let fans { self.fans = fans }
                if let temperature { self.temperature = temperature }
                self.disk = disk
                self.network = network
                self.info.uptime = uptime
                if let processes { self.processes = processes }
                if let volumes { self.volumes = volumes }
                if let drives { self.drives = drives }
                if let battery { self.battery = battery }

                Self.append(&self.cpuHistory, cpu.busy)
                Self.append(&self.memoryHistory, memory.usedFraction)
                Self.append(&self.pressureHistory, memory.pressure)
                Self.append(&self.gpuHistory, gpu.utilization)
                if self.fanHistory.count != self.fans.count {
                    self.fanHistory = Array(repeating: [], count: self.fans.count)
                }
                for fan in self.fans {
                    Self.append(&self.fanHistory[fan.id], fan.fraction)
                }
                if self.temperature.isPresent {
                    Self.append(&self.temperatureHistory, self.temperature.cpuAverage)
                }
                Self.append(&self.swapHistory, memory.swapInRate + memory.swapOutRate)
                Self.append(&self.diskReadHistory, disk.readRate)
                Self.append(&self.diskWriteHistory, disk.writeRate)
                Self.append(&self.netInHistory, network.inRate)
                Self.append(&self.netOutHistory, network.outRate)

                self.onSample?()
            }
        }
    }

    /// For images that get published (`--promo`): swaps values that identify
    /// this machine or its network for documentation placeholders.
    func redactForScreenshots() {
        var link = connectivity
        link.status = .online
        link.publicIP = "203.0.113.24"      // RFC 5737 documentation range
        link.localIP = "192.168.1.42"
        link.interfaceName = "en0"
        link.interfaceKind = "Wi-Fi"
        link.lastChecked = Date()
        connectivity = link
        drives = drives.map {
            DriveSample(name: $0.name, vendor: $0.vendor, revision: $0.revision, serial: "",
                        bsdName: $0.bsdName, mediumType: $0.mediumType,
                        interconnect: $0.interconnect, location: $0.location,
                        capacity: $0.capacity, smartCapable: $0.smartCapable)
        }
    }

    private static func append(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > historyLength {
            series.removeFirst(series.count - historyLength)
        }
    }
}
