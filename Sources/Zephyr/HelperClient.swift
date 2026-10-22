import Foundation
import ZephyrCore

public final class HelperClient: NSObject, @unchecked Sendable {
    public static let serviceName = "dev.kirniy.aervane.helper"
    private let connection: NSXPCConnection
    public init(serviceName: String = HelperClient.serviceName) {
        connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in self?.onDisconnect?() }
        connection.interruptionHandler = { [weak self] in self?.onDisconnect?() }
        guard let requirement = SigningRequirement.requirement(identifier: "dev.kirniy.aervane.helper") else { connection.invalidate(); return }
        connection.setCodeSigningRequirement(requirement)
        connection.activate()
    }
    public var onDisconnect: (() -> Void)?
    public func snapshot(_ reply: @escaping (Result<FanSnapshot, Error>) -> Void) { proxy { reply(.failure($0)) }.snapshot { d,e in reply(Self.decode(d,e)) } }
    public func set(percent: Double, _ reply: @escaping (Result<FanSnapshot, Error>) -> Void) { proxy { reply(.failure($0)) }.setFanPercent(percent) { d,e in reply(Self.decode(d,e)) } }
    public func automatic(_ reply: @escaping (Result<FanSnapshot, Error>) -> Void) { proxy { reply(.failure($0)) }.restoreAutomatic { d,e in reply(Self.decode(d,e)) } }
    public func heartbeat(_ reply: @escaping (Error?) -> Void = { _ in }) { proxy { reply($0) }.heartbeat(withReply: reply) }
    public func invalidate() { connection.invalidate() }
    private func proxy(_ error: @escaping (Error) -> Void) -> FanControlXPCProtocol { connection.remoteObjectProxyWithErrorHandler(error) as! FanControlXPCProtocol }
    private static func decode(_ data: Data?, _ error: Error?) -> Result<FanSnapshot, Error> { if let error { return .failure(error) }; guard let data else { return .failure(FanControlError.unavailable) }; do { return .success(try JSONDecoder().decode(FanSnapshot.self, from: data)) } catch { return .failure(error) } }
}
