import Foundation

// MARK: - Model

/// One rate-limit window of an AI coding assistant's plan.
struct LimitWindow: Equatable, Identifiable {
    /// "5h", "7d".
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    var id: String { label }

    static func label(minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

/// What one assistant has used: its plan's windows and today's tokens.
struct AssistantUsage: Equatable {
    var windows: [LimitWindow] = []
    /// When the windows were last reported.
    var windowsUpdated: Date?
    /// Tokens sent and generated today, not counting prompt-cache reads.
    var tokensToday = 0
    /// Prompt-cache reads today, cheap and usually far larger.
    var cachedToday = 0
    var model: String?
}

/// The home folder as the assistants see it: `HOME` if set, as Claude Code
/// and Codex use, otherwise the account's own.
let userHome: URL = {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}()

// MARK: - Reading growing JSONL files

/// Reads the lines appended to a set of JSONL files since the last call,
/// remembering how far it got in each. Assistants' session logs only grow,
/// and some reach tens of megabytes, so reading them whole each time would
/// be wasteful.
final class JSONLTail {
    private var offsets: [String: UInt64] = [:]

    /// Calls `line` for each complete new line. Lines are filtered by a
    /// substring first, since parsing JSON is the expensive part.
    func read(_ files: [URL], containing needle: String, line: (Data) -> Void) {
        let needleData = Data(needle.utf8)
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            var start = offsets[file.path] ?? 0
            if start > size { start = 0 }   // replaced or truncated
            guard size > start else { continue }
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) else { continue }
            // Up to the last newline; a half-written line waits for next time.
            offsets[file.path] = start + UInt64(end + 1)
            var lineStart = data.startIndex
            while lineStart <= end, let newline = data[lineStart...end].firstIndex(of: 0x0A) {
                let slice = data[lineStart..<newline]
                if slice.range(of: needleData) != nil { line(Data(slice)) }
                lineStart = newline + 1
            }
        }
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format
}()

private func date(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

/// Session logs touched in the last two days, newest last.
private func recentFiles(under root: URL, matching suffix: String) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
    let cutoff = Date().addingTimeInterval(-2 * 86400)
    var found: [(URL, Date)] = []
    for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified >= cutoff { found.append((url, modified)) }
    }
    return found.sorted { $0.1 < $1.1 }.map(\.0)
}

// MARK: - Codex

/// Codex writes each session to ~/.codex/sessions as JSONL. Its
/// `token_count` events carry the tokens of each turn and, for ChatGPT
/// plans, the account's rate-limit windows.
final class CodexReader {
    private let tail = JSONLTail()
    private let root = userHome.appendingPathComponent(".codex/sessions")
    private var usage = AssistantUsage()
    private var day = Calendar.current.startOfDay(for: Date())

    var isInstalled: Bool { FileManager.default.fileExists(atPath: root.path) }

    func read() -> AssistantUsage {
        let today = Calendar.current.startOfDay(for: Date())
        if today != day {
            day = today
            usage.tokensToday = 0
            usage.cachedToday = 0
        }
        tail.read(recentFiles(under: root, matching: ".jsonl"), containing: "\"token_count\"") { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { return }
            let when = date(object["timestamp"])
            if let when, when >= day,
               let info = payload["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any] {
                let input = last["input_tokens"] as? Int ?? 0
                let cached = last["cached_input_tokens"] as? Int ?? 0
                let output = last["output_tokens"] as? Int ?? 0
                usage.tokensToday += max(input - cached, 0) + output
                usage.cachedToday += cached
            }
            if let windows = Self.windows(payload["rate_limits"]) {
                if !windows.isEmpty, (when ?? .distantPast) >= (usage.windowsUpdated ?? .distantPast) {
                    usage.windows = windows
                    usage.windowsUpdated = when
                }
            }
        }
        if usage.windows.isEmpty, !lookedBack {
            lookedBack = true
            lookBack()
        }
        return usage
    }

    private var lookedBack = false

    /// Nothing in the last two days' sessions: the newest older session that
    /// reported limits, read from its end, so the card still shows them (or
    /// that they have reset since).
    private func lookBack() {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                files.append((url, date))
            }
        }
        for (file, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(30) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 1_000_000 ? size - 1_000_000 : 0)
            guard let data = try? handle.readToEnd() else { continue }
            for line in data.split(separator: 0x0A).reversed() where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let windows = Self.windows(payload["rate_limits"]), !windows.isEmpty else { continue }
                usage.windows = windows
                usage.windowsUpdated = date(object["timestamp"])
                return
            }
        }
    }

    static func windows(_ value: Any?) -> [LimitWindow]? {
        guard let limits = value as? [String: Any] else { return nil }
        return ["primary", "secondary"].compactMap { key -> LimitWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double,
                  let minutes = window["window_minutes"] as? Int else { return nil }
            let reset = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return LimitWindow(label: LimitWindow.label(minutes: minutes), usedPercent: used, resetsAt: reset)
        }
    }
}

// MARK: - Claude Code

/// Claude Code writes each session to ~/.claude/projects as JSONL, each
/// response logged several times as it streams, under one message id. The
/// plan's 5-hour and 7-day windows are not in those logs; Claude Code only
/// hands them to a statusLine command, which `ClaudeStatusLine` provides.
final class ClaudeReader {
    private let tail = JSONLTail()
    private let home = userHome
    private var root: URL { home.appendingPathComponent(".claude/projects") }
    /// Today's responses by message id: the largest count seen for each.
    private var responses: [String: (fresh: Int, cached: Int)] = [:]
    private var day = Calendar.current.startOfDay(for: Date())
    private var model: String?

    var isInstalled: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) }

    func read() -> AssistantUsage {
        let today = Calendar.current.startOfDay(for: Date())
        if today != day {
            day = today
            responses = [:]
        }
        tail.read(recentFiles(under: root, matching: ".jsonl"), containing: "\"usage\"") { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let when = date(object["timestamp"]), when >= day,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let id = message["id"] as? String ?? (object["uuid"] as? String ?? UUID().uuidString)
            let fresh = (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            let cached = usage["cache_read_input_tokens"] as? Int ?? 0
            let seen = responses[id]
            responses[id] = (max(seen?.fresh ?? 0, fresh), max(seen?.cached ?? 0, cached))
            if let name = message["model"] as? String { model = name }
        }
        var result = AssistantUsage()
        result.tokensToday = responses.values.reduce(0) { $0 + $1.fresh }
        result.cachedToday = responses.values.reduce(0) { $0 + $1.cached }
        result.model = model
        if let limits = ClaudeStatusLine.readSnapshot() {
            result.windows = limits.windows
            result.windowsUpdated = limits.updated
            result.model = limits.model ?? model
        }
        return result
    }
}

// MARK: - Claude Code statusLine

/// `Tacho --claude-statusline`: run by Claude Code as its statusLine after
/// each response, with the session's state as JSON on standard input. It
/// saves the plan's rate-limit windows for the notch and prints a short
/// status line for the terminal.
enum ClaudeStatusLine {
    static let flag = "--claude-statusline"

    static var snapshotURL: URL {
        userHome.appendingPathComponent(".claude/tacho-usage.json")
    }

    static var settingsURL: URL {
        userHome.appendingPathComponent(".claude/settings.json")
    }

    /// The statusLine that was there before Tacho, which Tacho runs in turn
    /// and shows instead of its own line, and puts back when removed.
    static var previousURL: URL {
        userHome.appendingPathComponent(".claude/tacho-statusline-previous.json")
    }

    static var previous: [String: Any]? {
        guard let data = try? Data(contentsOf: previousURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The command Claude Code runs: this copy of Tacho.
    static var command: String {
        "\"\(Bundle.main.executablePath ?? CommandLine.arguments[0])\" \(flag)"
    }

    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let model = (payload["model"] as? [String: Any])?["display_name"] as? String
        let context = (payload["context_window"] as? [String: Any])?["used_percentage"] as? Double
        let limits = payload["rate_limits"] as? [String: Any] ?? [:]

        var windows: [[String: Any]] = []
        var parts: [String] = []
        if let model { parts.append(model) }
        if let context { parts.append(String(format: "ctx %.0f%%", context)) }
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percentage"] as? Double else { continue }
            var entry: [String: Any] = ["label": label, "used": used]
            if let reset = window["resets_at"] as? Double { entry["resets_at"] = reset }
            windows.append(entry)
            parts.append(String(format: "%@ %.0f%%", label, used))
        }

        // Rate limits arrive only after a session's first response; keep the
        // last ones rather than wiping them with an empty update.
        if !windows.isEmpty {
            var snapshot: [String: Any] = ["windows": windows, "updated": Date().timeIntervalSince1970]
            if let model { snapshot["model"] = model }
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
                try? data.write(to: snapshotURL, options: .atomic)
            }
        }
        // With a statusLine of its own from before, the terminal keeps
        // showing that one; Tacho only takes the limits.
        if let previous = (previous?["command"] as? String), let line = runPrevious(previous, input: input) {
            print(line, terminator: line.hasSuffix("\n") ? "" : "\n")
        } else {
            print(parts.joined(separator: " · "))
        }
    }

    /// Runs the earlier statusLine with the same input, for up to 5 seconds.
    private static func runPrevious(_ command: String, input: Data) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let done = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global().async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    static func readSnapshot() -> (windows: [LimitWindow], updated: Date?, model: String?)? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["windows"] as? [[String: Any]] else { return nil }
        let windows = entries.compactMap { entry -> LimitWindow? in
            guard let label = entry["label"] as? String, let used = entry["used"] as? Double else { return nil }
            let reset = (entry["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return LimitWindow(label: label, usedPercent: used, resetsAt: reset)
        }
        let updated = (object["updated"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return (windows, updated, object["model"] as? String)
    }

    enum Hookup: Equatable {
        /// No statusLine set: Tacho can add itself.
        case none
        /// Tacho is the statusLine.
        case tacho
        /// Someone else's statusLine; Tacho leaves it alone.
        case other
    }

    static var hookup: Hookup {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = settings["statusLine"] as? [String: Any] else { return .none }
        return (line["command"] as? String)?.contains(flag) == true ? .tacho : .other
    }

    /// Adds Tacho as Claude Code's statusLine, keeping every other setting.
    /// Also repoints it when Tacho has moved. Another statusLine is only
    /// replaced with `keepingExisting`, and then kept: saved aside, run by
    /// Tacho each time, and put back by `uninstall`.
    @discardableResult
    static func install(keepingExisting: Bool = false) -> Bool {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            settings = parsed
        }
        var line: [String: Any] = ["type": "command"]
        if let existing = settings["statusLine"] as? [String: Any],
           (existing["command"] as? String)?.contains(flag) != true {
            guard keepingExisting,
                  let saved = try? JSONSerialization.data(withJSONObject: existing),
                  (try? saved.write(to: previousURL, options: .atomic)) != nil else { return false }
            // Its other options (padding and so on) carry over.
            line = existing
        } else if let existing = settings["statusLine"] as? [String: Any] {
            line = existing
        }
        // A copy of the settings as they were, in case anything goes wrong.
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.tacho-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        line["type"] = "command"
        line["command"] = command
        settings["statusLine"] = line
        guard let data = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: settingsURL, options: .atomic)) != nil
    }

    /// Takes Tacho back out, if it is the statusLine.
    static func uninstall() {
        guard hookup == .tacho, let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let previous {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try? FileManager.default.removeItem(at: previousURL)
        if let data = try? JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }
}

// MARK: - Watcher

/// Reads both assistants now and then, off the main thread, for the notch.
@MainActor
final class AIUsageWatcher: ObservableObject {
    static let shared = AIUsageWatcher()

    @Published private(set) var codex: AssistantUsage?
    @Published private(set) var claude: AssistantUsage?
    @Published private(set) var hookup = ClaudeStatusLine.hookup

    private let codexReader = CodexReader()
    private let claudeReader = ClaudeReader()
    private let queue = DispatchQueue(label: "tacho.ai-usage", qos: .utility)
    private var timer: Timer?
    private var reading = false

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        hookup = ClaudeStatusLine.hookup
        guard !reading else { return }
        reading = true
        let codexReader = self.codexReader, claudeReader = self.claudeReader
        queue.async {
            let codex = codexReader.isInstalled ? codexReader.read() : nil
            let claude = claudeReader.isInstalled ? claudeReader.read() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    if codex != self.codex { self.codex = codex }
                    if claude != self.claude { self.claude = claude }
                }
            }
        }
    }

    func connectClaude(keepingExisting: Bool = false) {
        ClaudeStatusLine.install(keepingExisting: keepingExisting)
        hookup = ClaudeStatusLine.hookup
    }

    /// Tacho runs a statusLine that was there before it.
    var keepsPreviousStatusLine: Bool { ClaudeStatusLine.previous != nil }

    func disconnectClaude() {
        ClaudeStatusLine.uninstall()
        hookup = ClaudeStatusLine.hookup
    }
}
