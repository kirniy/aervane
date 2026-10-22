import ServiceManagement
import XCTest
@testable import Zephyr

final class HelperInstallerTests: XCTestCase {
    private final class Service: HelperServiceRegistration {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var registerAction: (() throws -> Void)?
        func register() throws { registrations += 1; try registerAction?() }
        func unregister() throws { status = .notRegistered }
    }

    func testRegistrationErrorWithPendingApprovalIsAnExpectedState() throws {
        let service = Service()
        service.registerAction = {
            service.status = .requiresApproval
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
        }
        XCTAssertEqual(try HelperInstaller(service: service).enable(), .requiresApproval)
        XCTAssertEqual(service.registrations, 1)
    }

    func testApprovalPendingDoesNotRegisterAgain() throws {
        let service = Service(); service.status = .requiresApproval
        XCTAssertEqual(try HelperInstaller(service: service).enable(), .requiresApproval)
        XCTAssertEqual(service.registrations, 0)
    }

    func testEnabledServiceDoesNotRegisterAgain() throws {
        let service = Service(); service.status = .enabled
        XCTAssertEqual(try HelperInstaller(service: service).enable(), .enabled)
        XCTAssertEqual(service.registrations, 0)
    }

    func testRealRegistrationFailureIsPreserved() {
        let service = Service()
        service.registerAction = { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
        XCTAssertThrowsError(try HelperInstaller(service: service).enable()) {
            XCTAssertEqual(($0 as NSError).domain, "SMAppServiceErrorDomain")
            XCTAssertEqual(($0 as NSError).code, 1)
        }
    }

    func testMissingHelperDoesNotPretendToBeConnected() {
        let service = Service(); service.registerAction = { service.status = .notFound }
        XCTAssertThrowsError(try HelperInstaller(service: service).enable()) {
            guard case HelperInstallError.notFound = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }
}
