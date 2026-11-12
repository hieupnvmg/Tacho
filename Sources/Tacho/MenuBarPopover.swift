import SwiftUI
import AppKit

/// Detail panel shown when a menu bar readout is clicked.
struct MenuBarPopover: View {
    let module: MenuBarModule

    @EnvironmentObject private var store: MonitorStore
    @EnvironmentObject private var settings: MenuBarSettings
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: module.icon).font(.system(size: 11, weight: .semibold))
                Text(module.title).font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            detail

            updateBanner

            Divider()
            HStack(spacing: 10) {
                Button(L("Cửa sổ chính")) { Self.openMainWindow() }
                Button(L("Cài đặt")) { openSettings() }
                activityMonitorButton
                Spacer()
                Button(L("Thoát")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 290)
    }

    /// Opens Activity Monitor, for when the panel shows something worth a
    /// closer look. A small copy of the app's own icon, beside the other
    /// footer links.
    @ViewBuilder
    private var activityMonitorButton: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            Button {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } label: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Mở Activity Monitor"))
        }
    }

    /// Only shown while there is something to say about an update.
    @ViewBuilder
    private var updateBanner: some View {
        switch updater.state {
        case .available(let release):
            Button {
                Task { await updater.install() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(L("Có bản mới %@", release.version))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(updater.canInstallInPlace ? L("Cập nhật ngay") : L("Tải về"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(Palette.cpu)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.cpu.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Đang tải… %.0f%%", progress * 100))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ProgressView(value: progress)
            }
        case .installing:
            Text(L("Đang cài đặt… app sẽ tự mở lại"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch module {
        case .cpu:
            Sparkline(values: store.cpuHistory, color: Palette.cpu, normalizeToOne: true, height: 46)
            Legend(label: L("Tổng"), value: Fmt.percent(store.cpu.busy), color: Palette.cpu)
            Legend(label: L("User"), value: Fmt.percent(store.cpu.user), color: Palette.cpu)
            Legend(label: L("System"), value: Fmt.percent(store.cpu.system), color: Palette.cpuSystem)
            InfoRow(label: L("Load average"),
                    value: String(format: "%.2f  %.2f  %.2f",
                                  store.cpu.loadAverage.0,
                                  store.cpu.loadAverage.1,
                                  store.cpu.loadAverage.2))
            if store.temperature.isPresent {
                temperatureRow
            }
            ForEach(store.fans) { fan in
                fanRow(fan)
            }
            topCores
            ProcessList(title: L("Tốn CPU nhất"), apps: store.appsByCPU, metric: .cpu)

        case .gpu:
            Sparkline(values: store.gpuHistory, color: Palette.gpu,
                      normalizeToOne: true, height: 46)
            Legend(label: L("Tổng"), value: Fmt.percent(store.gpu.utilization), color: Palette.gpu)
            Legend(label: L("Renderer"), value: Fmt.percent(store.gpu.rendererUtilization),
                   color: Palette.gpu)
            Legend(label: L("Tiler"), value: Fmt.percent(store.gpu.tilerUtilization),
                   color: Palette.gpu.opacity(0.6))
            InfoRow(label: L("Bộ nhớ"), value: Fmt.bytes(store.gpu.inUseMemory))
            InfoRow(label: L("Chip"), value: "\(store.gpu.name) · " + L("%d nhân", store.gpu.coreCount))

        case .memory:
            memoryDetail

        case .disk:
            diskDetail

        case .network:
            networkDetail

        case .connectivity:
            HStack(spacing: 8) {
                Circle()
                    .fill(ConnectivityStyle.color(store.connectivity.status))
                    .frame(width: 10, height: 10)
                Text(ConnectivityStyle.label(store.connectivity.status))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            Divider()
            InfoRow(label: L("IP ra Internet"),
                    value: store.connectivity.publicIP.isEmpty ? "—" : store.connectivity.publicIP,
                    copyable: !store.connectivity.publicIP.isEmpty)
            InfoRow(label: L("IP nội bộ"),
                    value: store.connectivity.localIP.isEmpty ? "—" : store.connectivity.localIP,
                    copyable: !store.connectivity.localIP.isEmpty)
            if !store.connectivity.routeDescription.isEmpty {
                InfoRow(label: L("Đường ra"), value: store.connectivity.routeDescription)
            }
            if let checked = store.connectivity.lastChecked {
                InfoRow(label: L("Kiểm tra lúc"), value: Self.clock.string(from: checked))
            }
            Text(L("IP ra Internet lấy từ 1.1.1.1 của Cloudflare, 60 giây một lần."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

        case .battery:
            if store.battery.isPresent {
                batteryDetail
            } else {
                Text(L("Máy này không có pin."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            PeripheralList(devices: store.peripherals)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Pressure as the headline (it is what decides whether the Mac is
    /// struggling), then what the RAM holds, then swap.
    private var memoryDetail: some View {
        let memory = store.memory
        let tint = Palette.pressure(memory.pressureLevel)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ArcGauge(fraction: memory.pressure,
                         // Green for most of the dial: pressure is fine until the
                         // kernel says otherwise, which happens late.
                         ramp: [Palette.memory, Palette.memory, Palette.warning, Palette.critical],
                         value: String(format: "%.0f%%", memory.pressure * 100),
                         valueColor: tint,
                         caption: L("áp lực"),
                         size: 92)
                VStack(alignment: .leading, spacing: 6) {
                    StatusChip(text: memory.pressureLevel.label, color: tint)
                    Text(verbatim: "\(Fmt.bytes(memory.used)) / \(Fmt.bytes(memory.total))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: L("đã dùng %.0f%% RAM"), memory.usedFraction * 100))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                StackedBar(segments: [
                    .init(label: L("App"), value: Double(memory.appMemory), color: Palette.memory),
                    .init(label: L("Wired"), value: Double(memory.wired), color: Palette.cpuSystem),
                    .init(label: L("Nén"), value: Double(memory.compressed), color: Palette.netIn),
                    .init(label: L("Cache"), value: Double(memory.cached), color: Palette.read.opacity(0.6)),
                ], total: Double(max(memory.total, 1)), height: 10)
                HStack(spacing: 6) {
                    memoryTile(L("App"), memory.appMemory, color: Palette.memory)
                    memoryTile(L("Wired"), memory.wired, color: Palette.cpuSystem)
                    memoryTile(L("Nén"), memory.compressed, color: Palette.netIn)
                    memoryTile(L("Trống"), memory.free, color: .gray)
                }
            }

            Sparkline(values: store.pressureHistory, color: tint, normalizeToOne: true, height: 36)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(memory.isSwapping ? Palette.warning : .secondary)
                    Text(L("Swap")).font(.system(size: 11)).foregroundStyle(.secondary)
                    StatusChip(text: memory.isSwapping ? L("Đang swap") : L("Không swap"),
                               color: memory.isSwapping ? Palette.warning : Palette.memory)
                    Spacer()
                    Text(verbatim: "\(Fmt.bytes(memory.swapUsed)) / \(Fmt.bytes(memory.swapTotal))")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                }
                MeterBar(fraction: memory.swapFraction,
                         color: Palette.level(memory.swapFraction, base: Palette.warning),
                         height: 6)
                Text(String(format: L("vào %.0f · ra %.0f trang/giây"),
                            memory.swapInRate, memory.swapOutRate))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            ProcessList(title: L("Tốn RAM nhất"), apps: store.appsByMemory, metric: .memory)
        }
    }

    private func memoryTile(_ label: String, _ bytes: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(Fmt.bytes(bytes))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Throughput first, like the network panel, then how full each volume is,
    /// with the startup volume as a dial.
    private var diskDetail: some View {
        let disk = store.disk
        let volumes = Array(store.volumes.prefix(3))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                rateTile(L("Đọc"), icon: "arrow.down.doc", rate: disk.readRate,
                         history: store.diskReadHistory, color: Palette.read,
                         detail: String(format: "%.0f IOPS", disk.readIOPS))
                rateTile(L("Ghi"), icon: "square.and.pencil", rate: disk.writeRate,
                         history: store.diskWriteHistory, color: Palette.write,
                         detail: String(format: "%.0f IOPS", disk.writeIOPS))
            }

            if let main = volumes.first {
                Divider()
                HStack(spacing: 14) {
                    ArcGauge(fraction: main.usedFraction,
                             // Blue up to two thirds full, matching `Palette.level`,
                             // which only turns the number amber past 70%.
                             ramp: Array(repeating: Palette.read, count: 5)
                                + [Palette.warning, Palette.critical],
                             value: String(format: "%.0f%%", main.usedFraction * 100),
                             valueColor: Palette.level(main.usedFraction, base: Palette.read),
                             caption: L("đã dùng"),
                             size: 88)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.read)
                            Text(main.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(verbatim: L("còn %@", Fmt.bytes(main.free)))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(verbatim: "\(Fmt.bytes(main.used)) / \(Fmt.bytes(main.total))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let drive = store.drives.first {
                            HStack(spacing: 4) {
                                if !drive.interconnect.isEmpty {
                                    StatusChip(text: drive.interconnect, color: Palette.read)
                                }
                                if drive.smartCapable {
                                    StatusChip(text: "SMART", color: Palette.memory)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            ForEach(volumes.dropFirst()) { volume in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(volume.name).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(verbatim: L("còn %@", Fmt.bytes(volume.free)))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    MeterBar(fraction: volume.usedFraction,
                             color: Palette.level(volume.usedFraction, base: Palette.read),
                             height: 5)
                }
            }
        }
    }

    /// Down and up as two big tiles with their own history, then how the
    /// traffic leaves the machine.
    private var networkDetail: some View {
        let link = store.connectivity
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                rateTile(L("Nhận"), icon: "arrow.down", rate: store.network.inRate,
                         history: store.netInHistory, color: Palette.netIn)
                rateTile(L("Gửi"), icon: "arrow.up", rate: store.network.outRate,
                         history: store.netOutHistory, color: Palette.netOut)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(ConnectivityStyle.color(link.status))
                    .frame(width: 8, height: 8)
                Text(ConnectivityStyle.label(link.status))
                    .font(.system(size: 11, weight: .medium))
                if !link.routeDescription.isEmpty {
                    StatusChip(text: link.routeDescription,
                               color: link.isTunnelled ? Palette.warning : Palette.read)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Từ lúc mở app"))
                    .font(.system(size: 10, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    totalTile(L("Đã nhận"), store.network.inBytes, icon: "arrow.down", color: Palette.netIn)
                    totalTile(L("Đã gửi"), store.network.outBytes, icon: "arrow.up", color: Palette.netOut)
                }
            }
        }
    }

    private func rateTile(_ label: String, icon: String, rate: Double,
                          history: [Double], color: Color, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(Fmt.rate(rate))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Sparkline(values: history, color: color, height: 30)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func totalTile(_ label: String, _ bytes: UInt64, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text(Fmt.bytes(bytes))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Charge as the headline, then where the power goes, then long-term health.
    private var batteryDetail: some View {
        let battery = store.battery
        let tint = BatteryIcon.color(for: battery)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                BatteryGlyph(percentage: battery.percentage, state: battery.powerState,
                             color: tint, width: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.0f%%", battery.percentage * 100))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    StatusChip(text: battery.statusText, color: tint)
                    if battery.timeRemaining > 0 {
                        Text((battery.isCharging ? L("Đầy sau ") : L("Còn dùng "))
                             + Fmt.minutes(battery.timeRemaining))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                powerTile(L("Máy dùng"), battery.systemPowerW, icon: "laptopcomputer", color: Palette.cpu)
                if battery.isPluggedIn {
                    powerTile(L("Vào pin"), battery.chargingPowerW,
                              icon: "battery.100.bolt", color: Palette.memory)
                    powerTile(L("Từ sạc"), battery.adapterPowerW,
                              icon: "powerplug.fill", color: Palette.warning)
                }
            }

            if battery.isPluggedIn, battery.adapterWatts > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(battery.adapterName.isEmpty ? L("Cục sạc") : battery.adapterName)
                            .lineLimit(1)
                        Spacer()
                        Text(verbatim: String(format: L("%.0f%% của %d W"),
                                              battery.adapterLoad * 100, battery.adapterWatts))
                            .monospacedDigit()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    MeterBar(fraction: battery.adapterLoad,
                             color: Palette.level(battery.adapterLoad, base: Palette.memory),
                             height: 6)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(battery.healthColor)
                    Text(L("Sức khỏe")).font(.system(size: 11)).foregroundStyle(.secondary)
                    if !battery.condition.isEmpty {
                        StatusChip(text: battery.condition, color: battery.healthColor)
                    }
                    Spacer()
                    Text(Fmt.percent(battery.health))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(battery.healthColor)
                }
                MeterBar(fraction: battery.health, color: battery.healthColor, height: 6)
                HStack {
                    Text(L("Chu kỳ sạc"))
                    Spacer()
                    Text(verbatim: battery.designCycleCount > 0
                         ? "\(battery.cycleCount) / \(battery.designCycleCount)"
                         : "\(battery.cycleCount)")
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                if battery.designCycleCount > 0 {
                    MeterBar(fraction: battery.cycleFraction,
                             color: Palette.level(battery.cycleFraction, base: Palette.read),
                             height: 4)
                }
            }
        }
    }

    private func powerTile(_ label: String, _ watts: Double, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(BatteryView.watts(watts))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Average die temperature, coloured by how warm it is, over the spread
    /// from the coolest to the hottest sensor.
    private var temperatureRow: some View {
        let reading = store.temperature
        let color = Palette.temperature(reading.cpuAverage)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(L("Nhiệt độ")).font(.system(size: 11)).foregroundStyle(.secondary)
                StatusChip(text: TemperatureSample.label(reading.cpuAverage), color: color)
                Spacer()
                Text(String(format: "%.0f°", reading.cpuAverage))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(String(format: "max %.0f°", reading.cpuHottest))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            ThermalSpreadBar(coolest: reading.cpuCoolest,
                             average: reading.cpuAverage,
                             hottest: reading.cpuHottest,
                             height: 6)
        }
    }

    /// Same shape as the temperature row: icon, reading, number, ramp bar.
    private func fanRow(_ fan: FanSample) -> some View {
        let color = Palette.fan(fan.fraction)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(store.fans.count > 1 ? L("Quạt %d", fan.id + 1) : L("Quạt"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                StatusChip(text: fan.label, color: color)
                Spacer()
                Text(String(format: "%.0f", fan.current))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(L("rpm"))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            RampBar(fraction: fan.fraction, ramp: Palette.fanRamp, height: 6)
        }
    }

    /// Every core as a ring, matching the main window.
    private var topCores: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(store.cpu.cores) { core in
                    CoreRing(core: core, size: 22)
                }
            }
            if store.gpu.isPresent {
                Divider()
                HStack(spacing: 8) {
                    Text("GPU").font(.system(size: 11)).foregroundStyle(.secondary)
                    MeterBar(fraction: store.gpu.utilization,
                             color: Palette.level(store.gpu.utilization, base: Palette.gpu))
                    Text(Fmt.percent(store.gpu.utilization))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    /// Leaves the activation policy alone: the Dock icon follows the setting,
    /// and an accessory app can still bring a window to the front.
    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first {
            $0.canBecomeMain && !($0 is NSPanel)
                && !($0.identifier?.rawValue.contains("Settings") ?? false)
        }
        if let main {
            main.makeKeyAndOrderFront(nil)
        } else {
            // A closed WindowGroup window is gone for good; File › New Window
            // is how SwiftUI makes another one.
            Self.performMenuItem(keyEquivalent: "n")
        }
    }

    /// Since macOS 14 SwiftUI ignores `showSettingsWindow:` sent from outside a
    /// `SettingsLink`, and this view lives in an AppKit popover where that link
    /// has no scene to open. The app menu's "Settings…" item still works.
    /// Settings live in the main window as their own tab.
    private func openSettings() {
        store.section = .settings
        Self.openMainWindow()
    }

    /// Fires the first ⌘-<key> item found anywhere in the main menu.
    @discardableResult
    private static func performMenuItem(keyEquivalent key: String) -> Bool {
        func search(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == key,
                   item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command,
                   item.isEnabled {
                    return (menu, index)
                }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        guard let menu = NSApp.mainMenu, let (owner, index) = search(menu) else { return false }
        owner.performActionForItem(at: index)
        return true
    }
}

/// The few apps behind a busy CPU or a full RAM, each with its helper
/// processes counted in, as Activity Monitor's app view does.
private struct ProcessList: View {
    enum Metric { case cpu, memory }

    let title: String
    let apps: [AppUsage]
    let metric: Metric

    /// Loading an icon from disk on every redraw would be wasteful.
    private static var icons: [String: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if apps.isEmpty {
                Text(L("Đang lấy danh sách…"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(apps) { row($0) }
        }
    }

    private func row(_ app: AppUsage) -> some View {
        HStack(spacing: 7) {
            Group {
                if let icon = Self.icon(for: app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)

            Text(app.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            if app.processCount > 1 {
                Text(verbatim: "×\(app.processCount)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            MeterBar(fraction: fraction(app), color: color(app), height: 4)
                .frame(width: 46)
            Text(value(app))
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color(app))
                .frame(width: 58, alignment: .trailing)
        }
    }

    private static func icon(for app: AppUsage) -> NSImage? {
        guard let path = app.bundlePath else { return nil }
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    private func value(_ app: AppUsage) -> String {
        switch metric {
        case .cpu: return String(format: "%.0f%%", app.cpu)
        case .memory: return Fmt.bytes(app.memory)
        }
    }

    /// One core's worth (100%) fills the CPU bar; the RAM bar is measured
    /// against the heaviest app shown.
    private func fraction(_ app: AppUsage) -> Double {
        switch metric {
        case .cpu: return min(app.cpu / 100, 1)
        case .memory:
            let top = Double(apps.first?.memory ?? 1)
            return top > 0 ? Double(app.memory) / top : 0
        }
    }

    private func color(_ app: AppUsage) -> Color {
        switch metric {
        case .cpu: return app.cpu > 80 ? Palette.critical : app.cpu > 40 ? Palette.warning : Palette.cpu
        case .memory: return Palette.memory
        }
    }
}

/// Mice, keyboards and AirPods, each battery with its own bar.
private struct PeripheralList: View {
    let devices: [PeripheralSample]

    var body: some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text(L("Thiết bị Bluetooth"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Image(systemName: device.symbol)
                                .font(.system(size: 11))
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            Text(device.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            if device.levels.count == 1 {
                                level(device.levels[0])
                            }
                        }
                        if device.levels.count > 1 {
                            HStack(spacing: 10) {
                                ForEach(device.levels, id: \.self) { level($0) }
                            }
                            .padding(.leading, 23)
                        }
                    }
                }
            }
        }
    }

    private func level(_ level: PeripheralSample.Level) -> some View {
        let color = level.percent <= 20 ? Palette.critical
            : level.percent <= 40 ? Palette.warning : Palette.memory
        return HStack(spacing: 5) {
            if !level.part.isEmpty {
                Text(Self.partName(level.part))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            MeterBar(fraction: Double(level.percent) / 100, color: color, height: 4)
                .frame(width: 34)
            Text(verbatim: "\(level.percent)%")
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private static func partName(_ part: String) -> String {
        switch part {
        case "Trái": return L("Trái")
        case "Phải": return L("Phải")
        case "Hộp": return L("Hộp")
        default: return part
        }
    }
}
