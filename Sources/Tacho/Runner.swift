import AppKit

/// An animation that runs in the menu bar, faster the busier the CPU is.
/// The frames come from RunCat Neo, under the Apache License 2.0; see
/// Assets/Runners/NOTICE.
enum Runner: String, CaseIterable, Identifiable {
    case cat, dog, coffee, drop, engine, mochi, cradle, slime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cat: return L("Mèo")
        case .dog: return L("Chó")
        case .coffee: return L("Cà phê")
        case .drop: return L("Giọt nước")
        case .engine: return L("Động cơ")
        case .mochi: return L("Giã bánh mochi")
        case .cradle: return L("Con lắc Newton")
        case .slime: return L("Slime")
        }
    }

    private static var cache: [Runner: [NSImage]] = [:]

    /// The frames in order, as template images so each display's menu bar
    /// tints them its own colour. Drawn at 2x, so a 36-pixel frame is 18
    /// points tall. Empty when run outside the app bundle.
    var frames: [NSImage] {
        if let cached = Self.cache[self] { return cached }
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Runners/\(rawValue)") else { return [] }
        var frames: [NSImage] = []
        while let image = NSImage(contentsOf: folder.appendingPathComponent("frame-\(frames.count).png")) {
            if let rep = image.representations.first {
                image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
            }
            image.isTemplate = true
            frames.append(image)
        }
        Self.cache[self] = frames
        return frames
    }

    var width: CGFloat { (frames.first?.size.width ?? 28) + 6 }
}

/// Runs a runner in a status item's button, with the pace set by how busy
/// the CPU is. The approach follows RunCat Neo's RunnerBarView and
/// RunnerLayer (Apache License 2.0).
///
/// The frames play as a Core Animation keyframe animation on a layer in the
/// button, so the system's render server steps them and the app does no work
/// per frame. Swapping the button's image each frame instead made macOS
/// re-snapshot the item for every display's menu bar: several percent of a
/// core, and jerky because the pace had to stay low to keep that down.
///
/// The trade-off: the animation shows only on the active display. The
/// button's image, the first frame, stands in on the others; on the active
/// display an eraser layer behind the runner cuts that image out so the two
/// never overlap. The eraser's filter needs Apple silicon; on Intel the
/// still frame stays visible under the animation.
@MainActor
final class RunnerAnimator {
    weak var store: MonitorStore?
    private weak var item: NSStatusItem?
    private let runnerLayer = RunnerLayer()
    private let eraserLayer = EraserLayer()
    private var size = CGSize.zero
    private var appearanceObservation: NSKeyValueObservation?

    init(store: MonitorStore, item: NSStatusItem, runner: Runner) {
        self.store = store
        self.item = item
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        #if arch(arm64)
        button.layer?.addSublayer(eraserLayer)
        #endif
        button.layer?.addSublayer(runnerLayer)
        // The menu bar's text colour follows the wallpaper behind it, not
        // the app's appearance, so it is read from the button itself.
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] button, _ in
            MainActor.assumeIsolated { self?.updateColor(for: button.effectiveAppearance) }
        }
        show(runner)
    }

    func show(_ runner: Runner) {
        let frames = runner.frames
        size = frames.first?.size ?? .zero
        item?.length = runner.width
        item?.button?.image = frames.first
        layoutLayers()
        // The button may only take its new width on the next pass.
        DispatchQueue.main.async { [weak self] in self?.layoutLayers() }
        runnerLayer.setFrames(frames)
        updateSpeed()
    }

    /// Where the button draws its image: centred.
    private func layoutLayers() {
        guard let bounds = item?.button?.bounds, size != .zero else { return }
        let frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(),
                           y: ((bounds.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        runnerLayer.place(in: frame)
        eraserLayer.frame = frame
        CATransaction.commit()
    }

    private func updateColor(for appearance: NSAppearance) {
        var color = NSColor.labelColor.cgColor
        appearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        runnerLayer.setColor(color)
    }

    /// Animation speed for the current CPU load: one stride step every half
    /// second at idle, twenty times that at full load, as RunCat Neo does.
    func updateSpeed() {
        let percent = Float((store?.cpu.busy ?? 0) * 100)
        runnerLayer.setSpeed(max(1, min(20, percent / 5)))
    }

    func stop() {
        appearanceObservation = nil
        runnerLayer.removeFromSuperlayer()
        eraserLayer.removeFromSuperlayer()
    }
}

/// Plays the frames as a mask over a block of the menu bar's text colour,
/// which is how a template image is tinted.
final class RunnerLayer: CALayer {
    private let maskLayer = CALayer()
    private let animation = CAKeyframeAnimation(keyPath: "contents")

    override init() {
        super.init()
        masksToBounds = true
        contentsScale = 2
        maskLayer.contentsGravity = .resize
        maskLayer.contentsScale = 2
        mask = maskLayer
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func place(in frame: CGRect) {
        self.frame = frame
        maskLayer.frame = CGRect(origin: .zero, size: frame.size)
    }

    func setFrames(_ frames: [NSImage]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.removeAllAnimations()
        // At speed 1, two frames a second.
        animation.values = frames
        animation.duration = Double(frames.count) / 2
        maskLayer.add(animation, forKey: "running")
        CATransaction.commit()
    }

    func setColor(_ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundColor = color
        CATransaction.commit()
    }

    /// Changes pace without a jump: the animation carries on from the frame
    /// it is on.
    func setSpeed(_ speed: Float) {
        guard maskLayer.speed != speed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.timeOffset = maskLayer.convertTime(CACurrentMediaTime(), from: nil)
        maskLayer.beginTime = CACurrentMediaTime()
        maskLayer.speed = speed
        CATransaction.commit()
    }
}

/// Cuts the button's still image out from behind the running animation.
final class EraserLayer: CALayer {
    override init() {
        super.init()
        let filter = CIFilter(name: "CISourceOutCompositing")
        filter?.setValue(CIImage(color: CIColor.blue).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 40)),
                         forKey: kCIInputBackgroundImageKey)
        backgroundFilters = filter.map { [$0] }
        masksToBounds = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }
}
