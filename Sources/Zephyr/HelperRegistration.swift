import Foundation
import ServiceManagement

public enum HelperRegistration {
    public static let plistName = "dev.kirniy.aervane.helper.plist"
    @available(macOS 13.0, *)
    public static var status: SMAppService.Status { SMAppService.daemon(plistName: plistName).status }
    @available(macOS 13.0, *)
    @discardableResult public static func register() throws -> SMAppService.Status {
        let service = SMAppService.daemon(plistName: plistName)
        if service.status != .enabled { try service.register() }
        return service.status
    }
    @available(macOS 13.0, *)
    public static func unregister() throws { try SMAppService.daemon(plistName: plistName).unregister() }
}
