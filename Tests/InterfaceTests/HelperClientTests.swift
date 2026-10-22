import XCTest
@testable import Zephyr
import ZephyrCore

final class HelperClientTests: XCTestCase {
    func testSigningFailureReturnsUnauthorizedWithoutActivatingARequest() {
        let client = HelperClient(serviceName: "dev.kirniy.test.no-helper", requirementProvider: { nil })
        let expectation = expectation(description: "reply")
        client.snapshot { result in
            guard case .failure(let error) = result else {
                XCTFail("expected unauthorized failure")
                expectation.fulfill()
                return
            }
            XCTAssertEqual((error as? FanControlError)?.errorDescription,
                           FanControlError.unauthorized.errorDescription)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
    }

    func testReplyGateIgnoresLateReplyAndTimeoutAfterFirstCompletion() {
        let delivered = expectation(description: "one delivery")
        let timeout = expectation(description: "timeout must not run")
        timeout.isInverted = true
        let gate = HelperReplyGate<Int>(timeout: 0.05) {
            timeout.fulfill()
        }
        var count = 0
        gate.finish(1) { value in
            count += 1
            XCTAssertEqual(value, 1)
            delivered.fulfill()
        }
        gate.finish(2) { _ in count += 1 }
        wait(for: [delivered, timeout], timeout: 0.2)
        XCTAssertEqual(count, 1)
    }

    func testReplyGateTimesOutSilentRequestExactlyOnce() {
        let first = expectation(description: "timeout delivery")
        let late = expectation(description: "late completion must be ignored")
        late.isInverted = true
        let gate = HelperReplyGate<Int>(timeout: 0.03) {
            first.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            gate.finish(7) { _ in late.fulfill() }
        }
        wait(for: [first, late], timeout: 0.15)
    }
}
