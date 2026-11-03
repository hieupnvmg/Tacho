import Foundation
import IOKit

/// Reads keys from the System Management Controller through the `AppleSMC`
/// user client. Reading needs no root and no entitlement; the struct layout
/// and selectors are undocumented but stable, and the same ones iStat Menus
/// and Stats use. Only reads are implemented — nothing here can change a fan.
final class SMC {

    // Mirrors `SMCKeyData_t` from the kernel extension: 80 bytes.
    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        /// Swift does not pad `KeyInfo` to its C size of 12, so `result` would
        /// land at offset 37 instead of 40 without this.
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleEvent: UInt32 = 2   // kSMCHandleYPCEvent
    private static let readKey: UInt8 = 5        // kSMCReadKey
    private static let getKeyInfo: UInt8 = 9     // kSMCGetKeyInfo
    private static let keyFromIndex: UInt8 = 8   // kSMCGetKeyFromIndex

    private var connection: io_connect_t = 0
    /// Key info never changes, and looking it up doubles the calls per read.
    private var infoCache: [UInt32: KeyInfo] = [:]

    init?() {
        guard MemoryLayout<KeyData>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// A numeric key as a Double, decoding the SMC's own number formats.
    func number(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        switch type {
        case "flt " where bytes.count == 4:
            // Apple silicon: a little-endian Float.
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "fpe2" where bytes.count == 2:
            // Intel: unsigned big-endian fixed point with two fraction bits.
            return Double((UInt16(bytes[0]) << 8 | UInt16(bytes[1])) >> 2)
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count == 4:
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    /// Every key whose name starts with one of `prefixes`. Walks the SMC's
    /// whole key table (a couple of thousand entries), so call it once and
    /// keep the result.
    func keys(withPrefixes prefixes: [String]) -> [String] {
        let count = Int(number("#KEY") ?? 0)
        var result: [String] = []
        for index in 0..<count {
            var request = KeyData()
            request.data8 = Self.keyFromIndex
            request.data32 = UInt32(index)
            guard let response = call(request) else { continue }
            let name = Self.string(response.key)
            if prefixes.contains(where: name.hasPrefix) { result.append(name) }
        }
        return result
    }

    private func read(_ name: String) -> (type: String, bytes: [UInt8])? {
        let key = Self.fourCC(name)

        let info: KeyInfo
        if let cached = infoCache[key] {
            info = cached
        } else {
            var request = KeyData()
            request.key = key
            request.data8 = Self.getKeyInfo
            guard let response = call(request) else { return nil }
            info = response.keyInfo
            infoCache[key] = info
        }

        var request = KeyData()
        request.key = key
        request.keyInfo.dataSize = info.dataSize
        request.data8 = Self.readKey
        guard let response = call(request) else { return nil }

        let size = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: response.bytes) { Array($0.prefix(size)) }
        return (Self.string(info.dataType), bytes)
    }

    private func call(_ input: KeyData) -> KeyData? {
        var input = input
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, Self.handleEvent,
                                               &input, MemoryLayout<KeyData>.stride,
                                               &output, &outputSize)
        // A non-zero `result` means the key does not exist on this machine.
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
