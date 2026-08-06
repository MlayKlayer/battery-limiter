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
        // v1.0 configs predate all three of these and must not arrive as true:
        // a spurious `dischargeNow` would drain the battery unasked.
        XCTAssertFalse(config.dischargeEnabled)
        XCTAssertFalse(config.dischargeNow)
        XCTAssertFalse(config.topUp)
    }

    func testRoundTrip() throws {
        let config = LimiterConfig(enabled: true, targetPercent: 90, resumePercent: 70)
        let decoded = try JSONDecoder().decode(
            LimiterConfig.self, from: JSONEncoder().encode(config)
        )
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Discharge
    //
    // Discharge cuts adapter input, so every one of these is a case where
    // getting it wrong drains the machine instead of merely failing to cap it.

    func testDischargeOnlyRunsAboveTargetAndStopsThere() {
        let config = LimiterConfig(
            enabled: true, targetPercent: 80, resumePercent: 75, dischargeEnabled: true
        )
        XCTAssertEqual(config.action(percent: 100, pluggedIn: true, currentlyInhibited: false), .discharge)
        XCTAssertEqual(config.action(percent: 81, pluggedIn: true, currentlyInhibited: false), .discharge)
        // At the target it hands over to the deadband rather than overshooting.
        XCTAssertEqual(config.action(percent: 80, pluggedIn: true, currentlyInhibited: true), .inhibit)
        XCTAssertEqual(config.action(percent: 76, pluggedIn: true, currentlyInhibited: true), .inhibit)
        XCTAssertEqual(config.action(percent: 75, pluggedIn: true, currentlyInhibited: true), .normal)
    }

    func testSustainedDischargeDoesNotFlipStateBetweenPolls() {
        // Once discharging, `lastAction` is `.discharge`, so every later poll
        // arrives with `currentlyInhibited: true`. The decision has to stay put
        // across that -- an answer that alternates cycles the adapter on and
        // off every poll, which is what the deadband exists to prevent.
        let config = LimiterConfig(
            enabled: true, targetPercent: 80, resumePercent: 77, dischargeEnabled: true
        )
        for inhibited in [false, true] {
            XCTAssertEqual(
                config.action(percent: 85, pluggedIn: true, currentlyInhibited: inhibited),
                .discharge
            )
        }
    }

    func testDischargeNeverRunsOnBattery() {
        // Unplugged, `discharge` would mean cutting an adapter that isn't
        // there while the battery is already the only source.
        let config = LimiterConfig(
            enabled: true, targetPercent: 80, resumePercent: 75, dischargeEnabled: true
        )
        XCTAssertEqual(config.action(percent: 100, pluggedIn: false, currentlyInhibited: false), .normal)
    }

    func testDischargeRespectsHardFloorAgainstAHandEditedTarget() {
        // config.json is user-writable; a target below the floor must not be
        // able to flatten the pack.
        let config = LimiterConfig(
            enabled: true, targetPercent: 5, resumePercent: 4, dischargeEnabled: true
        )
        XCTAssertEqual(config.dischargeStopsAt, LimiterConfig.dischargeFloor)
        XCTAssertEqual(config.action(percent: 21, pluggedIn: true, currentlyInhibited: false), .discharge)
        // Below the floor it falls back to the ordinary cap: still above a
        // target of 5, so charging stays inhibited -- it just stops draining.
        XCTAssertEqual(config.action(percent: 20, pluggedIn: true, currentlyInhibited: false), .inhibit)
        XCTAssertEqual(config.action(percent: 10, pluggedIn: true, currentlyInhibited: false), .inhibit)
    }

    func testManualDischargeActsWithoutTheAutomaticToggle() {
        let config = LimiterConfig(
            enabled: true, targetPercent: 80, resumePercent: 75,
            dischargeEnabled: false, dischargeNow: true
        )
        XCTAssertEqual(config.action(percent: 95, pluggedIn: true, currentlyInhibited: false), .discharge)
    }

    func testLimitingOffDisablesDischargeToo() {
        let config = LimiterConfig(
            enabled: false, targetPercent: 80, resumePercent: 75,
            dischargeEnabled: true, dischargeNow: true
        )
        XCTAssertEqual(config.action(percent: 100, pluggedIn: true, currentlyInhibited: false), .normal)
    }

    // MARK: - Top Up

    func testTopUpOverridesBothCapAndDischarge() {
        // The interaction that would otherwise ruin the feature: reaching 100%
        // must not hand straight over to auto-discharge and drain it back.
        let config = LimiterConfig(
            enabled: true, targetPercent: 80, resumePercent: 75,
            dischargeEnabled: true, topUp: true
        )
        XCTAssertEqual(config.action(percent: 85, pluggedIn: true, currentlyInhibited: true), .normal)
        XCTAssertEqual(config.action(percent: 100, pluggedIn: true, currentlyInhibited: false), .normal)
    }
}
