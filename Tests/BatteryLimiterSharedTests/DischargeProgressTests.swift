import XCTest
@testable import BatteryLimiterShared

final class DischargeProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var justPastLimit: TimeInterval { DischargeProgress.maxStall + 1 }

    func testStuckAtTheSamePercentEventuallyGivesUp() {
        var progress = DischargeProgress()
        XCTAssertFalse(progress.isStalled(percent: 86, now: start))
        XCTAssertFalse(progress.isStalled(percent: 86, now: start.addingTimeInterval(3 * 3600)))
        XCTAssertTrue(progress.isStalled(percent: 86, now: start.addingTimeInterval(justPastLimit)))
    }

    /// The regression. A discharge that loses a percent is working, however
    /// slowly, and the clock has to start over each time -- measuring the whole
    /// run instead killed an overnight discharge that had reached 85%.
    func testEveryPercentLostRestartsTheClock() {
        var progress = DischargeProgress()
        var now = start
        for percent in stride(from: 86, through: 81, by: -1) {
            // Three hours per percent: over the limit cumulatively, under it
            // for any single step.
            XCTAssertFalse(
                progress.isStalled(percent: percent, now: now),
                "should still be discharging at \(percent)%"
            )
            now = now.addingTimeInterval(3 * 3600)
        }
        XCTAssertFalse(progress.isStalled(percent: 80, now: now))
    }

    /// Nothing drains while asleep -- the adapter cut is released before every
    /// sleep -- so a night of dark wakes must not spend the budget.
    func testSleepClearsTheClock() {
        var progress = DischargeProgress()
        XCTAssertFalse(progress.isStalled(percent: 86, now: start))
        progress.clear()
        XCTAssertFalse(progress.isStalled(percent: 86, now: start.addingTimeInterval(justPastLimit)))
    }

    /// The gauge only refreshes about once a minute and can tick back up a
    /// percent. That isn't progress, and must not hand the attempt a fresh
    /// four hours.
    func testABounceUpwardIsNotProgress() {
        var progress = DischargeProgress()
        XCTAssertFalse(progress.isStalled(percent: 85, now: start))
        XCTAssertFalse(progress.isStalled(percent: 86, now: start.addingTimeInterval(3600)))
        XCTAssertTrue(progress.isStalled(percent: 86, now: start.addingTimeInterval(justPastLimit)))
    }
}
