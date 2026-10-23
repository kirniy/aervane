import Foundation
import OSLog
import SMC
import ZephyrCore

/// AppleSMC through the C client, in ZephyrCore's raw-key terms.
final class SMCBridge: SMCKeyWriting {
    private let reader: SMCReader
    init(reader: SMCReader = SMCReader()) { self.reader = reader }

    func read(_ key: String) throws -> SMCValue {
        do {
            let value = try reader.read(key)
            return SMCValue(key: key, dataType: FourCC(rawValue: value.dataType), bytes: value.bytes)
        } catch SMCError.notFound { throw SMCAccessError.notFound(key) }
    }

    func write(_ value: SMCValue) throws {
        do { try reader.writeControlKey(value.key, dataType: value.dataType.rawValue, bytes: value.bytes) }
        catch SMCError.notFound { throw SMCAccessError.notFound(value.key) }
    }

    static var model: MacModel? { SMCReader.hardwareModel().map(MacModel.init(identifier:)) }
    static var platform: SMCPlatform { SMCReader.isAppleSiliconHardware() ? .appleSilicon : .intel }
}

/// Every fan through the shared AppleSMC connection. Writes go through one
/// `FanWriteTransaction` over all fans of the resolved mode scheme.
final class SMCFanDriver {
    private static let logger = Logger(subsystem: "dev.kirniy.aervane.helper", category: "smc")
    private let smc = SMCBridge()
    private let inventoryReader: FanInventoryReader
    private let sensors: TemperatureSensors
    /// The last fan set and scheme a write used. Restoring Auto falls back to
    /// it when a fresh inventory cannot be read, because restore is the
    /// fail-safe direction and must not wait for a perfect reading.
    private var lastBank: SMCFanBank?

    init() {
        let model = SMCBridge.model
        inventoryReader = FanInventoryReader(smc: smc, model: model, platform: SMCBridge.platform)
        let platform = SMCBridge.platform
        sensors = TemperatureSensors(smc: smc, model: model, platform: platform,
                                     hid: platform == .appleSilicon ? AppleSiliconHIDSource() : nil)
    }

    func inventory() throws -> FanInventory { try inventoryReader.read() }
    func hottestTemperature() throws -> Double { try sensors.readCPU().hottest }

    /// The firmware keeps an automatic fan's last target in F<n>Tg even
    /// though snapshots hide it. Recovery journals these raw values before
    /// switching fans to manual mode.
    func rawTargetPercents() throws -> [Int: Double] {
        let bank = try controlBank()
        var targets: [Int: Double] = [:]
        for fan in bank.fanIndices {
            let registers = try bank.readRegisters(fan: fan)
            guard registers.maximumRPM.isFinite, registers.maximumRPM > 0,
                  registers.targetRPM.isFinite, registers.targetRPM >= 0,
                  registers.targetRPM <= registers.maximumRPM * 1.02 else {
                throw FanControlError.unavailable
            }
            targets[fan] = max(0, min(100, registers.targetRPM / registers.maximumRPM * 100))
        }
        return targets
    }

    func set(percent: Double) throws {
        let bank = try controlBank()
        lastBank = bank
        let trace = try FanWriteTransaction(bank: bank, plan: .standard).apply(percent: percent)
        Self.logger.info("Manual write verified (\(bank.scheme.rawValue, privacy: .public)\(bank.usesAggregateGate ? "+Ftst" : "", privacy: .public), fans \(bank.fanIndices, privacy: .public)): \(trace.description, privacy: .public)")
    }

    func automatic(fans: [Int]? = nil) throws {
        let bank: SMCFanBank
        do { bank = try controlBank() } catch {
            guard let lastBank else { throw error }
            Self.logger.error("Restoring Auto with the last known fan set: \(error.localizedDescription, privacy: .public)")
            bank = lastBank
        }
        let restoreBank: SMCFanBank
        if let fans {
            let current = Set(bank.fanIndices)
            let surviving = fans.filter { current.contains($0) }
            guard !surviving.isEmpty else { throw FanControlError.unavailable }
            restoreBank = SMCFanBank(smc: smc, scheme: bank.scheme, fans: surviving, ftst: bank.usesAggregateGate)
        } else { restoreBank = bank }
        let trace = try FanWriteTransaction(bank: restoreBank, plan: .standard).restoreAutomatic()
        Self.logger.info("Automatic restore verified (fans \(restoreBank.fanIndices, privacy: .public)): \(trace.description, privacy: .public)")
    }

    /// A bank only for a supported scheme over a complete inventory: unknown
    /// control paths are reported, never attempted.
    private func controlBank() throws -> SMCFanBank {
        let inventory = try inventoryReader.read()
        guard !inventory.fans.isEmpty else { throw FanControlError.unavailable }
        guard let bank = SMCFanBank(smc: smc, inventory: inventory) else {
            throw FanControlError.hardwareFailure(inventory.control.message ?? "Fan control is unavailable on this Mac.")
        }
        return bank
    }
}
