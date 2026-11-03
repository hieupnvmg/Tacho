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
    /// Busiest first, for the Processes tab and the CPU popover.
    @Published private(set) var processes: [ProcessSample] = []
    /// Apps with their helper processes added up, for the popovers.
    @Published private(set) var appsByCPU: [AppUsage] = []
    @Published private(set) var appsByMemory: [AppUsage] = []
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
    /// Bluetooth accessories that report a battery: mice, keyboards, AirPods.
    @Published private(set) var peripherals: [PeripheralSample] = []

    /// Rolling history for the sparklines, newest last.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var pressureHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var netInHistory: [Double] = []
    @Published private(set) var netOutHistory: [Double] = []

    /// Run after every sample: the menu bar readouts are AppKit views, which
    /// SwiftUI does not refresh on its own, and alerts check their thresholds.
    private var sampleObservers: [() -> Void] = []

    func onEachSample(_ observer: @escaping () -> Void) {
        sampleObservers.append(observer)
    }

    private func notifySample() {
        for observer in sampleObservers { observer() }
    }

    /// The module whose popover is open. The CPU and memory popovers list the
    /// heaviest processes, which are otherwise only fetched for their tab.
    var popoverModule: MenuBarModule? {
        didSet {
            if wantsProcessList && popoverModule != oldValue { fetchProcesses() }
            if popoverModule == .battery && oldValue != .battery { fetchPeripherals() }
        }
    }

    private var wantsProcessList: Bool {
        section == .processes || popoverModule == .cpu || popoverModule == .memory
    }

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
            self.notifySample()
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
            notifySample()
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
        // Processes tab and the CPU and memory popovers show the result.
        let wantsProcesses = wantsProcessList && (tick % 3 == 1 || processes.isEmpty)
        let wantsVolumes = tick % 30 == 1
        // Die temperature and fan speed drift over seconds; each of the ~35
        // SMC keys is a kernel round trip, so they are read every third tick.
        let wantsThermal = tick % 3 == 1
        // Drive hardware never changes unless something is plugged in, and the
        // battery gauge only moves slowly.
        let wantsDrives = tick % 30 == 1
        let wantsBattery = tick % 5 == 1
        // Accessory batteries move by a percent every few minutes; reading them
        // runs system_profiler (~0.1 s).
        let wantsPeripherals = tick % 60 == 1
        let collector = self.collector

        queue.async {
            let cpu = collector.cpu()
            let memory = collector.memory()
            let gpu = collector.gpu()
            let fans = wantsThermal ? collector.fans() : nil
            let temperature = wantsThermal ? collector.temperature() : nil
            let disk = collector.diskIO()
            let network = collector.network()
            let processes = wantsProcesses ? ProcessRanking(collector.processes()) : nil
            let volumes = wantsVolumes ? collector.volumes() : nil
            let drives = wantsDrives ? collector.drives() : nil
            let battery = wantsBattery ? collector.battery() : nil
            let peripherals = wantsPeripherals ? PeripheralReader.read() : nil
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
                if let processes { self.apply(processes) }
                if let volumes { self.volumes = volumes }
                if let drives { self.drives = drives }
                if let battery { self.battery = battery }
                if let peripherals { self.peripherals = peripherals }

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

                self.notifySample()
            }
        }
    }

    /// Straight away, so an opened popover does not wait for the next round.
    private func fetchProcesses() {
        let collector = self.collector
        queue.async {
            let ranking = ProcessRanking(collector.processes())
            Task { @MainActor [weak self] in self?.apply(ranking) }
        }
    }

    private func fetchPeripherals() {
        queue.async {
            let peripherals = PeripheralReader.read()
            Task { @MainActor [weak self] in self?.peripherals = peripherals }
        }
    }

    private func apply(_ ranking: ProcessRanking) {
        processes = ranking.byCPU
        appsByCPU = ranking.appsByCPU
        appsByMemory = ranking.appsByMemory
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
        // What runs on this Mac is nobody else's business: keep the numbers,
        // swap the names for Apple's own apps.
        let names = ["Safari", "Music", "Photos", "Mail", "Notes", "Maps", "Preview",
                     "Calendar", "Messages", "Podcasts", "Books", "FaceTime"]
        processes = processes.enumerated().map { index, process in
            ProcessSample(pid: Int32.max - Int32(index), name: names[index % names.count],
                          cpu: process.cpu, memory: process.memory)
        }
        func anonymise(_ list: [AppUsage], offset: Int) -> [AppUsage] {
            list.enumerated().map { index, app in
                let name = names[(index + offset) % names.count]
                let path = ["/System/Applications", "/Applications", "/System/Volumes/Preboot/Cryptexes/App/System/Applications"]
                    .map { "\($0)/\(name).app" }
                    .first { FileManager.default.fileExists(atPath: $0) }
                return AppUsage(id: name, name: name, bundlePath: path,
                                cpu: app.cpu, memory: app.memory, processCount: app.processCount)
            }
        }
        appsByCPU = anonymise(appsByCPU, offset: 0)
        appsByMemory = anonymise(appsByMemory, offset: 3)
        // Accessory names usually carry the owner's name ("Hiếu's AirPods").
        peripherals = peripherals.map { device in
            let name: String
            switch device.kind {
            case .mouse: name = "Magic Mouse"
            case .keyboard: name = "Magic Keyboard"
            case .trackpad: name = "Magic Trackpad"
            case .airpods: name = "AirPods Pro"
            case .headphones, .other: name = "Headphones"
            }
            return PeripheralSample(name: name, address: "", kind: device.kind, levels: device.levels)
        }
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
