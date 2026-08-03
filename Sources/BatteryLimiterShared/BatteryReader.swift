import Foundation
import IOKit.ps

public struct BatteryStatus {
    public let percent: Int
    public let pluggedIn: Bool
}

/// Reads live battery state via the public IOKit power source APIs.
/// No special privileges required.
public enum BatteryReader {
    public static func current() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        guard let source = sources.first else { return nil }
        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: AnyObject] else {
            return nil
        }
        guard let capacity = description[kIOPSCurrentCapacityKey] as? Int,
              let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
              maxCapacity > 0
        else {
            return nil
        }

        let percent = Int((Double(capacity) / Double(maxCapacity) * 100).rounded())
        let pluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return BatteryStatus(percent: percent, pluggedIn: pluggedIn)
    }
}
