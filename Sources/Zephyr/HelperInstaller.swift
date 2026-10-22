import Foundation
import ServiceManagement
import Security

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

    /// Development fallback for macOS releases where the LaunchDaemon API is
    /// unavailable. The helper bundle must carry the matching SMPrivilegedExecutables
    /// requirement; production builds should use SMAppService and notarization.
    @available(macOS, deprecated: 13.0, message: "Use SMAppService.daemon for notarized builds")
    public func enableLegacyBless() throws {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else { throw HelperInstallError.notFound }
        defer { AuthorizationFree(authorization, []) }
        var error: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, "dev.kirniy.aervane.helper" as CFString, authorization, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw NSError(domain: "Aervane.Helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "SMJobBless failed"])
        }
    }
}
