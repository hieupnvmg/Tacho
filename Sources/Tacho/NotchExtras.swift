import AppKit
import CoreAudio
import CoreMediaIO
import EventKit
import IOKit.pwr_mgt
import SwiftUI

// MARK: - Microphone

/// Mutes the default microphone for every app at once, the way a hardware
/// mute switch would. Teams and the rest keep their own mute buttons; this
/// one works whichever app has the call.
enum Microphone {
    private static var savedVolume: Float32?

    static var defaultInput: AudioDeviceID {
        AudioOutputs.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                           default: AudioDeviceID(0))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func settable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static var isMuted: Bool {
        let device = defaultInput
        guard device != 0 else { return false }
        if settable(device, kAudioDevicePropertyMute) {
            return AudioOutputs.value(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput,
                                      default: UInt32(0)) != 0
        }
        return savedVolume != nil
    }

    /// Uses the device's mute switch where it has one; otherwise turns the
    /// input volume to zero and puts it back afterwards.
    static func setMuted(_ muted: Bool) {
        let device = defaultInput
        guard device != 0 else { return }
        if settable(device, kAudioDevicePropertyMute) {
            var address = address(kAudioDevicePropertyMute)
            var value: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            return
        }
        guard settable(device, kAudioDevicePropertyVolumeScalar) else { return }
        var address = address(kAudioDevicePropertyVolumeScalar)
        if muted {
            if savedVolume == nil {
                savedVolume = AudioOutputs.value(device, kAudioDevicePropertyVolumeScalar,
                                                 scope: kAudioDevicePropertyScopeInput, default: Float32(1))
            }
            var zero: Float32 = 0
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero)
        } else {
            var volume = savedVolume ?? 1
            savedVolume = nil
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        }
    }
}

// MARK: - Camera

/// Whether any camera is recording. The system does not say which app has
/// it, only that one does.
enum Camera {
    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static var isOn: Bool {
        var devicesAddress = address(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &devicesAddress, 0, nil, size, &used, &devices) == noErr else {
            return false
        }
        for device in devices {
            var runningAddress = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var running: UInt32 = 0
            var dataUsed: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                         &dataUsed, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - Meetings

/// One entry from the calendar, with its online-meeting link if it has one.
struct Meeting: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let joinURL: URL?

    /// Teams, Zoom, Google Meet and Webex links, from wherever the calendar
    /// put them: the event's URL, its location or its notes.
    static func joinURL(in texts: [String]) -> URL? {
        let pattern = #"https://(teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|[a-z0-9.-]*zoom\.us/j/|meet\.google\.com/|[a-z0-9.-]*webex\.com/)[^\s<>"']+"#
        for text in texts {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return URL(string: String(text[range]))
            }
        }
        return nil
    }

    /// Teams links open in the Teams app rather than a browser tab.
    func join() {
        guard var url = joinURL else { return }
        if url.host?.hasSuffix("teams.microsoft.com") == true,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.teams2") != nil,
           let app = URL(string: url.absoluteString.replacingOccurrences(of: "https://", with: "msteams://")) {
            url = app
        }
        NSWorkspace.shared.open(url)
    }
}

/// Reads the next meeting from the Mac's calendars. Teams meetings show up
/// there once the Microsoft 365 (Exchange) account is added under Internet
/// Accounts, with their join link in the notes.
@MainActor
final class MeetingWatcher: ObservableObject {
    /// One for the app: the notch shows what it finds, Settings its access.
    static let shared = MeetingWatcher()

    @Published private(set) var next: Meeting?
    @Published private(set) var access: Access = .unknown

    enum Access { case unknown, granted, denied }

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?

    /// How far ahead a meeting counts as "next".
    static let lookahead: TimeInterval = 12 * 3600

    func start() {
        guard timer == nil else { return }
        requestAccess { [weak self] granted in
            guard let self else { return }
            self.access = granted ? .granted : .denied
            guard granted else { return }
            self.refresh()
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            self.changeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: self.store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        next = nil
    }

    private func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        let finish: @Sendable (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: finish)
        } else {
            store.requestAccess(to: .event, completion: finish)
        }
    }

    func refresh() {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600),
                                                 end: now.addingTimeInterval(Self.lookahead), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { event in
                guard !event.isAllDay, event.endDate > now, event.status != .canceled else { return false }
                // Meetings this person declined are not theirs to go to.
                let me = event.attendees?.first { $0.isCurrentUser }
                return me?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
        guard let event = upcoming.first else {
            if next != nil { next = nil }
            return
        }
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        let meeting = Meeting(id: event.eventIdentifier ?? event.calendarItemIdentifier,
                              title: event.title ?? L("Cuộc họp"),
                              start: event.startDate, end: event.endDate,
                              color: Color(nsColor: event.calendar?.color ?? .systemBlue),
                              joinURL: Meeting.joinURL(in: texts))
        if meeting != next { next = meeting }
    }
}

// MARK: - Shelf

/// Files dropped on the notch, held there to be dragged out somewhere else.
/// Only references are kept; the files stay where they are.
@MainActor
final class NotchShelf: ObservableObject {
    @Published private(set) var files: [URL] = []

    static let limit = 12

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !files.contains(url) {
            files.append(url)
        }
        if files.count > Self.limit { files.removeFirst(files.count - Self.limit) }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
    func clear() { files.removeAll() }

    /// Drops the files that were moved or deleted since.
    func prune() {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing != files { files = existing }
    }
}

// MARK: - Resource alerts

/// Something about the machine worth a look, shown in the notch while it lasts.
struct ResourceAlert: Equatable {
    enum Kind: Equatable {
        /// One app using a lot of CPU for a while.
        case heavyApp(name: String, bundlePath: String?, cpu: Double)
        case hot(celsius: Int)
        case memory
    }

    let kind: Kind

    var symbol: String {
        switch kind {
        case .heavyApp: return "flame.fill"
        case .hot: return "thermometer.high"
        case .memory: return "memorychip"
        }
    }

    var tint: Color {
        switch kind {
        case .heavyApp, .hot: return Palette.warning
        case .memory: return Palette.critical
        }
    }

    /// Short, for the wings.
    var short: String {
        switch kind {
        case .heavyApp(let name, _, let cpu): return "\(name) \(Int(cpu))%"
        case .hot(let celsius): return "\(celsius)°C"
        case .memory: return L("Hết RAM")
        }
    }

    var title: String {
        switch kind {
        case .heavyApp(let name, _, let cpu): return L("%@ đang dùng %d%% CPU", name, Int(cpu))
        case .hot(let celsius): return L("CPU nóng %d°C", celsius)
        case .memory: return L("Bộ nhớ đang cạn")
        }
    }

    var detail: String {
        switch kind {
        case .heavyApp: return L("Đã hơn nửa phút. Thoát app nếu nó bị treo.")
        case .hot: return L("Máy đang chạy rất nặng; quạt sẽ quay mạnh.")
        case .memory: return L("macOS đang phải nén và đẩy bộ nhớ ra ổ đĩa.")
        }
    }

    var icon: NSImage? {
        if case .heavyApp(_, let path?, _) = kind { return NSWorkspace.shared.icon(forFile: path) }
        return nil
    }

    /// The running app behind a heavy-app alert, to quit it.
    var app: NSRunningApplication? {
        guard case .heavyApp(_, let path?, _) = kind else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }
    }

    /// Two alerts about the same thing, whatever the latest numbers.
    func sameSubject(as other: ResourceAlert?) -> Bool {
        switch (kind, other?.kind) {
        case (.heavyApp(let a, _, _), .heavyApp(let b, _, _)?): return a == b
        case (.hot, .hot?), (.memory, .memory?): return true
        default: return false
        }
    }
}

/// Decides when the machine is struggling enough to say so: a reading has to
/// stay past its threshold for a while, and the alert clears only once it is
/// well back under, so a value hovering on the line does not flicker.
@MainActor
final class ResourceWatch: ObservableObject {
    @Published private(set) var current: ResourceAlert?

    static let heavyCPU: Double = 150
    static let heavyClear: Double = 80
    static let hotCelsius: Double = 95
    static let hotClear: Double = 85
    static let sustain: TimeInterval = 30

    private var heavySince: [String: Date] = [:]
    private var hotSince: Date?
    private var lastProcessCheck = Date.distantPast

    /// Returns a newly started alert, for the notch to announce.
    func update(store: MonitorStore) -> ResourceAlert? {
        let now = Date()
        var alert: ResourceAlert?

        if store.memory.pressureLevel == .critical {
            alert = ResourceAlert(kind: .memory)
        }

        if store.temperature.isPresent {
            let celsius = store.temperature.cpuAverage
            if celsius >= Self.hotCelsius {
                hotSince = hotSince ?? now
            } else if celsius < Self.hotClear {
                hotSince = nil
            }
            if alert == nil, let since = hotSince, now.timeIntervalSince(since) >= Self.sustain {
                alert = ResourceAlert(kind: .hot(celsius: Int(celsius.rounded())))
            }
        }

        // The app list refreshes on its own schedule; only a fresh one counts.
        if store.processesUpdated > lastProcessCheck {
            lastProcessCheck = store.processesUpdated
            var seen: Set<String> = []
            for app in store.appsByCPU {
                let held = current.map { if case .heavyApp(let name, _, _) = $0.kind { return name == app.name }
                                         return false } ?? false
                let threshold = held ? Self.heavyClear : Self.heavyCPU
                guard app.cpu >= threshold else { continue }
                seen.insert(app.id)
                heavySince[app.id] = heavySince[app.id] ?? now
            }
            heavySince = heavySince.filter { seen.contains($0.key) }
        }
        if alert == nil,
           let (id, _) = heavySince.filter({ now.timeIntervalSince($0.value) >= Self.sustain })
               .min(by: { $0.value < $1.value }),
           let app = store.appsByCPU.first(where: { $0.id == id }) {
            alert = ResourceAlert(kind: .heavyApp(name: app.name, bundlePath: app.bundlePath, cpu: app.cpu))
        }

        let started = alert.flatMap { $0.sameSubject(as: current) ? nil : $0 }
        if alert != current { current = alert }
        return started
    }

    func reset() {
        heavySince = [:]
        hotSince = nil
        current = nil
    }
}

/// Opens Activity Monitor, from the notch or a popover.
enum ActivityMonitor {
    static var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
    }

    static var icon: NSImage? { url.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    static func open() {
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Keep awake

/// Keeps the display and the Mac from sleeping, like `caffeinate -d`, until
/// turned off or for a set time.
@MainActor
final class KeepAwake: ObservableObject {
    @Published private(set) var isOn = false
    /// When it turns itself off; nil while it stays on until turned off.
    @Published private(set) var until: Date?

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func toggle() {
        if isOn { stop() } else { start(hours: nil) }
    }

    func start(hours: Double?) {
        stop()
        let reason = "Tacho: keep awake" as CFString
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn), reason,
                                          &assertion) == kIOReturnSuccess else { return }
        isOn = true
        if let hours {
            let end = Date().addingTimeInterval(hours * 3600)
            until = end
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isOn { IOPMAssertionRelease(assertion) }
        assertion = 0
        isOn = false
        until = nil
    }
}

// MARK: - Screen sharing

/// Whether a meeting app is sharing the screen. There is no system call for
/// this, so it goes by what Teams, Zoom and Webex do while sharing: they put
/// a frame around the shared screen, a window of their own the size of a
/// whole display, floating above ordinary windows.
enum ScreenSharing {
    static let apps: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "Cisco-Systems.Spark",
    ]

    /// The meeting apps' windows, for `--notch-info`.
    static func windows() -> [[String: Any]] {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { apps.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? pid_t) ?? -1) }
    }

    static var isSharing: Bool {
        let displays = NSScreen.screens.map(\.frame.size)
        return windows().contains { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat else { return false }
            return displays.contains { abs($0.width - width) <= 4 && abs($0.height - height) <= 4 }
        }
    }
}

// MARK: - Clipboard

/// What was copied lately, to copy again. Never anything a password manager
/// marks as secret. Unless turned off, it is also kept on disk so it lasts
/// past a restart or an update: in Application Support, readable only by
/// this account, not encrypted, for up to a week.
@MainActor
final class ClipboardHistory: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum Content: Equatable {
            case text(String)
            case image(NSImage)
            case files([URL])
        }

        var id = UUID()
        let content: Content
        let date: Date
        let appName: String?
        let appPath: String?

        static func == (a: Item, b: Item) -> Bool { a.id == b.id }

        var icon: NSImage? { appPath.map { NSWorkspace.shared.icon(forFile: $0) } }
    }

    @Published private(set) var items: [Item] = [] {
        didSet { scheduleSave() }
    }
    /// Narrows the list: words in the text, file names, the app's name.
    @Published var query = ""
    /// The item just copied back, for a moment's feedback.
    @Published private(set) var justCopied: UUID?

    static let limit = 20
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount

    /// Types password managers and other apps set on what should not be kept.
    private static let skipped: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]

    func start() {
        guard timer == nil else { return }
        if persists && items.isEmpty { load() }
        changeCount = NSPasteboard.general.changeCount
        // Reading the change count is one cheap call; the pasteboard is only
        // read when it has changed.
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Turning the history off forgets it, on disk too.
    func stop() {
        timer?.invalidate()
        timer = nil
        items = []
        deleteStore()
    }

    // MARK: Keeping it on disk

    /// Whether the history outlasts Tacho quitting. Turned off, what was
    /// saved is deleted and the history lives in memory only.
    var persists = false {
        didSet {
            guard persists != oldValue else { return }
            // On at launch, before anything was copied: load what was saved
            // rather than overwrite it with an empty list.
            if persists { if items.isEmpty { load() } else { save() } } else { deleteStore() }
        }
    }

    /// `--notch-demo` shows sample entries; they must not land in, or show,
    /// the real history.
    private let storageAllowed = !CommandLine.arguments.contains("--notch-demo")
    static let keepFor: TimeInterval = 7 * 86400
    /// Images larger than this stay in memory only.
    private static let largestSavedImage = 5_000_000

    private var store: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tacho/Clipboard", isDirectory: true)
    }

    private struct Saved: Codable {
        var id: UUID
        var kind: String
        var text: String?
        var paths: [String]?
        var date: Date
        var appName: String?
        var appPath: String?
    }

    private var saveWork: DispatchWorkItem?

    private func scheduleSave() {
        guard persists, storageAllowed else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        // Copying in a burst writes once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func save() {
        guard persists, storageAllowed else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: store, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        var saved: [Saved] = []
        var images: Set<String> = []
        for item in items {
            var entry = Saved(id: item.id, kind: "", date: item.date, appName: item.appName, appPath: item.appPath)
            switch item.content {
            case .text(let text):
                entry.kind = "text"
                entry.text = text
            case .files(let urls):
                entry.kind = "files"
                entry.paths = urls.map(\.path)
            case .image(let image):
                let name = item.id.uuidString + ".png"
                let file = store.appendingPathComponent(name)
                if !manager.fileExists(atPath: file.path) {
                    guard let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                          png.count <= Self.largestSavedImage else { continue }
                    manager.createFile(atPath: file.path, contents: png, attributes: [.posixPermissions: 0o600])
                }
                images.insert(name)
                entry.kind = "image"
            }
            saved.append(entry)
        }
        let index = store.appendingPathComponent("history.json")
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: index, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        }
        // Images of entries that are gone.
        for file in (try? manager.contentsOfDirectory(atPath: store.path)) ?? []
        where file.hasSuffix(".png") && !images.contains(file) {
            try? manager.removeItem(at: store.appendingPathComponent(file))
        }
    }

    private func load() {
        guard storageAllowed,
              let data = try? Data(contentsOf: store.appendingPathComponent("history.json")),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        items = saved.filter { $0.date >= cutoff }.compactMap { entry in
            let content: Item.Content
            switch entry.kind {
            case "text":
                guard let text = entry.text else { return nil }
                content = .text(text)
            case "files":
                guard let paths = entry.paths, !paths.isEmpty else { return nil }
                content = .files(paths.map { URL(fileURLWithPath: $0) })
            case "image":
                guard let image = NSImage(contentsOf: store.appendingPathComponent(entry.id.uuidString + ".png"))
                else { return nil }
                content = .image(image)
            default:
                return nil
            }
            return Item(id: entry.id, content: content, date: entry.date, appName: entry.appName, appPath: entry.appPath)
        }
    }

    private func deleteStore() {
        guard storageAllowed else { return }
        saveWork?.cancel()
        try? FileManager.default.removeItem(at: store)
    }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        let types = Set((board.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skipped) else { return }

        let content: Item.Content
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            content = .files(urls)
        } else if let text = board.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = .text(text)
        } else if let image = NSImage(pasteboard: board) {
            content = .image(image)
        } else {
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        items.removeAll { $0.content == content }
        items.insert(Item(content: content, date: Date(), appName: app?.localizedName,
                          appPath: app?.bundleURL?.path), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    /// Puts an item back on the clipboard and moves it to the top.
    func copy(_ item: Item) {
        let board = NSPasteboard.general
        board.clearContents()
        switch item.content {
        case .text(let text): board.setString(text, forType: .string)
        case .image(let image): board.writeObjects([image])
        case .files(let urls): board.writeObjects(urls as [NSURL])
        }
        changeCount = board.changeCount
        items.removeAll { $0.id == item.id }
        let moved = Item(content: item.content, date: Date(), appName: item.appName, appPath: item.appPath)
        items.insert(moved, at: 0)
        justCopied = moved.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.justCopied == moved.id { self?.justCopied = nil }
        }
    }

    /// The items matching the search, ignoring case and accents, so "hop"
    /// finds "họp".
    var filtered: [Item] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            var haystack = item.appName ?? ""
            switch item.content {
            case .text(let text): haystack += " " + text
            case .image: haystack += " " + L("Ảnh")
            case .files(let urls): haystack += " " + urls.map(\.lastPathComponent).joined(separator: " ")
            }
            return words.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Sample entries for `--notch-demo`, without touching the real clipboard.
    func addSamples() {
        let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")?.path
        let samples = ["ssh admin@build-server", "Họp daily lúc 9 giờ 30", "https://github.com/hieupnvmg/Tacho"]
        for (index, text) in samples.enumerated() {
            items.insert(Item(content: .text(text), date: Date().addingTimeInterval(Double(-60 * (3 - index))),
                              appName: "Finder", appPath: finder), at: 0)
        }
    }

    func remove(_ item: Item) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }
}
