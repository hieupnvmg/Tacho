import Foundation
import IOKit
import CoreAudio

/// A connected Bluetooth accessory that reports its battery.
struct PeripheralSample: Identifiable {
    enum Kind { case mouse, keyboard, trackpad, airpods, headphones, other }

    /// One battery inside the accessory: AirPods have three.
    struct Level: Hashable {
        /// Untranslated key ("Trái", "Phải", "Hộp"); empty for a single battery.
        let part: String
        let percent: Int
    }

    var id: String { address.isEmpty ? name : address }
    let name: String
    let address: String
    let kind: Kind
    let levels: [Level]

    var lowest: Int { levels.map(\.percent).min() ?? 100 }

    var symbol: String {
        switch kind {
        case .mouse: return "magicmouse"
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .airpods: return "airpodspro"
        case .headphones: return "headphones"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Apple's own accessories report through IOKit; AirPods, Beats and some
/// third-party headsets only appear in the Bluetooth section of
/// system_profiler. Both are read and merged by Bluetooth address.
enum PeripheralReader {

    static func read() -> [PeripheralSample] {
        var byAddress: [String: PeripheralSample] = [:]
        var order: [String] = []

        for device in profilerDevices() {
            byAddress[device.id] = device
            order.append(device.id)
        }
        for device in ioKitDevices() {
            if let known = byAddress[device.id] {
                // system_profiler names the kind but often leaves out the
                // battery of a mouse or keyboard, which IOKit has.
                if known.levels.isEmpty {
                    byAddress[device.id] = PeripheralSample(name: known.name, address: known.address,
                                                            kind: known.kind, levels: device.levels)
                }
            } else {
                byAddress[device.id] = device
                order.append(device.id)
            }
        }
        return order.compactMap { byAddress[$0] }.filter { !$0.levels.isEmpty }
    }

    private static func normalise(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func kind(fromName name: String) -> PeripheralSample.Kind {
        let lower = name.lowercased()
        if lower.contains("mouse") { return .mouse }
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("airpods") { return .airpods }
        return .other
    }

    private static func ioKitDevices() -> [PeripheralSample] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [PeripheralSample] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            guard let percent = property("BatteryPercent") as? Int else { continue }
            let name = property("Product") as? String ?? "Bluetooth"
            let address = normalise(property("DeviceAddress") as? String ?? "")
            result.append(PeripheralSample(name: name, address: address, kind: kind(fromName: name),
                                           levels: [.init(part: "", percent: percent)]))
        }
        return result
    }

    private static func profilerDevices() -> [PeripheralSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var result: [PeripheralSample] = []
        for controller in controllers {
            // Devices that are paired but away still carry their last reading;
            // only connected ones are current.
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    var levels: [PeripheralSample.Level] = []
                    for (key, part) in [("device_batteryLevelMain", ""), ("device_batteryLevel", ""),
                                        ("device_batteryLevelLeft", "Trái"),
                                        ("device_batteryLevelRight", "Phải"),
                                        ("device_batteryLevelCase", "Hộp")] {
                        if let text = info[key] as? String,
                           let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                            levels.append(.init(part: part, percent: percent))
                        }
                    }
                    let minor = (info["device_minorType"] as? String ?? "").lowercased()
                    var kind = Self.kind(fromName: name)
                    if kind == .other {
                        switch minor {
                        case "mouse": kind = .mouse
                        case "keyboard": kind = .keyboard
                        case "headphones", "headset": kind = .headphones
                        default: break
                        }
                    }
                    result.append(PeripheralSample(name: name,
                                                   address: normalise(info["device_address"] as? String ?? ""),
                                                   kind: kind, levels: levels))
                }
            }
        }
        return result
    }
}

/// Calls back as soon as an accessory connects or goes away, so its battery is
/// read then instead of at the next minute-long refresh. Neither source needs
/// a permission: AirPods and headsets show up as audio devices, mice and
/// keyboards as HID services that report a battery.
final class PeripheralWatcher {
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var audioAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &audioAddress,
                                               .main, listener) == noErr {
            audioListener = listener
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type,
                                                          IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                                          { context, iterator in
                PeripheralWatcher.drain(iterator)
                guard let context else { return }
                Unmanaged<PeripheralWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
            }, context, &iterator)
            guard result == KERN_SUCCESS else { continue }
            // The notification only arms once the existing matches are read.
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    deinit {
        if let audioListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &audioAddress,
                                                   .main, audioListener)
        }
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
