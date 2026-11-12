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
            // The Air reports 33.5pt. A half-point height leaves the window 0.5pt
            // short of a whole point, and the gap shows as a grey line on top.
            let height = screen.safeAreaInsets.top.rounded(.up)
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
    /// A resource alert starting: its symbol, short text, and whether it is
    /// serious (red) rather than a warning (amber).
    case resource(symbol: String, text: String, critical: Bool)
    case meetingSoon(minutes: Int)
    case meetingNow
    case lowBattery(Int)

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
        case .resource(let symbol, _, _): return symbol
        case .meetingSoon: return "calendar"
        case .meetingNow: return "video.fill"
        case .lowBattery: return "battery.25"
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
        case .resource(_, let text, _): return text
        case .meetingSoon(let minutes): return L("%d phút", minutes)
        case .meetingNow: return L("Bắt đầu")
        case .lowBattery(let percent): return "\(percent)%"
        }
    }

    var tint: Color {
        switch self {
        case .charging, .online, .callStarted: return Palette.memory
        case .callEnded: return Palette.critical
        case .offline: return Palette.critical
        case .unplugged(let percent), .device(_, let percent):
            return percent <= 20 ? Palette.critical : .white
        case .resource(_, _, let critical): return critical ? Palette.critical : Palette.warning
        case .meetingSoon, .meetingNow: return Palette.cpu
        case .lowBattery: return Palette.critical
        }
    }

    /// One wing, wide enough for whichever side is wider.
    var wingWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return max(ceil(textWidth), 20) + 24
    }
}

enum NotchPage: Hashable {
    case main, clipboard, ai
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
        /// The screen is being shared in a meeting: a red glow round the
        /// notch, for as long as it lasts.
        case sharing
    }

    struct Layout {
        var size: CGSize
        /// The concave flare that blends the shape into the top edge.
        var shoulder: CGFloat
        var corner: CGFloat
    }

    @Published var mode: Mode = .hidden
    var notch = CGSize(width: 185, height: 32)

    /// A call in progress, a meeting coming up and a resource alert each add
    /// a row to the panel.
    @Published var hasCall = false
    @Published var hasMeeting = false
    @Published var hasAlert = false
    /// The panel's pages, side by side, swiped between: the main one, and
    /// the clipboard and AI usage when they are turned on.
    @Published var pages: [NotchPage] = [.main]
    @Published var page: NotchPage = .main
    var hasPages: Bool { pages.count > 1 }
    /// Music, outputs, and the shelf.
    private static let bodyHeight: CGFloat = 190
    private static let rowHeight: CGFloat = 60
    private var extraRows: Int { [hasCall, hasMeeting, hasAlert].filter { $0 }.count }
    /// The page dots under the panel's rows.
    static let dotsHeight: CGFloat = 16
    var peekBodyHeight: CGFloat {
        Self.bodyHeight + Self.rowHeight * CGFloat(extraRows) + (hasPages ? Self.dotsHeight : 0)
    }

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
        case .sharing:
            return Layout(size: CGSize(width: notch.width + 28, height: notch.height + 2), shoulder: 5, corner: 11)
        }
    }

    /// The window: the largest shape plus room for its shadow.
    var canvas: CGSize {
        CGSize(width: peekInnerWidth + 24 + 80,
               height: notch.height + Self.bodyHeight + Self.rowHeight * 3 + Self.dotsHeight + 44)
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

/// The objects the panel shows, passed down together.
struct NotchParts {
    let store: MonitorStore
    let media: NotchMedia
    let resources: ResourceWatch
    let meetings: MeetingWatcher
    let shelf: NotchShelf
    let keepAwake: KeepAwake
    let clipboard: ClipboardHistory
    let ai: AIUsageWatcher
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let parts: NotchParts
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(model.mode == .hidden ? 0 : 1)
        // The panel sits in the notch, which SwiftUI may count as unsafe
        // area and push the shape down from; it must start at the very top.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var glow: Color {
        switch model.mode {
        case .event(let event): return event.tint.opacity(0.35)
        case .peek: return .black.opacity(0.5)
        case .sharing: return Palette.critical.opacity(0.85)
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
            NotchPeek(model: model, parts: parts, store: parts.store, media: parts.media,
                      resources: parts.resources, meetings: parts.meetings, keepAwake: parts.keepAwake,
                      notch: model.notch, onOpenTacho: onClick)
                .transition(.notchContent(reduceMotion: reduceMotion))
        case .sharing:
            SharingMarks(notch: model.notch)
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
    @ObservedObject var model: NotchModel
    let parts: NotchParts
    @ObservedObject var store: MonitorStore
    @ObservedObject var media: NotchMedia
    @ObservedObject var resources: ResourceWatch
    @ObservedObject var meetings: MeetingWatcher
    @ObservedObject var keepAwake: KeepAwake
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
                awakeButton
                    .padding(.leading, 10)
                Spacer(minLength: 0)

                Color.clear.frame(width: notch.width)

                battery.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: notch.height)

            pager
            if model.hasPages {
                PageDots(pages: model.pages, page: $model.page)
                    .frame(height: NotchModel.dotsHeight - 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, model.hasPages ? 6 : 0)
    }

    /// Every page side by side, slid along to the current one.
    private var pager: some View {
        let width = model.peekInnerWidth - 24
        let gap: CGFloat = 24
        let index = CGFloat(model.pages.firstIndex(of: model.page) ?? 0)
        return HStack(alignment: .top, spacing: gap) {
            ForEach(model.pages, id: \.self) { page in
                Group {
                    switch page {
                    case .main: mainPage
                    case .clipboard: ClipboardPage(clipboard: parts.clipboard)
                    case .ai: AIUsagePage(watcher: parts.ai)
                    }
                }
                .frame(width: width, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(page == model.page ? 1 : 0.3)
            }
        }
        .offset(x: -index * (width + gap))
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var mainPage: some View {
        VStack(spacing: 8) {
            if let alert = resources.current {
                AlertRow(alert: alert).riseIn(0)
            }
            if let meeting = meetings.next, MeetingRow.shows(meeting) {
                MeetingRow(meeting: meeting).riseIn(0)
            }
            if let call = media.call {
                CallRow(call: call, media: media).riseIn(0)
            }
            NowPlayingRow(media: media).riseIn(1)
            OutputRow(media: media).riseIn(2)
            ShelfView(shelf: parts.shelf)
                .frame(height: 44)
                .riseIn(3)
        }
    }

    /// Keeps the Mac awake: a click turns it on until clicked again, the
    /// menu sets a time limit.
    private var awakeButton: some View {
        Button { keepAwake.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 12, weight: .semibold))
                if let until = keepAwake.until {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Fmt.minutes(max(1, Int(until.timeIntervalSince(context.date) / 60))))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
            .foregroundStyle(keepAwake.isOn ? Palette.warning : .white.opacity(0.45))
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle())
        .help(keepAwake.isOn ? L("Đang giữ máy thức. Bấm để tắt.") : L("Giữ máy thức. Chuột phải để chọn thời gian."))
        .contextMenu {
            Button(L("Giữ thức 1 giờ")) { keepAwake.start(hours: 1) }
            Button(L("Giữ thức 2 giờ")) { keepAwake.start(hours: 2) }
            Button(L("Giữ thức đến khi tắt")) { keepAwake.start(hours: nil) }
            if keepAwake.isOn { Button(L("Tắt")) { keepAwake.stop() } }
        }
    }

    @ViewBuilder private var battery: some View {
        let sample = store.battery
        if sample.isPresent {
            HStack(spacing: 6) {
                if sample.isCharging && sample.timeRemaining > 0 {
                    Text(L("Đầy sau ") + Fmt.minutes(sample.timeRemaining))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.memory.opacity(0.9))
                        .lineLimit(1)
                }
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
    @ObservedObject var media: NotchMedia

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
                HStack(spacing: 4) {
                    if media.cameraOn {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.memory)
                    }
                    Text(call.title ?? L("Đang trong cuộc gọi"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(CallClock.string(Int(context.date.timeIntervalSince(call.since))))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.memory)
            }
            Button { media.toggleMic() } label: {
                Image(systemName: media.micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(media.micMuted ? Color.white : .white.opacity(0.85))
                    .frame(width: 28, height: 24)
                    .background(Capsule().fill(media.micMuted ? Palette.critical : Color.white.opacity(0.14)))
            }
            .buttonStyle(NotchButtonStyle())
            .help(media.micMuted ? L("Bật micro") : L("Tắt micro"))
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
            .strokeBorder(Palette.memory.opacity(0.28), lineWidth: 1)
            .allowsHitTesting(false))
        // The whole row opens the call, not just the small button.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { call.activate() }
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
            // Sideways swipes turn the page, so the chips share the width
            // instead of scrolling.
            HStack(spacing: 6) {
                ForEach(media.outputs.prefix(5)) { output in
                    chip(output, selected: output.id == media.selectedOutput)
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
                Text(output.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: selected ? nil : .infinity)
            .frame(height: 26)
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.09)))
        }
        .buttonStyle(NotchButtonStyle())
    }
}

/// A resource alert: what is wrong, and a way to act on it.
private struct AlertRow: View {
    let alert: ResourceAlert

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let icon = alert.icon {
                    Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: alert.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(alert.tint)
                        .frame(width: 30, height: 30)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(alert.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let app = alert.app {
                Button { app.terminate() } label: {
                    Text(L("Thoát"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(Capsule().fill(alert.tint.opacity(0.6)))
                }
                .buttonStyle(NotchButtonStyle())
            }
            Button { ActivityMonitor.open() } label: {
                if let icon = ActivityMonitor.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
            }
            .buttonStyle(NotchButtonStyle())
            .help(L("Mở Activity Monitor"))
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(alert.tint.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(alert.tint.opacity(0.28), lineWidth: 1)
            .allowsHitTesting(false))
    }
}

/// The next meeting from the calendar, with a button to join it.
private struct MeetingRow: View {
    let meeting: Meeting

    /// Within the hour before it starts, and while it runs.
    static func shows(_ meeting: Meeting, at date: Date = Date()) -> Bool {
        date >= meeting.start.addingTimeInterval(-3600) && date < meeting.end
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(meeting.color.opacity(0.25))
                Image(systemName: meeting.joinURL == nil ? "calendar" : "video.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(meeting.color)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(when(at: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if meeting.joinURL != nil {
                Button { meeting.join() } label: {
                    Text(L("Vào họp"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(Capsule().fill(Palette.cpu.opacity(0.75)))
                }
                .buttonStyle(NotchButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func when(at date: Date) -> String {
        let format = DateFormatter()
        format.timeStyle = .short
        format.dateStyle = .none
        let range = format.string(from: meeting.start) + "–" + format.string(from: meeting.end)
        if date >= meeting.start {
            let left = Int(meeting.end.timeIntervalSince(date) / 60)
            return L("Đang diễn ra · còn %d phút", max(left, 1))
        }
        let minutes = Int((meeting.start.timeIntervalSince(date) / 60).rounded(.up))
        return L("Sau %d phút · %@", minutes, range)
    }
}

/// Files dropped on the notch, to drag out again later.
private struct ShelfView: View {
    @ObservedObject var shelf: NotchShelf
    @StateObject private var targeted = NotchFlag()

    var body: some View {
        HStack(spacing: 6) {
            if shelf.files.isEmpty {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(L("Thả file vào đây"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 4) {
                        ForEach(shelf.files, id: \.self) { url in
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                                .help(url.lastPathComponent)
                                .onDrag { NSItemProvider(object: url as NSURL) }
                                .contextMenu {
                                    Button(L("Hiện trong Finder")) {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                    Button(L("Bỏ khỏi kệ")) { shelf.remove(url) }
                                }
                        }
                }
                Spacer(minLength: 0)
                Button { shelf.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(NotchButtonStyle())
                .help(L("Dọn kệ"))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(targeted.on ? 0.16 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(targeted.on ? 0.5 : 0.15),
                          style: StrokeStyle(lineWidth: 1, dash: shelf.files.isEmpty ? [4] : []))
            .allowsHitTesting(false))
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { targeted.on }, set: { targeted.on = $0 })) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { shelf.add([url]) } }
                }
            }
            return true
        }
    }
}

/// The red glow's companions while the screen is shared: a dot pulsing
/// either side of the notch.
private struct SharingMarks: View {
    let notch: CGSize
    @StateObject private var pulse = NotchFlag()

    var body: some View {
        HStack {
            dot
            Spacer(minLength: notch.width)
            dot
        }
        .padding(.horizontal, 3)
        .frame(height: notch.height)
        .onAppear { pulse.on = true }
    }

    private var dot: some View {
        Circle()
            .fill(Palette.critical)
            .frame(width: 6, height: 6)
            .opacity(pulse.on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse.on)
    }
}

/// Which page the panel shows, and a click to change it.
private struct PageDots: View {
    let pages: [NotchPage]
    @Binding var page: NotchPage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(pages, id: \.self) { index in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { page = index }
                } label: {
                    Capsule()
                        .fill(Color.white.opacity(page == index ? 0.85 : 0.25))
                        .frame(width: page == index ? 14 : 6, height: 6)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The second page: what was copied lately. A click copies it again.
private struct ClipboardPage: View {
    @ObservedObject var clipboard: ClipboardHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Clipboard"))
                    .textCase(.uppercase)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if !clipboard.items.isEmpty {
                    Button(L("Xoá hết")) { clipboard.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 2)
            if !clipboard.items.isEmpty {
                searchField
            }
            if clipboard.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(L("Những gì bạn copy sẽ hiện ở đây."))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        if clipboard.filtered.isEmpty {
                            Text(L("Không có mục nào khớp."))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 12)
                        }
                        ForEach(clipboard.filtered) { item in
                            ClipboardRow(item: item, copied: clipboard.justCopied == item.id,
                                         onCopy: { clipboard.copy(item) }, onRemove: { clipboard.remove(item) })
                        }
                    }
                }
            }
        }
    }
}

private extension ClipboardPage {
    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            TextField(L("Tìm trong clipboard"), text: $clipboard.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .onExitCommand { clipboard.query = "" }
            if !clipboard.query.isEmpty {
                Button { clipboard.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.1)))
    }
}

private struct ClipboardRow: View {
    let item: ClipboardHistory.Item
    let copied: Bool
    var onCopy: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            preview
            Spacer(minLength: 6)
            if copied {
                Text(L("Đã copy"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.memory)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.ago(item.date, now: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(copied ? Palette.memory.opacity(0.18) : Color.white.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture(perform: onCopy)
        .help(L("Bấm để copy lại"))
    }

    /// "now", "5 min", "2 hr": short enough for the row's edge.
    private static let agoFormat: RelativeDateTimeFormatter = {
        let format = RelativeDateTimeFormatter()
        format.unitsStyle = .short
        format.locale = Locale(identifier: L10n.current.rawValue)
        return format
    }()

    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? L("vừa xong") : agoFormat.localizedString(for: date, relativeTo: now)
    }

    @ViewBuilder private var preview: some View {
        HStack(spacing: 8) {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            switch item.content {
            case .text(let text):
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 60, maxHeight: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(L("Ảnh")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            case .files(let urls):
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path))
                    .resizable().frame(width: 20, height: 20)
                Text(urls.count == 1 ? urls[0].lastPathComponent : L("%d file", urls.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// The third page: how much of Claude Code's and Codex's plans is used,
/// and today's tokens.
private struct AIUsagePage: View {
    @ObservedObject var watcher: AIUsageWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Trợ lý AI"))
                .textCase(.uppercase)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 2)
            if watcher.claude == nil && watcher.codex == nil {
                Text(L("Chưa thấy Claude Code hay Codex trên máy này."))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if let claude = watcher.claude {
                        AssistantCard(name: "Claude Code", symbol: "sparkle", usage: claude,
                                      missing: claudeMissing)
                    }
                    if let codex = watcher.codex {
                        AssistantCard(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right",
                                      usage: codex, missing: L("Hạn mức hiện sau lượt Codex tiếp theo."))
                    }
                }
            }
        }
        .onAppear { watcher.refresh() }
    }

    /// Why Claude Code's limits are not shown, if they are not.
    private var claudeMissing: String {
        switch watcher.hookup {
        case .none: return L("Bật Kết nối Claude Code trong Cài đặt để xem hạn mức.")
        case .tacho: return L("Hạn mức cập nhật mỗi khi bạn dùng claude trong terminal.")
        case .other: return L("Claude Code đang dùng statusLine khác, nên chưa có hạn mức.")
        }
    }
}

private struct AssistantCard: View {
    let name: String
    let symbol: String
    let usage: AssistantUsage
    let missing: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.warning)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !usage.windows.isEmpty, let updated = usage.windowsUpdated,
                   Date().timeIntervalSince(updated) > 600 {
                    Text(ClipboardRow.ago(updated, now: Date()))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .help(L("Lần cập nhật hạn mức gần nhất"))
                }
            }
            if usage.windows.isEmpty {
                Text(missing)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(usage.windows) { window in
                    WindowBar(window: window)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(Self.tokens(usage.tokensToday))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                Text(L("token hôm nay"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .help(L("Không tính %@ token đọc lại từ cache", Self.tokens(usage.cachedToday)))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    /// "1.2M", "295K".
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(count) / 1_000)
        default: return "\(count)"
        }
    }
}

/// One limit window: how full, and when it empties.
private struct WindowBar: View {
    let window: LimitWindow

    /// The window has started over since it was read, so the number is old.
    private var hasReset: Bool { window.resetsAt.map { $0 < Date() } ?? false }

    private var tint: Color {
        if hasReset { return .white.opacity(0.35) }
        switch window.usedPercent {
        case 95...: return Palette.critical
        case 80...: return Palette.warning
        default: return Palette.cpu
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                if let reset = window.resetsAt, !hasReset {
                    Text("· " + L("Reset %@", Self.when(reset)))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(hasReset ? L("Đã reset") : String(format: "%.0f%%", window.usedPercent))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(tint)
                        .frame(width: hasReset ? 0 : geometry.size.width * min(max(window.usedPercent / 100, 0), 1))
                }
            }
            .frame(height: 5)
        }
    }

    /// "14:30" today, "Fri 03:00" later in the week.
    static func when(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: L10n.current.rawValue)
        format.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jmm" : "EEEjmm")
        return format.string(from: date)
    }
}

// MARK: - Controller

/// AppKit keeps windows clear of the menu bar on some Macs (seen on a
/// MacBook Air M2), which left a strip of wallpaper above the shape. The
/// panel belongs exactly at the top edge, so it opts out.
final class NotchPanel: NSPanel {
    /// Only while the clipboard's search can be typed in. Being a
    /// non-activating panel, it takes the keyboard without bringing Tacho to
    /// the front, the way Spotlight does.
    var allowsKey = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Sits exactly over the camera housing, painted black so it cannot be
/// seen. Files dragged there open the panel to drop them on the shelf: a
/// drag in progress sends no mouse events to other apps, so only a window
/// under the pointer hears about it. It also reports the pointer resting
/// there, which the global mouse monitor no longer sees once this window is
/// under it.
final class NotchCatcherView: NSView {
    var onPointer: (() -> Void)?
    var onDrag: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                               .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Rounded at the bottom like the camera housing, and drawn a little
    /// inside it (see `catcherFrame`), so no square corner shows past the
    /// hardware's rounded ones.
    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 8
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: bounds.maxY))
        path.line(to: NSPoint(x: bounds.minX, y: bounds.minY + radius))
        path.appendArc(withCenter: NSPoint(x: bounds.minX + radius, y: bounds.minY + radius), radius: radius,
                       startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: bounds.maxX - radius, y: bounds.minY))
        path.appendArc(withCenter: NSPoint(x: bounds.maxX - radius, y: bounds.minY + radius), radius: radius,
                       startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        path.close()
        NSColor.black.setFill()
        path.fill()
    }

    override func mouseEntered(with event: NSEvent) { onPointer?() }
    override func mouseMoved(with event: NSEvent) { onPointer?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrag?()
        // Not dropped here: the panel opening over it takes the drop.
        return []
    }
}

/// Owns the panel over the notch: watches for events worth showing in its
/// wings, and for the pointer resting on it.
@MainActor
final class NotchController {
    private let store: MonitorStore
    private let model = NotchModel()
    private let media = NotchMedia()
    private let resources = ResourceWatch()
    private let meetings = MeetingWatcher.shared
    private let shelf = NotchShelf()
    private let keepAwake = KeepAwake()
    private let clipboard = ClipboardHistory()
    private let ai = AIUsageWatcher.shared
    private var clipboardOn = false
    private var aiOn = false
    /// AI limit warnings already shown, by assistant, window, level and reset.
    private var aiWarned: Set<String> = []
    private var sharing = false
    /// Holds the sharing glow on for `--notch-demo`, with no real call.
    private var demoSharing = false
    /// A sideways swipe in progress, added up until it is far enough.
    private var swipe: CGFloat = 0
    private var swipeDone = false
    /// The current gesture went sideways, so its momentum is the panel's too.
    private var swipeSideways = false
    /// No new page turn before this, so one flick turns one page.
    private var swipeCooldown = Date.distantPast
    private var lastScroll = Date.distantPast
    private var meetingsOn = false
    /// Meeting reminders already shown, by meeting and kind.
    private var announced: Set<String> = []
    /// The low-battery level last warned about, until the charger goes in.
    private var batteryWarned: Int?
    /// Refreshes the song and the output list while the panel is open.
    private var peekTimer: Timer?
    private var callTick = 0
    /// Keeps the demo's panel open wherever the pointer is.
    private var demoPinned = false
    private var panel: NSPanel?
    private var catcher: NSPanel?
    private var panelFrame: CGRect?
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
        settings.$notchMeetings
            .sink { [weak self] on in
                guard let self else { return }
                self.meetingsOn = on
                if on { self.meetings.start() } else { self.meetings.stop() }
            }
            .store(in: &cancellables)
        model.$page
            .sink { [weak self] page in self?.updateKeyAllowance(page: page) }
            .store(in: &cancellables)
        settings.$notchClipboard
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.clipboard.start() } else { self.clipboard.stop() }
                self.clipboardOn = on
                self.updatePages()
            }
            .store(in: &cancellables)
        settings.$notchAI
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.ai.start() } else { self.ai.stop() }
                self.aiOn = on
                self.updatePages()
            }
            .store(in: &cancellables)
        ai.$codex.combineLatest(ai.$claude)
            .receive(on: RunLoop.main)
            .sink { [weak self] codex, claude in self?.checkAILimits(codex: codex, claude: claude) }
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
        updateCatcher()
        store.watchHeavyApps = (events || peek) && geometry != nil
        if !store.watchHeavyApps { resources.reset() }
        if events && geometry != nil {
            startPowerWatch()
        } else {
            stopPowerWatch()
            knownDevices = nil
            lastOnline = nil
            pending.removeAll()
        }
        if !events, case .event = model.mode { collapse() }
        if !events, sharing {
            sharing = false
            if model.mode == .sharing { collapse() }
        }
        if !peek, model.mode == .peek { collapse() }
    }

    private func updateCatcher() {
        catcher?.orderOut(nil)
        catcher = nil
        guard peekOn, let geometry else { return }
        // Inside the housing on every side but the top, the same margin the
        // idle shape keeps, so it stays hidden behind the hardware.
        var frame = geometry.rect.insetBy(dx: 6, dy: 0)
        frame.origin.y += 3
        frame.size.height -= 3
        let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Just under the notch panel, so the panel takes over once open.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let view = NotchCatcherView(frame: CGRect(origin: .zero, size: frame.size))
        view.onPointer = { [weak self] in self?.pointerMoved() }
        view.onDrag = { [weak self] in self?.filesDragged() }
        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        catcher = panel
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
        let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // Not .fullScreenAuxiliary: a full-screen app keeps its notch area.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let parts = NotchParts(store: store, media: media, resources: resources, meetings: meetings,
                               shelf: shelf, keepAwake: keepAwake, clipboard: clipboard, ai: ai)
        let host = NSHostingView(rootView: NotchView(model: model, parts: parts, reduceMotion: reduceMotion) {
            [weak self] in
            self?.collapse()
            MenuBarPopover.openMainWindow()
        })
        host.frame = CGRect(origin: .zero, size: canvas)
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        panel.contentView = host
        panel.setFrame(frame, display: false)
        self.panel = panel
        panelFrame = frame
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
            // Placed again after ordering in, in case the system moved it
            // while it was off screen.
            if let panelFrame, panel.frame != panelFrame { panel.setFrame(panelFrame, display: false) }
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
        releaseKeyboard()
        clipboard.query = ""
        peekTimer?.invalidate()
        peekTimer = nil
        media.stopPlayback()


        // While the screen is shared the notch keeps its red glow.
        if sharing && eventsOn && geometry != nil {
            guard model.mode != .sharing else { return }
            withAnimation(collapseAnimation) { model.mode = .sharing }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.showNextEvent() }
            return
        }
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
        case .hidden, .sharing:
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
        // A two-finger swipe sideways on the panel turns the page.
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.takesSwipe(event) ?? false }
            return consumed ? nil : event
        }) {
            mouseMonitors.append(scroll)
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

    /// The clipboard page's search can be typed in; the other page never
    /// takes the keyboard from the app in front.
    private func updateKeyAllowance(page: NotchPage) {
        (panel as? NotchPanel)?.allowsKey = page == .clipboard
        if page != .clipboard { releaseKeyboard() }
    }

    private func updatePages() {
        var pages: [NotchPage] = [.main]
        if clipboardOn { pages.append(.clipboard) }
        if aiOn { pages.append(.ai) }
        model.pages = pages
        if !pages.contains(model.page) { model.page = .main }
    }

    /// Says so once when an assistant's window passes 80% and again at 95%,
    /// per reset, so a window that resets can warn again.
    private func checkAILimits(codex: AssistantUsage?, claude: AssistantUsage?) {
        guard eventsOn, aiOn else { return }
        for (name, usage) in [("Codex", codex), ("Claude", claude)] {
            for window in usage?.windows ?? [] {
                guard let level = [95.0, 80.0].first(where: { window.usedPercent >= $0 }) else { continue }
                let key = "\(name)|\(window.label)|\(Int(level))|\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
                guard aiWarned.insert(key).inserted else { continue }
                // Crossing 95% also counts as having passed 80%.
                aiWarned.insert("\(name)|\(window.label)|80|\(window.resetsAt?.timeIntervalSince1970 ?? 0)")
                show(.resource(symbol: "gauge.with.dots.needle.67percent",
                               text: "\(name) \(window.label) \(Int(window.usedPercent))%", critical: level >= 95))
            }
        }
    }

    private func releaseKeyboard() {
        guard let panel = panel as? NotchPanel else { return }
        panel.allowsKey = false
        if panel.isKeyWindow { panel.resignKey() }
        clipboard.query = ""
    }

    /// Whether the panel takes this scroll as a page swipe.
    /// One swipe turns one page. A Magic Mouse keeps sending momentum
    /// scrolls after the finger lifts, and counting those as a new swipe
    /// skipped a page, so momentum never turns one, and after a turn the
    /// panel waits a moment before taking the next.
    private func takesSwipe(_ event: NSEvent) -> Bool {
        guard model.mode == .peek, model.hasPages, event.window === panel else { return false }
        let sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let now = Date()

        // Momentum after the fingers lift: swallowed if sideways, never counted.
        if !event.momentumPhase.isEmpty {
            return sideways && swipeSideways
        }
        if event.phase == .began || event.phase == .mayBegin {
            swipe = 0
            swipeDone = false
            swipeSideways = false
        } else if event.phase.isEmpty, now.timeIntervalSince(lastScroll) > 0.3 {
            // A wheel without gesture phases: a pause starts a new swipe.
            swipe = 0
            swipeDone = false
        }
        lastScroll = now
        guard sideways || swipe != 0 else { return false }
        if sideways { swipeSideways = true }

        if !swipeDone, now >= swipeCooldown {
            swipe += event.scrollingDeltaX
            if abs(swipe) > 40 {
                swipeDone = true
                swipeCooldown = now.addingTimeInterval(0.4)
                let pages = model.pages
                let index = pages.firstIndex(of: model.page) ?? 0
                // Content follows the fingers: swiping left brings the next page.
                let next = min(max(index + (swipe < 0 ? 1 : -1), 0), pages.count - 1)
                let target = pages[next]
                if target != model.page {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.page = target }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            swipe = 0
        }
        // Sideways swipes are the panel's; vertical ones still scroll lists.
        return sideways
    }

    /// Files dragged onto the notch: open the panel at once, no dwell.
    private func filesDragged() {
        guard peekOn, model.mode != .peek else { return }
        hoverWork?.cancel()
        hoverWork = nil
        openPeek()
    }

    private func openPeek() {
        dismissWork?.cancel()
        pending.removeAll()
        media.refreshCall()
        media.refreshDevices()
        shelf.prune()
        model.hasCall = media.call != nil
        model.hasAlert = resources.current != nil
        model.hasMeeting = meetingShows
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
        updateKeyAllowance(page: model.page)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: Demo

    /// `--notch-demo`: plays each state once, for checking the animation and
    /// recording it, without waiting for a charger or a pointer.
    /// `--notch-info`: opens the panel, prints where it really ended up next
    /// to what the screen reports, and quits. For Macs where it does not sit
    /// flush with the top edge.
    func printInfo() {
        configure(events: true, peek: peekOn)
        demoPinned = true
        openPeek()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            var lines = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            lines.append("model \(String(cString: model))")
            for screen in NSScreen.screens {
                lines.append("screen \(screen.localizedName) frame \(screen.frame) visible \(screen.visibleFrame) "
                             + "scale \(screen.backingScaleFactor) safeTop \(screen.safeAreaInsets.top) "
                             + "left \(screen.auxiliaryTopLeftArea ?? .zero) right \(screen.auxiliaryTopRightArea ?? .zero)")
            }
            lines.append("menu bar \(NSApp.mainMenu?.menuBarHeight ?? -1) status bar \(NSStatusBar.system.thickness)")
            lines.append("notch \(geometry?.rect ?? .zero)")
            lines.append("panel wanted \(panelFrame ?? .zero) actual \(panel?.frame ?? .zero) "
                         + "level \(panel?.level.rawValue ?? 0) onscreen \(panel?.isVisible ?? false)")
            if let host = panel?.contentView {
                lines.append("host frame \(host.frame) safe area \(host.safeAreaInsets)")
            }
            if let call = CallDetector.current() {
                lines.append("call \(call.name) (\(call.bundleID), pid \(call.pid))")
            }
            lines.append("sharing \(ScreenSharing.isSharing)")
            for window in ScreenSharing.windows() {
                let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
                lines.append("  window \(window[kCGWindowOwnerName as String] ?? "?") layer \(window[kCGWindowLayer as String] ?? "?") "
                             + "\(bounds["X"] ?? 0),\(bounds["Y"] ?? 0) \(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0) "
                             + "alpha \(window[kCGWindowAlpha as String] ?? "?")")
            }
            print(lines.joined(separator: "\n"))
            exit(0)
        }
    }

    func runDemo() {
        configure(events: true, peek: peekOn)
        let steps: [(TimeInterval, () -> Void)] = [
            (1, { self.show(.charging(64)) }),
            (5, { self.show(.device(symbol: "airpodspro", percent: 82)) }),
            (9, { self.show(.callStarted("Teams")) }),
            (13, { self.show(.resource(symbol: "flame.fill", text: "Chrome 180%", critical: false)) }),
            (17, { self.show(.meetingSoon(minutes: 5)) }),
            (21, { self.demoSharing = true; self.sharing = true; self.expand(to: .sharing) }),
            (25, { self.demoPinned = true; self.openPeek() }),
            (29, { self.clipboard.addSamples(); withAnimation { self.model.page = .clipboard } }),
            (31, { if self.model.pages.contains(.ai) { withAnimation { self.model.page = .ai } } }),
            (33, { withAnimation { self.model.page = .main } }),
            (34, { self.demoPinned = false; self.demoSharing = false; self.sharing = false; self.collapse() }),
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
            if hasCall || model.mode == .peek { media.refreshDevices() }
            // Sharing only happens in a call; outside one there is nothing to look for.
            let nowSharing = demoSharing || (eventsOn && hasCall && ScreenSharing.isSharing)
            if nowSharing != sharing {
                sharing = nowSharing
                if sharing, model.mode == .hidden {
                    expand(to: .sharing)
                } else if !sharing, model.mode == .sharing {
                    collapse()
                }
            }
        }

        if eventsOn || peekOn {
            if let started = resources.update(store: store) {
                show(.resource(symbol: started.symbol, text: started.short, critical: started.kind == .memory))
            }
            let hasAlert = resources.current != nil
            if hasAlert != model.hasAlert {
                withAnimation(expandAnimation) { model.hasAlert = hasAlert }
            }
            let hasMeeting = meetingShows
            if hasMeeting != model.hasMeeting {
                withAnimation(expandAnimation) { model.hasMeeting = hasMeeting }
            }
        }
        guard eventsOn else { return }

        if meetingsOn, let meeting = meetings.next {
            let until = meeting.start.timeIntervalSinceNow
            if until > 0, until <= 5 * 60, announced.insert(meeting.id + "|soon").inserted {
                show(.meetingSoon(minutes: max(1, Int((until / 60).rounded(.up)))))
            } else if until <= 0, until > -120, announced.insert(meeting.id + "|now").inserted {
                show(.meetingNow)
            }
        }

        let battery = store.battery
        if battery.isPresent {
            if battery.isPluggedIn {
                batteryWarned = nil
            } else {
                let percent = Int((battery.percentage * 100).rounded())
                for level in [10, 20] where percent <= level && (batteryWarned ?? 101) > level {
                    batteryWarned = level
                    show(.lowBattery(percent))
                    break
                }
            }
        }

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

    // MARK: Meetings

    private var meetingShows: Bool {
        guard meetingsOn, let meeting = meetings.next else { return false }
        return MeetingRow.shows(meeting)
    }

}
