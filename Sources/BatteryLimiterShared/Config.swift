import Foundation

/// What the hardware should be doing right now. `discharge` implies `inhibit`
/// -- cutting the adapter already stops charging, but setting both means the
/// adapter coming back can't produce a charge surge before the next poll.
public enum ChargeAction: String, Equatable {
    case normal
    case inhibit
    case discharge
}

/// Shared between the menu bar app and the privileged helper daemon.
/// The app writes this file when the user changes settings; the daemon
/// polls it to decide what to do, and clears the transient requests
/// (`dischargeNow`, `topUp`) once they're spent.
public struct LimiterConfig: Codable, Equatable {
    public var enabled: Bool
    public var targetPercent: Int
    /// Charging resumes only after the battery drifts down to this. See
    /// `shouldInhibit` for why the gap exists.
    public var resumePercent: Int
    /// Drain to `targetPercent` automatically whenever the battery is above it
    /// on AC. Off by default: draining 100->80 and later charging 60->80 spends
    /// real cycle life, which only pays off against sitting at 100% for days.
    public var dischargeEnabled: Bool
    /// One-shot "Discharge Now". Cleared by the daemon on unplug, or once the
    /// target is reached.
    public var dischargeNow: Bool
    /// One-shot "Top Up": charge to 100% ignoring the limit *and* suppressing
    /// discharge. Cleared by the daemon on unplug, or by the app on cancel --
    /// deliberately not on reaching 100%, or auto-discharge would immediately
    /// drain the top-up back down while still plugged in.
    public var topUp: Bool

    /// Never force-discharge below this, whatever the config says. The file is
    /// user-writable and a hand-edited `targetPercent` of 5 shouldn't be able
    /// to flatten the battery.
    public static let dischargeFloor = 20

    public init(
        enabled: Bool = false,
        targetPercent: Int = 80,
        resumePercent: Int = 77,
        dischargeEnabled: Bool = false,
        dischargeNow: Bool = false,
        topUp: Bool = false
    ) {
        self.enabled = enabled
        self.targetPercent = targetPercent
        self.resumePercent = resumePercent
        self.dischargeEnabled = dischargeEnabled
        self.dischargeNow = dischargeNow
        self.topUp = topUp
    }

    /// Decoded key-by-key so a config written by an older build still loads.
    /// Synthesised `Decodable` throws on a missing key even when the property
    /// has a default, and `ConfigStore.read()` turns any throw into "all
    /// defaults" -- which would silently flip `enabled` back to false.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LimiterConfig()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        targetPercent = try container.decodeIfPresent(Int.self, forKey: .targetPercent) ?? defaults.targetPercent
        resumePercent = try container.decodeIfPresent(Int.self, forKey: .resumePercent) ?? defaults.resumePercent
        dischargeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dischargeEnabled) ?? defaults.dischargeEnabled
        dischargeNow = try container.decodeIfPresent(Bool.self, forKey: .dischargeNow) ?? defaults.dischargeNow
        topUp = try container.decodeIfPresent(Bool.self, forKey: .topUp) ?? defaults.topUp
    }

    /// The single decision the daemon acts on. `currentlyInhibited` carries the
    /// deadband's memory -- it is whatever was last applied to the hardware,
    /// discharge included.
    public func action(percent: Int, pluggedIn: Bool, currentlyInhibited: Bool) -> ChargeAction {
        guard enabled, pluggedIn else { return .normal }
        // Top Up outranks everything: it exists precisely to override the cap.
        if topUp { return .normal }
        if wantsDischarge, percent > dischargeStopsAt { return .discharge }
        return shouldInhibit(percent: percent, currentlyInhibited: currentlyInhibited) ? .inhibit : .normal
    }

    public var wantsDischarge: Bool { dischargeEnabled || dischargeNow }

    /// Discharge never goes below the target or the hard floor, whichever is
    /// higher.
    public var dischargeStopsAt: Int { max(targetPercent, Self.dischargeFloor) }

    /// Thermostat with a deadband. Once charging is inhibited it stays
    /// inhibited until the battery drifts all the way down to `resumePercent`,
    /// rather than resuming the instant it drops below `targetPercent` --
    /// otherwise the pack micro-cycles between target-1 and target forever,
    /// since it keeps losing charge to self-discharge and to load peaks the
    /// adapter can't cover.
    ///
    /// `resumePercent` is clamped below `targetPercent`: this file is
    /// user-writable and a hand-edit that inverts them would oscillate.
    public func shouldInhibit(percent: Int, currentlyInhibited: Bool) -> Bool {
        let resume = min(resumePercent, targetPercent - 1)
        return currentlyInhibited ? percent > resume : percent >= targetPercent
    }
}

public enum ConfigStore {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/BatteryLimiter")
    public static let fileURL = directory.appendingPathComponent("config.json")

    public static func read() -> LimiterConfig {
        readIfPresent() ?? LimiterConfig()
    }

    /// `nil` when the file is missing, unreadable or corrupt, so a caller that
    /// already holds live state can keep it rather than falling back to
    /// defaults -- `read()`'s fallback includes `enabled: false`, which would
    /// silently stop limiting.
    public static func readIfPresent() -> LimiterConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LimiterConfig.self, from: data)
    }

    public static func write(_ config: LimiterConfig) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: fileURL, options: .atomic)
        // An atomic write replaces the file, so the writer's ownership and
        // umask replace it too. The daemon runs as root; left at root's
        // default this can end up unreadable to the user-level app, and an
        // unreadable config reads as "all defaults" -- limiter off. The
        // directory is user-owned, so rename() keeps working both ways.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fileURL.path
        )
    }
}
