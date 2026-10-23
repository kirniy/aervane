import Foundation
import ZephyrCore

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = FanControlService()
        connection.exportedInterface = NSXPCInterface(with: FanControlXPCProtocol.self)
        connection.exportedObject = service
        guard let requirement = SigningRequirement.requirement(identifier: "dev.kirniy.aervane") else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.invalidationHandler = { service.clientDisconnected() }
        connection.interruptionHandler = { service.clientDisconnected() }
        // NSXPCConnection.activate() is macOS 14+; resume() is the macOS 13 equivalent.
        if #available(macOS 14.0, *) { connection.activate() } else { connection.resume() }
        return true
    }
}

let delegate = Delegate()
FanControlService.bootstrap()
let listener = NSXPCListener(machServiceName: "dev.kirniy.aervane.helper")
listener.delegate = delegate; listener.resume(); RunLoop.current.run()
