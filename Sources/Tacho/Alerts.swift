import Foundation
import AppKit
import ServiceManagement
import UserNotifications

/// Things worth interrupting the user for. Each fires once when its condition
/// starts and re-arms only after the condition has clearly ended, so a reading
/// hovering on the threshold does not produce a stream of notifications.
enum AlertKind: String, CaseIterable, Identifiable {
    case hotCPU, lowBattery, fullBattery, lowDisk, offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hotCPU: return L("CPU quá nóng")
        case .lowBattery: return L("Pin yếu")
        case .fullBattery: return L("Pin đã sạc đầy")
        case .lowDisk: return L("Ổ đĩa sắp đầy")
        case .offline: return L("Mất Internet")
        }
    }

    var condition: String {
        switch self {
        case .hotCPU: return L("CPU trên 95°C hơn 2 phút")
        case .lowBattery: return L("Pin còn dưới 20% và chưa cắm sạc")
        case .fullBattery: return L("Đang cắm sạc và pin đã đầy")
        case .lowDisk: return L("Ổ khởi động còn trống dưới 10%")
        case .offline: return L("Mất Internet hơn 30 giây (cần bật kiểm tra kết nối Internet)")
        }
    }

    /// A full battery is good news; only worth a notification to those who ask.
    var enabledByDefault: Bool { self != .fullBattery }
}

@MainActor
final class AlertMonitor: NSObject, ObservableObject {

    @Published var enabled: Set<AlertKind> {
        didSet {
            UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
            if !enabled.isEmpty { requestAuthorization() }
        }
    }
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private static let enabledKey = "alerts.enabled"
    static let hotCelsius: Double = 95
    static let hotDuration: TimeInterval = 120
    static let offlineDuration: TimeInterval = 30

    /// Alerts that have fired and not yet re-armed.
    private var fired: Set<AlertKind> = []
    private var hotSince: Date?
    private var offlineSince: Date?

    /// Notifications need a bundle; the bare binary (`--dump`, tests) has none
    /// and `UNUserNotificationCenter` would crash there.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : .current()

    override init() {
        if let stored = UserDefaults.standard.array(forKey: Self.enabledKey) as? [String] {
            enabled = Set(stored.compactMap(AlertKind.init(rawValue:)))
        } else {
            enabled = Set(AlertKind.allCases.filter(\.enabledByDefault))
        }
        super.init()
    }

    func start(store: MonitorStore) {
        center?.delegate = self
        if !enabled.isEmpty { requestAuthorization() }
        store.onEachSample { [weak self, weak store] in
            guard let self, let store else { return }
            self.evaluate(store)
        }
    }

    func isEnabled(_ kind: AlertKind) -> Bool { enabled.contains(kind) }

    func setEnabled(_ kind: AlertKind, _ value: Bool) {
        if value { enabled.insert(kind) } else { enabled.remove(kind) }
    }

    func sendTest() {
        deliver(id: "test", title: "Tacho", body: L("Thông báo đang hoạt động."))
    }

    func refreshAuthorization() {
        center?.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in self?.authorization = status }
        }
    }

    private func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor [weak self] in self?.refreshAuthorization() }
        }
    }

    // MARK: Rules

    private func evaluate(_ store: MonitorStore) {
        let now = Date()

        let temperature = store.temperature
        if temperature.isPresent && temperature.cpuAverage >= Self.hotCelsius {
            let since = hotSince ?? now
            hotSince = since
            if now.timeIntervalSince(since) >= Self.hotDuration {
                trigger(.hotCPU, body: String(format: L("%.0f°C suốt hơn 2 phút. Mở Tacho để xem app nào đang chạy nặng."),
                                              temperature.cpuAverage))
            }
        } else if !temperature.isPresent || temperature.cpuAverage < Self.hotCelsius - 10 {
            hotSince = nil
            fired.remove(.hotCPU)
        }

        let battery = store.battery
        if battery.isPresent {
            if !battery.isPluggedIn && battery.percentage <= 0.2 {
                trigger(.lowBattery, body: String(format: L("Còn %.0f%%. Nên cắm sạc."), battery.percentage * 100))
            } else if battery.isPluggedIn || battery.percentage > 0.25 {
                fired.remove(.lowBattery)
            }

            if battery.isPluggedIn && (battery.fullyCharged || battery.percentage >= 0.995) {
                trigger(.fullBattery, body: String(format: L("Pin đã %.0f%%, có thể rút sạc."), battery.percentage * 100))
            } else if !battery.isPluggedIn {
                fired.remove(.fullBattery)
            }
        }

        if let startup = store.volumes.first(where: { $0.path == "/" }), startup.total > 0 {
            let freeFraction = Double(startup.free) / Double(startup.total)
            if freeFraction < 0.1 {
                trigger(.lowDisk, body: L("%@ chỉ còn trống %@.", startup.name, Fmt.bytes(startup.free)))
            } else if freeFraction > 0.12 {
                fired.remove(.lowDisk)
            }
        }

        switch store.connectivity.status {
        case .offline:
            let since = offlineSince ?? now
            offlineSince = since
            if now.timeIntervalSince(since) >= Self.offlineDuration {
                trigger(.offline, body: L("Không kết nối được Internet hơn 30 giây."))
            }
        case .online:
            offlineSince = nil
            if fired.remove(.offline) != nil && enabled.contains(.offline) {
                deliver(id: "online", title: L("Đã có Internet trở lại"), body: L("Kết nối đã hoạt động lại."))
            }
        case .pending:
            // Still checking, or the check was switched off; neither says the
            // connection is down.
            if !store.connectivityMonitor.isRunning {
                offlineSince = nil
                fired.remove(.offline)
            }
        }
    }

    private func trigger(_ kind: AlertKind, body: String) {
        guard !fired.contains(kind) else { return }
        fired.insert(kind)
        guard enabled.contains(kind) else { return }
        deliver(id: kind.rawValue, title: kind.title, body: body)
    }

    private func deliver(id: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A fixed identifier replaces an older notification of the same kind
        // instead of stacking up beside it.
        center.add(UNNotificationRequest(identifier: "tacho.\(id)", content: content, trigger: nil))
    }
}

extension AlertMonitor: UNUserNotificationCenterDelegate {
    /// Without this, macOS hides notifications while Tacho is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// "Open Tacho at login", backed by the system's own login item list, so
/// System Settings and this switch always agree.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
