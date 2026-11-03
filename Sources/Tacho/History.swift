import Foundation
import SwiftUI
import Charts

/// One minute of the machine, averaged. A day of these is ~1,440 points, a
/// few hundred KB on disk.
struct HistoryPoint: Codable {
    let time: Date
    let cpu: Double          // 0...1, average over the minute
    let cpuPeak: Double      // 0...1, busiest sample in the minute
    let temperature: Double? // °C
    let pressure: Double     // memory pressure 0...1
    let netIn: Double        // bytes/s
    let netOut: Double
    let battery: Double?     // 0...1, last reading of the minute
}

/// Folds the per-second samples into per-minute points, keeps the last 24
/// hours, and saves them so the history survives a restart.
@MainActor
final class HistoryRecorder: ObservableObject {

    enum Range: String, CaseIterable, Identifiable {
        case hour, day
        var id: String { rawValue }
        var seconds: TimeInterval { self == .hour ? 3600 : 86_400 }
        var title: String { self == .hour ? L("1 giờ") : L("24 giờ") }
        /// A day is drawn in 5-minute steps: 1,440 points are more than a
        /// chart can show, and slow to draw.
        var bucket: TimeInterval { self == .hour ? 60 : 300 }
    }

    @Published private(set) var points: [HistoryPoint] = []
    @Published var range: Range = .hour

    private static let keep: TimeInterval = 86_400
    private let file: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("Tacho", isDirectory: true).appendingPathComponent("history.json")
    }()

    // The minute being collected.
    private var minute: Date?
    private var count = 0
    private var cpuSum = 0.0, cpuPeak = 0.0
    private var temperatureSum = 0.0, temperatureCount = 0
    private var pressureSum = 0.0, inSum = 0.0, outSum = 0.0
    private var battery: Double?
    private var unsaved = 0

    init() {
        load()
    }

    func start(store: MonitorStore) {
        store.onEachSample { [weak self, weak store] in
            guard let self, let store else { return }
            self.record(store)
        }
    }

    private func record(_ store: MonitorStore) {
        let now = Date()
        let current = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        if let minute, minute != current { finish(minute) }
        if minute != current { minute = current }

        count += 1
        cpuSum += store.cpu.busy
        cpuPeak = max(cpuPeak, store.cpu.busy)
        if store.temperature.isPresent {
            temperatureSum += store.temperature.cpuAverage
            temperatureCount += 1
        }
        pressureSum += store.memory.pressure
        inSum += store.network.inRate
        outSum += store.network.outRate
        battery = store.battery.isPresent ? store.battery.percentage : nil
    }

    private func finish(_ minute: Date) {
        guard count > 0 else { return }
        let n = Double(count)
        points.append(HistoryPoint(time: minute, cpu: cpuSum / n, cpuPeak: cpuPeak,
                                   temperature: temperatureCount > 0 ? temperatureSum / Double(temperatureCount) : nil,
                                   pressure: pressureSum / n, netIn: inSum / n, netOut: outSum / n,
                                   battery: battery))
        let cutoff = Date().addingTimeInterval(-Self.keep)
        if let first = points.first, first.time < cutoff {
            points.removeAll { $0.time < cutoff }
        }
        count = 0
        cpuSum = 0; cpuPeak = 0
        temperatureSum = 0; temperatureCount = 0
        pressureSum = 0; inSum = 0; outSum = 0

        // Losing up to ten minutes in a crash is fine; writing every minute
        // would wake the disk for nothing.
        unsaved += 1
        if unsaved >= 10 { save() }
    }

    func save() {
        guard let file else { return }
        unsaved = 0
        let points = self.points
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(points) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// On quit: also keeps the half-finished minute.
    func saveNow() {
        if let minute { finish(minute) }
        minute = nil
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(points) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func load() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode([HistoryPoint].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.keep)
        points = stored.filter { $0.time >= cutoff }
    }

    // MARK: For the charts

    /// Points in the chosen range, merged into the range's step, each tagged
    /// with a segment number that changes across gaps (the Mac was asleep or
    /// Tacho was not running), so the lines break there instead of bridging.
    func series() -> [ChartPoint] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let step = range.bucket
        var groups: [(Date, [HistoryPoint])] = []
        for point in points where point.time >= cutoff {
            let slot = Date(timeIntervalSince1970: floor(point.time.timeIntervalSince1970 / step) * step)
            if let last = groups.last, last.0 == slot {
                groups[groups.count - 1].1.append(point)
            } else {
                groups.append((slot, [point]))
            }
        }

        var segment = 0
        var previous: Date?
        return groups.map { slot, members in
            if let previous, slot.timeIntervalSince(previous) > step * 2.5 { segment += 1 }
            previous = slot
            let n = Double(members.count)
            let temperatures = members.compactMap(\.temperature)
            return ChartPoint(time: slot, segment: segment,
                              cpu: members.map(\.cpu).reduce(0, +) / n,
                              cpuPeak: members.map(\.cpuPeak).max() ?? 0,
                              temperature: temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count),
                              pressure: members.map(\.pressure).reduce(0, +) / n,
                              netIn: members.map(\.netIn).reduce(0, +) / n,
                              netOut: members.map(\.netOut).reduce(0, +) / n,
                              battery: members.last?.battery)
        }
    }
}

struct ChartPoint: Identifiable {
    var id: Date { time }
    let time: Date
    let segment: Int
    let cpu, cpuPeak: Double
    let temperature: Double?
    let pressure, netIn, netOut: Double
    let battery: Double?
}

// MARK: - View

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryRecorder

    var body: some View {
        let points = history.series()
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("", selection: $history.range) {
                    ForEach(HistoryRecorder.Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                Text(L("Trung bình mỗi phút, lưu 24 giờ gần nhất"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if points.count < 2 {
                Card(title: L("Lịch sử"), systemImage: "clock.arrow.circlepath") {
                    Text(L("Tacho đang ghi lại. Biểu đồ sẽ hiện sau vài phút."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            } else {
                cpuChart(points)
                if points.contains(where: { $0.temperature != nil }) { temperatureChart(points) }
                memoryChart(points)
                networkChart(points)
                if points.contains(where: { $0.battery != nil }) { batteryChart(points) }
            }
        }
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour().minute())
        }
    }

    private func summary(_ values: [Double], format: (Double) -> String) -> String {
        guard !values.isEmpty else { return "" }
        let average = values.reduce(0, +) / Double(values.count)
        return L("TB %@ · cao nhất %@", format(average), format(values.max() ?? 0))
    }

    private func cpuChart(_ points: [ChartPoint]) -> some View {
        Card(title: L("CPU"), systemImage: "cpu",
             accessory: summary(points.map(\.cpu)) { String(format: "%.0f%%", $0 * 100) }) {
            Chart(points) { point in
                AreaMark(x: .value("t", point.time), y: .value("cpu", point.cpu * 100),
                         series: .value("s", point.segment))
                    .foregroundStyle(Palette.cpu.opacity(0.35))
                LineMark(x: .value("t", point.time), y: .value("cpu", point.cpu * 100),
                         series: .value("s", point.segment))
                    .foregroundStyle(Palette.cpu)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
            .chartXAxis { timeAxis }
            .frame(height: 140)
        }
    }

    private func temperatureChart(_ points: [ChartPoint]) -> some View {
        let values = points.compactMap(\.temperature)
        return Card(title: L("Nhiệt độ"), systemImage: "thermometer.medium",
                    accessory: summary(values) { String(format: "%.0f°", $0) }) {
            Chart(points.filter { $0.temperature != nil }) { point in
                LineMark(x: .value("t", point.time), y: .value("°C", point.temperature ?? 0),
                         series: .value("s", point.segment))
                    .foregroundStyle(Palette.warning)
            }
            .chartYScale(domain: max(0, (values.min() ?? 30) - 5)...((values.max() ?? 90) + 5))
            .chartXAxis { timeAxis }
            .frame(height: 120)
        }
    }

    private func memoryChart(_ points: [ChartPoint]) -> some View {
        Card(title: L("Áp lực bộ nhớ"), systemImage: "memorychip",
             accessory: summary(points.map(\.pressure)) { String(format: "%.0f%%", $0 * 100) }) {
            Chart(points) { point in
                AreaMark(x: .value("t", point.time), y: .value("p", point.pressure * 100),
                         series: .value("s", point.segment))
                    .foregroundStyle(Palette.memory.opacity(0.35))
                LineMark(x: .value("t", point.time), y: .value("p", point.pressure * 100),
                         series: .value("s", point.segment))
                    .foregroundStyle(Palette.memory)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
            .chartXAxis { timeAxis }
            .frame(height: 120)
        }
    }

    private func networkChart(_ points: [ChartPoint]) -> some View {
        Card(title: L("Mạng"), systemImage: "network",
             accessory: summary(points.map(\.netIn)) { Fmt.rate($0) }) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("t", point.time), y: .value("B/s", point.netIn),
                             series: .value("s", "in\(point.segment)"))
                        .foregroundStyle(Palette.netIn)
                    LineMark(x: .value("t", point.time), y: .value("B/s", point.netOut),
                             series: .value("s", "out\(point.segment)"))
                        .foregroundStyle(Palette.netOut)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Fmt.compact(value.as(Double.self) ?? 0)) }
                }
            }
            .chartXAxis { timeAxis }
            .frame(height: 120)
            HStack(spacing: 14) {
                Legend(label: L("Nhận"), value: "", color: Palette.netIn).frame(width: 120)
                Legend(label: L("Gửi"), value: "", color: Palette.netOut).frame(width: 120)
            }
        }
    }

    private func batteryChart(_ points: [ChartPoint]) -> some View {
        let values = points.compactMap(\.battery)
        return Card(title: L("Pin"), systemImage: "battery.75percent",
                    accessory: values.last.map { String(format: "%.0f%%", $0 * 100) }) {
            Chart(points.filter { $0.battery != nil }) { point in
                LineMark(x: .value("t", point.time), y: .value("%", (point.battery ?? 0) * 100),
                         series: .value("s", point.segment))
                    .foregroundStyle(Palette.memory)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
            .chartXAxis { timeAxis }
            .frame(height: 120)
        }
    }
}
