import Foundation
import AppKit
import CryptoKit

/// Over-the-air updates from the GitHub Releases of `hieupnvmg/Tacho`.
///
/// A release qualifies when its tag (`v1.2.0`) is newer than this build and it
/// carries two assets: the `.dmg` that `build-dmg.sh` produces and the matching
/// `.dmg.sha256`. Installing downloads both, checks the hash, mounts the image,
/// checks the app inside (same bundle id, the advertised version, a valid
/// signature), then swaps it in for the running copy and relaunches.
@MainActor
final class Updater: ObservableObject {

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL
        let checksum: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let repository = "hieupnvmg/Tacho"

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: Self.autoKey) }
    }

    /// The release found by the last check, kept while downloading or after a
    /// failed install so the user can retry.
    private(set) var latest: Release?

    private static let autoKey = "update.automaticChecks"
    private static let lastCheckedKey = "update.lastChecked"
    /// Automatic checks run at most this often.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?

    /// `TACHO_UPDATE_FEED` points the updater at another releases JSON — a
    /// local file in tests, so the whole flow can run without publishing.
    private var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["TACHO_UPDATE_FEED"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    init() {
        let defaults = UserDefaults.standard
        automaticChecks = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    /// Checks shortly after launch and then hourly whether a day has passed.
    func startAutomaticChecks() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        // Tolerance lets macOS fold this wakeup in with others.
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard automaticChecks else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        Task { await check() }
    }

    // MARK: Check

    func check() async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await fetchLatest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
            if let release, Self.isVersion(release.version, newerThan: currentVersion) {
                latest = release
                state = .available(release)
            } else {
                latest = nil
                state = .upToDate
            }
        } catch {
            state = .failed(L("Không kiểm tra được: %@", error.localizedDescription))
        }
    }

    /// `nil` when the repository has no published release yet.
    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tacho/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else {
                throw UpdateError(L("GitHub trả về mã %d", http.statusCode))
            }
        }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let body: String?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let dmg = payload.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            throw UpdateError(L("Bản phát hành không có file .dmg"))
        }
        let checksum = payload.assets.first { $0.name == dmg.name + ".sha256" }
        let version = payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return Release(version: version,
                       notes: payload.body ?? "",
                       page: payload.html_url,
                       dmg: dmg.browser_download_url,
                       checksum: checksum?.browser_download_url)
    }

    // MARK: Install

    /// Where the running app lives, if it can be replaced in place.
    private var replaceableBundle: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }   // `swift run`, not a bundle
        let parent = bundle.deletingLastPathComponent().path
        // A read-only parent is a mounted DMG or a folder this user cannot write.
        guard FileManager.default.isWritableFile(atPath: parent) else { return nil }
        return bundle
    }

    var canInstallInPlace: Bool { replaceableBundle != nil }

    /// Downloads, verifies and stages the update, then calls `quit` so a small
    /// helper can swap the bundles once this process is gone, and relaunch.
    func install(relaunch: Bool = true,
                 quit: @MainActor () -> Void = { NSApp.terminate(nil) }) async {
        guard let release = latest else { return }
        guard let destination = replaceableBundle else {
            NSWorkspace.shared.open(release.page)
            return
        }

        state = .downloading(0)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tacho-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            guard let checksumURL = release.checksum else {
                throw UpdateError(L("Bản phát hành thiếu file .sha256 để kiểm tra"))
            }
            let image = work.appendingPathComponent("Tacho.dmg")
            try await download(release.dmg, to: image)
            let expected = try await fetchChecksum(checksumURL)

            state = .installing
            let expectedBundleID = Bundle.main.bundleIdentifier ?? ""
            let staged = try await Task.detached {
                try Self.verifyAndStage(image: image, expectedHash: expected,
                                        bundleID: expectedBundleID,
                                        version: release.version, in: work)
            }.value

            try Self.launchSwap(staged: staged, destination: destination,
                                workDirectory: work, relaunch: relaunch)
            quit()
        } catch {
            try? FileManager.default.removeItem(at: work)
            state = .failed(L("Lỗi cập nhật: %@", error.localizedDescription))
        }
    }

    private func download(_ url: URL, to file: URL) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError(L("GitHub trả về mã %d", http.statusCode))
        }
        let expected = max(response.expectedContentLength, 1)
        var data = Data()
        data.reserveCapacity(Int(max(response.expectedContentLength, 0)))
        for try await byte in bytes {
            data.append(byte)
            if data.count % 65_536 == 0 {
                state = .downloading(min(Double(data.count) / Double(expected), 1))
            }
        }
        state = .downloading(1)
        try data.write(to: file)
    }

    /// The `.sha256` asset holds `shasum -a 256` output: the hex digest first.
    private func fetchChecksum(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8),
              let digest = text.split(whereSeparator: \.isWhitespace).first,
              digest.count == 64 else {
            throw UpdateError(L("File .sha256 không hợp lệ"))
        }
        return digest.lowercased()
    }

    /// Runs off the main thread: hashing, mounting and copying are slow.
    nonisolated private static func verifyAndStage(image: URL, expectedHash: String,
                                                   bundleID: String, version: String,
                                                   in work: URL) throws -> URL {
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else {
            throw UpdateError(L("Mã SHA-256 không khớp — file tải về có thể bị hỏng"))
        }

        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly",
                                       "-noautoopen", "-mountpoint", mount.path]) == 0 else {
            throw UpdateError(L("Không mở được file .dmg"))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: mount,
                                                                    includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError(L("App trong bản cập nhật không đúng"))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError(L("Chữ ký của app trong bản cập nhật không hợp lệ"))
        }

        let staged = work.appendingPathComponent(app.lastPathComponent)
        guard run("/usr/bin/ditto", [app.path, staged.path]) == 0 else {
            throw UpdateError(L("Không chép được bản cập nhật"))
        }
        return staged
    }

    /// The swap has to happen after this process exits, so a detached shell
    /// script waits for it, moves the old bundle aside, puts the new one in
    /// place (restoring the old one if that fails) and relaunches.
    private static func launchSwap(staged: URL, destination: URL,
                                   workDirectory: URL, relaunch: Bool) throws {
        let script = workDirectory.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"; RELAUNCH="$5"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && ditto "$NEW" "$DEST"; then
            rm -rf "$DEST.old"
        else
            rm -rf "$DEST"
            mv "$DEST.old" "$DEST"
        fi
        [ "$RELAUNCH" = "1" ] && open "$DEST"
        rm -rf "$WORK"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                             staged.path, destination.path, workDirectory.path,
                             relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: Versions

    /// Compares dotted numeric versions: `1.10` is newer than `1.9`.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// `Tacho --update-check` prints what the updater finds; `--update-install`
/// also installs it (add `--no-relaunch` to leave the new copy closed). Runs
/// before the app's windows exist and exits when done.
enum UpdateCommand {
    @MainActor
    static func run(install: Bool, relaunch: Bool) -> Never {
        let updater = Updater()
        var finished = false
        var status: Int32 = 0
        Task { @MainActor in
            await updater.check()
            print("current: \(updater.currentVersion)")
            print("state: \(updater.state)")
            if install, case .available = updater.state {
                await updater.install(relaunch: relaunch) {
                    print("installed: swapping in the new copy after exit")
                    finished = true
                }
                if !finished {
                    print("state: \(updater.state)")
                    status = 1
                }
            } else if case .failed = updater.state {
                status = 1
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        exit(status)
    }
}
