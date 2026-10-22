import Foundation
import ServiceManagement

public enum HelperInstallError: Error, LocalizedError {
    case requiresApproval
    case notFound
    public var errorDescription: String? { switch self { case .requiresApproval: return "macOS requires approval for Aervane's helper in System Settings → Login Items & Extensions."; case .notFound: return "Aervane's embedded helper was not found in the application bundle." } }
}

public final class HelperInstaller {
    public init() {}
    @available(macOS 13.0, *)
    public var status: SMAppService.Status { SMAppService.daemon(plistName: HelperRegistration.plistName).status }
    @available(macOS 13.0, *)
    @discardableResult public func enable() throws -> SMAppService.Status {
        let service = SMAppService.daemon(plistName: HelperRegistration.plistName)
        try service.register()
        if service.status == .requiresApproval { throw HelperInstallError.requiresApproval }
        if service.status == .notFound { throw HelperInstallError.notFound }
        return service.status
    }
    @available(macOS 13.0, *)
    public func disable() throws { try SMAppService.daemon(plistName: HelperRegistration.plistName).unregister() }

}
