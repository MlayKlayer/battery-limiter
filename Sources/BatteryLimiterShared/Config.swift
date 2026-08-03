import Foundation

/// Shared between the menu bar app and the privileged helper daemon.
/// The app writes this file when the user changes settings; the daemon
/// polls it to decide whether to inhibit charging.
public struct LimiterConfig: Codable, Equatable {
    public var enabled: Bool
    public var targetPercent: Int
    /// Charging resumes only after the battery drifts down to this. See
    /// `shouldInhibit` for why the gap exists.
    public var resumePercent: Int

    public init(enabled: Bool = false, targetPercent: Int = 80, resumePercent: Int = 77) {
        self.enabled = enabled
        self.targetPercent = targetPercent
        self.resumePercent = resumePercent
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
    }

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
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(LimiterConfig.self, from: data)
        else {
            return LimiterConfig()
        }
        return config
    }

    public static func write(_ config: LimiterConfig) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
