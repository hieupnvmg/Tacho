import AppKit
import SwiftUI

/// Draws one menu bar readout. SwiftUI's `MenuBarExtra` label can only show a
/// static symbol or string, so the live graphs are drawn by hand here.
final class StatusItemView: NSView {

    let module: MenuBarModule
    weak var store: MonitorStore?
    var showGraph = true {
        didSet { drawnSignature = nil }
    }

    /// What was on screen at the last draw. macOS snapshots a status item for
    /// every menu bar it appears in each time it redraws, which costs far more
    /// than the drawing itself, so unchanged items are not redrawn at all.
    ///
    /// Deliberately no `viewDidChangeEffectiveAppearance` hook clearing this:
    /// those snapshots switch the view's appearance per display, so the hook
    /// fired on every snapshot and redrew every item ~11 times a second.
    /// AppKit already redraws a view whose appearance really changes.
    private var drawnSignature: String?

    private let graphWidth: CGFloat = 26
    private let spacing: CGFloat = 4

    init(module: MenuBarModule, store: MonitorStore) {
        self.module = module
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Clicks belong to the status item button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }


    // MARK: Fonts

    // Built once: creating a system font and converting a SwiftUI colour are
    // both slow enough to show up when six items redraw every second.
    private static let singleLine = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let doubleLine = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let colors: [String: NSColor] = [
        "cpu": NSColor(Palette.cpu), "gpu": NSColor(Palette.gpu),
        "read": NSColor(Palette.read), "write": NSColor(Palette.write),
        "netIn": NSColor(Palette.netIn), "netOut": NSColor(Palette.netOut),
        "memory": NSColor(Palette.memory), "warning": NSColor(Palette.warning),
        "critical": NSColor(Palette.critical),
    ]

    private static func color(_ name: String) -> NSColor { colors[name] ?? .labelColor }

    private static func pressureColor(_ level: MemoryPressureLevel) -> NSColor {
        switch level {
        case .normal: return color("memory")
        case .warning: return color("warning")
        case .critical: return color("critical")
        }
    }

    private var singleLineFont: NSFont { Self.singleLine }
    private var doubleLineFont: NSFont { Self.doubleLine }

    private func attributes(_ font: NSFont, _ color: NSColor = .labelColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    // MARK: Content

    /// The strings to draw: one entry renders centred, two render stacked.
    private var lines: [String] {
        guard let store else { return [] }
        switch module {
        case .cpu:
            return [String(format: "%.0f%%", store.cpu.busy * 100)]
        case .gpu:
            return [String(format: "%.0f%%", store.gpu.utilization * 100)]
        case .memory:
            return [String(format: "%.0f%%", store.memory.pressure * 100)]
        case .disk:
            return ["R \(Fmt.compact(store.disk.readRate))",
                    "W \(Fmt.compact(store.disk.writeRate))"]
        case .network:
            return ["↓ \(Fmt.compact(store.network.inRate))",
                    "↑ \(Fmt.compact(store.network.outRate))"]
        case .connectivity:
            return []       // the dot says everything
        case .battery:
            return [String(format: "%.0f%%", store.battery.percentage * 100)]
        }
    }

    /// Drawn after a single-line value in its own colour: the CPU temperature.
    /// It stays the menu bar's text colour while cool and only turns amber or
    /// red when warm, so colour in the menu bar always means something.
    private var suffix: (text: String, color: NSColor)? {
        guard module == .cpu, let store, store.temperature.isPresent else { return nil }
        let celsius = store.temperature.cpuAverage
        let color: NSColor
        switch celsius {
        case ..<70: color = .secondaryLabelColor
        case ..<90: color = Self.color("warning")
        default: color = Self.color("critical")
        }
        return (String(format: " %.0f°", celsius), color)
    }

    /// History series drawn behind the text, newest on the right.
    private var graphSeries: [(values: [Double], color: NSColor)] {
        guard showGraph, let store else { return [] }
        switch module {
        case .cpu:
            return [(store.cpuHistory, Self.color("cpu"))]
        case .gpu:
            return [(store.gpuHistory, Self.color("gpu"))]
        case .memory:
            // Pressure, not the share of RAM in use: that is what tells you
            // whether the machine is actually struggling.
            return [(store.pressureHistory, Self.pressureColor(store.memory.pressureLevel))]
        case .disk:
            return [(store.diskReadHistory, Self.color("read")),
                    (store.diskWriteHistory, Self.color("write"))]
        case .network:
            return [(store.netInHistory, Self.color("netIn")),
                    (store.netOutHistory, Self.color("netOut"))]
        case .battery, .connectivity:
            return []
        }
    }

    /// CPU and memory are already 0...1; rates are scaled to their own peak.
    private var graphIsNormalised: Bool {
        module == .cpu || module == .memory || module == .gpu
    }

    private var drawsBattery: Bool { module == .battery }
    private var drawsDot: Bool { module == .connectivity }

    private let dotDiameter: CGFloat = 9

    /// Green reachable, red offline, amber still checking.
    private func drawConnectivityDot(at center: NSPoint) {
        guard let store else { return }
        let color: NSColor
        switch store.connectivity.status {
        case .online: color = Self.color("memory")
        case .offline: color = Self.color("critical")
        case .pending: color = Self.color("warning")
        }

        let rect = NSRect(x: center.x - dotDiameter / 2, y: center.y - dotDiameter / 2,
                          width: dotDiameter, height: dotDiameter)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        // A faint ring keeps the dot visible against a same-coloured wallpaper.
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -0.75, dy: -0.75))
        ring.lineWidth = 1
        ring.stroke()
    }

    private let batterySize = NSSize(width: 24, height: 11)

    /// A battery drawn by hand: an SF Symbol cannot show the actual charge
    /// level, only one of five fixed steps.
    private func drawBattery(at origin: NSPoint) {
        guard let store else { return }
        let battery = store.battery
        let body = NSRect(origin: origin, size: batterySize)
        let radius: CGFloat = 3

        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.55).setStroke()
        outline.stroke()

        let cap = NSRect(x: body.maxX + 1, y: body.midY - 2.2, width: 1.8, height: 4.4)
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: cap, xRadius: 0.9, yRadius: 0.9).fill()

        let inner = body.insetBy(dx: 2.2, dy: 2.2)
        let fraction = min(max(battery.percentage, 0), 1)
        let fillWidth = max(inner.width * CGFloat(fraction), fraction > 0 ? 1.5 : 0)
        if fillWidth > 0 {
            let fill = NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height)
            NSColor(BatteryIcon.color(for: battery)).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.4, yRadius: 1.4).fill()
        }

        // The overlay is what distinguishes the three states at a glance;
        // without it a plugged-in full battery looks the same as one on its own.
        let overlay: String?
        switch battery.powerState {
        case .charging: overlay = "bolt.fill"
        case .pluggedNotCharging: overlay = "powerplug.fill"
        case .onBattery: overlay = nil
        }

        if let name = overlay,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            symbol.isTemplate = true
            let side: CGFloat = 8
            let rect = NSRect(x: body.midX - side / 2, y: body.midY - side / 2,
                              width: side, height: side)
            NSColor.labelColor.set()
            symbol.draw(in: rect)
        }
    }

    // MARK: Redraw

    /// Marks the view for redrawing only if what it shows has changed, down to
    /// the pixel row each graph sample lands on. Returns whether it will redraw.
    @discardableResult
    func redrawIfChanged() -> Bool {
        let signature = contentSignature
        guard signature != drawnSignature else { return false }
        drawnSignature = signature
        needsDisplay = true
        return true
    }

    /// Forgets what was drawn, so the next `redrawIfChanged` draws again.
    func invalidateDrawing() {
        drawnSignature = nil
    }

    private var contentSignature: String {
        guard let store else { return "" }
        var parts = lines
        if let suffix { parts.append(suffix.text + suffix.color.description) }
        switch module {
        case .connectivity: parts.append("\(store.connectivity.status)")
        case .battery:
            parts.append("\(store.battery.powerState) \(Int(store.battery.percentage * 100))")
        default: break
        }
        let height = Int(bounds.height - 6)
        for entry in graphSeries {
            let values = visibleSamples(entry.values)
            let ceiling = graphCeiling(graphSeries)
            parts.append(values.map { String(Int((min(max($0 / ceiling, 0), 1)) * Double(height))) }
                            .joined(separator: ","))
            parts.append(entry.color.description)
        }
        return parts.joined(separator: "|")
    }

    /// One sample per pixel column: older samples would be squeezed into
    /// sub-pixel steps nobody can see, yet still force a redraw.
    private func visibleSamples(_ values: [Double]) -> ArraySlice<Double> {
        values.suffix(Int(graphWidth))
    }

    /// A shared ceiling keeps the two rate curves comparable to each other.
    private func graphCeiling(_ series: [(values: [Double], color: NSColor)]) -> Double {
        guard !graphIsNormalised else { return 1 }
        let peak = series.flatMap { visibleSamples($0.values) }.max() ?? 1
        return peak > 0 ? peak : 1
    }

    // MARK: Layout

    /// The widest text each readout can show. Sizing to it keeps the item a
    /// fixed width: a status item that changes length makes macOS lay out the
    /// whole menu bar again in another process, and the icons jitter.
    private var widestLines: [String] {
        switch module {
        case .cpu, .gpu, .memory, .battery: return ["100%"]
        case .disk: return ["R 1023K", "W 1023K"]
        case .network: return ["↓ 1023K", "↑ 1023K"]
        case .connectivity: return []
        }
    }

    private var textWidth: CGFloat {
        let font = lines.count > 1 ? doubleLineFont : singleLineFont
        func widest(_ strings: [String]) -> CGFloat {
            strings.map { ($0 as NSString).size(withAttributes: attributes(font)).width }.max() ?? 0
        }
        var width = max(widest(lines), widest(widestLines))
        if suffix != nil {
            width += (" 100°" as NSString).size(withAttributes: attributes(font)).width
        }
        return width
    }

    var preferredWidth: CGFloat {

        if drawsDot { return dotDiameter + 12 }

        var width = ceil(textWidth)
        if !graphSeries.isEmpty { width += graphWidth + spacing }
        if drawsBattery { width += batterySize.width + 3 + spacing }
        return max(width + 8, 24)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if drawsDot {
            drawConnectivityDot(at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }

        var x: CGFloat = 4

        if drawsBattery {
            drawBattery(at: NSPoint(x: x, y: (bounds.height - batterySize.height) / 2))
            x += batterySize.width + 3 + spacing
        }

        let series = graphSeries
        if !series.isEmpty {
            drawGraph(series, in: NSRect(x: x, y: 3, width: graphWidth, height: bounds.height - 6))
            x += graphWidth + spacing
        }

        drawText(from: x)
    }

    private func drawText(from x: CGFloat) {
        let lines = self.lines
        guard !lines.isEmpty else { return }

        if lines.count == 1 {
            // Right-aligned in the reserved width, so digits stay put as the
            // value grows from "9%" to "10%".
            let attrs = attributes(singleLineFont)
            let size = (lines[0] as NSString).size(withAttributes: attrs)
            let suffixAttrs = suffix.map { attributes(singleLineFont, $0.color) }
            let suffixWidth = suffix.map { ($0.text as NSString).size(withAttributes: suffixAttrs!).width } ?? 0
            let start = max(x, bounds.width - 4 - suffixWidth - size.width)
            let y = (bounds.height - size.height) / 2
            (lines[0] as NSString).draw(at: NSPoint(x: start, y: y), withAttributes: attrs)
            if let suffix, let suffixAttrs {
                (suffix.text as NSString).draw(at: NSPoint(x: start + size.width, y: y),
                                               withAttributes: suffixAttrs)
            }
            return
        }

        // Two stacked rows, mirroring how iStat shows up/down rates.
        let attrs = attributes(doubleLineFont, .labelColor)
        let lineHeight = (lines[0] as NSString).size(withAttributes: attrs).height
        let total = lineHeight * CGFloat(lines.count)
        var y = (bounds.height - total) / 2
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            y += lineHeight
        }
    }

    private func drawGraph(_ series: [(values: [Double], color: NSColor)], in rect: NSRect) {
        let ceiling = graphCeiling(series)

        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        for entry in series {
            let values = Array(visibleSamples(entry.values))
            guard values.count > 1 else { continue }

            // Stretch the available samples across the box so it is never a
            // mostly-empty rectangle while history is still filling up.
            let step = rect.width / CGFloat(max(values.count - 1, 1))

            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            for (index, value) in values.enumerated() {
                let x = rect.minX + CGFloat(index) * step
                let fraction = min(max(value / ceiling, 0), 1)
                path.line(to: NSPoint(x: x, y: rect.maxY - rect.height * CGFloat(fraction)))
            }
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()

            entry.color.withAlphaComponent(0.75).setFill()
            path.fill()
        }
    }
}
