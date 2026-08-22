import BatteryLimiterShared
import Foundation
import IOKit

// Minimal Apple SMC (System Management Controller) client.
// Adapted from SMCKit (MIT License, github.com/beltex/SMCKit and
// github.com/rurza/BatFi), trimmed to the single-byte read/write path
// needed to toggle the CH0B/CH0C charge-inhibit keys on Apple Silicon.
// Writing requires the calling process to be running as root.

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

enum SMCError: Error {
    case driverNotFound
    case failedToOpen
    case keyNotFound
    case notPrivileged
    case unknown(kIOReturn: kern_return_t, smcResult: UInt8)
}

extension FourCharCode {
    init(fromStaticString str: StaticString) {
        precondition(str.utf8CodeUnitCount == 4)
        self = str.withUTF8Buffer { buffer in
            (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16) | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])
        }
    }
}

private struct SMCParamStruct {
    enum Selector: UInt8 {
        case kSMCHandleYPCEvent = 2
        case kSMCWriteKey = 6
        case kSMCGetKeyInfo = 9
    }

    enum Result: UInt8 {
        case kSMCSuccess = 0
        case kSMCKeyNotFound = 132
    }

    struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

/// Talks to the AppleSMC IOKit user client.
enum SMC {
    private static var connection: io_connect_t = 0

    static func open() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else { throw SMCError.failedToOpen }
    }

    static func close() {
        IOServiceClose(connection)
        connection = 0
    }

    /// Writes `value` as the first byte of a `size`-byte key, the rest zero.
    /// Both key sets only ever need a small value in the low byte, and the SMC
    /// is little-endian, so a 4-byte `ui32` of 1 is `01 00 00 00` -- the same
    /// call with a different `size`.
    static func write(_ key: FourCharCode, value: UInt8, size: UInt32 = 1) throws {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = size
        input.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        input.bytes.0 = value
        _ = try call(&input)
    }

    /// Whether the SMC knows this key at all. Unprivileged, and the basis for
    /// picking a key set -- see `ChargeControl.KeySet`.
    ///
    /// Only `keyNotFound` counts as absent. Anything else is rethrown rather
    /// than folded into `false`: a stale connection answering the probe would
    /// otherwise latch the wrong key set for the life of that connection, and
    /// a limiter that picks the wrong set fails exactly as silently as the bug
    /// this split exists to fix.
    static func keyExists(_ key: FourCharCode) throws -> Bool {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCParamStruct.Selector.kSMCGetKeyInfo.rawValue
        do {
            _ = try call(&input)
            return true
        } catch SMCError.keyNotFound {
            return false
        }
    }

    @discardableResult
    private static func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        assert(MemoryLayout<SMCParamStruct>.stride == 80, "SMCParamStruct size is != 80")

        var output = SMCParamStruct()
        let inSize = MemoryLayout<SMCParamStruct>.stride
        var outSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCParamStruct.Selector.kSMCHandleYPCEvent.rawValue),
            &input, inSize,
            &output, &outSize
        )

        switch (result, output.result) {
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCSuccess.rawValue):
            return output
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCKeyNotFound.rawValue):
            throw SMCError.keyNotFound
        case (kIOReturnNotPrivileged, _):
            throw SMCError.notPrivileged
        default:
            throw SMCError.unknown(kIOReturn: result, smcResult: output.result)
        }
    }
}

/// Apple Silicon charge control.
///
/// There are two key sets, and which one a Mac speaks is not something to
/// assume: macOS 15.7.9 on a Mac15,12 (M3 Air) has no CH0B, CH0C or CH0I in
/// its SMC key table at all -- every write returned `keyNotFound` and the cap
/// silently stopped working. All 1719 keys were enumerated to confirm it, and
/// the same table on that machine does carry CHTE and CHIE. See
/// SMC-KEYS-MACOS15.md.
///
/// So the set is probed at open rather than keyed off the model or the OS
/// version, neither of which the changeover lines up with cleanly. Values are
/// from OpenDente's helper (github.com/killerk3emstar/OpenDente), which drives
/// both sets; the previous reference, BatFi, predates the split.
///
/// Note CHIE's discharge value is 8, not the 1 that CH0I takes -- guessing by
/// analogy would have been wrong, and this is the key that runs the Mac off
/// its battery.
///
/// Measured on an M3 Air / macOS 14.5, back when CH0I still existed: under six
/// pinned cores the pack held flat with the adapter attached, and drew
/// -827 mA (-54 mAh in 90s) with CH0I set, while ExternalConnected read false.
enum ChargeControl {
    struct KeySet {
        let name: String
        /// Written together, all with the same value.
        let inhibit: [FourCharCode]
        /// CHTE is a ui32; CH0B/CH0C are single bytes.
        let inhibitSize: UInt32
        /// The value that means "stop charging". Zero always means "resume".
        let inhibitValue: UInt8
        /// Cuts adapter input, so the Mac runs off the pack while plugged in.
        let adapter: FourCharCode
        let adapterCutValue: UInt8

        static let legacy = KeySet(
            name: "CH0B/CH0C/CH0I",
            inhibit: [FourCharCode(fromStaticString: "CH0B"), FourCharCode(fromStaticString: "CH0C")],
            inhibitSize: 1,
            inhibitValue: 2,
            adapter: FourCharCode(fromStaticString: "CH0I"),
            adapterCutValue: 1
        )

        static let modern = KeySet(
            name: "CHTE/CHIE",
            inhibit: [FourCharCode(fromStaticString: "CHTE")],
            inhibitSize: 4,
            inhibitValue: 1,
            adapter: FourCharCode(fromStaticString: "CHIE"),
            adapterCutValue: 8
        )
    }

    private static var opened = false
    private static var keys = KeySet.legacy

    /// Which set was detected, for the daemon to log at startup. A limiter that
    /// silently stops limiting is the failure this whole file exists to avoid,
    /// so the one line that would have identified it immediately is worth it.
    static var activeKeySet: String { keys.name }

    private static func openIfNeeded() throws {
        guard !opened else { return }
        try SMC.open()
        opened = true
        do {
            keys = try SMC.keyExists(KeySet.modern.inhibit[0]) ? .modern : .legacy
        } catch {
            // No set latched: close and rethrow so the next poll re-probes,
            // rather than committing to a guess made from a bad answer.
            SMC.close()
            opened = false
            throw error
        }
    }

    static func apply(_ action: ChargeAction) throws {
        try openIfNeeded()
        let inhibit: UInt8 = action == .normal ? 0 : keys.inhibitValue
        do {
            for key in keys.inhibit {
                try SMC.write(key, value: inhibit, size: keys.inhibitSize)
            }
            try SMC.write(keys.adapter, value: action == .discharge ? keys.adapterCutValue : 0)
        } catch {
            SMC.close()
            opened = false
            throw error
        }
    }

    /// Clears the adapter cut on its own, ahead of anything else. Used on every
    /// path where the dangerous outcome is leaving the Mac running on battery:
    /// daemon start (a previous instance may have been SIGKILLed mid-discharge,
    /// which no handler can catch), shutdown, sleep, and SMC failure. A stuck
    /// CH0B/CH0C only fails to charge; a stuck CH0I flattens the battery.
    ///
    /// Retries once against a fresh connection, and reports whether the write
    /// landed. The connection is long-lived and held across arbitrarily many
    /// sleep cycles, so a stale handle is the likely failure -- and on the sleep
    /// path there is no next poll to recover on, because nothing runs again
    /// until wake.
    @discardableResult
    static func releaseAdapter() -> Bool {
        if writeAdapterDisable(0) { return true }
        if opened {
            SMC.close()
            opened = false
        }
        return writeAdapterDisable(0)
    }

    /// What `apply` would write, without writing it. See `main.swift --check`.
    static func dryRun() -> String {
        guard (try? openIfNeeded()) != nil else { return "SMC unavailable" }
        let names = keys.inhibit.map(describe).joined(separator: ", ")
        var lines = ["key set: \(activeKeySet)"]
        for action in [ChargeAction.normal, .inhibit, .discharge] {
            let inhibit = action == .normal ? 0 : keys.inhibitValue
            let cut = action == .discharge ? keys.adapterCutValue : 0
            lines.append("  \(action.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "\(names) = \(inhibit) (\(keys.inhibitSize)B), "
                + "\(describe(keys.adapter)) = \(cut)")
        }
        for key in keys.inhibit + [keys.adapter] where (try? SMC.keyExists(key)) == false {
            lines.append("  MISSING: \(describe(key)) is not in this Mac's SMC key table")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ key: FourCharCode) -> String {
        String(bytes: [UInt8(key >> 24 & 0xff), UInt8(key >> 16 & 0xff),
                       UInt8(key >> 8 & 0xff), UInt8(key & 0xff)], encoding: .ascii) ?? "????"
    }

    private static func writeAdapterDisable(_ value: UInt8) -> Bool {
        do {
            try openIfNeeded()
            try SMC.write(keys.adapter, value: value)
            return true
        } catch {
            return false
        }
    }
}
