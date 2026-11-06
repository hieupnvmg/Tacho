import AppKit
import SwiftUI

/// Every enabled readout in one menu bar item: a column each, a small label
/// over its value, with the column's recent history drawn faintly behind the
/// text. On a notched MacBook the menu bar runs out of room fast, and one item
/// is also one snapshot for macOS instead of six.
final class CompactStatusView: NSView {

    weak var store: MonitorStore?
    var modules: [MenuBarModule] = [] {
        didSet { layoutColumns() }
    }
    var showGraph = true {
        didSet { drawnSignature = nil }
    }

    /// Where each column sits, for clicks and popover placement.
    private(set) var columns: [(module: MenuBarModule, frame: NSRect)] = []
    private var drawnSignature: String?

    private static let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    // Converted once: turning a SwiftUI colour into an NSColor is slow enough
    // to matter when it happens every second.
    private static let warning = MenuBarText.warning
    private static let critical = MenuBarText.critical
    private static let good = NSColor(Palette.memory)
    private static let cpu = NSColor(Palette.cpu)
    private static let gpu = NSColor(Palette.gpu)
    private static let read = NSColor(Palette.read)
    private static let write = NSColor(Palette.write)
    private static let netIn = NSColor(Palette.netIn)
    private static let netOut = NSColor(Palette.netOut)

    private let gap: CGFloat = 4
    private let inset: CGFloat = 3
    /// Room between a column's edge and its text, so the graph shows around it.
    private let padding: CGFloat = 4
    private let dotDiameter: CGFloat = 7
    private let batterySize = NSSize(width: 21, height: 10)

    init(store: MonitorStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func module(atX x: CGFloat) -> MenuBarModule? {
        columns.first { x >= $0.frame.minX - gap / 2 && x < $0.frame.maxX + gap / 2 }?.module
            ?? columns.last?.module
    }

    // MARK: Content

    /// The two rows of one column, top then bottom, each with its colour. The
    /// battery's top row is drawn as a glyph instead.
    private func rows(_ module: MenuBarModule) -> [(String, NSFont, NSColor)] {
        guard let store else { return [] }
        let label = NSColor.secondaryLabelColor
        switch module {
        case .cpu:
            var top = L("CPU")
            var topColor = label
            if store.temperature.isPresent {
                let celsius = store.temperature.cpuAverage
                top += String(format: " %.0f°", celsius)
                if celsius >= 90 { topColor = Self.critical } else if celsius >= 70 { topColor = Self.warning }
            }
            return [(top, Self.labelFont, topColor),
                    (String(format: "%.0f%%", store.cpu.busy * 100), Self.valueFont, .labelColor)]
        case .gpu:
            return [(L("GPU"), Self.labelFont, label),
                    (String(format: "%.0f%%", store.gpu.utilization * 100), Self.valueFont, .labelColor)]
        case .memory:
            return [(L("RAM"), Self.labelFont, label),
                    (String(format: "%.0f%%", store.memory.pressure * 100), Self.valueFont,
                     store.memory.pressureLevel == .normal ? .labelColor : pressureColor)]
        case .disk:
            return [("R \(Fmt.compact(store.disk.readRate))", Self.rateFont, .labelColor),
                    ("W \(Fmt.compact(store.disk.writeRate))", Self.rateFont, .labelColor)]
        case .network:
            return [("↓ \(Fmt.compact(store.network.inRate))", Self.rateFont, .labelColor),
                    ("↑ \(Fmt.compact(store.network.outRate))", Self.rateFont, .labelColor)]
        case .connectivity:
            return []
        case .battery:
            let battery = store.battery
            let color: NSColor = !battery.isPluggedIn && battery.percentage <= 0.2 ? Self.critical : .labelColor
            return [("", Self.labelFont, label),
                    (String(format: "%.0f%%", battery.percentage * 100), Self.valueFont, color)]
        }
    }

    private var pressureColor: NSColor {
        switch store?.memory.pressureLevel ?? .normal {
        case .normal: return Self.good
        case .warning: return Self.warning
        case .critical: return Self.critical
        }
    }

    /// History drawn behind a column's text, newest on the right.
    private func series(_ module: MenuBarModule) -> [(values: [Double], color: NSColor)] {
        guard showGraph, let store else { return [] }
        switch module {
        case .cpu: return [(store.cpuHistory, Self.cpu)]
        case .gpu: return [(store.gpuHistory, Self.gpu)]
        case .memory: return [(store.pressureHistory, pressureColor)]
        case .disk: return [(store.diskReadHistory, Self.read), (store.diskWriteHistory, Self.write)]
        case .network: return [(store.netInHistory, Self.netIn), (store.netOutHistory, Self.netOut)]
        case .connectivity, .battery: return []
        }
    }

    /// Percentages are already 0...1; rates share their own peak so the two
    /// curves stay comparable.
    private func ceiling(_ module: MenuBarModule, _ series: [(values: [Double], color: NSColor)],
                         samples: Int) -> Double {
        guard module == .disk || module == .network else { return 1 }
        let peak = series.flatMap { $0.values.suffix(samples) }.max() ?? 1
        return peak > 0 ? peak : 1
    }

    /// The widest each column's text can get, so the item keeps one width
    /// (see `StatusItemView.widestLines`).
    private func widest(_ module: MenuBarModule) -> CGFloat {
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        switch module {
        case .cpu:
            return max(width(L("CPU") + " 100°", Self.labelFont), width("100%", Self.valueFont))
        case .gpu:
            return max(width(L("GPU"), Self.labelFont), width("100%", Self.valueFont))
        case .memory:
            return max(width(L("RAM"), Self.labelFont), width("100%", Self.valueFont))
        case .disk:
            return width("W 1023K", Self.rateFont)
        case .network:
            return width("↓ 1023K", Self.rateFont)
        case .connectivity:
            return dotDiameter
        case .battery:
            return max(batterySize.width + 10, width("100%", Self.valueFont))
        }
    }

    private func layoutColumns() {
        var x = inset
        columns = modules.map { module in
            let pad = module == .connectivity ? 2 : padding
            let width = ceil(widest(module)) + pad * 2
            defer { x += width + gap }
            return (module, NSRect(x: x, y: 0, width: width, height: 22))
        }
        drawnSignature = nil
    }

    var preferredWidth: CGFloat {
        guard let last = columns.last else { return 24 }
        return last.frame.maxX + inset
    }

    // MARK: Redraw

    /// Same rule as `StatusItemView`: redraw only when something visible moved,
    /// down to the pixel row each graph sample lands on.
    @discardableResult
    func redrawIfChanged() -> Bool {
        guard let store else { return false }
        let signature = columns.map { column -> String in
            switch column.module {
            case .connectivity:
                return "\(store.connectivity.status)"
            case .battery:
                return "\(store.battery.powerState) \(Int(store.battery.percentage * 100))"
            default:
                var part = rows(column.module).map { $0.0 + $0.2.description }.joined(separator: "/")
                let samples = Int(column.frame.width)
                let entries = series(column.module)
                let top = ceiling(column.module, entries, samples: samples)
                for entry in entries {
                    part += "#" + entry.values.suffix(samples)
                        .map { String(Int(min(max($0 / top, 0), 1) * 18)) }.joined(separator: ",")
                }
                return part
            }
        }.joined(separator: "|")
        guard signature != drawnSignature else { return false }
        drawnSignature = signature
        needsDisplay = true
        return true
    }

    func invalidateDrawing() { drawnSignature = nil }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for column in columns {
            switch column.module {
            case .connectivity:
                drawDot(in: column.frame)
                continue
            case .battery:
                drawBackground(column.frame)
                drawBattery(rightEdge: column.frame.maxX - padding)
            default:
                drawBackground(column.frame)
                drawGraph(column.module, in: column.frame.insetBy(dx: 0, dy: 1))
            }
            drawRows(column)
        }
    }

    private func drawBackground(_ frame: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    private func drawGraph(_ module: MenuBarModule, in rect: NSRect) {
        let entries = series(module)
        guard !entries.isEmpty else { return }
        let samples = Int(rect.width)
        let top = ceiling(module, entries, samples: samples)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        for entry in entries {
            let values = Array(entry.values.suffix(samples))
            guard values.count > 1 else { continue }
            let step = rect.width / CGFloat(values.count - 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            for (index, value) in values.enumerated() {
                let fraction = CGFloat(min(max(value / top, 0), 1))
                path.line(to: NSPoint(x: rect.minX + CGFloat(index) * step,
                                      y: rect.maxY - rect.height * fraction))
            }
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()
            entry.color.withAlphaComponent(0.38).setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Right-aligned so digits stay put as values change length.
    private func drawRows(_ column: (module: MenuBarModule, frame: NSRect)) {
        let rows = self.rows(column.module)
        guard rows.count == 2 else { return }
        let right = column.frame.maxX - padding

        if !rows[0].0.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: rows[0].1, .foregroundColor: rows[0].2]
            let size = (rows[0].0 as NSString).size(withAttributes: attrs)
            (rows[0].0 as NSString).draw(at: NSPoint(x: right - size.width, y: bounds.midY - size.height + 0.5),
                                         withAttributes: attrs)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: rows[1].1, .foregroundColor: rows[1].2]
        let size = (rows[1].0 as NSString).size(withAttributes: attrs)
        (rows[1].0 as NSString).draw(at: NSPoint(x: right - size.width, y: bounds.midY - 2),
                                     withAttributes: attrs)
    }

    /// A small battery in place of a label: its fill says the level and its
    /// colour the state, at a glance.
    private func drawBattery(rightEdge: CGFloat) {
        guard let store else { return }
        let battery = store.battery
        let body = NSRect(x: rightEdge - batterySize.width - 1.5, y: bounds.midY - batterySize.height - 0.5,
                          width: batterySize.width, height: batterySize.height)

        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.5).setStroke()
        outline.stroke()
        NSColor.labelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.5, y: body.midY - 1.5, width: 1.5, height: 3),
                     xRadius: 0.7, yRadius: 0.7).fill()

        let inner = body.insetBy(dx: 1.8, dy: 1.8)
        let fraction = CGFloat(min(max(battery.percentage, 0), 1))
        if fraction > 0 {
            NSColor(BatteryIcon.color(for: battery)).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                             width: max(inner.width * fraction, 1.2), height: inner.height),
                         xRadius: 1, yRadius: 1).fill()
        }

        if battery.powerState == .charging,
           let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            bolt.isTemplate = true
            let side: CGFloat = 9
            NSColor.labelColor.set()
            bolt.draw(in: NSRect(x: body.minX - side - 1, y: body.midY - side / 2, width: side, height: side))
        }
    }

    private func drawDot(in frame: NSRect) {
        guard let store else { return }
        let color: NSColor
        switch store.connectivity.status {
        case .online: color = Self.good
        case .offline: color = Self.critical
        case .pending: color = Self.warning
        }
        let rect = NSRect(x: frame.midX - dotDiameter / 2, y: bounds.midY - dotDiameter / 2,
                          width: dotDiameter, height: dotDiameter)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -0.75, dy: -0.75))
        ring.lineWidth = 1
        ring.stroke()
    }
}
