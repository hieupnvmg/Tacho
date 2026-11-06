import SwiftUI
import AppKit

// MARK: - Palette

enum Palette {
    static let cpu = Color(red: 0.31, green: 0.56, blue: 0.95)
    /// The two CPU clusters are categories, so they get two hues, not a ramp.
    static let corePerformance = Color(red: 0.31, green: 0.56, blue: 0.95)
    static let coreEfficiency = Color(red: 0.25, green: 0.78, blue: 0.75)
    static let gpu = Color(red: 0.56, green: 0.50, blue: 0.88)
    static let cpuSystem = Color(red: 0.95, green: 0.55, blue: 0.29)
    static let memory = Color(red: 0.45, green: 0.74, blue: 0.44)
    static let read = Color(red: 0.36, green: 0.73, blue: 0.84)
    static let write = Color(red: 0.86, green: 0.47, blue: 0.62)
    static let netIn = Color(red: 0.56, green: 0.50, blue: 0.88)
    static let netOut = Color(red: 0.93, green: 0.72, blue: 0.33)
    static let warning = Color(red: 0.93, green: 0.64, blue: 0.25)
    static let critical = Color(red: 0.89, green: 0.35, blue: 0.35)

    /// Matches Activity Monitor: the kernel's pressure level picks the colour,
    /// not the height of the graph.
    static func pressure(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return memory
        case .warning: return warning
        case .critical: return critical
        }
    }

    /// Die temperature: green while cool, amber once warm, red when hot.
    static func temperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<70: return memory
        case ..<90: return warning
        default: return critical
        }
    }

    /// Cool-to-hot ramp along a temperature scale, for gauges.
    static let thermalRamp = [read, memory, warning, critical]
    /// Fan speed from idle to flat out. A fast fan is not a fault, so this
    /// ramp stays cool and only warms near the top.
    static let fanRamp = [read, cpu, gpu, warning]

    static func fan(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.35: return read
        case ..<0.7: return cpu
        case ..<0.9: return gpu
        default: return warning
        }
    }

    static func level(_ fraction: Double, base: Color) -> Color {
        switch fraction {
        case ..<0.7: return base
        case ..<0.9: return warning
        default: return critical
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    var accessory: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if let accessory {
                    Text(accessory)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var normalizeToOne = false
    var height: CGFloat = 44

    private var maxValue: Double {
        if normalizeToOne { return 1 }
        return max(values.max() ?? 1, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let maxV = maxValue
            // Spread whatever history exists across the whole box. Reserving all
            // 90 slots leaves the chart nearly empty for the first 90 seconds.
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { index, value -> CGPoint in
                let y = geo.size.height * (1 - CGFloat(min(value / maxV, 1)))
                return CGPoint(x: CGFloat(index) * step, y: y)
            }

            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Bars

struct MeterBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)), fraction > 0 ? 2 : 0))
            }
        }
        .frame(height: height)
    }
}

/// A horizontal bar made of several proportional segments.
struct StackedBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: total > 0 ? geo.size.width * CGFloat(segment.value / total) : 0)
                }
                Rectangle().fill(.quaternary.opacity(0.45))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: height)
    }
}

struct Legend: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Ring gauge

struct RingGauge: View {
    let fraction: Double
    let color: Color
    let caption: String
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary.opacity(0.5), lineWidth: 9)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // No animation: a new value lands every second, and easing it
                // redraws the window at display refresh rate (see CoreRing).
            VStack(spacing: 1) {
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: 9, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Connectivity

/// A 270° dial. The arc is painted with the whole `ramp`, so the colour at
/// its tip says where on the scale the value sits.
struct ArcGauge: View {
    let fraction: Double
    let ramp: [Color]
    let value: String
    var valueColor: Color = .primary
    let caption: String
    var scale: (low: String, high: String)? = nil
    var size: CGFloat = 116

    private var lineWidth: CGFloat { size * 0.085 }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(.quaternary.opacity(0.55),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * CGFloat(min(max(fraction, 0), 1)))
                .stroke(AngularGradient(colors: ramp,
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: size * (value.count >= 4 ? 0.23 : 0.3),
                                  weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(caption)
                    .font(.system(size: max(size * 0.08, 8), weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            .offset(y: size * 0.03)
            // Scale ends sit in the gap at the bottom of the dial.
            if let scale {
                HStack {
                    Text(verbatim: scale.low)
                    Spacer()
                    Text(verbatim: scale.high)
                }
                .font(.system(size: max(size * 0.07, 8), design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, size * 0.2)
                .offset(y: size * 0.47)
            }
        }
        .frame(width: size, height: size)
    }
}

struct TemperatureGauge: View {
    let celsius: Double
    var caption = L("trung bình")
    var size: CGFloat = 116

    var body: some View {
        ArcGauge(fraction: TemperatureSample.fraction(celsius),
                 ramp: Palette.thermalRamp,
                 value: String(format: "%.0f°", celsius),
                 valueColor: Palette.temperature(celsius),
                 caption: caption,
                 scale: ("\(Int(TemperatureSample.scale.lowerBound))°",
                         "\(Int(TemperatureSample.scale.upperBound))°"),
                 size: size)
    }
}

/// A bar filled along a colour ramp up to `fraction`, the ramp faintly
/// visible behind it so the scale reads even when the bar is short.
struct RampBar: View {
    let fraction: Double
    let ramp: [Color]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let gradient = LinearGradient(colors: ramp, startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(gradient).opacity(0.18)
                Capsule().fill(gradient)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)),
                                                   fraction > 0 ? height : 0))
                    }
            }
        }
        .frame(height: height)
    }
}

/// Where every sensor sits on the scale: the band spans coolest to hottest,
/// the dot marks the average.
struct ThermalSpreadBar: View {
    let coolest: Double
    let average: Double
    let hottest: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let low = width * CGFloat(TemperatureSample.fraction(coolest))
            let high = width * CGFloat(TemperatureSample.fraction(hottest))
            let mid = width * CGFloat(TemperatureSample.fraction(average))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: Palette.thermalRamp,
                                         startPoint: .leading, endPoint: .trailing))
                    .opacity(0.22)
                Capsule()
                    .fill(LinearGradient(colors: Palette.thermalRamp,
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: max(high - low, height))
                            .offset(x: low)
                    }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                    .frame(width: height + 4, height: height + 4)
                    .offset(x: min(max(mid - (height + 4) / 2, 0), width - height - 4))
            }
        }
        .frame(height: height + 4)
    }
}

enum ConnectivityStyle {
    static func color(_ status: ConnectivityStatus) -> Color {
        switch status {
        case .online: return Palette.memory
        case .offline: return Palette.critical
        case .pending: return Palette.warning
        }
    }

    static func label(_ status: ConnectivityStatus) -> String {
        switch status {
        case .online: return L("Có Internet")
        case .offline: return L("Mất mạng")
        case .pending: return L("Đang kiểm tra")
        }
    }
}

// MARK: - Battery glyph

/// A drawn battery, filled to the current charge. Reads at a glance in a way a
/// row of numbers does not.
struct BatteryGlyph: View {
    let percentage: Double
    let state: BatteryPowerState
    let color: Color
    var width: CGFloat = 190

    private var overlaySymbol: String? {
        switch state {
        case .charging: return "bolt.fill"
        case .pluggedNotCharging: return "powerplug.fill"
        case .onBattery: return nil
        }
    }

    private var height: CGFloat { width * 0.44 }
    private var corner: CGFloat { width * 0.07 }
    private var wall: CGFloat { max(width * 0.011, 1.5) }
    private var inset: CGFloat { wall * 2.2 }

    var body: some View {
        HStack(spacing: width * 0.013) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.tertiary, lineWidth: wall)

                RoundedRectangle(cornerRadius: max(corner - inset, 1.5), style: .continuous)
                    .fill(color)
                    .padding(inset)
                    .frame(width: max((width - inset * 2) * CGFloat(clamped) + inset * 2,
                                      inset * 2 + 2),
                           alignment: .leading)
                    .animation(.easeOut(duration: 0.3), value: clamped)

                if let overlaySymbol {
                    Image(systemName: overlaySymbol)
                        .font(.system(size: height * 0.38, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                        .frame(width: width, alignment: .center)
                }
            }
            .frame(width: width, height: height)

            // Terminal cap, kept close enough to read as part of the battery.
            RoundedRectangle(cornerRadius: wall, style: .continuous)
                .fill(.tertiary)
                .frame(width: width * 0.028, height: height * 0.42)
        }
    }

    private var clamped: Double { min(max(percentage, 0), 1) }
}

// MARK: - Stat tile and status pill

/// One headline figure. Big number, quiet label — the opposite of a dense row.
struct StatTile: View {
    let label: String
    let value: String
    var caption: String? = nil
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Status always carries its own label, never colour alone.
struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Key/value row

struct InfoRow: View {
    let label: String
    let value: String
    /// Adds a copy button after the value, for things people paste elsewhere
    /// (IP addresses).
    var copyable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            if copyable {
                CopyButton(text: value)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
    }
}

/// Copies `text` to the clipboard and turns into a green tick for a moment,
/// so the click visibly did something.
struct CopyButton: View {
    let text: String
    @StateObject private var feedback = CopyFeedback()

    var body: some View {
        Button {
            feedback.copy(text)
        } label: {
            Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(feedback.copied ? Palette.memory : Color.secondary)
                .frame(width: 20, height: 18)
                .background(.quaternary.opacity(feedback.copied ? 0 : 0.5),
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(feedback.copied ? L("Đã copy") : "Copy \(text)")
    }
}

/// Lives in a class because `@State` is unavailable with only the Command
/// Line Tools (see `MonitorSection`).
@MainActor
final class CopyFeedback: ObservableObject {
    @Published private(set) var copied = false
    private var reset: DispatchWorkItem?

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        reset?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copied = false }
        reset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// Warning colours for text in the menu bar. The palette's amber and red are
/// light enough to vanish on a light menu bar at nine or ten points, so a
/// light menu bar gets deeper tones; a dark one keeps the palette's.
enum MenuBarText {
    static let warning = adaptive(light: NSColor(red: 0.80, green: 0.38, blue: 0.0, alpha: 1),
                                  dark: NSColor(Palette.warning))
    static let critical = adaptive(light: NSColor(red: 0.82, green: 0.13, blue: 0.13, alpha: 1),
                                   dark: NSColor(Palette.critical))

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
