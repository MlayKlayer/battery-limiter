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

    static func writeUInt8(_ key: FourCharCode, value: UInt8) throws {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = 1
        input.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        input.bytes.0 = value
        _ = try call(&input)
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

/// Apple Silicon charge-inhibit control. CH0B/CH0C set to 2 stops charging
/// without discharging; 0 restores normal charging. Keys and values verified
/// against the current (2026) BatFi source (github.com/rurza/BatFi).
enum ChargeControl {
    private static let inhibitB = FourCharCode(fromStaticString: "CH0B")
    private static let inhibitC = FourCharCode(fromStaticString: "CH0C")
    private static var opened = false

    static func setInhibited(_ inhibited: Bool) throws {
        if !opened {
            try SMC.open()
            opened = true
        }
        let value: UInt8 = inhibited ? 2 : 0
        do {
            try SMC.writeUInt8(inhibitB, value: value)
            try SMC.writeUInt8(inhibitC, value: value)
        } catch {
            SMC.close()
            opened = false
            throw error
        }
    }
}
