import XCTest

@testable import BatteryLimiterShared

/// The charge deadband can't be exercised on real hardware without waiting
/// hours for the pack to drift, and getting it wrong either micro-cycles the
/// battery or never resumes charging. So it gets checked here.
final class ConfigTests: XCTestCase {
    func testDeadbandHoldsUntilResumePercent() {
        let config = LimiterConfig(enabled: true, targetPercent: 80, resumePercent: 75)

        // Charging up: nothing is inhibited until the target is actually hit.
        XCTAssertFalse(config.shouldInhibit(percent: 79, currentlyInhibited: false))
        XCTAssertTrue(config.shouldInhibit(percent: 80, currentlyInhibited: false))

        // Already inhibited: stay inhibited all the way down to the resume
        // point. This is the whole reason the band exists -- without it, 79%
        // would resume charging and micro-cycle against 80%.
        XCTAssertTrue(config.shouldInhibit(percent: 79, currentlyInhibited: true))
        XCTAssertTrue(config.shouldInhibit(percent: 76, currentlyInhibited: true))
        XCTAssertFalse(config.shouldInhibit(percent: 75, currentlyInhibited: true))

        // Having resumed, it charges the full way back to target, not to 76.
        XCTAssertFalse(config.shouldInhibit(percent: 79, currentlyInhibited: false))
    }

    func testInvertedBandCannotOscillate() {
        // config.json is user-writable, so a hand-edit can invert the two.
        let config = LimiterConfig(enabled: true, targetPercent: 80, resumePercent: 90)
        XCTAssertTrue(config.shouldInhibit(percent: 80, currentlyInhibited: false))
        XCTAssertFalse(config.shouldInhibit(percent: 79, currentlyInhibited: true))
    }

    func testConfigWrittenByOlderBuildStillLoads() throws {
        // A missing key must not fall back to "all defaults" -- that would
        // flip `enabled` to false and silently stop limiting.
        let old = Data(#"{"enabled":true,"targetPercent":85}"#.utf8)
        let config = try JSONDecoder().decode(LimiterConfig.self, from: old)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.targetPercent, 85)
        XCTAssertEqual(config.resumePercent, 77)
    }

    func testRoundTrip() throws {
        let config = LimiterConfig(enabled: true, targetPercent: 90, resumePercent: 70)
        let decoded = try JSONDecoder().decode(
            LimiterConfig.self, from: JSONEncoder().encode(config)
        )
        XCTAssertEqual(decoded, config)
    }
}
