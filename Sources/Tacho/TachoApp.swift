import SwiftUI
import AppKit

/// Shared instances, because `NSApplicationDelegateAdaptor` builds the delegate
/// itself and cannot be handed the objects the scenes use.
@MainActor
enum AppEnvironment {
    static let store = MonitorStore()
    static let settings = MenuBarSettings()
    static let updater = Updater()
    static let alerts = AlertMonitor()
    static let history = HistoryRecorder()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--promo"), index + 1 < arguments.count {
            PromoRenderer.run(directory: arguments[index + 1])
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            SnapshotRenderer.run(directory: arguments[index + 1])
            exit(0)
        }

        AppEnvironment.settings.applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        statusBar = StatusBarController(store: AppEnvironment.store,
                                        settings: AppEnvironment.settings,
                                        updater: AppEnvironment.updater)
        notch = NotchController(store: AppEnvironment.store, settings: AppEnvironment.settings)
        if arguments.contains("--notch-demo") { notch?.runDemo() }
        if arguments.contains("--notch-info") { notch?.printInfo() }
        AppEnvironment.updater.startAutomaticChecks()
        AppEnvironment.alerts.start(store: AppEnvironment.store)
        AppEnvironment.history.start(store: AppEnvironment.store)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.history.saveNow() }
    }

    /// The menu bar readouts keep running after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct TachoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppEnvironment.store
    @StateObject private var settings = AppEnvironment.settings
    @StateObject private var updater = AppEnvironment.updater
    @StateObject private var alerts = AppEnvironment.alerts
    @StateObject private var history = AppEnvironment.history

    init() {
        // Claude Code runs this after every response; it must answer fast
        // and touch nothing else.
        if CommandLine.arguments.contains(ClaudeStatusLine.flag) {
            ClaudeStatusLine.run()
            exit(0)
        }
        // The same as the Settings buttons, for scripts.
        if CommandLine.arguments.contains("--claude-connect") {
            let done = ClaudeStatusLine.install(keepingExisting: true)
            print(done ? "Connected: \(ClaudeStatusLine.settingsURL.path)" : "Could not connect")
            exit(done ? 0 : 1)
        }
        if CommandLine.arguments.contains("--claude-disconnect") {
            ClaudeStatusLine.uninstall()
            print("Disconnected")
            exit(0)
        }
        // What the notch's AI page would show, for checking the readers.
        if CommandLine.arguments.contains("--ai-usage") {
            for (name, usage) in [("Codex", CodexReader().read()), ("Claude Code", ClaudeReader().read())] {
                let windows = usage.windows.map { window in
                    "\(window.label) \(window.usedPercent)% reset \(window.resetsAt.map { "\($0)" } ?? "-")"
                }
                print("\(name): tokens today \(usage.tokensToday) cached \(usage.cachedToday) "
                      + "model \(usage.model ?? "-") windows [\(windows.joined(separator: ", "))]")
            }
            exit(0)
        }
        SettingsMigration.run()
        let arguments = CommandLine.arguments
        if arguments.contains("--dump") {
            DiagnosticDump.run()
            exit(0)
        }
        if arguments.contains("--update-check") || arguments.contains("--update-install") {
            UpdateCommand.run(install: arguments.contains("--update-install"),
                              relaunch: !arguments.contains("--no-relaunch"))
        }
    }

    var body: some Scene {
        WindowGroup("Tacho") {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(updater)
                .environmentObject(alerts)
                .environmentObject(history)
        }
        .windowToolbarStyle(.unified(showsTitle: true))

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(updater)
                .environmentObject(alerts)
                .environmentObject(history)
        }
    }
}

/// Carries settings over from the app's previous name ("Resource Monitor",
/// bundle `local.macresourcemonitor`), once, before anything reads them.
enum SettingsMigration {
    private static let oldDomain = "local.macresourcemonitor"
    private static let doneKey = "migration.fromResourceMonitor"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = UserDefaults.standard.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil
            && !key.hasPrefix("NS") {
            defaults.set(value, forKey: key)
        }
    }
}
