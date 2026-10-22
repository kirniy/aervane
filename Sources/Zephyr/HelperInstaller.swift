import Foundation
import ServiceManagement

public enum HelperInstallError: Error, LocalizedError {
    case notFound, notRegistered
    public var errorDescription: String? {
        switch self {
        case .notFound: return "Aervane's embedded helper was not found. Reinstall Aervane in Applications."
        case .notRegistered: return "macOS did not register Aervane's helper. Try setup again."
        }
    }
}

protocol HelperServiceRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}
extension SMAppService: HelperServiceRegistration {}

public final class HelperInstaller {
    private let service: any HelperServiceRegistration
    public init() { service = SMAppService.daemon(plistName: HelperRegistration.plistName) }
    init(service: any HelperServiceRegistration) { self.service = service }
    public var status: SMAppService.Status { service.status }

    @discardableResult public func enable() throws -> SMAppService.Status {
        let before = service.status
        if before == .enabled || before == .requiresApproval { return before }
        do { try service.register() }
        catch {
            // register() can throw EPERM after successfully adding the daemon
            // for approval. The resulting status distinguishes that expected
            // first-run state from an actual installation failure.
            if service.status == .requiresApproval { return .requiresApproval }
            throw error
        }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: throw HelperInstallError.notFound
        default: throw HelperInstallError.notRegistered
        }
    }
    public func disable() throws { try service.unregister() }
}
