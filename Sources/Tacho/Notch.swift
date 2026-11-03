import AppKit
import SwiftUI
import Combine
import IOKit.ps

/// The camera housing on the built-in display, in screen points.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let rect: CGRect

    /// Nil on Macs without a notch, and while the lid is closed.
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else { continue }
            let frame = screen.frame
            let height = screen.safeAreaInsets.top
            let minX = frame.minX + left.width
            let width = frame.width - left.width - right.width
            return NotchGeometry(screenFrame: frame,
                                 rect: CGRect(x: minX, y: frame.maxY - height, width: width, height: height))
        }
        return nil
    }
}

/// Something short enough to say in the two "wings" either side of the notch.
enum NotchEvent: Hashable {
    case charging(Int)
    case unplugged(Int)
    case device(symbol: String, percent: Int)
    case offline
    case online
    case callStarted(String)
    case callEnded(String)

    var symbol: String {
        switch self {
        case .charging: return "bolt.fill"
        case .unplugged(let percent):
            switch percent {
            case ..<13: return "battery.0"
            case ..<38: return "battery.25"
            case ..<63: return "battery.50"
            case ..<88: return "battery.75"
            default: return "battery.100"
            }
        case .device(let symbol, _): return symbol
        case .offline: return "wifi.slash"
        case .online: return "wifi"
        case .callStarted: return "phone.fill"
        case .callEnded: return "phone.down.fill"
        }
    }

    var text: String {
        switch self {
        case .charging(let percent), .unplugged(let percent), .device(_, let percent):
            return "\(percent)%"
        case .offline: return L("Mất mạng")
        case .online: return L("Có mạng")
        case .callStarted(let app): return app
        case .callEnded(let duration): return duration
        }
    }

    var tint: Color {
        switch self {
        case .charging, .online, .callStarted: return Palette.memory
        case .callEnded: return Palette.critical
        case .offline: return Palette.critical
        case .unplugged(let percent), .device(_, let percent):
            return percent <= 20 ? Palette.critical : .white
        }
    }

    /// One wing, wide enough for whichever side is wider.
    var wingWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return max(ceil(textWidth), 20) + 24
    }
}

@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        /// Off screen.
        case hidden
        /// Tucked just inside the notch, where the black shape cannot be seen;
        /// every animation starts and ends here.
        case idle
        case event(NotchEvent)
        case peek
    }

    struct Layout {
        var size: CGSize
        /// The concave flare that blends the shape into the top edge.
        var shoulder: CGFloat
        var corner: CGFloat
    }

    @Published var mode: Mode = .hidden
    var notch = CGSize(width: 185, height: 32)

    /// A call in progress adds a row to the panel.
    @Published var hasCall = false
    private static let bodyHeight: CGFloat = 138
    private static let callRowHeight: CGFloat = 60
    var peekBodyHeight: CGFloat { Self.bodyHeight + (hasCall ? Self.callRowHeight : 0) }
    var peekInnerWidth: CGFloat { max(notch.width + 236, 430) }

    func layout(_ mode: Mode) -> Layout {
        switch mode {
        case .hidden, .idle:
            return Layout(size: CGSize(width: notch.width - 12, height: notch.height - 4), shoulder: 3, corner: 8)
        case .event(let event):
            return Layout(size: CGSize(width: notch.width + event.wingWidth * 2 + 12, height: notch.height),
                          shoulder: 6, corner: 12)
        case .peek:
            return Layout(size: CGSize(width: peekInnerWidth + 24, height: notch.height + peekBodyHeight),
                          shoulder: 12, corner: 26)
        }
    }

    /// The window: the largest shape plus room for its shadow.
    var canvas: CGSize {
        CGSize(width: peekInnerWidth + 24 + 80, height: notch.height + Self.bodyHeight + Self.callRowHeight + 44)
    }
}

/// The notch outline: square top edge with flared shoulders, rounded bottom.
/// Both radii animate, so the shape morphs instead of just stretching.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set { shoulder = newValue.first; corner = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4)
        let c = min(corner, rect.height / 2, (rect.width - 2 * s) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s),
                          control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - c))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + c, y: rect.maxY),
                          control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - c, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - c),
                          control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Views

private struct BlurFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.86 : 1, anchor: .top)
    }
}

private extension AnyTransition {
    /// Content sharpens into place just after the shape has started to grow,
    /// and is gone before it shrinks back.
    static func notchContent(reduceMotion: Bool) -> AnyTransition {
        let blurFade = AnyTransition.modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.2)) }
        return .asymmetric(insertion: blurFade.animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.07)),
                           removal: blurFade.animation(.easeIn(duration: 0.12)))
    }
}

private extension View {
    /// Digits roll instead of snapping, where the system supports it.
    @ViewBuilder func numericTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    @ViewBuilder func bounceOnAppear(_ trigger: Bool) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.bounce, value: trigger)
        } else {
            self
        }
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let store: MonitorStore
    let media: NotchMedia
    let reduceMotion: Bool
    var onClick: () -> Void

    var body: some View {
        let layout = model.layout(model.mode)
        ZStack(alignment: .top) {
            NotchShape(shoulder: layout.shoulder, corner: layout.corner)
                .fill(Color.black)
                .frame(width: layout.size.width, height: layout.size.height)
                .shadow(color: glow, radius: model.mode == .peek ? 18 : 10, y: model.mode == .peek ? 8 : 3)

            content
                .frame(width: max(layout.size.width - layout.shoulder * 2, 0), height: layout.size.height,
                       alignment: .top)
                .clipped()
        }
        .frame(width: model.canvas.width, height: model.canvas.height, alignment: .top)
        .opacity(model.mode == .hidden ? 0 : 1)
        .environment(\.colorScheme, .dark)
    }

    private var glow: Color {
        switch model.mode {
        case .event(let event): return event.tint.opacity(0.35)
        case .peek: return .black.opacity(0.5)
        case .hidden, .idle: return .clear
        }
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .event(let event):
            NotchWings(event: event, notch: model.notch)
                .id(event)
                .transition(.notchContent(reduceMotion: reduceMotion))
        case .peek:
            NotchPeek(store: store, media: media, notch: model.notch, onOpenTacho: onClick)
                .transition(.notchContent(reduceMotion: reduceMotion))
        case .hidden, .idle:
            EmptyView()
        }
    }
}

private final class NotchFlag: ObservableObject {
    @Published var on = false
}

private struct NotchWings: View {
    let event: NotchEvent
    let notch: CGSize
    /// `@State` needs the SwiftUI macro plugin, which ships only with Xcode.
    @StateObject private var appeared = NotchFlag()

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: event.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(event.tint)
                .bounceOnAppear(appeared.on)
                .frame(width: event.wingWidth)
            Spacer(minLength: notch.width)
            Text(event.text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(event.tint)
                .lineLimit(1)
                .fixedSize()
                .frame(width: event.wingWidth)
        }
        .frame(height: notch.height)
        .onAppear {
            // Let the wing open first, then nudge the icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { appeared.on = true }
        }
    }
}

enum CallClock {
    /// "4:07", or "1:04:07" past the hour.
    static func string(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}

/// Rows slide down into place one after another as the panel opens.
private struct RiseIn: ViewModifier {
    let index: Int
    @StateObject private var shown = NotchFlag()

    func body(content: Content) -> some View {
        content
            .opacity(shown.on ? 1 : 0)
            .offset(y: shown.on ? 0 : -8)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.1 + Double(index) * 0.05)) {
                    shown.on = true
                }
            }
    }
}

private extension View {
    func riseIn(_ index: Int) -> some View { modifier(RiseIn(index: index)) }
}

/// Shrinks a little while held, so a click on the black panel is felt.
private struct NotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct NotchPeek: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var media: NotchMedia
    let notch: CGSize
    var onOpenTacho: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Button(action: onOpenTacho) {
                    HStack(spacing: 6) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text("Tacho")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .buttonStyle(NotchButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear.frame(width: notch.width)

                battery.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: notch.height)

            if let call = media.call {
                CallRow(call: call).riseIn(0)
            }
            NowPlayingRow(media: media).riseIn(1)
            OutputRow(media: media).riseIn(2)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var battery: some View {
        let sample = store.battery
        if sample.isPresent {
            HStack(spacing: 6) {
                Text(String(format: "%.0f%%", sample.percentage * 100))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                BatteryGlyph(percentage: sample.percentage, state: sample.powerState,
                             color: sample.isCharging ? Palette.memory
                                 : sample.percentage <= 0.2 ? Palette.critical : .white,
                             width: 24)
            }
        }
    }
}

private struct CallRow: View {
    let call: ActiveCall

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = call.icon {
                    Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.memory)
                        .frame(width: 30, height: 30)
                }
                Circle()
                    .fill(Palette.memory)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(call.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(call.title ?? L("Đang trong cuộc gọi"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(CallClock.string(Int(context.date.timeIntervalSince(call.since))))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.memory)
            }
            Button { call.activate() } label: {
                Text(L("Mở"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(NotchButtonStyle())
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.memory.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Palette.memory.opacity(0.28), lineWidth: 1))
    }
}

private struct NowPlayingRow: View {
    @ObservedObject var media: NotchMedia

    var body: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                if let track = media.nowPlaying {
                    Text(track.title.isEmpty ? "—" : track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    if media.needsPermission {
                        Button(L("Cho phép Tacho trong Trợ năng để bấm phát, chuyển bài")) {
                            MediaKeys.openSettings()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.warning)
                        .lineLimit(1)
                    } else {
                        HStack(spacing: 5) {
                            if track.isPlaying { EqualizerBars() }
                            Text(track.sourceName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                } else {
                    Text(L("Không có nhạc đang phát"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(L("Phát nhạc ở bất kỳ app nào để điều khiển ở đây."))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let track = media.nowPlaying {
                HStack(spacing: 2) {
                    control("backward.fill", size: 13) { media.press(.previous) }
                    control(track.isPlaying ? "pause.fill" : "play.fill", size: 20) { media.press(.playPause) }
                    control("forward.fill", size: 13) { media.press(.next) }
                }
                .foregroundStyle(.white)
            }
        }
        .padding(8)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1))
            if let art = media.nowPlaying?.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = media.nowPlaying?.sourceIcon {
                Image(nsImage: icon).resizable().padding(5)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle())
    }
}

/// Three bars bobbing out of step while music plays.
private struct EqualizerBars: View {
    @StateObject private var moving = NotchFlag()

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Palette.memory)
                    .frame(width: 2, height: 8)
                    .scaleEffect(y: moving.on ? [1, 0.45, 0.8][index] : [0.35, 1, 0.4][index], anchor: .bottom)
                    .animation(.easeInOut(duration: [0.42, 0.33, 0.5][index]).repeatForever(autoreverses: true),
                               value: moving.on)
            }
        }
        .frame(height: 8)
        .onAppear { moving.on = true }
    }
}

private struct OutputRow: View {
    @ObservedObject var media: NotchMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Phát ra"))
                .textCase(.uppercase)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(media.outputs) { output in
                        chip(output, selected: output.id == media.selectedOutput)
                    }
                }
            }
        }
        .frame(height: 42)
    }

    private func chip(_ output: AudioOutput, selected: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { media.select(output) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: output.symbol).font(.system(size: 11, weight: .medium))
                Text(output.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.09)))
        }
        .buttonStyle(NotchButtonStyle())
    }
}

// MARK: - Controller

/// Owns the panel over the notch: watches for events worth showing in its
/// wings, and for the pointer resting on it.
@MainActor
final class NotchController {
    private let store: MonitorStore
    private let model = NotchModel()
    private let media = NotchMedia()
    /// Refreshes the song and the output list while the panel is open.
    private var peekTimer: Timer?
    private var callTick = 0
    /// Keeps the demo's panel open wherever the pointer is.
    private var demoPinned = false
    private var panel: NSPanel?
    private var geometry: NotchGeometry?
    private var eventsOn = false
    private var peekOn = false

    private var mouseMonitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var pending: [NotchEvent] = []

    private var powerSource: CFRunLoopSource?
    private var lastPluggedIn: Bool?
    private var knownDevices: Set<String>?
    private var startedAt = Date()
    private var lastOnline: Bool?
    private var cancellables: Set<AnyCancellable> = []

    private static let eventDuration: TimeInterval = 3
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(store: MonitorStore, settings: MenuBarSettings) {
        self.store = store
        settings.$notchEvents.combineLatest(settings.$notchPeek)
            .sink { [weak self] events, peek in self?.configure(events: events, peek: peek) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.configure(events: self.eventsOn, peek: self.peekOn)
            }
            .store(in: &cancellables)
        store.onEachSample { [weak self] in self?.checkStore() }
    }

    // MARK: Setup

    private func configure(events: Bool, peek: Bool) {
        eventsOn = events
        peekOn = peek
        let geometry = (events || peek) ? NotchGeometry.current() : nil
        if geometry != self.geometry {
            self.geometry = geometry
            rebuildPanel()
        }

        if peek && geometry != nil { installMouseMonitors() } else { removeMouseMonitors() }
        if events && geometry != nil {
            startPowerWatch()
        } else {
            stopPowerWatch()
            knownDevices = nil
            lastOnline = nil
            pending.removeAll()
        }
        if !events, case .event = model.mode { collapse() }
        if !peek, model.mode == .peek { collapse() }
    }

    private func rebuildPanel() {
        panel?.orderOut(nil)
        panel = nil
        model.mode = .hidden
        guard let geometry else { return }

        model.notch = geometry.rect.size
        let canvas = model.canvas
        let frame = CGRect(x: geometry.rect.midX - canvas.width / 2, y: geometry.screenFrame.maxY - canvas.height,
                           width: canvas.width, height: canvas.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // Not .fullScreenAuxiliary: a full-screen app keeps its notch area.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NotchView(model: model, store: store, media: media, reduceMotion: reduceMotion) {
            [weak self] in
            self?.collapse()
            MenuBarPopover.openMainWindow()
        })
        host.frame = CGRect(origin: .zero, size: canvas)
        panel.contentView = host
        panel.setFrame(frame, display: false)
        self.panel = panel
    }

    // MARK: Showing

    private var expandAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.44, dampingFraction: 0.74)
    }

    private var collapseAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.95)
    }

    private func expand(to mode: NotchModel.Mode) {
        guard let panel else { return }
        hideWork?.cancel()
        let fromHidden = model.mode == .hidden
        if fromHidden {
            model.mode = .idle
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = mode != .peek
        // From hidden, give the idle shape one frame on screen so the spring
        // has a starting point.
        DispatchQueue.main.asyncAfter(deadline: .now() + (fromHidden ? 0.02 : 0)) { [weak self] in
            guard let self else { return }
            withAnimation(self.expandAnimation) { self.model.mode = mode }
        }
    }

    private func collapse() {
        dismissWork?.cancel()
        leaveWork?.cancel()
        guard model.mode != .hidden, model.mode != .idle else { return }
        panel?.ignoresMouseEvents = true
        peekTimer?.invalidate()
        peekTimer = nil
        media.stopPlayback()
        withAnimation(collapseAnimation) { model.mode = .idle }

        let hide = DispatchWorkItem { [weak self] in
            guard let self, self.model.mode == .idle else { return }
            self.model.mode = .hidden
            // Off screen entirely, so nothing is composited while idle.
            self.panel?.orderOut(nil)
            self.showNextEvent()
        }
        hideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: hide)
    }

    private func show(_ event: NotchEvent) {
        guard eventsOn, panel != nil else { return }
        switch model.mode {
        case .peek:
            return   // the dashboard already says it
        case .event, .idle:
            pending.append(event)
            return
        case .hidden:
            break
        }
        expand(to: .event(event))
        let dismiss = DispatchWorkItem { [weak self] in self?.collapse() }
        dismissWork = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.eventDuration, execute: dismiss)
    }

    private func showNextEvent() {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.show(next) }
    }

    // MARK: Pointer

    private func installMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }
        // Pointer movement needs no permission to observe, unlike keystrokes.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func removeMouseMonitors() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        hoverWork?.cancel()
        leaveWork?.cancel()
    }

    /// Slightly wider than the notch, and up to the very top edge, where a
    /// pointer pushed into the corner of the screen ends up.
    private var hotRect: CGRect? {
        geometry.map { $0.rect.insetBy(dx: -6, dy: 0).offsetBy(dx: 0, dy: 1) }
    }

    private var peekRect: CGRect? {
        guard let geometry else { return nil }
        let size = model.layout(.peek).size
        return CGRect(x: geometry.rect.midX - size.width / 2, y: geometry.screenFrame.maxY - size.height,
                      width: size.width, height: size.height + 2).insetBy(dx: -10, dy: -10)
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if model.mode == .peek {
            guard !demoPinned else { return }
            if peekRect?.contains(point) == true {
                leaveWork?.cancel()
                leaveWork = nil
            } else if leaveWork == nil {
                let leave = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.leaveWork = nil
                    if self.peekRect?.contains(NSEvent.mouseLocation) != true { self.collapse() }
                }
                leaveWork = leave
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: leave)
            }
            return
        }

        guard hotRect?.contains(point) == true else {
            hoverWork?.cancel()
            hoverWork = nil
            return
        }
        guard hoverWork == nil else { return }
        // A short dwell, so passing over the notch on the way to the menu bar
        // does not open anything.
        let hover = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            guard self.peekOn, self.hotRect?.contains(NSEvent.mouseLocation) == true else { return }
            self.openPeek()
        }
        hoverWork = hover
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: hover)
    }

    private func openPeek() {
        dismissWork?.cancel()
        pending.removeAll()
        media.refreshCall()
        model.hasCall = media.call != nil
        media.refreshOutputs()
        media.startPlayback()
        peekTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.media.refreshOutputs()
                self.media.refreshPermission()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        peekTimer = timer
        expand(to: .peek)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: Demo

    /// `--notch-demo`: plays each state once, for checking the animation and
    /// recording it, without waiting for a charger or a pointer.
    func runDemo() {
        configure(events: true, peek: peekOn)
        let steps: [(TimeInterval, () -> Void)] = [
            (1, { self.show(.charging(64)) }),
            (5, { self.show(.device(symbol: "airpodspro", percent: 82)) }),
            (9, { self.show(.callStarted("Teams")) }),
            (13, { self.demoPinned = true; self.openPeek() }),
            (19, { self.demoPinned = false; self.collapse() }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
    }

    // MARK: Events

    private func startPowerWatch() {
        guard powerSource == nil else { return }
        lastPluggedIn = Self.powerReading()?.pluggedIn
        startedAt = Date()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<NotchController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.powerChanged() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func stopPowerWatch() {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        lastPluggedIn = nil
    }

    /// Straight from the power source list, which updates the moment the
    /// charger goes in, rather than waiting for the next battery sample.
    private static func powerReading() -> (pluggedIn: Bool, percent: Int)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (providing == kIOPMACPowerKey, Int((Double(current) / Double(max) * 100).rounded()))
        }
        return nil
    }

    private func powerChanged() {
        guard let reading = Self.powerReading() else { return }
        defer { lastPluggedIn = reading.pluggedIn }
        guard let last = lastPluggedIn, last != reading.pluggedIn else { return }
        show(reading.pluggedIn ? .charging(reading.percent) : .unplugged(reading.percent))
    }

    private func checkStore() {
        guard geometry != nil else { return }
        callTick += 1
        // Listing the microphone's users is a handful of calls to coreaudiod;
        // every other second is plenty for something that lasts minutes.
        if (eventsOn || peekOn) && callTick % 2 == 0 {
            switch media.refreshCall() {
            case .started(let call):
                show(.callStarted(call.shortName))
            case .ended(let call):
                show(.callEnded(CallClock.string(Int(Date().timeIntervalSince(call.since)))))
            case nil:
                break
            }
            let hasCall = media.call != nil
            if hasCall != model.hasCall {
                withAnimation(expandAnimation) { model.hasCall = hasCall }
            }
        }
        guard eventsOn else { return }

        let devices = store.peripherals
        let ids = Set(devices.map(\.id))
        if let known = knownDevices, Date().timeIntervalSince(startedAt) > 10 {
            for device in devices where !known.contains(device.id) {
                show(.device(symbol: device.symbol, percent: device.lowest))
            }
        }
        knownDevices = ids

        let online: Bool?
        switch store.connectivity.status {
        case .online: online = true
        case .offline: online = false
        case .pending: online = nil
        }
        if let online {
            if let last = lastOnline, last != online { show(online ? .online : .offline) }
            lastOnline = online
        }
    }
}
