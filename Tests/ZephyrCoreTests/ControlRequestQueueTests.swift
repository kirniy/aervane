import XCTest
@testable import ZephyrCore

final class ControlRequestQueueTests: XCTestCase {
    func testIdleQueueSendsImmediately() {
        var queue = ControlRequestQueue()
        XCTAssertEqual(queue.submit(.set(60)), .set(60))
        XCTAssertTrue(queue.isBusy)
    }

    /// Regression: Auto pressed while the first manual write was in flight
    /// was ignored (the app did not own control yet), leaving the fan manual.
    func testAutoDuringInFlightSetRunsNext() {
        var queue = ControlRequestQueue()
        _ = queue.submit(.set(100))
        XCTAssertNil(queue.submit(.automatic))
        XCTAssertEqual(queue.finish(), .automatic)
        XCTAssertNil(queue.finish())
        XCTAssertFalse(queue.isBusy)
    }

    /// Regression: slider input during a command was dropped because every
    /// control was disabled while busy.
    func testDragsDuringCommandCoalesceToNewestValue() {
        var queue = ControlRequestQueue()
        _ = queue.submit(.set(40))
        for value in [45.0, 52, 61, 70] { XCTAssertNil(queue.submit(.set(value))) }
        XCTAssertEqual(queue.pendingPercent, 70)
        XCTAssertEqual(queue.finish(), .set(70))
        XCTAssertNil(queue.finish())
    }

    func testNewerSpeedReplacesQueuedAutoAndViceVersa() {
        var queue = ControlRequestQueue()
        _ = queue.submit(.set(40))
        _ = queue.submit(.automatic); _ = queue.submit(.set(80))
        XCTAssertEqual(queue.queued, .set(80))
        _ = queue.submit(.automatic)
        XCTAssertEqual(queue.queued, .automatic)
        XCTAssertNil(queue.pendingPercent)
    }

    func testRepeatOfInFlightCommandIsNotSentTwice() {
        var queue = ControlRequestQueue()
        _ = queue.submit(.automatic)
        XCTAssertNil(queue.submit(.automatic))
        XCTAssertNil(queue.finish())
    }

    func testResetReportsWhetherAutoWasWanted() {
        var queue = ControlRequestQueue()
        _ = queue.submit(.set(40)); _ = queue.submit(.automatic)
        XCTAssertTrue(queue.reset())
        XCTAssertFalse(queue.isBusy)
        _ = queue.submit(.set(40))
        XCTAssertFalse(queue.reset())
    }

    func testWireCodesRoundTripEveryActionableError() {
        let errors: [FanControlError] = [.invalidPercent, .unavailable, .staleSensor, .hardwareFailure("detail"), .unauthorized, .timedOut, .notOwner]
        for error in errors {
            let decoded = FanControlError.fromWire(domain: FanControlError.wireDomain, code: error.wireCode, message: error.errorDescription ?? "")
            XCTAssertEqual(decoded?.errorDescription, error.errorDescription)
        }
        XCTAssertNil(FanControlError.fromWire(domain: "NSCocoaErrorDomain", code: 8, message: ""))
    }
}
