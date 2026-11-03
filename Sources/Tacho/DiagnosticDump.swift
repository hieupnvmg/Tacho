import Foundation

/// Prints one sample of every metric to stdout and exits. Useful for checking the
/// collectors without opening the window: `Tacho --dump`.
enum DiagnosticDump {
    static func run() {
        let collector = MetricsCollector()
        let info = collector.systemInfo()

        // Prime the delta-based counters, then sample again a second later.
        _ = collector.cpu()
        _ = collector.diskIO()
        _ = collector.network()
        Thread.sleep(forTimeInterval: 1.0)

        let cpu = collector.cpu()
        let memory = collector.memory()
        let disk = collector.diskIO()
        let network = collector.network()

        print("SYSTEM")
        print("  chip      : \(info.chip)")
        print("  model     : \(info.model)")
        print("  os        : \(info.osVersion)")
        print("  cores     : \(info.logicalCores) logical / \(info.physicalCores) physical "
              + "(\(info.performanceCores)P + \(info.efficiencyCores)E)")
        print("  memory    : \(Fmt.bytes(info.memoryBytes))")
        print("  uptime    : \(Fmt.uptime(info.uptime))")

        print("\nCPU")
        print("  busy      : \(Fmt.percent(cpu.busy)) "
              + "(user \(Fmt.percent(cpu.user)), system \(Fmt.percent(cpu.system)), idle \(Fmt.percent(cpu.idle)))")
        print(String(format: "  load avg  : %.2f %.2f %.2f",
                     cpu.loadAverage.0, cpu.loadAverage.1, cpu.loadAverage.2))
        for core in cpu.cores {
            print("  core \(String(format: "%2d", core.id)) [\(core.kind.rawValue)] : \(Fmt.percent(core.busy))")
        }

        let temperature = collector.temperature()
        if temperature.isPresent {
            print("  temp      : \(Fmt.celsius(temperature.cpuAverage)) avg, "
                  + "\(Fmt.celsius(temperature.cpuHottest)) hottest (\(temperature.sensorCount) sensors)")
        }

        print("\nFANS")
        let fans = collector.fans()
        if fans.isEmpty { print("  (không có quạt hoặc không đọc được SMC)") }
        for fan in fans {
            print("  fan \(fan.id)     : \(Fmt.rpm(fan.current)) "
                  + "(min \(Fmt.rpm(fan.minimum)), max \(Fmt.rpm(fan.maximum)))")
        }

        let gpu = collector.gpu()
        print("\nGPU")
        if gpu.isPresent {
            print("  model     : \(gpu.name) (\(gpu.coreCount) nhân)")
            print("  device    : \(Fmt.percent(gpu.utilization))")
            print("  renderer  : \(Fmt.percent(gpu.rendererUtilization))")
            print("  tiler     : \(Fmt.percent(gpu.tilerUtilization))")
            print("  memory    : \(Fmt.bytes(gpu.inUseMemory)) đang dùng / \(Fmt.bytes(gpu.allocatedMemory)) cấp phát")
        } else {
            print("  (không đọc được)")
        }

        print("\nMEMORY")
        print("  used      : \(Fmt.bytes(memory.used)) / \(Fmt.bytes(memory.total)) "
              + "(\(Fmt.percent(memory.usedFraction)))")
        print("  pressure  : \(Fmt.percent(memory.pressure)) (\(memory.pressureLevel.label))")
        print("  app       : \(Fmt.bytes(memory.appMemory))")
        print("  wired     : \(Fmt.bytes(memory.wired))")
        print("  compressed: \(Fmt.bytes(memory.compressed))")
        print("  cached    : \(Fmt.bytes(memory.cached))")
        print("  free      : \(Fmt.bytes(memory.free))")
        print("  swap      : \(Fmt.bytes(memory.swapUsed)) / \(Fmt.bytes(memory.swapTotal))")

        print("\nDISK I/O")
        print("  read      : \(Fmt.rate(disk.readRate))  total \(Fmt.bytes(disk.readBytes))  "
              + String(format: "%.0f IOPS", disk.readIOPS))
        print("  write     : \(Fmt.rate(disk.writeRate))  total \(Fmt.bytes(disk.writeBytes))  "
              + String(format: "%.0f IOPS", disk.writeIOPS))
        for volume in collector.volumes() {
            print("  volume    : \(volume.name) — \(Fmt.bytes(volume.used)) / \(Fmt.bytes(volume.total)) "
                  + "(\(Fmt.percent(volume.usedFraction)))")
        }

        print("\nDRIVES")
        for drive in collector.drives() {
            print("  \(drive.name) — \(Fmt.bytes(drive.capacity))"
                  + (drive.bsdName.isEmpty ? "" : " (/dev/\(drive.bsdName))"))
            print("    \(drive.tags.joined(separator: " · "))")
            if !drive.serial.isEmpty { print("    serial    : \(drive.serial)") }
            if !drive.revision.isEmpty { print("    firmware  : \(drive.revision)") }
        }

        let battery = collector.battery()
        print("\nBATTERY")
        if battery.isPresent {
            print("  charge    : \(Fmt.percent(battery.percentage))"
                  + (battery.isCharging ? " (charging)" : battery.isPluggedIn ? " (plugged in)" : " (on battery)"))
            print("  remaining : \(Fmt.minutes(battery.timeRemaining))")
            print("  max cap   : \(Fmt.percent(battery.health)) "
                  + "(\(battery.maxCapacity) / \(battery.designCapacity) mAh)")
            print("  cycles    : \(battery.cycleCount)"
                  + (battery.designCycleCount > 0 ? " / \(battery.designCycleCount)" : ""))
            print("  condition : \(battery.condition.isEmpty ? "unknown" : battery.condition)")
            print(String(format: "  power     : %.2f V  %.2f A  %.1f W",
                         battery.voltage, battery.amperage, battery.watts))
            if battery.temperature > 0 {
                print(String(format: "  temp      : %.1f °C", battery.temperature))
            }
            print(String(format: "  system    : %.1f W", battery.systemPowerW))
            print(String(format: "  charging  : %.1f W", battery.chargingPowerW))
            if !battery.adapterName.isEmpty {
                print("  adapter   : \(battery.adapterName) (\(battery.adapterWatts) W max, "
                      + String(format: "%.1f W in)", battery.adapterPowerW))
            }
        } else {
            print("  (no battery)")
        }

        print("\nNETWORK")
        print("  in        : \(Fmt.rate(network.inRate))  since start \(Fmt.bytes(network.inBytes))")
        print("  out       : \(Fmt.rate(network.outRate))  since start \(Fmt.bytes(network.outBytes))")

        print("\nTOP PROCESSES")
        for process in collector.topProcesses(limit: 8) {
            let name = process.name.count > 34
                ? String(process.name.prefix(33)) + "…"
                : process.name.padding(toLength: 34, withPad: " ", startingAt: 0)
            print(String(format: "  %6d  %@ %6.1f%%  %@",
                         process.pid, name, process.cpu, Fmt.bytes(process.memory)))
        }
    }
}
