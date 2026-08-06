import Foundation
import IOKit
import IOKit.ps

public struct BatteryStatus {
    public let percent: Int
    /// True whenever a charger is *physically attached* -- deliberately not
    /// "is currently supplying power".
    ///
    /// Forcing a discharge cuts adapter input, which makes macOS report the
    /// power source as Battery. Reading that as "the user unplugged" makes the
    /// limiter stop its own discharge, restore the adapter, see AC again on the
    /// next poll, and start over: the adapter flaps once every two polls.
    /// Observed doing exactly that on an M3 Air before this distinction existed.
    public let pluggedIn: Bool
}

/// The detail readout behind the menu's Stats submenu. Only the app uses this;
/// the daemon needs nothing beyond `BatteryStatus`.
///
/// Note that the gauge behind most of these refreshes roughly once a minute,
/// not continuously -- capacity and amperage sit perfectly still and then jump.
/// Values here can be up to a minute stale and that is the hardware, not a bug.
public struct BatteryStats {
    public let temperatureCelsius: Double
    public let cycleCount: Int
    /// Present charge, in mAh.
    public let currentCapacity: Int
    /// What the pack can hold now, in mAh.
    public let maxCapacity: Int
    /// What it could hold new, in mAh.
    public let designCapacity: Int
    public let volts: Double
    /// Signed: positive is charging, negative is drawing from the battery.
    public let milliamps: Int
    /// Seconds, or nil when macOS won't estimate (it declines for a while after
    /// any power transition).
    public let timeRemaining: TimeInterval?
    public let charging: Bool

    /// Raw ratio of present to design capacity. This is *not* the number in
    /// System Settings -- Apple smooths and rounds theirs, so expect a point or
    /// two of disagreement.
    public var healthPercent: Int {
        guard designCapacity > 0 else { return 0 }
        return Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())
    }

    /// Power flowing in or out of the pack. Zero when the adapter is carrying
    /// the whole load, which is the normal state at the cap.
    public var watts: Double { abs(Double(milliamps)) * volts / 1000 }
}

/// Reads live battery state via the public IOKit power source APIs.
/// No special privileges required.
public enum BatteryReader {
    public static func current() -> BatteryStatus? {
        guard let description = powerSourceDescription(),
              let capacity = description[kIOPSCurrentCapacityKey] as? Int,
              let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
              maxCapacity > 0
        else {
            return nil
        }

        let percent = Int((Double(capacity) / Double(maxCapacity) * 100).rounded())
        let onACPower = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        // Either signal is enough. `onACPower` alone misses a charger whose
        // input we cut ourselves; `adapterAttached` alone would silently stop
        // the cap working on any Mac that doesn't publish AdapterDetails.
        return BatteryStatus(percent: percent, pluggedIn: onACPower || adapterAttached())
    }

    /// Whether a charger is physically attached. Verified to survive a `CH0I`
    /// adapter cut on an M3 Air, which is the whole reason it's consulted
    /// rather than the power-source state.
    ///
    /// Tested against the key's real shapes, because "is it there" is not the
    /// question -- with nothing plugged in the key still exists:
    ///
    ///     attached:  {"Watts"=35, "SerialString"="C4H4...", "Name"="35W USB-C
    ///                 Power Adapter ", "FamilyCode"=18446744073172697098, ...}
    ///     unplugged: {"FamilyCode"=0}
    ///
    /// A false negative here is the dangerous direction -- it reads as "the
    /// user unplugged" mid-discharge and reinstates the flapping this signal
    /// exists to prevent -- so two independent markers count as attached.
    private static func adapterAttached() -> Bool {
        guard let details = smartBatteryProperties()["AdapterDetails"] as? [String: Any] else {
            return false
        }
        return (details["Watts"] as? Int ?? 0) > 0 || details["SerialString"] != nil
    }

    public static func stats() -> BatteryStats? {
        let smart = smartBatteryProperties()
        guard let designCapacity = smart["DesignCapacity"] as? Int else { return nil }

        let charging = smart["IsCharging"] as? Bool ?? false
        // Time estimates come from the power-source API rather than the raw
        // registry: it is the documented path, and it reports both directions.
        let description = powerSourceDescription() ?? [:]
        let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let minutes = description[minutesKey] as? Int ?? -1

        return BatteryStats(
            // Centi-degrees Celsius.
            temperatureCelsius: Double(smart["Temperature"] as? Int ?? 0) / 100,
            cycleCount: smart["CycleCount"] as? Int ?? 0,
            currentCapacity: smart["AppleRawCurrentCapacity"] as? Int ?? 0,
            maxCapacity: smart["AppleRawMaxCapacity"] as? Int ?? 0,
            designCapacity: designCapacity,
            volts: Double(smart["Voltage"] as? Int ?? 0) / 1000,
            milliamps: smart["Amperage"] as? Int ?? 0,
            timeRemaining: minutes > 0 ? TimeInterval(minutes * 60) : nil,
            charging: charging
        )
    }

    private static func powerSourceDescription() -> [String: AnyObject]? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?
                  .takeUnretainedValue() as? [String: AnyObject]
        else {
            return nil
        }
        return description
    }

    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }
}
