import XCTest
@testable import ZephyrCore

final class FanLeaseTests: XCTestCase {
    func testOnlyOneSessionOwnsLease() {
        let leases = FanLeaseCoordinator(); let first = UUID(); let second = UUID()
        XCTAssertTrue(leases.claim(first)); XCTAssertFalse(leases.claim(second)); XCTAssertTrue(leases.owns(first)); XCTAssertFalse(leases.owns(second))
        leases.release(second); XCTAssertTrue(leases.owns(first)); leases.release(first); XCTAssertTrue(leases.claim(second))
    }

    func testRecoveryKeepsLeaseUntilRestoreIsConfirmed() {
        var recovery = FanRecoveryState()
        let owner = UUID()
        let other = UUID()
        XCTAssertTrue(recovery.claim(owner))
        recovery.didSetManual(owner)
        recovery.requestRestore(owner)
        XCTAssertTrue(recovery.owns(owner))
        XCTAssertFalse(recovery.claim(other))
        recovery.restoreConfirmed(owner)
        XCTAssertTrue(recovery.claim(other))
    }

    func testNonOwnerEventsDoNotChangeRecovery() {
        var recovery = FanRecoveryState()
        let owner = UUID()
        let other = UUID()
        XCTAssertTrue(recovery.claim(owner))
        recovery.didSetManual(owner)
        recovery.requestRestore(other)
        XCTAssertFalse(recovery.restorePending)
        recovery.restoreConfirmed(other)
        XCTAssertTrue(recovery.owns(owner))
    }
}
