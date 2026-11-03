// Draws Tacho's app icon — a tachometer dial on the promo images' blue-violet —
// and writes Assets/AppIcon.icns plus docs/images/icon.png.
//
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Point on the dial for a reading in 0...1; the scale sweeps 240° clockwise
/// from lower left to lower right, like a car's rev counter.
func dialPoint(_ value: CGFloat, radius: CGFloat, center: CGPoint) -> CGPoint {
    let angle = (210 - 240 * value) * .pi / 180
    return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
}

func drawIcon(in ctx: CGContext, size s: CGFloat) {
    let u = s / 1024
    ctx.scaleBy(x: u, y: u)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: an 824pt rounded square centred on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0.08, 0.09, 0.2)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let backdrop = CGGradient(colorsSpace: space, colors: [
        color(0.05, 0.07, 0.17), color(0.13, 0.15, 0.37), color(0.27, 0.13, 0.4),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(backdrop, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // A soft glow behind the dial.
    let glow = CGGradient(colorsSpace: space, colors: [color(0.45, 0.5, 1, 0.28), color(0.45, 0.5, 1, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 400, options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 490)
    let radius: CGFloat = 270

    // Faint track under the coloured scale.
    ctx.setLineCap(.round)
    ctx.setLineWidth(58)
    ctx.setStrokeColor(color(1, 1, 1, 0.1))
    ctx.addArc(center: center, radius: radius, startAngle: 210 * .pi / 180, endAngle: -30 * .pi / 180, clockwise: true)
    ctx.strokePath()

    // The scale, green through amber to red, drawn as short segments so the
    // colour follows the arc.
    let ramp: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.85, 0.55), (0.98, 0.78, 0.2), (1, 0.33, 0.36)]
    func rampColor(_ t: CGFloat) -> CGColor {
        let scaled = t * CGFloat(ramp.count - 1)
        let i = min(Int(scaled), ramp.count - 2)
        let f = scaled - CGFloat(i)
        let a = ramp[i], b = ramp[i + 1]
        return color(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }
    let filled: CGFloat = 0.78
    let steps = 120
    ctx.setLineCap(.butt)
    for step in 0..<steps {
        let t0 = CGFloat(step) / CGFloat(steps) * filled
        let t1 = CGFloat(step + 1) / CGFloat(steps) * filled + 0.002
        ctx.setStrokeColor(rampColor(t0 / filled * 0.999))
        ctx.addArc(center: center, radius: radius,
                   startAngle: (210 - 240 * t0) * .pi / 180, endAngle: (210 - 240 * t1) * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    // Round caps at both ends of the coloured part.
    for (t, c) in [(CGFloat(0), rampColor(0)), (filled, rampColor(0.999))] {
        let p = dialPoint(t, radius: radius, center: center)
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: p.x - 29, y: p.y - 29, width: 58, height: 58))
    }

    // Tick marks inside the scale.
    for tick in 0...8 {
        let t = CGFloat(tick) / 8
        let major = tick % 2 == 0
        let outer = dialPoint(t, radius: radius - 52, center: center)
        let inner = dialPoint(t, radius: radius - (major ? 100 : 82), center: center)
        ctx.setStrokeColor(color(1, 1, 1, major ? 0.75 : 0.4))
        ctx.setLineWidth(major ? 14 : 9)
        ctx.setLineCap(.round)
        ctx.move(to: outer); ctx.addLine(to: inner); ctx.strokePath()
    }

    // The needle, pointing to the end of the coloured scale.
    let tip = dialPoint(filled, radius: radius - 40, center: center)
    let angle = atan2(tip.y - center.y, tip.x - center.x)
    let normal = CGPoint(x: -sin(angle), y: cos(angle))
    let tail = CGPoint(x: center.x - cos(angle) * 50, y: center.y - sin(angle) * 50)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0, 0, 0.45))
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: center.x + normal.x * 26, y: center.y + normal.y * 26))
    ctx.addLine(to: tail)
    ctx.addLine(to: CGPoint(x: center.x - normal.x * 26, y: center.y - normal.y * 26))
    ctx.closePath()
    ctx.setFillColor(color(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Hub.
    ctx.setFillColor(color(1, 1, 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 50, y: center.y - 50, width: 100, height: 100))
    ctx.setFillColor(color(0.13, 0.15, 0.37))
    ctx.fillEllipse(in: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))

    // A small readout under the hub, as on a real gauge.
    let bar = CGRect(x: 512 - 120, y: 238, width: 240, height: 30)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.setFillColor(color(1, 1, 1, 0.14)); ctx.fillPath()
    let level = CGRect(x: bar.minX, y: bar.minY, width: bar.width * 0.62, height: bar.height)
    ctx.addPath(CGPath(roundedRect: level, cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.setFillColor(color(0.35, 0.75, 1)); ctx.fillPath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    drawIcon(in: context.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let assets = root.appendingPathComponent("Assets")
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

try png(size: 512).write(to: root.appendingPathComponent("docs/images/icon.png"))
print("Wrote Assets/AppIcon.icns and docs/images/icon.png")
