import AppKit
import ApplicationServices
import CoreAudio

// MARK: - Audio outputs

/// A device sound can be sent to: the built-in speakers, AirPods, a display.
struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var symbol: String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return "hifispeaker"
        default:
            return "speaker.wave.2"
        }
    }
}

enum AudioOutputs {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var address = address(selector, scope: scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return fallback }
        return value
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// Devices a person would pick from. Virtual ones (Teams' and Zoom's own
    /// audio drivers) and hidden ones are left out.
    static func list() -> [AudioOutput] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return objects(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard !objects(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty,
                  value(id, kAudioDevicePropertyIsHidden, default: UInt32(0)) == 0,
                  value(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput,
                        default: UInt32(1)) != 0 else { return nil }
            let transport = value(id, kAudioDevicePropertyTransportType, default: UInt32(0))
            guard transport != kAudioDeviceTransportTypeVirtual,
                  transport != kAudioDeviceTransportTypeAggregate,
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutput(id: id, name: name, transport: transport)
        }
    }

    static func defaultOutput() -> AudioDeviceID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
              default: AudioDeviceID(0))
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }
}

// MARK: - Now playing

struct NowPlaying: Equatable {
    /// The app playing it: a browser, a web app such as YouTube, Spotify…
    let source: String
    let title: String
    let artist: String
    var isPlaying: Bool
    var artwork: NSImage?

    var sourceName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) else { return source }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var sourceIcon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: source)
            .map { IconCache.icon(forFile: $0.path) }
    }
}

/// Reads macOS's "Now Playing" (the same source as Control Center), so
/// YouTube in a browser counts as much as Spotify or Music.
///
/// The MediaRemote framework behind it stopped answering apps outside Apple
/// in macOS 15.4, but still answers Apple's own `osascript`. So a small
/// JavaScript-for-Automation loop runs in osascript while the notch panel is
/// open, printing one JSON line every half second, and is stopped when the
/// panel closes. Reading needs no permission.
final class NowPlayingStream {
    private static let prelude = """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
        """

    private static let loop = prelude + """
        const Req = $.NSClassFromString('MRNowPlayingRequest');
        const out = $.NSFileHandle.fileHandleWithStandardOutput;
        const text = v => (v === undefined || v.isNil()) ? '' : ObjC.unwrap(v);
        let artKey = null;
        while (true) {
            let line = {};
            try {
                const info = Req.localNowPlayingItem.nowPlayingInfo;
                if (!info.isNil()) {
                    line.title = text(info.valueForKey('kMRMediaRemoteNowPlayingInfoTitle'));
                    line.artist = text(info.valueForKey('kMRMediaRemoteNowPlayingInfoArtist'));
                    line.playing = !!ObjC.unwrap(Req.localIsPlaying);
                    const client = Req.localNowPlayingPlayerPath.client;
                    line.source = text(client.parentApplicationBundleIdentifier) || text(client.bundleIdentifier);
                    const key = line.source + '|' + line.title;
                    if (key !== artKey) {
                        artKey = key;
                        const art = info.valueForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
                        line.art = art.isNil() ? '' : ObjC.unwrap(art.base64EncodedStringWithOptions(0));
                    }
                }
            } catch (e) {}
            // Written every time, not only on change: if Tacho has gone, the
            // write fails and takes this process with it.
            out.writeData($(JSON.stringify(line) + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
            delay(0.5);
        }
        """

    private var process: Process?
    private var buffer = Data()
    private var artwork: NSImage?

    /// `onUpdate` runs on the main queue with nil when nothing is playing.
    func start(onUpdate: @escaping (NowPlaying?) -> Void) {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.loop]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        buffer.removeAll()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data, onUpdate: onUpdate) }
        }
        do { try process.run() } catch { return }
        self.process = process
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    deinit { process?.terminate() }

    private func consume(_ data: Data, onUpdate: (NowPlaying?) -> Void) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let title = json["title"] as? String, !title.isEmpty else {
                onUpdate(nil)
                continue
            }
            // Artwork comes only when the track changes.
            if let art = json["art"] as? String {
                artwork = Data(base64Encoded: art).flatMap(NSImage.init(data:))
            }
            onUpdate(NowPlaying(source: json["source"] as? String ?? "", title: title,
                                artist: json["artist"] as? String ?? "",
                                isPlaying: json["playing"] as? Bool ?? false, artwork: artwork))
        }
    }
}

/// Play, pause and skip, sent as the media keys on the keyboard, so they
/// reach whatever macOS considers to be playing, YouTube in Chrome included.
/// MediaRemote's own commands are no use here: sent from outside Apple's
/// apps they are dropped, and even via osascript they only work sometimes.
/// Posting key events needs the Accessibility permission.
enum MediaKeys {
    enum Key: Int {
        // NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT, NX_KEYTYPE_PREVIOUS
        case playPause = 16, next = 17, previous = 18
    }

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow Tacho to control this computer" prompt.
    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func press(_ key: Key) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key.rawValue << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Calls

/// An app holding the microphone: Teams, Zoom, Slack, a browser on Meet.
struct ActiveCall: Equatable {
    let bundleID: String
    let pid: pid_t
    let name: String
    let since: Date
    var title: String?

    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }

    /// "Teams" rather than "Microsoft Teams", to fit beside the notch.
    var shortName: String {
        name.replacingOccurrences(of: "Microsoft ", with: "")
    }

    /// Opening the app through Launch Services also brings back a minimised
    /// or closed call window, and is not refused the way activating another
    /// app from a background app can be.
    func activate() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard let url = app.bundleURL else { app.activate(); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { app.activate() } }
        }
    }
}

enum CallDetector {
    /// Apple's own background users of the microphone (Siri, dictation,
    /// sound recognition) are not calls.
    private static let ignoredApple = ["com.apple."]
    private static let appleCallApps: Set<String> = ["com.apple.FaceTime"]

    /// Finds the app using the microphone right now. Needs macOS 14.2, which
    /// lists audio clients per process; older systems just see no calls.
    static func current() -> (bundleID: String, pid: pid_t, name: String)? {
        guard #available(macOS 14.2, *) else { return nil }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let running = NSWorkspace.shared.runningApplications
        let ownID = Bundle.main.bundleIdentifier

        // Asking every audio client costs a round trip each; a quick look at
        // the microphones first settles the usual case of nobody listening.
        let micInUse = AudioOutputs.objects(system, kAudioHardwarePropertyDevices).contains { device in
            !AudioOutputs.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty
                && AudioOutputs.value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) != 0
        }
        guard micInUse else { return nil }

        for process in AudioOutputs.objects(system, kAudioHardwarePropertyProcessObjectList) {
            guard AudioOutputs.value(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                  let bundleID = AudioOutputs.string(process, kAudioProcessPropertyBundleID),
                  bundleID != ownID else { continue }

            // Helpers ("com.microsoft.teams2.modulehost") belong to the app
            // whose identifier they extend. Helpers are running apps too, but
            // without windows, so the app with a Dock icon wins.
            let processPID = AudioOutputs.value(process, kAudioProcessPropertyPID, default: pid_t(0))
            let matches = running.filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return bundleID == id || bundleID.hasPrefix(id + ".")
            }
            let owner = matches.filter { $0.activationPolicy == .regular }
                .min { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
                ?? containingApp(of: processPID, in: running)
                ?? matches.max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            let appID = owner?.bundleIdentifier ?? bundleID
            if appID.hasPrefix("com.apple.") && !appleCallApps.contains(appID) { continue }

            return (appID, owner?.processIdentifier ?? processPID, owner?.localizedName ?? appID)
        }
        return nil
    }

    /// The regular app whose bundle holds this helper process, for helpers
    /// whose identifier does not extend the app's.
    private static func containingApp(of pid: pid_t, in running: [NSRunningApplication]) -> NSRunningApplication? {
        guard let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path else { return nil }
        return running.first { app in
            guard app.activationPolicy == .regular, let appPath = app.bundleURL?.path else { return false }
            return path.hasPrefix(appPath + "/")
        }
    }

    /// The meeting's name, from the call window's title. Window titles of
    /// other apps are only readable with Screen Recording permission, so
    /// without it there is no title.
    static func title(pid: pid_t, appName: String) -> String? {
        guard CGPreflightScreenCaptureAccess(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  var name = window[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            for suffix in [" | \(appName)", " - \(appName)"] where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
            }
            if name != appName && !name.isEmpty { return name }
        }
        return nil
    }
}

// MARK: - Model

/// What the notch panel shows: the call in progress, the song, and where the
/// sound goes. Only polled while the panel is open, except for calls, which
/// the event wings announce.
@MainActor
final class NotchMedia: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var selectedOutput: AudioDeviceID = 0
    @Published private(set) var call: ActiveCall?
    /// Read alongside the call, for its row in the panel.
    @Published private(set) var micMuted = false
    @Published private(set) var cameraOn = false

    func refreshDevices() {
        let muted = Microphone.isMuted
        if muted != micMuted { micMuted = muted }
        let camera = Camera.isOn
        if camera != cameraOn { cameraOn = camera }
    }

    func toggleMic() {
        Microphone.setMuted(!micMuted)
        micMuted = Microphone.isMuted
    }

    /// When the microphone was last seen free during a call. Muting can
    /// release it for a moment, so a call only ends after a short quiet spell.
    private var callQuietSince: Date?
    private static let callEndGrace: TimeInterval = 8

    private let stream = NowPlayingStream()

    func startPlayback() {
        stream.start { [weak self] track in
            guard let self, track != self.nowPlaying else { return }
            self.nowPlaying = track
        }
    }

    func stopPlayback() { stream.stop() }

    /// The play and skip buttons need the Accessibility permission; until
    /// it is given the panel says so in place of the player's name.
    @Published private(set) var needsPermission = false

    func press(_ key: MediaKeys.Key) {
        guard MediaKeys.isAllowed else {
            needsPermission = true
            MediaKeys.requestPermission()
            return
        }
        // Answer the click straight away; the stream confirms it.
        if key == .playPause { nowPlaying?.isPlaying.toggle() }
        MediaKeys.press(key)
    }

    func refreshPermission() {
        if needsPermission && MediaKeys.isAllowed { needsPermission = false }
    }

    func refreshOutputs() {
        let list = AudioOutputs.list()
        if list != outputs { outputs = list }
        let selected = AudioOutputs.defaultOutput()
        if selected != selectedOutput { selectedOutput = selected }
    }

    func select(_ output: AudioOutput) {
        AudioOutputs.setDefaultOutput(output.id)
        refreshOutputs()
    }

    enum CallChange { case started(ActiveCall), ended(ActiveCall) }

    @discardableResult
    func refreshCall() -> CallChange? {
        let found = CallDetector.current()
        if let found {
            callQuietSince = nil
            if call?.bundleID == found.bundleID {
                if call?.title == nil { call?.title = CallDetector.title(pid: found.pid, appName: found.name) }
                return nil
            }
            let started = ActiveCall(bundleID: found.bundleID, pid: found.pid, name: found.name, since: Date(),
                                     title: CallDetector.title(pid: found.pid, appName: found.name))
            call = started
            return .started(started)
        }
        guard let ended = call else { return nil }
        let quiet = callQuietSince ?? Date()
        callQuietSince = quiet
        guard Date().timeIntervalSince(quiet) >= Self.callEndGrace else { return nil }
        callQuietSince = nil
        call = nil
        return .ended(ended)
    }
}
