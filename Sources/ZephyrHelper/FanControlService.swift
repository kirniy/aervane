import Foundation
import OSLog
import ZephyrCore

final class FanControlService: NSObject, FanControlXPCProtocol {
    private static let logger = Logger(subsystem: "dev.kirniy.aervane.helper", category: "fan-control")
    private let sessionID = UUID()
    private let controller = FanControlController.shared
    static func bootstrap() { FanControlController.initialize() }

    func clientDisconnected() { controller.disconnected(sessionID) }
    func start() {}
    func snapshot(withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.snapshot { data, error in reply(data, error.map(Self.xpcError)) }
    }
    func setFanPercent(_ percent: Double, withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.set(percent: percent, session: sessionID) { data, error in
            if let error {
                Self.logger.error("Fan set failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.info("Fan set succeeded")
            }
            reply(data, error.map(Self.xpcError))
        }
    }
    func restoreAutomatic(withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.restore(session: sessionID) { data, error in
            if let error {
                Self.logger.error("Automatic restore failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.info("Automatic restore succeeded")
            }
            reply(data, error.map(Self.xpcError))
        }
    }
    func heartbeat(withReply reply: @escaping (Error?) -> Void) {
        controller.heartbeat(session: sessionID) { error in reply(error.map(Self.xpcError)) }
    }

    static func xpcError(_ error: Error) -> NSError {
        if let error = error as? FanControlError {
            return NSError(domain: FanControlError.wireDomain, code: error.wireCode,
                           userInfo: [NSLocalizedDescriptionKey: error.errorDescription ?? "Fan control failed."])
        }
        let nsError = error as NSError
        return NSError(domain: nsError.domain, code: nsError.code,
                       userInfo: [NSLocalizedDescriptionKey: nsError.localizedDescription])
    }
}

/// The production driver: AppleSMC fan inventory, all-fan transactions and
/// the hottest CPU sensor, through `SMCFanDriver`.
final class SMCRecoveryDriver: FanRecoveryDriver, FanRawTargetReader {
    private let hardware = SMCFanDriver()

    func snapshot() throws -> FanSnapshot {
        let inventory = try hardware.inventory()
        let temperature = try FanSafety.validateTemperature(hardware.hottestTemperature())
        return inventory.snapshot(temperatureCelsius: temperature)
    }

    func fanSnapshot() throws -> FanReadback {
        let inventory = try hardware.inventory()
        return FanReadback(fans: inventory.fans, aggregateGate: inventory.aggregateGate)
    }
    func rawTargetPercent() throws -> Double {
        guard let value = try hardware.rawTargetPercents()[0] else { throw FanControlError.unavailable }
        return value
    }
    func rawTargetPercents() throws -> [Int: Double] { try hardware.rawTargetPercents() }

    func set(percent: Double) throws { try hardware.set(percent: percent) }
    func restoreAutomatic() throws { try hardware.automatic() }
    func restoreAutomatic(fans: [Int]?) throws { try hardware.automatic(fans: fans) }
    func automatic() throws -> Bool { try fanSnapshot().automatic }
}
