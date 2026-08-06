import Foundation

/// Decides whether a running discharge is going *nowhere* -- as opposed to
/// merely going slowly. `dischargeStopsAt` is the primary stop, but it reads
/// the same gauge that would be at fault if the gauge froze, so this backstop
/// doesn't trust it.
///
/// It lives here, taking `now` as a parameter, because the daemon's own loop
/// can only be exercised with four hours of real clock and a real battery.
///
/// Measuring elapsed time alone was wrong, and killed a healthy discharge
/// overnight: `CH0I` is cleared before every sleep, so draining only progresses
/// while the Mac is awake, and a night of dark wakes spent four hours of wall
/// clock on about one percent of real drain. Hence both halves of the rule --
/// the clock restarts on every percent actually lost, and sleep clears it
/// outright.
public struct DischargeProgress {
    /// How long the pack may sit at the same percent, awake and discharging,
    /// before the attempt is abandoned.
    public static let maxStall: TimeInterval = 4 * 60 * 60

    private var lowWater: Int?
    private var stalledSince: Date?

    public init() {}

    /// Call once per poll while discharging. `true` means the pack has held the
    /// same percent for `maxStall` and the attempt should be given up.
    public mutating func isStalled(percent: Int, now: Date) -> Bool {
        if let low = lowWater, percent >= low {
            // No progress since the last low. Let the existing clock run on.
        } else {
            lowWater = percent
            stalledSince = now
        }
        let since = stalledSince ?? now
        stalledSince = since
        return now.timeIntervalSince(since) >= Self.maxStall
    }

    /// Discharge is no longer running -- reached target, unplugged, or about to
    /// sleep. Sleep is the one that matters: the adapter cut is released before
    /// every sleep, so none of the time about to pass counts against the
    /// attempt.
    public mutating func clear() {
        lowWater = nil
        stalledSince = nil
    }
}
