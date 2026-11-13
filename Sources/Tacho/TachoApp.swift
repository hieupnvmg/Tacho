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
    private var infra: InfraStatusController?

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
        infra = InfraStatusController(settings: AppEnvironment.settings)
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
    // Plain references, not @StateObject: these live for the whole run in
    // AppEnvironment, and observing them here made SwiftUI rebuild the
    // scenes, and update every window even while hidden, on every sample.
    // The views that show them observe them themselves.
    private let store = AppEnvironment.store
    private let settings = AppEnvironment.settings
    private let updater = AppEnvironment.updater
    private let alerts = AppEnvironment.alerts
    private let history = AppEnvironment.history

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
        if CommandLine.arguments.contains("--network-info") {
            print("VPN interfaces: \(VPN.activeInterfaces())")
            for app in NetworkApps.sampleNow() {
                print("\(app.name): in \(Fmt.rate(app.inRate)) out \(Fmt.rate(app.outRate))")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--infra-info") {
            let containers = DockerSocket.containers()
            print(containers.map { "Docker: \($0.filter(\.isRunning).count) running of \($0.count)" } ?? "Docker: not reachable")
            if let containers {
                print("VM memory: \(DockerSocket.vmMemory().map { Fmt.bytes($0) } ?? "-")")
                for container in containers where container.isRunning {
                    print("  \(container.name): \(DockerSocket.memory(of: container.id).map { Fmt.bytes($0) } ?? "-")")
                }
            }
            // `--infra-info stop <id>` / `start <id>`: the panel's buttons, for checking.
            if let index = CommandLine.arguments.firstIndex(of: "--infra-info"), index + 2 < CommandLine.arguments.count {
                let verb = CommandLine.arguments[index + 1], id = CommandLine.arguments[index + 2]
                print("\(verb) \(id): \(DockerSocket.setRunning(verb == "start", id: id) ? "ok" : "failed")")
            }
            let kube = KubeConfig.read()
            print("Kubernetes: current \(kube.current?.name ?? "-") cluster \(kube.current?.cluster ?? "-") "
                  + "namespace \(kube.current?.namespace ?? "default") production \(kube.current?.isProduction ?? false), "
                  + "\(kube.all.count) contexts")
            // The menu bar title's width, for a sample state and this Mac's.
            let sample = InfraState(containers: [Container(id: "a", name: "web", image: "", state: "running", status: "")],
                                    kubeCurrent: KubeContext(name: "gke-asia-staging-cluster", cluster: "", namespace: nil))
            let mine = InfraState(containers: containers, kubeCurrent: kube.current, kubeContexts: kube.all)
            print(String(format: "Title width: sample %.0f pt, this Mac %.0f pt",
                         InfraStatusController.title(for: sample).size().width,
                         InfraStatusController.title(for: mine).size().width))
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
