import XCTest
@testable import ZephyrCore

final class ManualReturnTimerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testDefaultNeverExpiresEvenAfterSeveralDays() {
        var timer = ManualReturnTimer()
        timer.start(now: now)
        XCTAssertNil(timer.deadline)
        XCTAssertFalse(timer.isDue(now: now.addingTimeInterval(7 * 86400)))
    }

    func testEnabledTimerStartsOnlyWithManualControl() {
        var timer = ManualReturnTimer()
        timer.configure(enabled: true, minutes: 30, manual: false, now: now)
        XCTAssertNil(timer.deadline)
        timer.start(now: now.addingTimeInterval(20))
        XCTAssertFalse(timer.isDue(now: now.addingTimeInterval(1819)))
        XCTAssertTrue(timer.isDue(now: now.addingTimeInterval(1820)))
    }

    func testChangingDurationRestartsAndDisablingCancels() {
        var timer = ManualReturnTimer(enabled: true)
        timer.start(now: now)
        timer.configure(enabled: true, minutes: 5, manual: true, now: now.addingTimeInterval(60))
        XCTAssertEqual(timer.deadline, now.addingTimeInterval(360))
        timer.configure(enabled: false, minutes: 5, manual: true, now: now.addingTimeInterval(100))
        XCTAssertNil(timer.deadline)
        XCTAssertFalse(timer.isDue(now: now.addingTimeInterval(86400)))
    }

    func testIdenticalSettingsDoNotExtendRunningTimer() {
        var timer = ManualReturnTimer(enabled: true, minutes: 30)
        timer.start(now: now)
        timer.configure(enabled: true, minutes: 30, manual: true, now: now.addingTimeInterval(60))
        XCTAssertEqual(timer.deadline, now.addingTimeInterval(1800))
    }

    func testInvalidDurationsAreBoundedAndAutoClearsDeadline() {
        XCTAssertEqual(ManualReturnTimer(minutes: .nan).minutes, 30)
        XCTAssertEqual(ManualReturnTimer(minutes: -.infinity).minutes, 30)
        XCTAssertEqual(ManualReturnTimer(minutes: -10).minutes, 5)
        XCTAssertEqual(ManualReturnTimer(minutes: 200).minutes, 120)
        XCTAssertEqual(ManualReturnTimer(minutes: 13).minutes, 15)
        var timer = ManualReturnTimer(enabled: true)
        timer.start(now: now)
        timer.cancel()
        XCTAssertNil(timer.deadline)
    }
}
