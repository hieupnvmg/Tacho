import AppKit

/// An animation that runs in the menu bar, faster the busier the CPU is:
/// one of the built-in ones, whose frames come from RunCat Neo under the
/// Apache License 2.0 (see Assets/Runners/NOTICE), or one the user imported.
struct Runner: Identifiable, Hashable {
    let id: String
    let title: String
    /// Monochrome runners are tinted the menu bar's text colour; colour ones
    /// keep their own colours.
    let isTemplate: Bool
    let folder: URL
    let isCustom: Bool

    static let defaultID = "cat"

    static let builtIn: [Runner] = {
        let root = Bundle.main.resourceURL?.appendingPathComponent("Runners") ?? URL(fileURLWithPath: "/")
        let names: [(String, String)] = [
            ("cat", L("Mèo")), ("dog", L("Chó")), ("coffee", L("Cà phê")), ("drop", L("Giọt nước")),
            ("engine", L("Động cơ")), ("mochi", L("Giã bánh mochi")), ("cradle", L("Con lắc Newton")),
            ("slime", L("Slime")),
        ]
        return names.map { Runner(id: $0.0, title: $0.1, isTemplate: true,
                                  folder: root.appendingPathComponent($0.0), isCustom: false) }
    }()

    private static var cache: [String: [NSImage]] = [:]

    /// The frames in order, frame-0.png, frame-1.png and so on. Drawn at 2x,
    /// so a 36-pixel frame is 18 points tall.
    var frames: [NSImage] {
        if let cached = Self.cache[id] { return cached }
        var frames: [NSImage] = []
        while let image = NSImage(contentsOf: folder.appendingPathComponent("frame-\(frames.count).png")) {
            if let rep = image.representations.first {
                image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
            }
            image.isTemplate = isTemplate
            frames.append(image)
        }
        Self.cache[id] = frames
        return frames
    }

    var width: CGFloat { (frames.first?.size.width ?? 28) + 6 }
}

/// The built-in runners and the ones the user imported. Imported runners
/// live in Application Support, a folder each with their frames and an
/// info.json, in the same frame format RunCat Neo takes, so runners from its
/// Runner Gallery import as they are.
@MainActor
final class RunnerLibrary: ObservableObject {
    static let shared = RunnerLibrary()

    @Published private(set) var custom: [Runner] = []

    var all: [Runner] { Runner.builtIn + custom }

    /// RunCat Neo's limits, so a runner that works there works here.
    static let frameHeight = 36
    static let frameWidths = 10...100
    static let maxFrames = 30

    private struct Info: Codable {
        var name: String
        var isTemplate: Bool
        var added: Date
    }

    private let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tacho/Runners", isDirectory: true)
    }()

    private init() { reload() }

    func runner(id: String) -> Runner {
        all.first { $0.id == id } ?? Runner.builtIn[0]
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        custom = folders.compactMap { folder -> (Runner, Date)? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")),
                  let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
            let runner = Runner(id: "custom-" + folder.lastPathComponent, title: info.name,
                                isTemplate: info.isTemplate, folder: folder, isCustom: true)
            return (runner, info.added)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    func nameIsTaken(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        return all.contains { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves the frames as a new runner and returns it.
    func add(name: String, isTemplate: Bool, frames: [CGImage]) throws -> Runner {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for (index, frame) in frames.enumerated() {
                guard let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: folder.appendingPathComponent("frame-\(index).png"))
            }
            let info = Info(name: name.trimmingCharacters(in: .whitespaces), isTemplate: isTemplate, added: Date())
            try JSONEncoder().encode(info).write(to: folder.appendingPathComponent("info.json"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        reload()
        return runner(id: "custom-" + folder.lastPathComponent)
    }

    /// Moves an imported runner to the Trash.
    func delete(_ runner: Runner) {
        guard runner.isCustom else { return }
        try? FileManager.default.trashItem(at: runner.folder, resultingItemURL: nil)
        reload()
    }
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
        runnerLayer.setFrames(frames, isTemplate: runner.isTemplate)
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

/// Plays the frames. A monochrome runner plays as a mask over a block of the
/// menu bar's text colour, which is how a template image is tinted; a colour
/// one plays in a sublayer of its own. Either way the animation and its
/// timing live on a child layer: retiming this layer itself, in the button's
/// layer tree, froze the animation.
final class RunnerLayer: CALayer {
    private let maskLayer = CALayer()
    private let colorLayer = CALayer()
    /// The layer the animation runs on.
    private var animated: CALayer { mask == nil ? colorLayer : maskLayer }
    private var tint: CGColor?
    private let animation = CAKeyframeAnimation(keyPath: "contents")

    override init() {
        super.init()
        masksToBounds = true
        contentsScale = 2
        maskLayer.contentsGravity = .resize
        maskLayer.contentsScale = 2
        colorLayer.contentsGravity = .resize
        colorLayer.contentsScale = 2
        addSublayer(colorLayer)
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func place(in frame: CGRect) {
        self.frame = frame
        maskLayer.frame = CGRect(origin: .zero, size: frame.size)
        colorLayer.frame = CGRect(origin: .zero, size: frame.size)
    }

    func setFrames(_ frames: [NSImage], isTemplate: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let speed = animated.speed
        maskLayer.removeAllAnimations()
        colorLayer.removeAllAnimations()
        mask = isTemplate ? maskLayer : nil
        backgroundColor = isTemplate ? tint : nil
        colorLayer.isHidden = isTemplate
        animated.speed = speed
        // At speed 1, two frames a second.
        animation.values = frames
        animation.duration = Double(frames.count) / 2
        animated.add(animation, forKey: "running")
        CATransaction.commit()
    }

    func setColor(_ color: CGColor) {
        tint = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if mask != nil { backgroundColor = color }
        CATransaction.commit()
    }

    /// Changes pace without a jump: the animation carries on from the frame
    /// it is on.
    func setSpeed(_ speed: Float) {
        let layer = animated
        guard layer.speed != speed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.beginTime = CACurrentMediaTime()
        layer.speed = speed
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
