import SwiftUI
import AppKit

/// Sidebar sections. Kept out of `ContentView` because the selection lives in
/// `MonitorStore`: the SwiftUI `@State` macro plugin is unavailable when only the
/// Command Line Tools are installed.
enum MonitorSection: String, CaseIterable, Identifiable {
    case overview = "Tổng quan"
    case cpu = "CPU"
    case memory = "Bộ nhớ"
    case disk = "Ổ đĩa"
    case battery = "Pin"
    case network = "Mạng"
    case history = "Lịch sử"
    case processes = "Tiến trình"
    case settings = "Cài đặt"

    var id: String { rawValue }

    /// The raw value is the Vietnamese name, which is also its `L` key.
    var title: String { L(rawValue) }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .battery: return "battery.100"
        case .network: return "network"
        case .history: return "clock.arrow.circlepath"
        case .processes: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

/// The main window. It watches only whether it can be seen; everything that
/// follows the readings lives in `MainWindowContent`, which exists only while
/// the window is on screen. Before, the window's frame (sidebar, toolbar,
/// uptime) kept following the store while hidden, and laying out its toolbar
/// on every sample was most of the app's idle CPU time.
struct ContentView: View {
    @EnvironmentObject private var settings: MenuBarSettings
    @StateObject private var visibility = WindowVisibility()

    var body: some View {
        Group {
            if visibility.isVisible {
                MainWindowContent()
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(WindowObserver { visibility.isVisible = $0 })
        // See SettingsView: re-render every string when the language changes.
        .id(settings.language)
    }
}

struct MainWindowContent: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        NavigationSplitView {
            List(MonitorSection.allCases, selection: $store.section) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) { refreshPicker }
        } detail: {
            detail
            .navigationTitle((store.section ?? .overview).title)
            .toolbar {
                ToolbarItem(placement: .status) {
                    Text(store.info.chip.isEmpty ? store.info.model : store.info.chip)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if store.section == .settings {
            // Form scrolls on its own and collapses inside a ScrollView.
            SettingsView(embedded: true)
        } else {
            ScrollView {
                Group {
                    switch store.section ?? .overview {
                    case .overview: OverviewView()
                    case .cpu: CPUView()
                    case .memory: MemoryView()
                    case .disk: DiskView()
                    case .battery: BatteryView()
                    case .network: NetworkView()
                    case .history: HistoryView()
                    case .processes: ProcessesView()
                    case .settings: EmptyView()
                    }
                }
                .padding(18)
            }
        }
    }

    private var refreshPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Picker(L("Tần suất"), selection: $store.interval) {
                Text("0.5s").tag(0.5)
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
                Text("5s").tag(5.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(L("Uptime") + " " + Fmt.uptime(store.info.uptime))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var store: MonitorStore

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            Card(title: "CPU", systemImage: "cpu", accessory: String(format: "load %.2f", store.cpu.loadAverage.0)) {
                HStack(spacing: 16) {
                    RingGauge(fraction: store.cpu.busy,
                              color: Palette.level(store.cpu.busy, base: Palette.cpu),
                              caption: L("đang dùng"))
                    VStack(alignment: .leading, spacing: 6) {
                        Legend(label: L("User"), value: Fmt.percent(store.cpu.user), color: Palette.cpu)
                        Legend(label: L("System"), value: Fmt.percent(store.cpu.system), color: Palette.cpuSystem)
                        Legend(label: L("Idle"), value: Fmt.percent(store.cpu.idle), color: .gray)
                        Divider().padding(.vertical, 2)
                        InfoRow(label: L("Lõi"), value: L("%d logic / %d vật lý", store.info.logicalCores, store.info.physicalCores))
                    }
                }
                Sparkline(values: store.cpuHistory, color: Palette.cpu, normalizeToOne: true)
                // Same ring row as the CPU tab, so the overview does not fall
                // back to a different visual language for the same data.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(store.cpu.cores) { core in
                        CoreRing(core: core, size: 24)
                    }
                }
            }

            if store.gpu.isPresent {
                Card(title: "GPU", systemImage: "square.stack.3d.up.fill",
                     accessory: store.gpu.coreCount > 0 ? L("%d nhân", store.gpu.coreCount) : nil) {
                    HStack(spacing: 16) {
                        RingGauge(fraction: store.gpu.utilization,
                                  color: Palette.level(store.gpu.utilization, base: Palette.gpu),
                                  caption: L("đang dùng"))
                        VStack(alignment: .leading, spacing: 6) {
                            Legend(label: L("Renderer"),
                                   value: Fmt.percent(store.gpu.rendererUtilization),
                                   color: Palette.gpu)
                            Legend(label: L("Tiler"),
                                   value: Fmt.percent(store.gpu.tilerUtilization),
                                   color: Palette.gpu.opacity(0.6))
                            Divider().padding(.vertical, 2)
                            InfoRow(label: L("Bộ nhớ"), value: Fmt.bytes(store.gpu.inUseMemory))
                            InfoRow(label: L("Chip"), value: store.gpu.name)
                        }
                    }
                    Sparkline(values: store.gpuHistory, color: Palette.gpu, normalizeToOne: true)
                }
            }

            Card(title: L("Bộ nhớ"), systemImage: "memorychip", accessory: Fmt.bytes(store.memory.total)) {
                HStack(spacing: 16) {
                    RingGauge(fraction: store.memory.usedFraction,
                              color: Palette.level(store.memory.usedFraction, base: Palette.memory),
                              caption: L("đã dùng"))
                    VStack(alignment: .leading, spacing: 6) {
                        Legend(label: L("App"), value: Fmt.bytes(store.memory.appMemory), color: Palette.memory)
                        Legend(label: L("Wired"), value: Fmt.bytes(store.memory.wired), color: Palette.cpuSystem)
                        Legend(label: L("Nén"), value: Fmt.bytes(store.memory.compressed), color: Palette.netIn)
                        Legend(label: L("Còn trống"), value: Fmt.bytes(store.memory.free), color: .gray)
                    }
                }
                Sparkline(values: store.memoryHistory, color: Palette.memory, normalizeToOne: true)
            }

            Card(title: "Disk I/O", systemImage: "internaldrive",
                 accessory: "R \(Fmt.rate(store.disk.readRate))  W \(Fmt.rate(store.disk.writeRate))") {
                VStack(alignment: .leading, spacing: 8) {
                    Legend(label: L("Đọc"), value: Fmt.rate(store.disk.readRate), color: Palette.read)
                    Sparkline(values: store.diskReadHistory, color: Palette.read, height: 34)
                    Legend(label: L("Ghi"), value: Fmt.rate(store.disk.writeRate), color: Palette.write)
                    Sparkline(values: store.diskWriteHistory, color: Palette.write, height: 34)
                }
            }

            Card(title: L("Mạng"), systemImage: "network",
                 accessory: "↓ \(Fmt.rate(store.network.inRate))  ↑ \(Fmt.rate(store.network.outRate))") {
                VStack(alignment: .leading, spacing: 8) {
                    Legend(label: L("Nhận"), value: Fmt.rate(store.network.inRate), color: Palette.netIn)
                    Sparkline(values: store.netInHistory, color: Palette.netIn, height: 34)
                    Legend(label: L("Gửi"), value: Fmt.rate(store.network.outRate), color: Palette.netOut)
                    Sparkline(values: store.netOutHistory, color: Palette.netOut, height: 34)
                }
            }

            Card(title: L("Hệ thống"), systemImage: "desktopcomputer") {
                VStack(spacing: 6) {
                    InfoRow(label: L("Chip"), value: store.info.chip)
                    InfoRow(label: L("Model"), value: store.info.model)
                    InfoRow(label: L("Hệ điều hành"), value: store.info.osVersion)
                    InfoRow(label: "RAM", value: Fmt.bytes(store.info.memoryBytes))
                    InfoRow(label: L("Uptime"), value: Fmt.uptime(store.info.uptime))
                    InfoRow(label: L("Load average"),
                            value: String(format: "%.2f  %.2f  %.2f",
                                          store.cpu.loadAverage.0,
                                          store.cpu.loadAverage.1,
                                          store.cpu.loadAverage.2))
                }
            }

            Card(title: L("Dung lượng ổ đĩa"), systemImage: "externaldrive") {
                VStack(spacing: 10) {
                    ForEach(store.volumes) { volume in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(volume.name).font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text("\(Fmt.bytes(volume.used)) / \(Fmt.bytes(volume.total))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            MeterBar(fraction: volume.usedFraction,
                                     color: Palette.level(volume.usedFraction, base: Palette.read))
                        }
                    }
                }
            }

            if store.battery.isPresent {
                Card(title: L("Pin"), systemImage: BatteryIcon.name(for: store.battery),
                     accessory: store.battery.condition) {
                    HStack(spacing: 14) {
                        BatteryGlyph(percentage: store.battery.percentage,
                                     state: store.battery.powerState,
                                     color: BatteryIcon.color(for: store.battery),
                                     width: 96)
                        Text(String(format: "%.0f%%", store.battery.percentage * 100))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(BatteryIcon.color(for: store.battery))
                        Spacer()
                    }
                    VStack(spacing: 6) {
                        InfoRow(label: L("Dung lượng tối đa"), value: Fmt.percent(store.battery.health))
                        InfoRow(label: L("Chu kỳ sạc"), value: "\(store.battery.cycleCount)")
                        InfoRow(label: store.battery.isCharging ? L("Đầy sau") : L("Còn dùng"),
                                value: Fmt.minutes(store.battery.timeRemaining))
                    }
                }
            }
        }
    }
}

/// Picks the SF Symbol and tint that match the current charge.
enum BatteryIcon {
    static func name(for battery: BatterySample) -> String {
        switch battery.powerState {
        case .charging: return "battery.100.bolt"
        case .pluggedNotCharging: return "powerplug.fill"
        case .onBattery: break
        }
        switch battery.percentage {
        case ..<0.15: return "battery.0"
        case ..<0.4: return "battery.25"
        case ..<0.7: return "battery.50"
        case ..<0.9: return "battery.75"
        default: return "battery.100"
        }
    }

    static func color(for battery: BatterySample) -> Color {
        if battery.isCharging || battery.isPluggedIn { return Palette.memory }
        switch battery.percentage {
        case ..<0.15: return Palette.critical
        case ..<0.3: return Palette.warning
        default: return Palette.memory
        }
    }
}

// MARK: - CPU

struct CPUView: View {
    @EnvironmentObject private var store: MonitorStore

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 44), spacing: 14)]
    }

    private var efficiencyCores: [CoreSample] {
        store.cpu.cores.filter { $0.kind == .efficiency }
    }

    private var performanceCores: [CoreSample] {
        store.cpu.cores.filter { $0.kind == .performance }
    }

    var body: some View {
        VStack(spacing: 16) {
            Card(title: L("Tổng tải CPU"), systemImage: "cpu",
                 accessory: L("%d lõi logic", store.info.logicalCores)) {
                HStack(alignment: .center, spacing: 20) {
                    RingGauge(fraction: store.cpu.busy,
                              color: Palette.level(store.cpu.busy, base: Palette.cpu),
                              caption: L("busy"), size: 110)
                    VStack(alignment: .leading, spacing: 8) {
                        StackedBar(segments: [
                            .init(label: "user", value: store.cpu.user, color: Palette.cpu),
                            .init(label: "system", value: store.cpu.system, color: Palette.cpuSystem),
                        ], total: 1)
                        Legend(label: L("User"), value: Fmt.percent(store.cpu.user), color: Palette.cpu)
                        Legend(label: L("System"), value: Fmt.percent(store.cpu.system), color: Palette.cpuSystem)
                        Legend(label: L("Idle"), value: Fmt.percent(store.cpu.idle), color: .gray)
                        InfoRow(label: L("Load average"),
                                value: String(format: "%.2f  %.2f  %.2f",
                                              store.cpu.loadAverage.0,
                                              store.cpu.loadAverage.1,
                                              store.cpu.loadAverage.2))
                    }
                    .frame(maxWidth: 260)
                }
                Sparkline(values: store.cpuHistory, color: Palette.cpu, normalizeToOne: true, height: 60)
            }

            if store.temperature.isPresent { temperatureCard }

            Card(title: L("Từng lõi"), systemImage: "circle.grid.3x3",
                 accessory: store.info.performanceCores > 0
                    ? "\(store.info.performanceCores)P + \(store.info.efficiencyCores)E"
                    : nil) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(store.cpu.cores) { core in
                        CoreRing(core: core)
                    }
                }

                if !efficiencyCores.isEmpty || !performanceCores.isEmpty {
                    Divider().padding(.vertical, 2)
                    VStack(spacing: 7) {
                        if !efficiencyCores.isEmpty {
                            ClusterSummary(title: L("Lõi tiết kiệm điện"),
                                           cores: efficiencyCores,
                                           color: Palette.coreEfficiency)
                        }
                        if !performanceCores.isEmpty {
                            ClusterSummary(title: L("Lõi hiệu năng"),
                                           cores: performanceCores,
                                           color: Palette.corePerformance)
                        }
                    }
                }
            }

            if store.gpu.isPresent { gpuCard }
            if !store.fans.isEmpty { fanCard }
        }
    }

    private var temperatureCard: some View {
        let reading = store.temperature
        return Card(title: L("Nhiệt độ CPU"), systemImage: "thermometer.medium",
                    accessory: L("%d cảm biến trên chip", reading.sensorCount)) {
            HStack(alignment: .center, spacing: 24) {
                TemperatureGauge(celsius: reading.cpuAverage)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(TemperatureSample.label(reading.cpuAverage))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.temperature(reading.cpuAverage))
                        Text(L("trung bình các lõi CPU"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ThermalSpreadBar(coolest: reading.cpuCoolest,
                                     average: reading.cpuAverage,
                                     hottest: reading.cpuHottest)
                    HStack(spacing: 10) {
                        StatTile(label: L("Mát nhất"), value: Fmt.celsius(reading.cpuCoolest),
                                 color: Palette.temperature(reading.cpuCoolest))
                        StatTile(label: L("Nóng nhất"), value: Fmt.celsius(reading.cpuHottest),
                                 color: Palette.temperature(reading.cpuHottest))
                    }
                }
                .frame(maxWidth: 360)
                Spacer(minLength: 0)
            }
            Sparkline(values: store.temperatureHistory.map(TemperatureSample.fraction),
                      color: Palette.temperature(reading.cpuAverage),
                      normalizeToOne: true, height: 50)
            Text(L("Đo ngay trên die chip, cạnh từng lõi CPU — không phải nhiệt độ vỏ máy. Chip Apple chạy 70–90 °C khi tải nặng là bình thường; chỉ đáng lo khi liên tục quanh 100 °C, lúc đó chip tự hạ xung."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var fanCard: some View {
        Card(title: L("Quạt"), systemImage: "fan",
             accessory: store.fans.count > 1 ? L("%d quạt", store.fans.count) : nil) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(store.fans) { fan in
                    FanPanel(fan: fan,
                             title: store.fans.count > 1 ? L("Quạt %d", fan.id + 1) : L("Quạt"),
                             history: fan.id < store.fanHistory.count ? store.fanHistory[fan.id] : [])
                }
            }
            Text(L("Tốc độ đo bằng vòng/phút. Quạt quay nhanh khi chip nóng là bình thường — macOS tự điều khiển, app chỉ đọc."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var gpuCard: some View {
        Card(title: "GPU", systemImage: "square.stack.3d.up.fill",
             accessory: store.gpu.coreCount > 0
                ? "\(store.gpu.name) · " + L("%d nhân", store.gpu.coreCount)
                : store.gpu.name) {
            HStack(alignment: .center, spacing: 20) {
                RingGauge(fraction: store.gpu.utilization,
                          color: Palette.level(store.gpu.utilization, base: Palette.gpu),
                          caption: L("gpu"), size: 92)
                VStack(spacing: 8) {
                    Legend(label: L("Renderer"),
                           value: Fmt.percent(store.gpu.rendererUtilization),
                           color: Palette.gpu)
                    Legend(label: L("Tiler"),
                           value: Fmt.percent(store.gpu.tilerUtilization),
                           color: Palette.gpu.opacity(0.6))
                    InfoRow(label: L("Bộ nhớ đang dùng"), value: Fmt.bytes(store.gpu.inUseMemory))
                    InfoRow(label: L("Bộ nhớ đã cấp phát"), value: Fmt.bytes(store.gpu.allocatedMemory))
                }
                .frame(maxWidth: 300)
                Spacer()
            }
            Sparkline(values: store.gpuHistory, color: Palette.gpu,
                      normalizeToOne: true, height: 60)
        }
    }
}

/// One core as a ring gauge, the way iStat Menus lays the cluster out.
struct CoreRing: View {
    let core: CoreSample
    var size: CGFloat = 34

    private var label: String {
        switch core.kind {
        case .performance: return "P-core \(core.id)"
        case .efficiency: return "E-core \(core.id)"
        case .generic: return "Core \(core.id)"
        }
    }

    private var color: Color {
        core.kind == .efficiency ? Palette.coreEfficiency : Palette.corePerformance
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.quaternary.opacity(0.55), lineWidth: size * 0.12)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(core.busy, 0), 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Deliberately not animated. Every core changes every sample, so
                    // a 0.25 s ease kept the window redrawing at 120 Hz for a quarter
                    // of each second: ~28% CPU with the window open, ~6% without.
            }
            .frame(width: size, height: size)

            Text(String(format: "%.0f", core.busy * 100))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .help("\(label) — \(Fmt.percent(core.busy))")
    }
}

/// One fan: a dial over its own min…max range, a plain-language reading,
/// and its recent history.
struct FanPanel: View {
    let fan: FanSample
    let title: String
    let history: [Double]

    private var color: Color { Palette.fan(fan.fraction) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                ArcGauge(fraction: fan.fraction,
                         ramp: Palette.fanRamp,
                         value: String(format: "%.0f", fan.current),
                         valueColor: color,
                         caption: L("vòng/phút"),
                         scale: (String(format: "%.0f", fan.minimum),
                                 String(format: "%.0f", fan.maximum)),
                         size: 112)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "fan.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(color)
                        Text(title).font(.system(size: 13, weight: .semibold))
                        StatusChip(text: fan.label, color: color)
                    }
                    RampBar(fraction: fan.fraction, ramp: Palette.fanRamp)
                    Text(verbatim: String(format: L("%.0f%% công suất quạt"), fan.fraction * 100))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Sparkline(values: history, color: color, normalizeToOne: true, height: 36)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Small tinted capsule holding a one-word reading such as "Êm" or "Ấm".
struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Average load of one cluster, shown beside its colour key.
struct ClusterSummary: View {
    let title: String
    let cores: [CoreSample]
    let color: Color

    private var average: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.map(\.busy).reduce(0, +) / Double(cores.count)
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) (\(cores.count))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(Fmt.percent(average))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

// MARK: - Memory

struct MemoryView: View {
    @EnvironmentObject private var store: MonitorStore

    private var segments: [StackedBar.Segment] {
        let m = store.memory
        return [
            .init(label: L("App"), value: Double(m.appMemory), color: Palette.memory),
            .init(label: L("Wired"), value: Double(m.wired), color: Palette.cpuSystem),
            .init(label: L("Nén"), value: Double(m.compressed), color: Palette.netIn),
            .init(label: L("Cache"), value: Double(m.cached), color: Palette.read.opacity(0.6)),
        ]
    }

    var body: some View {
        VStack(spacing: 16) {
            Card(title: L("Sử dụng bộ nhớ"), systemImage: "memorychip",
                 accessory: "\(Fmt.bytes(store.memory.used)) / \(Fmt.bytes(store.memory.total))") {
                StackedBar(segments: segments, total: Double(max(store.memory.total, 1)), height: 18)
                VStack(spacing: 6) {
                    Legend(label: L("App memory"), value: Fmt.bytes(store.memory.appMemory), color: Palette.memory)
                    Legend(label: L("Wired (kernel)"), value: Fmt.bytes(store.memory.wired), color: Palette.cpuSystem)
                    Legend(label: L("Đã nén"), value: Fmt.bytes(store.memory.compressed), color: Palette.netIn)
                    Legend(label: L("Cached files"), value: Fmt.bytes(store.memory.cached), color: Palette.read.opacity(0.6))
                    Legend(label: L("Trống"), value: Fmt.bytes(store.memory.free), color: .gray)
                }
                Sparkline(values: store.memoryHistory, color: Palette.memory, normalizeToOne: true, height: 60)
            }

            Card(title: L("Áp lực bộ nhớ"), systemImage: "gauge.with.dots.needle.33percent",
                 accessory: store.memory.pressureLevel.label) {
                Sparkline(values: store.pressureHistory,
                          color: Palette.pressure(store.memory.pressureLevel),
                          normalizeToOne: true, height: 60)
                VStack(spacing: 6) {
                    InfoRow(label: L("Áp lực hiện tại"), value: Fmt.percent(store.memory.pressure))
                    InfoRow(label: L("Mức theo kernel"), value: store.memory.pressureLevel.label)
                }
                Text(L("Áp lực khác với tỉ lệ RAM đã dùng: máy có thể dùng 75% RAM mà áp lực vẫn thấp."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Card(title: L("Chi tiết"), systemImage: "list.bullet") {
                VStack(spacing: 6) {
                    InfoRow(label: L("Tổng RAM"), value: Fmt.bytes(store.memory.total))
                    InfoRow(label: L("Active"), value: Fmt.bytes(store.memory.active))
                    InfoRow(label: L("Inactive"), value: Fmt.bytes(store.memory.inactive))
                }
            }

            Card(title: L("Swap"), systemImage: "arrow.left.arrow.right.square",
                 accessory: store.memory.isSwapping ? L("đang swap") : L("không swap")) {
                HStack(spacing: 10) {
                    StatTile(label: L("Đã dùng"), value: Fmt.bytes(store.memory.swapUsed),
                             caption: L("trên %@", Fmt.bytes(store.memory.swapTotal)),
                             color: Palette.level(store.memory.swapFraction, base: Palette.warning))
                    StatTile(label: L("Đọc vào"),
                             value: String(format: "%.0f", store.memory.swapInRate),
                             caption: L("trang mỗi giây"))
                    StatTile(label: L("Ghi ra"),
                             value: String(format: "%.0f", store.memory.swapOutRate),
                             caption: L("trang mỗi giây"))
                }
                MeterBar(fraction: store.memory.swapFraction,
                         color: Palette.level(store.memory.swapFraction, base: Palette.warning),
                         height: 10)
                Sparkline(values: store.swapHistory, color: Palette.warning, height: 50)
                Text(L("Đường trên là tổng số trang swap vào và ra mỗi giây. Swap đã cấp phát mà đứng yên thì vô hại; chỉ khi tốc độ này duy trì cao máy mới thực sự chậm."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Disk

struct DiskView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        VStack(spacing: 16) {
            Card(title: L("Thông lượng I/O"), systemImage: "arrow.up.arrow.down",
                 accessory: String(format: "%.0f IOPS", store.disk.readIOPS + store.disk.writeIOPS)) {
                HStack(spacing: 16) {
                    MetricTile(title: L("Đọc"), value: Fmt.rate(store.disk.readRate),
                               sub: String(format: "%.0f IOPS", store.disk.readIOPS), color: Palette.read)
                    MetricTile(title: L("Ghi"), value: Fmt.rate(store.disk.writeRate),
                               sub: String(format: "%.0f IOPS", store.disk.writeIOPS), color: Palette.write)
                }
                Sparkline(values: store.diskReadHistory, color: Palette.read, height: 50)
                Sparkline(values: store.diskWriteHistory, color: Palette.write, height: 50)
            }

            Card(title: L("Tổng cộng từ lúc khởi động"), systemImage: "sum") {
                VStack(spacing: 6) {
                    InfoRow(label: L("Đã đọc"), value: Fmt.bytes(store.disk.readBytes))
                    InfoRow(label: L("Đã ghi"), value: Fmt.bytes(store.disk.writeBytes))
                    InfoRow(label: L("Lượt đọc"), value: "\(store.disk.readOps)")
                    InfoRow(label: L("Lượt ghi"), value: "\(store.disk.writeOps)")
                }
            }

            Card(title: L("Phần cứng"), systemImage: "internaldrive.fill",
                 accessory: store.drives.count > 1 ? L("%d ổ", store.drives.count) : nil) {
                VStack(spacing: 12) {
                    ForEach(store.drives) { drive in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(drive.name).font(.system(size: 12, weight: .semibold))
                                if !drive.bsdName.isEmpty {
                                    Text("/dev/\(drive.bsdName)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(Fmt.bytes(drive.capacity))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                            HStack(spacing: 6) {
                                ForEach(drive.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary.opacity(0.6),
                                                    in: Capsule())
                                }
                            }
                            if !drive.serial.isEmpty {
                                InfoRow(label: L("Serial"), value: drive.serial)
                            }
                            if !drive.revision.isEmpty {
                                InfoRow(label: L("Firmware"), value: drive.revision)
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            Card(title: L("Phân vùng"), systemImage: "externaldrive") {
                VStack(spacing: 12) {
                    ForEach(store.volumes) { volume in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(volume.name).font(.system(size: 12, weight: .medium))
                                Text(volume.path).font(.system(size: 10)).foregroundStyle(.tertiary)
                                Spacer()
                                Text(L("còn %@", Fmt.bytes(volume.free)))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            MeterBar(fraction: volume.usedFraction,
                                     color: Palette.level(volume.usedFraction, base: Palette.read),
                                     height: 8)
                            Text(L("%@ đã dùng trên %@", Fmt.bytes(volume.used), Fmt.bytes(volume.total)))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let sub: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(sub).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Battery

/// Presentation of a battery reading, shared by the Battery tab and the
/// menu bar popover.
extension BatterySample {
    var statusText: String {
        if !isPluggedIn { return L("Đang dùng pin") }
        if isCharging { return L("Đang sạc") }
        if fullyCharged { return L("Đã sạc đầy") }
        return L("Cắm nguồn, không sạc")
    }

    var statusIcon: String {
        if !isPluggedIn { return "battery.75" }
        if isCharging { return "bolt.fill" }
        return "powerplug.fill"
    }

    var healthColor: Color {
        switch health {
        case ..<0.7: return Palette.critical
        case ..<0.8: return Palette.warning
        default: return Palette.memory
        }
    }

    var cycleFraction: Double {
        guard designCycleCount > 0 else { return 0 }
        return min(Double(cycleCount) / Double(designCycleCount), 1)
    }

    /// Share of the adapter's rating being drawn right now; 0 when unknown.
    var adapterLoad: Double {
        guard isPluggedIn, adapterWatts > 0 else { return 0 }
        return min(adapterPowerW / Double(adapterWatts), 1)
    }
}

struct BatteryView: View {
    @EnvironmentObject private var store: MonitorStore

    private var battery: BatterySample { store.battery }

    private var statusText: String { battery.statusText }
    private var statusIcon: String { battery.statusIcon }
    private var healthColor: Color { battery.healthColor }
    private var cycleFraction: Double { battery.cycleFraction }

    /// Charge is the headline: one big number beside a battery you can read
    /// across the room.
    private var hero: some View {
        HStack(spacing: 26) {
            BatteryGlyph(percentage: battery.percentage,
                         state: battery.powerState,
                         color: BatteryIcon.color(for: battery),
                         width: 190)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "%.0f%%", battery.percentage * 100))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BatteryIcon.color(for: battery))
                StatusPill(text: statusText, systemImage: statusIcon,
                           color: BatteryIcon.color(for: battery))
                if battery.timeRemaining > 0 {
                    Text((battery.isCharging ? L("Đầy sau ") : L("Còn dùng được "))
                         + Fmt.minutes(battery.timeRemaining))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.5), lineWidth: 1)
        )
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            StatTile(label: L("Dung lượng tối đa"), value: Fmt.percent(battery.health),
                     caption: battery.condition.isEmpty ? nil : battery.condition,
                     color: healthColor)
            StatTile(label: L("Chu kỳ sạc"), value: "\(battery.cycleCount)",
                     caption: battery.designCycleCount > 0 ? L("trên %d", battery.designCycleCount) : nil)
            StatTile(label: L("Máy đang dùng"), value: Self.watts(battery.systemPowerW),
                     caption: battery.isPluggedIn ? L("lấy từ cục sạc") : L("lấy từ pin"))
            StatTile(label: L("Dung lượng"), value: "\(battery.currentCapacity)",
                     caption: L("mAh hiện có"))
        }
    }

    static func watts(_ value: Double) -> String {
        String(format: value >= 10 ? "%.0f W" : "%.1f W", value)
    }

    private var chargingCaption: String {
        if battery.isCharging { return L("đang nạp vào pin") }
        return battery.isPluggedIn ? L("đang không sạc") : L("đang dùng pin")
    }

    /// Where the adapter's power goes besides the machine (whose draw is the
    /// headline tile above), and how hard the adapter is working.
    @ViewBuilder
    private var powerFlow: some View {
        HStack(spacing: 10) {
            StatTile(label: L("Sạc vào pin"), value: Self.watts(battery.chargingPowerW),
                     caption: chargingCaption,
                     color: battery.isCharging ? Palette.memory : .primary)
            if battery.isPluggedIn {
                StatTile(label: L("Cục sạc tối đa"),
                         value: battery.adapterWatts > 0 ? "\(battery.adapterWatts) W" : "—",
                         caption: battery.adapterPowerW > 0
                            ? L("đang cấp %@", Self.watts(battery.adapterPowerW))
                            : nil)
            }
        }
        if battery.isPluggedIn, battery.adapterWatts > 0, battery.adapterPowerW > 0 {
            let load = min(battery.adapterPowerW / Double(battery.adapterWatts), 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Mức dùng cục sạc"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "\(Self.watts(battery.adapterPowerW)) / \(battery.adapterWatts) W")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                MeterBar(fraction: load, color: Palette.level(load, base: Palette.memory), height: 10)
            }
        }
    }

    var body: some View {
        if !battery.isPresent {
            Card(title: L("Pin"), systemImage: "battery.slash") {
                Text(L("Máy này không có pin."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 16) {
                hero
                tiles

                Card(title: L("Sức khỏe pin"), systemImage: "heart.text.square",
                     accessory: battery.condition) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(battery.maximumCapacityPercent > 0
                                 ? L("Dung lượng tối đa theo macOS")
                                 : L("Dung lượng tối đa (ước tính)"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.percent(battery.health))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(healthColor)
                        }
                        MeterBar(fraction: battery.health, color: healthColor, height: 10)
                        // Verbatim, otherwise SwiftUI localises the integers and
                        // prints a thousands separator.
                        Text(verbatim: L("Sạc đầy %d mAh trên thiết kế %d mAh", battery.maxCapacity, battery.designCapacity))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    if battery.designCycleCount > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(L("Chu kỳ sạc đã dùng"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Text(verbatim: "\(battery.cycleCount) / \(battery.designCycleCount)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            MeterBar(fraction: cycleFraction,
                                     color: Palette.level(cycleFraction, base: Palette.read),
                                     height: 10)
                        }
                    }
                }

                Card(title: L("Nguồn điện"), systemImage: "bolt") {
                    powerFlow
                    HStack(spacing: 10) {
                        StatTile(label: L("Điện áp"), value: String(format: "%.2f", battery.voltage),
                                 caption: L("volt"))
                        StatTile(label: L("Dòng điện"), value: String(format: "%.2f", battery.amperage),
                                 caption: battery.amperage >= 0 ? L("ampe, nạp vào") : L("ampe, xả ra"))
                        if battery.temperature > 0 {
                            StatTile(label: L("Nhiệt độ"),
                                     value: String(format: "%.0f°", battery.temperature),
                                     caption: L("celsius"))
                        }
                    }
                    if !battery.adapterName.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "powerplug.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.memory)
                            Text(battery.adapterName).font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

// MARK: - Network

struct NetworkView: View {
    @EnvironmentObject private var store: MonitorStore

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 16) {
            Card(title: L("Kết nối Internet"), systemImage: "wifi",
                 accessory: L(store.connectivity.interfaceKind)) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(ConnectivityStyle.color(store.connectivity.status))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                    Text(ConnectivityStyle.label(store.connectivity.status))
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    if let checked = store.connectivity.lastChecked {
                        Text(L("kiểm tra lúc %@", Self.clock.string(from: checked)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                VStack(spacing: 6) {
                    InfoRow(label: L("IP ra Internet"),
                            value: store.connectivity.publicIP.isEmpty ? "—" : store.connectivity.publicIP,
                            copyable: !store.connectivity.publicIP.isEmpty)
                    InfoRow(label: L("IP nội bộ"),
                            value: store.connectivity.localIP.isEmpty ? "—" : store.connectivity.localIP,
                            copyable: !store.connectivity.localIP.isEmpty)
                    if !store.connectivity.routeDescription.isEmpty {
                        InfoRow(label: L("Đường ra"), value: store.connectivity.routeDescription)
                    }
                }
                if store.connectivity.isTunnelled {
                    Text(L("Đang đi qua VPN, nên IP ra Internet là IP của điểm thoát VPN chứ không phải của nhà mạng."))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.warning)
                }
                Text(L("Trạng thái dựa trên NWPathMonitor cộng một lần gọi HTTP tới 1.1.1.1 của Cloudflare mỗi 60 giây — đó cũng là chỗ lấy IP ra Internet."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Card(title: L("Băng thông"), systemImage: "network") {
                HStack(spacing: 16) {
                    MetricTile(title: L("Nhận"), value: Fmt.rate(store.network.inRate),
                               sub: L("từ lúc mở app %@", Fmt.bytes(store.network.inBytes)), color: Palette.netIn)
                    MetricTile(title: L("Gửi"), value: Fmt.rate(store.network.outRate),
                               sub: L("từ lúc mở app %@", Fmt.bytes(store.network.outBytes)), color: Palette.netOut)
                }
                Sparkline(values: store.netInHistory, color: Palette.netIn, height: 50)
                Sparkline(values: store.netOutHistory, color: Palette.netOut, height: 50)
            }
        }
    }
}

// MARK: - Processes

struct ProcessesView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        Card(title: L("Tiến trình tốn CPU nhất"), systemImage: "list.bullet.rectangle",
             accessory: L("cập nhật mỗi 3 chu kỳ")) {
            VStack(spacing: 0) {
                HStack {
                    Text(L("PID")).frame(width: 60, alignment: .leading)
                    Text(L("Tên")).frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU").frame(width: 70, alignment: .trailing)
                    Text("RAM").frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

                ForEach(store.processes) { process in
                    HStack {
                        // Verbatim, or SwiftUI adds a thousands separator to the PID.
                        Text(verbatim: "\(process.pid)")
                            .frame(width: 60, alignment: .leading)
                            .foregroundStyle(.tertiary)
                        Text(process.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(String(format: "%.1f%%", process.cpu))
                            .frame(width: 70, alignment: .trailing)
                            .foregroundStyle(process.cpu > 50 ? Palette.critical : .primary)
                        Text(Fmt.bytes(process.memory))
                            .frame(width: 80, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.vertical, 4)
                    .background(alignment: .leading) {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Palette.cpu.opacity(0.12))
                                .frame(width: geo.size.width * CGFloat(min(process.cpu / 100, 1)))
                        }
                    }
                }
            }
        }
    }
}

/// Whether the main window can currently be seen by the user.
@MainActor
final class WindowVisibility: ObservableObject {
    @Published var isVisible = true
}

/// Reports the hosting window's visibility: occlusion covers being behind
/// other windows, on another Space or on a sleeping display; miniaturising is
/// checked separately because the Dock copy still counts as visible.
struct WindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification]
            tokens = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) {
                    [weak self] _ in self?.report()
                }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
            onChange?(visible)
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
