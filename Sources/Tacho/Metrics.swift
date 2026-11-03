import Foundation
import IOKit
import IOKit.storage
import IOKit.ps
import Darwin

/// `IOBlockStorageDriver` statistics keys. The C constants are not exported to
/// Swift, so the raw registry key names are used directly.
private enum IOStatsKey {
    static let statistics = "Statistics"
    static let bytesRead = "Bytes (Read)"
    static let bytesWritten = "Bytes (Write)"
    static let reads = "Operations (Read)"
    static let writes = "Operations (Write)"
}

// MARK: - Model types

struct CoreSample: Identifiable {
    let id: Int
    let kind: CoreKind
    let user: Double
    let system: Double
    let idle: Double
    var busy: Double { min(max(user + system, 0), 1) }
}

enum CoreKind: String {
    case efficiency = "E"
    case performance = "P"
    case generic = "C"
}

struct CPUSample {
    var user = 0.0
    var system = 0.0
    var idle = 1.0
    var cores: [CoreSample] = []
    var loadAverage: (Double, Double, Double) = (0, 0, 0)
    var busy: Double { min(max(user + system, 0), 1) }
}

struct GPUSample {
    var isPresent = false
    var name = ""
    var coreCount = 0
    var utilization: Double = 0          // 0...1, overall device
    var rendererUtilization: Double = 0
    var tilerUtilization: Double = 0
    var inUseMemory: UInt64 = 0
    var allocatedMemory: UInt64 = 0
}

/// CPU die temperature in °C from the SMC; 0 when no sensor could be read.
struct TemperatureSample {
    var cpuAverage: Double = 0
    var cpuHottest: Double = 0
    var cpuCoolest: Double = 0
    var sensorCount = 0
    var isPresent: Bool { sensorCount > 0 }

    /// The scale the gauges draw on. Apple silicon idles in the 30s–40s and
    /// throttles past roughly 100 °C.
    static let scale: ClosedRange<Double> = 20...110

    static func fraction(_ celsius: Double) -> Double {
        min(max((celsius - scale.lowerBound) / (scale.upperBound - scale.lowerBound), 0), 1)
    }

    /// Plain-language reading of a die temperature.
    static func label(_ celsius: Double) -> String {
        switch celsius {
        case ..<70: return L("Mát")
        case ..<90: return L("Ấm")
        default: return L("Nóng")
        }
    }
}

/// One fan, in RPM, as the SMC reports it.
struct FanSample: Identifiable {
    let id: Int
    let current: Double
    let minimum: Double
    let maximum: Double

    /// Share of the fan's own range, so a fan idling at its floor reads 0.
    var fraction: Double {
        guard maximum > minimum else { return 0 }
        return min(max((current - minimum) / (maximum - minimum), 0), 1)
    }

    /// Plain-language reading of how hard the fan is working.
    var label: String {
        switch fraction {
        case ..<0.25: return L("Êm")
        case ..<0.6: return L("Vừa")
        default: return L("Mạnh")
        }
    }
}

struct MemorySample {
    var total: UInt64 = 0
    var wired: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var appMemory: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// Cumulative page moves, and the per-second rate between two samples.
    /// Sustained non-zero rates mean the machine is actively swapping, which
    /// matters far more than how much swap has merely been allocated.
    var swapIns: UInt64 = 0
    var swapOuts: UInt64 = 0
    var swapInRate: Double = 0
    var swapOutRate: Double = 0

    var swapFraction: Double {
        swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0
    }

    var isSwapping: Bool { swapInRate > 1 || swapOutRate > 1 }

    /// Real memory pressure from the kernel, not the share of RAM in use. These
    /// are different numbers: a machine can sit at 75% used with low pressure.
    var pressure: Double = 0
    var pressureLevel: MemoryPressureLevel = .normal

    /// Apple-style "memory used" = app + wired + compressed
    var used: UInt64 { appMemory &+ wired &+ compressed }

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}

/// `kern.memorystatus_vm_pressure_level`, the same signal that drives Activity
/// Monitor's green / yellow / red pressure graph.
enum MemoryPressureLevel: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return L("Bình thường")
        case .warning: return L("Cảnh báo")
        case .critical: return L("Nghiêm trọng")
        }
    }
}

struct DiskIOSample {
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
    var readOps: UInt64 = 0
    var writeOps: UInt64 = 0
    var readRate: Double = 0      // bytes/sec
    var writeRate: Double = 0     // bytes/sec
    var readIOPS: Double = 0
    var writeIOPS: Double = 0
}

struct VolumeSample: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    let free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// A physical storage device as reported by `IOBlockStorageDevice`.
struct DriveSample: Identifiable {
    var id: String { bsdName.isEmpty ? name + serial : bsdName }
    let name: String
    let vendor: String
    let revision: String
    let serial: String
    let bsdName: String
    let mediumType: String
    let interconnect: String
    let location: String
    let capacity: UInt64
    let smartCapable: Bool

    var isInternal: Bool { location.localizedCaseInsensitiveContains("internal") }

    /// Short badges describing the device, skipping anything the registry left blank.
    var tags: [String] {
        var result: [String] = []
        if !mediumType.isEmpty { result.append(mediumType) }
        if !interconnect.isEmpty { result.append(interconnect) }
        if !location.isEmpty { result.append(location) }
        if !vendor.isEmpty { result.append(vendor) }
        if smartCapable { result.append("SMART") }
        return result
    }
}

struct BatterySample {
    var isPresent = false
    var percentage: Double = 0        // 0...1
    var isCharging = false
    var isPluggedIn = false
    var fullyCharged = false
    var cycleCount = 0
    var designCapacity = 0            // mAh
    var maxCapacity = 0               // mAh, current full-charge capacity
    var currentCapacity = 0           // mAh
    var condition = ""                // "Normal", "Service Recommended", …
    var temperature: Double = 0       // °C, 0 when the machine does not report it
    var voltage: Double = 0           // V
    var amperage: Double = 0          // A, negative while discharging
    var timeRemaining: Int = 0        // minutes, 0 when still being estimated
    var designCycleCount = 0          // cycles the battery is rated for
    var adapterName = ""
    var adapterWatts = 0
    /// What System Settings shows as "Maximum Capacity". 0 when unknown.
    var maximumCapacityPercent = 0

    /// Prefers Apple's own figure; the raw capacity ratio is only a fallback,
    /// because macOS does not derive the displayed percentage from it directly.
    var health: Double {
        if maximumCapacityPercent > 0 { return Double(maximumCapacityPercent) / 100 }
        return designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) : 0
    }

    /// Power on the battery terminals: into it when charging, out of it when not.
    var watts: Double { abs(voltage * amperage) }

    /// Total pulled from the adapter — system load plus whatever goes into the
    /// battery. From `PowerTelemetryData.SystemPowerIn`.
    var adapterPowerW: Double = 0
    /// Going into the battery right now; 0 when not charging.
    var chargingPowerW: Double = 0
    /// What the machine itself is consuming, charging excluded. From
    /// `PowerTelemetryData.SystemLoad` when published.
    var systemPowerW: Double = 0

    var powerState: BatteryPowerState {
        if isCharging { return .charging }
        return isPluggedIn ? .pluggedNotCharging : .onBattery
    }
}

enum BatteryPowerState {
    case charging
    case pluggedNotCharging
    case onBattery
}

struct NetworkSample {
    var inBytes: UInt64 = 0
    var outBytes: UInt64 = 0
    var inRate: Double = 0
    var outRate: Double = 0
}

struct ProcessSample: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let cpu: Double      // percent (can exceed 100)
    let memory: UInt64   // resident bytes
}

/// One app's share of the machine: every process inside its bundle (helpers,
/// renderers, XPC services) added up, or a lone process outside any app.
struct AppUsage: Identifiable {
    /// The app bundle's path, or the process name for one outside any app.
    let id: String
    let name: String
    let bundlePath: String?
    var cpu: Double
    var memory: UInt64
    var processCount: Int
}

/// The views of the process table the interface shows.
struct ProcessRanking {
    /// Busiest single processes, for the Processes tab.
    let byCPU: [ProcessSample]
    /// Busiest and largest apps, for the popovers.
    let appsByCPU: [AppUsage]
    let appsByMemory: [AppUsage]

    init(_ all: [ProcessSample]) {
        byCPU = Array(all.prefix(12))
        var apps: [String: AppUsage] = [:]
        for process in all {
            let bundle = Self.outermostApp(of: process.pid)
            let key = bundle ?? process.name
            if apps[key] == nil {
                let name = bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                apps[key] = AppUsage(id: key, name: name ?? process.name, bundlePath: bundle,
                                     cpu: 0, memory: 0, processCount: 0)
            }
            apps[key]?.cpu += process.cpu
            apps[key]?.memory += process.memory
            apps[key]?.processCount += 1
        }
        appsByCPU = Array(apps.values.sorted { $0.cpu > $1.cpu }.prefix(5))
        appsByMemory = Array(apps.values.sorted { $0.memory > $1.memory }.prefix(5))
    }

    /// Chrome's renderers live at …/Google Chrome.app/Contents/Frameworks/…/
    /// Google Chrome Helper (Renderer).app; the outermost bundle is the app
    /// the user knows.
    private static func outermostApp(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

struct SystemInfo {
    var model = ""
    var chip = ""
    var osVersion = ""
    var physicalCores = 0
    var logicalCores = 0
    var performanceCores = 0
    var efficiencyCores = 0
    var memoryBytes: UInt64 = 0
    var uptime: TimeInterval = 0
}

// MARK: - sysctl helpers

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}

private func sysctlInt(_ name: String) -> Int {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
    return Int(value)
}

// MARK: - Collector

final class MetricsCollector {

    /// Cumulative counters of one disk or network interface. Rates are summed
    /// from per-device deltas, so a device appearing or disappearing between two
    /// samples cannot make the total jump backwards (and wrap to a huge rate).
    private struct Counters {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var readOps: UInt64 = 0
        var writeOps: UInt64 = 0
    }

    private var previousCPUTicks: [[UInt32]] = []
    private var previousTotalTicks: [UInt32] = []
    private var previousDisk: (devices: [UInt64: Counters], time: Date)?
    private var previousNet: (interfaces: [UInt16: Counters], time: Date)?
    private var networkTotals = Counters()
    private var cachedBatteryHealth: (condition: String, maximumCapacity: Int, time: Date)?
    private var previousSwap: (ins: UInt64, outs: UInt64, time: Date)?
    /// GPU name and core count never change, and reading every registry
    /// property of the accelerator each tick is the costliest part of a sample.
    private var gpuIdentity: (name: String, coreCount: Int)?
    private lazy var smc = SMC()
    /// Fan count and limits are fixed; only the current speed is re-read.
    private var fanLimits: [(minimum: Double, maximum: Double)]?
    /// CPU sensor keys, found once by walking the SMC key table.
    private var cpuTemperatureKeys: [String]?

    private let coreKinds: [CoreKind]

    init() {
        // On Apple silicon perflevel0 is the performance cluster, perflevel1 the efficiency one,
        // while host_processor_info() enumerates the efficiency cores first.
        let performance = sysctlInt("hw.perflevel0.logicalcpu")
        let efficiency = sysctlInt("hw.perflevel1.logicalcpu")
        let logical = sysctlInt("hw.logicalcpu")
        if performance > 0, efficiency > 0, performance + efficiency == logical {
            coreKinds = Array(repeating: .efficiency, count: efficiency)
                + Array(repeating: .performance, count: performance)
        } else {
            coreKinds = Array(repeating: .generic, count: max(logical, 1))
        }
    }

    // MARK: Static info

    func systemInfo() -> SystemInfo {
        var info = SystemInfo()
        info.model = sysctlString("hw.model")
        info.chip = sysctlString("machdep.cpu.brand_string")
        let v = ProcessInfo.processInfo.operatingSystemVersion
        info.osVersion = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        info.physicalCores = sysctlInt("hw.physicalcpu")
        info.logicalCores = sysctlInt("hw.logicalcpu")
        info.performanceCores = coreKinds.filter { $0 == .performance }.count
        info.efficiencyCores = coreKinds.filter { $0 == .efficiency }.count
        info.memoryBytes = UInt64(sysctlInt("hw.memsize"))
        info.uptime = ProcessInfo.processInfo.systemUptime
        return info
    }

    // MARK: CPU

    func cpu() -> CPUSample {
        var sample = CPUSample()

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        sample.loadAverage = (loads[0], loads[1], loads[2])

        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount,
                                         &cpuInfo,
                                         &infoCount)
        guard result == KERN_SUCCESS, let cpuInfo else { return sample }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: cpuInfo),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))

        var totals = [UInt32](repeating: 0, count: states)
        var cores: [CoreSample] = []

        for i in 0..<Int(cpuCount) {
            var ticks = [UInt32](repeating: 0, count: states)
            for s in 0..<states {
                let t = UInt32(bitPattern: cpuInfo[i * states + s])
                ticks[s] = t
                totals[s] = totals[s] &+ t
            }
            current.append(ticks)

            let previous = i < previousCPUTicks.count ? previousCPUTicks[i] : [UInt32](repeating: 0, count: states)
            let delta = (0..<states).map { Double(ticks[$0] &- previous[$0]) }
            let sum = delta.reduce(0, +)
            let kind = i < coreKinds.count ? coreKinds[i] : .generic
            if sum > 0 {
                cores.append(CoreSample(id: i,
                                        kind: kind,
                                        user: (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / sum,
                                        system: delta[Int(CPU_STATE_SYSTEM)] / sum,
                                        idle: delta[Int(CPU_STATE_IDLE)] / sum))
            } else {
                cores.append(CoreSample(id: i, kind: kind, user: 0, system: 0, idle: 1))
            }
        }

        if !previousTotalTicks.isEmpty {
            let delta = (0..<states).map { Double(totals[$0] &- previousTotalTicks[$0]) }
            let sum = delta.reduce(0, +)
            if sum > 0 {
                sample.user = (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / sum
                sample.system = delta[Int(CPU_STATE_SYSTEM)] / sum
                sample.idle = delta[Int(CPU_STATE_IDLE)] / sum
            }
        }

        previousCPUTicks = current
        previousTotalTicks = totals
        sample.cores = cores
        return sample
    }

    // MARK: Memory

    func memory() -> MemorySample {
        var sample = MemorySample()
        sample.total = UInt64(sysctlInt("hw.memsize"))

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return sample }

        let page = UInt64(vm_kernel_page_size)
        sample.free = UInt64(stats.free_count) * page
        sample.active = UInt64(stats.active_count) * page
        sample.inactive = UInt64(stats.inactive_count) * page
        sample.wired = UInt64(stats.wire_count) * page
        sample.compressed = UInt64(stats.compressor_page_count) * page
        sample.cached = UInt64(stats.external_page_count) * page
        let internalPages = UInt64(stats.internal_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        sample.appMemory = internalPages > purgeable ? internalPages - purgeable : internalPages

        // kern.memorystatus_level is the system-wide free percentage — the same
        // number /usr/bin/memory_pressure prints — so pressure is its complement.
        let freePercent = sysctlInt("kern.memorystatus_level")
        if freePercent > 0 {
            sample.pressure = min(max(Double(100 - freePercent) / 100, 0), 1)
        }
        sample.pressureLevel = MemoryPressureLevel(
            rawValue: sysctlInt("kern.memorystatus_vm_pressure_level")) ?? .normal

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            sample.swapUsed = swap.xsu_used
            sample.swapTotal = swap.xsu_total
        }

        sample.swapIns = stats.swapins
        sample.swapOuts = stats.swapouts
        let now = Date()
        if let previous = previousSwap {
            let elapsed = now.timeIntervalSince(previous.time)
            if elapsed > 0 {
                sample.swapInRate = Double(stats.swapins &- previous.ins) / elapsed
                sample.swapOutRate = Double(stats.swapouts &- previous.outs) / elapsed
            }
        }
        previousSwap = (stats.swapins, stats.swapouts, now)
        return sample
    }

    // MARK: Disk I/O

    /// Sum of `current - previous` over the devices present in both samples.
    /// A counter that went backwards (device reset) contributes nothing.
    private static func delta<Key>(_ current: [Key: Counters],
                                   _ previous: [Key: Counters],
                                   _ field: KeyPath<Counters, UInt64>) -> UInt64 {
        current.reduce(0) { sum, entry in
            guard let old = previous[entry.key]?[keyPath: field],
                  entry.value[keyPath: field] >= old else { return sum }
            return sum &+ (entry.value[keyPath: field] - old)
        }
    }

    private static func total<Key>(_ devices: [Key: Counters],
                                   _ field: KeyPath<Counters, UInt64>) -> UInt64 {
        devices.values.reduce(0) { $0 &+ $1[keyPath: field] }
    }

    /// Statistics of every `IOBlockStorageDriver`, keyed by registry entry ID.
    private func rawDiskCounters() -> [UInt64: Counters] {
        var devices: [UInt64: Counters] = [:]
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return devices }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return devices
        }
        defer { IOObjectRelease(iterator) }

        var drive = IOIteratorNext(iterator)
        while drive != 0 {
            defer {
                IOObjectRelease(drive)
                drive = IOIteratorNext(iterator)
            }
            guard let cf = IORegistryEntryCreateCFProperty(drive,
                                                           IOStatsKey.statistics as CFString,
                                                           kCFAllocatorDefault,
                                                           0)?.takeRetainedValue(),
                  let stats = cf as? [String: Any] else { continue }

            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(drive, &id) == KERN_SUCCESS else { continue }
            devices[id] = Counters(
                read: (stats[IOStatsKey.bytesRead] as? NSNumber)?.uint64Value ?? 0,
                write: (stats[IOStatsKey.bytesWritten] as? NSNumber)?.uint64Value ?? 0,
                readOps: (stats[IOStatsKey.reads] as? NSNumber)?.uint64Value ?? 0,
                writeOps: (stats[IOStatsKey.writes] as? NSNumber)?.uint64Value ?? 0)
        }
        return devices
    }

    func diskIO() -> DiskIOSample {
        let now = Date()
        let devices = rawDiskCounters()
        var sample = DiskIOSample()
        sample.readBytes = Self.total(devices, \.read)
        sample.writeBytes = Self.total(devices, \.write)
        sample.readOps = Self.total(devices, \.readOps)
        sample.writeOps = Self.total(devices, \.writeOps)

        if let prev = previousDisk {
            let dt = now.timeIntervalSince(prev.time)
            if dt > 0 {
                sample.readRate = Double(Self.delta(devices, prev.devices, \.read)) / dt
                sample.writeRate = Double(Self.delta(devices, prev.devices, \.write)) / dt
                sample.readIOPS = Double(Self.delta(devices, prev.devices, \.readOps)) / dt
                sample.writeIOPS = Double(Self.delta(devices, prev.devices, \.writeOps)) / dt
            }
        }
        previousDisk = (devices, now)
        return sample
    }

    func volumes() -> [VolumeSample] {
        let keys: [URLResourceKey] = [.volumeNameKey,
                                      .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsBrowsableKey,
                                      .volumeIsReadOnlyKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  // Skip the read-only disk images apps mount for themselves.
                  values.volumeIsReadOnly != true,
                  let total = values.volumeTotalCapacity, total > 1_000_000_000 else { return nil }
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            return VolumeSample(name: values.volumeName ?? url.lastPathComponent,
                                path: url.path,
                                total: UInt64(total),
                                free: UInt64(max(free, 0)))
        }
        .sorted { $0.total > $1.total }
    }

    // MARK: Storage hardware

    /// Every property of an IORegistry entry as a Swift dictionary.
    private func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    /// Capacity of the whole-disk `IOMedia` underneath a device. The media is a
    /// grandchild — `IOBlockStorageDevice` → `IOBlockStorageDriver` → `IOMedia` —
    /// so the children are walked recursively.
    private func wholeMediaSize(of entry: io_registry_entry_t,
                                depth: Int = 3) -> (size: UInt64, bsdName: String) {
        guard depth > 0 else { return (0, "") }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, "IOService", &children) == KERN_SUCCESS else {
            return (0, "")
        }
        defer { IOObjectRelease(children) }

        var child = IOIteratorNext(children)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(children)
            }
            let props = properties(of: child)
            if (props["Whole"] as? Bool) == true,
               let size = (props["Size"] as? NSNumber)?.uint64Value, size > 0 {
                return (size, props["BSD Name"] as? String ?? "")
            }
            let nested = wholeMediaSize(of: child, depth: depth - 1)
            if nested.size > 0 { return nested }
        }
        return (0, "")
    }

    /// SATA drives advertise "SMART Capable"; NVMe ones instead expose the
    /// NVMeSMARTLib plug-in.
    private func isSMARTCapable(_ props: [String: Any]) -> Bool {
        if (props["SMART Capable"] as? Bool) == true { return true }
        if (props["NVMe SMART Capable"] as? Bool) == true { return true }
        if let plugins = props["IOCFPlugInTypes"] as? [String: Any] {
            return plugins.values.contains {
                ($0 as? String)?.localizedCaseInsensitiveContains("SMART") == true
            }
        }
        return false
    }

    func drives() -> [DriveSample] {
        var result: [DriveSample] = []
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOBlockStorageDevice") else { return [] }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var device = IOIteratorNext(iterator)
        while device != 0 {
            defer {
                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
            }
            let props = properties(of: device)
            let characteristics = props["Device Characteristics"] as? [String: Any] ?? [:]
            let protocolInfo = props["Protocol Characteristics"] as? [String: Any] ?? [:]
            let interconnect = protocolInfo["Physical Interconnect"] as? String ?? ""

            // Disk images and other synthetic devices are not hardware.
            if interconnect.localizedCaseInsensitiveContains("virtual") { continue }
            let media = wholeMediaSize(of: device)
            guard media.size > 0 else { continue }

            result.append(DriveSample(
                name: characteristics["Product Name"] as? String ?? "Unknown",
                vendor: characteristics["Vendor Name"] as? String ?? "",
                revision: characteristics["Product Revision Level"] as? String ?? "",
                serial: characteristics["Serial Number"] as? String ?? "",
                bsdName: media.bsdName,
                mediumType: characteristics["Medium Type"] as? String ?? "",
                interconnect: interconnect,
                location: protocolInfo["Physical Interconnect Location"] as? String ?? "",
                capacity: media.size,
                smartCapable: isSMARTCapable(props)
            ))
        }
        return result.sorted { $0.capacity > $1.capacity }
    }

    // MARK: GPU

    func gpu() -> GPUSample {
        var sample = GPUSample()
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator") else { return sample }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return sample
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let stats = IORegistryEntryCreateCFProperty(service,
                                                              "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault,
                                                              0)?.takeRetainedValue() as? [String: Any]
            else { continue }

            func percent(_ key: String) -> Double {
                let raw = (stats[key] as? NSNumber)?.doubleValue ?? 0
                return min(max(raw / 100, 0), 1)
            }

            sample.isPresent = true
            sample.utilization = percent("Device Utilization %")
            sample.rendererUtilization = percent("Renderer Utilization %")
            sample.tilerUtilization = percent("Tiler Utilization %")
            sample.inUseMemory = (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            sample.allocatedMemory = (stats["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0

            if gpuIdentity == nil {
                let props = properties(of: service)
                var name = ""
                // "model" comes back as a NUL-terminated C string in a data blob.
                if let data = props["model"] as? Data {
                    name = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
                } else if let text = props["model"] as? String {
                    name = text
                }
                gpuIdentity = (name, (props["gpu-core-count"] as? NSNumber)?.intValue ?? 0)
            }
            sample.name = gpuIdentity?.name ?? ""
            sample.coreCount = gpuIdentity?.coreCount ?? 0
            break
        }
        return sample
    }

    // MARK: Fans

    /// Empty on fanless Macs (MacBook Air) or when the SMC cannot be opened.
    func fans() -> [FanSample] {
        guard let smc else { return [] }
        if fanLimits == nil {
            let count = Int(smc.number("FNum") ?? 0)
            fanLimits = (0..<count).map { index in
                (smc.number("F\(index)Mn") ?? 0, smc.number("F\(index)Mx") ?? 0)
            }
        }
        return (fanLimits ?? []).enumerated().map { index, limits in
            FanSample(id: index,
                      current: smc.number("F\(index)Ac") ?? 0,
                      minimum: limits.minimum,
                      maximum: limits.maximum)
        }
    }

    // MARK: Temperature

    /// Apple silicon names its CPU die sensors `Tp…` (performance cores),
    /// `Te…` (efficiency cores) and, from M3 on, `Tf…`. The exact keys differ
    /// per chip, so they are discovered rather than hard-coded. Intel Macs
    /// use `TC0P`-style keys and are not covered.
    func temperature() -> TemperatureSample {
        guard let smc else { return TemperatureSample() }
        if cpuTemperatureKeys == nil {
            cpuTemperatureKeys = smc.keys(withPrefixes: ["Tp", "Te", "Tf"])
        }
        // Unused sensor slots read 0; anything outside this range is noise.
        let readings = (cpuTemperatureKeys ?? [])
            .compactMap { smc.number($0) }
            .filter { $0 > 1 && $0 < 130 }
        guard !readings.isEmpty else { return TemperatureSample() }
        return TemperatureSample(cpuAverage: readings.reduce(0, +) / Double(readings.count),
                                 cpuHottest: readings.max() ?? 0,
                                 cpuCoolest: readings.min() ?? 0,
                                 sensorCount: readings.count)
    }

    // MARK: Battery

    /// Condition and "Maximum Capacity" exactly as System Settings reports them.
    /// macOS does not compute the percentage from the registry's mAh values, so
    /// asking system_profiler is the only way to match what the user sees. It
    /// takes about a second, hence the cache.
    private func batteryHealthInfo() -> (condition: String, maximumCapacity: Int) {
        // Maximum capacity moves over weeks; system_profiler costs about a second.
        if let cached = cachedBatteryHealth, Date().timeIntervalSince(cached.time) < 30 * 60 {
            return (cached.condition, cached.maximumCapacity)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPPowerDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        var result = (condition: "", maximumCapacity: 0)
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entries = root["SPPowerDataType"] as? [[String: Any]] {
                for entry in entries {
                    guard let health = entry["sppower_battery_health_info"] as? [String: Any] else { continue }
                    result.condition = health["sppower_battery_health"] as? String ?? ""
                    if let text = health["sppower_battery_health_maximum_capacity"] as? String {
                        result.maximumCapacity = Int(text.replacingOccurrences(of: "%", with: "")) ?? 0
                    }
                    break
                }
            }
        } catch {
            return result
        }

        cachedBatteryHealth = (result.condition, result.maximumCapacity, Date())
        return result
    }

    /// Battery condition reported by IOPowerSources, when it exposes one.
    private func batteryCondition() -> String {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else {
            return ""
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let health = description["BatteryHealth"] as? String, !health.isEmpty {
                return health
            }
        }
        return ""
    }

    func battery() -> BatterySample {
        var sample = BatterySample()
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return sample }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return sample }
        defer { IOObjectRelease(service) }

        let props = properties(of: service)
        guard !props.isEmpty else { return sample }
        func int(_ key: String) -> Int { (props[key] as? NSNumber)?.intValue ?? 0 }

        sample.isPresent = (props["BatteryInstalled"] as? Bool) ?? true
        guard sample.isPresent else { return sample }

        // On Apple silicon CurrentCapacity is already a percentage and MaxCapacity
        // is 100; on Intel both are mAh. The ratio is correct either way.
        let current = int("CurrentCapacity")
        let maximum = int("MaxCapacity")
        sample.percentage = maximum > 0 ? min(Double(current) / Double(maximum), 1) : 0

        sample.isCharging = (props["IsCharging"] as? Bool) ?? false
        sample.isPluggedIn = (props["ExternalConnected"] as? Bool) ?? false
        sample.cycleCount = int("CycleCount")
        sample.designCycleCount = int("DesignCycleCount9C")

        // The mAh figures live in a nested dictionary; the top-level keys are
        // percentages on Apple silicon.
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func dataInt(_ key: String) -> Int { (data[key] as? NSNumber)?.intValue ?? 0 }

        sample.fullyCharged = (props["FullyCharged"] as? Bool)
            ?? (dataInt("FullyCharged") == 1)
        sample.designCapacity = dataInt("DesignCapacity")
        // System Settings bases "Maximum Capacity" on the nominal figure.
        sample.maxCapacity = dataInt("NominalChargeCapacity") > 0
            ? dataInt("NominalChargeCapacity")
            : dataInt("FullChargeCapacity")
        sample.currentCapacity = dataInt("RemainingCapacity")

        // Milliwatts, measured by the power controller itself. Apple silicon
        // publishes these; older Macs leave the dictionary out.
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        func milliwatts(_ key: String) -> Double {
            Double((telemetry[key] as? NSNumber)?.intValue ?? 0) / 1000
        }
        sample.adapterPowerW = milliwatts("SystemPowerIn")
        let measuredLoad = milliwatts("SystemLoad")
        let measuredBattery = milliwatts("BatteryPower")

        if let adapter = props["AdapterDetails"] as? [String: Any] {
            sample.adapterName = adapter["Name"] as? String ?? ""
            sample.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue ?? 0
        }

        // Not every Mac publishes a battery temperature.
        sample.temperature = Double(int("Temperature")) / 100
        sample.voltage = Double(int("Voltage")) / 1000
        sample.amperage = Double((props["Amperage"] as? NSNumber)?.int64Value ?? 0) / 1000

        // A positive battery current means energy flowing in. Prefer the
        // controller's own figures; voltage × current is the fallback.
        if sample.amperage > 0 {
            sample.chargingPowerW = measuredBattery > 0 ? measuredBattery : sample.watts
        }

        if measuredLoad > 0 {
            sample.systemPowerW = measuredLoad
        } else if sample.isPluggedIn, sample.adapterPowerW > 0 {
            // SystemPowerIn covers the whole machine including charging, so the
            // machine's own draw is what is left after the battery's share.
            sample.systemPowerW = max(sample.adapterPowerW - sample.chargingPowerW, 0)
        } else {
            // On battery the draw is simply what leaves the cells.
            sample.systemPowerW = sample.amperage < 0 ? sample.watts : 0
        }

        // 65535 is the "still computing" sentinel the SMC reports.
        let remaining = int("TimeRemaining")
        sample.timeRemaining = (remaining > 0 && remaining < 65535) ? remaining : 0

        // Report what macOS itself says rather than inferring a verdict from the
        // capacity ratio, which does not reproduce Apple's figure.
        let official = batteryHealthInfo()
        sample.maximumCapacityPercent = official.maximumCapacity
        sample.condition = official.condition.isEmpty ? batteryCondition() : official.condition
        return sample
    }

    // MARK: Network

    /// Byte counters of every non-loopback interface, keyed by interface index.
    /// Read from `if_data64` via `NET_RT_IFLIST2`, but for a process without
    /// Apple's private networking entitlement the kernel still truncates them to
    /// 32 bits (`netstat` sees the real totals, this app does not), so callers
    /// must treat them as wrapping every 4 GiB.
    private func rawInterfaceCounters() -> [UInt16: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var interfaces: [UInt16: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if info.ifm_flags & IFF_LOOPBACK != 0 { continue }
                interfaces[info.ifm_index] = Counters(read: info.ifm_data.ifi_ibytes,
                                                      write: info.ifm_data.ifi_obytes)
            }
        }
        return interfaces
    }

    /// Like `delta`, for counters that wrap at 2^32. A drop of less than half
    /// the range is a counter reset (interface recreated), not a wrap, and
    /// counts as nothing.
    private static func wrappingDelta(_ current: [UInt16: Counters],
                                      _ previous: [UInt16: Counters],
                                      _ field: KeyPath<Counters, UInt64>) -> UInt64 {
        current.reduce(0) { sum, entry in
            guard let old = previous[entry.key]?[keyPath: field] else { return sum }
            let new = UInt32(truncatingIfNeeded: entry.value[keyPath: field])
            let before = UInt32(truncatingIfNeeded: old)
            if new < before && before - new < UInt32.max / 2 { return sum }
            return sum &+ UInt64(new &- before)
        }
    }

    func network() -> NetworkSample {
        var sample = NetworkSample()
        let interfaces = rawInterfaceCounters()

        let now = Date()
        if let prev = previousNet {
            let received = Self.wrappingDelta(interfaces, prev.interfaces, \.read)
            let sent = Self.wrappingDelta(interfaces, prev.interfaces, \.write)
            networkTotals.read &+= received
            networkTotals.write &+= sent
            let dt = now.timeIntervalSince(prev.time)
            if dt > 0 {
                sample.inRate = Double(received) / dt
                sample.outRate = Double(sent) / dt
            }
        }
        // The kernel's own totals are truncated (see rawInterfaceCounters), so
        // the totals shown are what this app has counted since it started.
        sample.inBytes = networkTotals.read
        sample.outBytes = networkTotals.write
        previousNet = (interfaces, now)
        return sample
    }

    // MARK: Processes

    /// Every process, busiest first.
    func processes() -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid,pcpu,rss,comm", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var result: [ProcessSample] = []
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rss = UInt64(parts[2]) else { continue }
            result.append(ProcessSample(pid: pid,
                                        name: String(parts[3]).trimmingCharacters(in: .whitespaces),
                                        cpu: cpu,
                                        memory: rss * 1024))
        }
        return result
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(value, 0)
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return String(format: v >= 100 || i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    /// Menu bar width is precious: "1.2M" rather than "1.2 MB/s".
    static func compact(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = max(bytesPerSecond, 0)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return String(format: "%.0f%@", value, units[index]) }
        return String(format: value >= 10 ? "%.0f%@" : "%.1f%@", value, units[index])
    }

    static func celsius(_ value: Double) -> String {
        String(format: "%.0f °C", value)
    }

    static func rpm(_ value: Double) -> String {
        String(format: "%.0f rpm", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    static func minutes(_ value: Int) -> String {
        guard value > 0 else { return "—" }
        return value >= 60 ? "\(value / 60)h \(value % 60)m" : "\(value)m"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
