import Foundation
import AppKit

/// One readout on the menu bar. Each enabled module gets its own `NSStatusItem`,
/// the way iStat Menus lays them out.
enum MenuBarModule: String, CaseIterable, Identifiable {
    case cpu
    case gpu
    case memory
    case disk
    case network
    case connectivity
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return L("Bộ nhớ")
        case .disk: return L("Ổ đĩa")
        case .network: return L("Mạng")
        case .connectivity: return L("Kết nối")
        case .battery: return L("Pin")
        }
    }

    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up.fill"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .connectivity: return "wifi"
        case .battery: return "battery.100"
        }
    }

    /// Menu bar space is scarce, so only the most-watched ones start on: CPU,
    /// memory, network and the connectivity dot.
    var enabledByDefault: Bool {
        switch self {
        case .cpu, .memory, .network, .connectivity: return true
        case .gpu, .disk, .battery: return false
        }
    }
}

@MainActor
final class MenuBarSettings: ObservableObject {

    @Published var enabled: Set<MenuBarModule> { didSet { persist() } }
    @Published var showGraphs: Bool { didSet { persist() } }
    /// All readouts in one menu bar item instead of one item each.
    @Published var compact: Bool { didSet { persist() } }
    /// Controls the only outbound request the app makes. Off means the app
    /// talks to nothing outside this machine.
    @Published var checkConnectivity: Bool { didSet { persist() } }
    @Published var language: Language {
        didSet {
            L10n.current = language
            persist()
        }
    }
    @Published var hideDockIcon: Bool {
        didSet {
            persist()
            applyActivationPolicy()
        }
    }

    private static let enabledKey = "menubar.enabled"
    private static let graphsKey = "menubar.showGraphs"
    private static let compactKey = "menubar.compact"
    private static let dockKey = "menubar.hideDockIcon"
    private static let probeKey = "network.checkConnectivity"
    /// Every module this install has already seen, so later additions can be
    /// told apart from ones the user deliberately switched off.
    private static let knownKey = "menubar.known"

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: Self.enabledKey) as? [String] {
            var modules = Set(stored.compactMap(MenuBarModule.init(rawValue:)))

            // A saved list from an older build cannot mention modules that did
            // not exist yet. Without this, anything added later would stay
            // invisible forever instead of honouring its default.
            let known = Set((defaults.array(forKey: Self.knownKey) as? [String] ?? [])
                .compactMap(MenuBarModule.init(rawValue:)))
            for module in MenuBarModule.allCases
            where !known.contains(module) && module.enabledByDefault {
                modules.insert(module)
            }
            enabled = modules
        } else {
            enabled = Set(MenuBarModule.allCases.filter(\.enabledByDefault))
        }
        showGraphs = defaults.object(forKey: Self.graphsKey) as? Bool ?? true
        compact = defaults.bool(forKey: Self.compactKey)
        hideDockIcon = defaults.object(forKey: Self.dockKey) as? Bool ?? false
        checkConnectivity = defaults.object(forKey: Self.probeKey) as? Bool ?? true
        language = L10n.current

        // didSet does not fire during init, so record the module list now;
        // otherwise the migration above would re-run on every launch and undo a
        // deliberate "off" for a newly added module.
        persist()
    }

    func isEnabled(_ module: MenuBarModule) -> Bool { enabled.contains(module) }

    func setEnabled(_ module: MenuBarModule, _ value: Bool) {
        if value {
            enabled.insert(module)
        } else {
            enabled.remove(module)
            // With no readout left and no Dock icon there would be no way back
            // into the app, so bring the Dock icon along.
            if enabled.isEmpty && hideDockIcon {
                hideDockIcon = false
            }
        }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
        defaults.set(showGraphs, forKey: Self.graphsKey)
        defaults.set(compact, forKey: Self.compactKey)
        defaults.set(hideDockIcon, forKey: Self.dockKey)
        defaults.set(checkConnectivity, forKey: Self.probeKey)
        defaults.set(language.rawValue, forKey: L10n.defaultsKey)
        defaults.set(MenuBarModule.allCases.map(\.rawValue), forKey: Self.knownKey)
    }
}
