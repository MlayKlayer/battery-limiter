import Foundation

/// Shared between the menu bar app and the privileged helper daemon.
/// The app writes this file when the user changes settings; the daemon
/// polls it to decide whether to inhibit charging.
public struct LimiterConfig: Codable, Equatable {
    public var enabled: Bool
    public var targetPercent: Int

    public init(enabled: Bool = false, targetPercent: Int = 80) {
        self.enabled = enabled
        self.targetPercent = targetPercent
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
