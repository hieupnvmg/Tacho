import AppKit
import SwiftUI

/// Every enabled readout in one menu bar item: a column each, a small label
/// over its value. On a notched MacBook the menu bar runs out of room fast,
/// and one item is also one snapshot for macOS instead of six.
final class CompactStatusView: NSView {

    weak var store: MonitorStore?
    var modules: [MenuBarModule] = [] {
        didSet { layoutColumns() }
    }

    /// Where each column sits, for clicks and popover placement.
    private(set) var columns: [(module: MenuBarModule, frame: NSRect)] = []
    private var drawnSignature: String?

    private static let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let warning = NSColor(Palette.warning)
    private static let critical = NSColor(Palette.critical)
    private static let good = NSColor(Palette.memory)

    private let gap: CGFloat = 9
    private let inset: CGFloat = 5
    private let dotDiameter: CGFloat = 7

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

    /// The two rows of one column, top then bottom, each with its colour.
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
            let color: NSColor
            switch store.memory.pressureLevel {
            case .normal: color = .labelColor
            case .warning: color = Self.warning
            case .critical: color = Self.critical
            }
            return [(L("RAM"), Self.labelFont, label),
                    (String(format: "%.0f%%", store.memory.pressure * 100), Self.valueFont, color)]
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
            var top = L("PIN")
            if battery.powerState == .charging { top += " ⚡︎" }
            let color: NSColor = !battery.isPluggedIn && battery.percentage <= 0.2 ? Self.critical : .labelColor
            return [(top, Self.labelFont, label),
                    (String(format: "%.0f%%", battery.percentage * 100), Self.valueFont, color)]
        }
    }

    /// The widest each column can get, so the item keeps one width (see
    /// `StatusItemView.widestLines`).
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
            return max(width(L("PIN") + " ⚡︎", Self.labelFont), width("100%", Self.valueFont))
        }
    }

    private func layoutColumns() {
        var x = inset
        columns = modules.map { module in
            let width = ceil(widest(module))
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

    @discardableResult
    func redrawIfChanged() -> Bool {
        let signature = modules.map { module -> String in
            if module == .connectivity { return "\(store?.connectivity.status ?? .pending)" }
            return rows(module).map { $0.0 + $0.2.description }.joined(separator: "/")
        }.joined(separator: "|")
        guard signature != drawnSignature else { return false }
        drawnSignature = signature
        needsDisplay = true
        return true
    }

    func invalidateDrawing() { drawnSignature = nil }

    override func draw(_ dirtyRect: NSRect) {
        for column in columns {
            if column.module == .connectivity {
                drawDot(in: column.frame)
                continue
            }
            let rows = self.rows(column.module)
            guard rows.count == 2 else { continue }
            // Top row hugs the top edge, bottom row the bottom, both right-aligned
            // so digits stay put as values change length.
            let top = (rows[0].0 as NSString)
            let topAttrs: [NSAttributedString.Key: Any] = [.font: rows[0].1, .foregroundColor: rows[0].2]
            let topSize = top.size(withAttributes: topAttrs)
            top.draw(at: NSPoint(x: column.frame.maxX - topSize.width, y: bounds.midY - topSize.height + 1),
                     withAttributes: topAttrs)

            let bottom = (rows[1].0 as NSString)
            let bottomAttrs: [NSAttributedString.Key: Any] = [.font: rows[1].1, .foregroundColor: rows[1].2]
            let bottomSize = bottom.size(withAttributes: bottomAttrs)
            bottom.draw(at: NSPoint(x: column.frame.maxX - bottomSize.width, y: bounds.midY - 1),
                        withAttributes: bottomAttrs)
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
