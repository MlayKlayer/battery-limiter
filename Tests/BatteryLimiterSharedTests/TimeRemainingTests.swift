import XCTest
@testable import BatteryLimiterShared

final class TimeRemainingTests: XCTestCase {
    /// 5000 mAh pack at 3000 mAh, charging at 1000 mA, cap 80% -> 1000 mAh to
    /// go, one hour. macOS's own estimate is to 100% and must not be used.
    private func stats(
        current: Int,
        milliamps: Int,
        charging: Bool,
        timeRemaining: TimeInterval? = 2 * 3600
    ) -> BatteryStats {
        BatteryStats(
            temperatureCelsius: 30, cycleCount: 10,
            currentCapacity: current, maxCapacity: 5000, designCapacity: 5000,
            volts: 12, milliamps: milliamps, timeRemaining: timeRemaining, charging: charging
        )
    }

    func testChargingUnderACapCountsToTheCapNotToFull() {
        let seconds = stats(current: 3000, milliamps: 1000, charging: true).secondsUntil(cap: 80)
        XCTAssertEqual(seconds ?? 0, 3600, accuracy: 1)
    }

    func testDischargingKeepsTheSystemEstimate() {
        XCTAssertEqual(
            stats(current: 3000, milliamps: -1000, charging: false).secondsUntil(cap: 80),
            2 * 3600
        )
    }

    func testChargingToFullKeepsTheSystemEstimate() {
        XCTAssertEqual(stats(current: 3000, milliamps: 1000, charging: true).secondsUntil(cap: 100), 2 * 3600)
    }

    func testAlreadyPastTheCapEstimatesNothing() {
        XCTAssertNil(stats(current: 4500, milliamps: 1000, charging: true).secondsUntil(cap: 80))
    }
}
