import Foundation

/// A structured, local-only description of what Aervane found on this Mac:
/// the model, every fan's readings, the control path or why there is none,
/// and which temperature sensors were chosen. It holds no serial numbers,
/// user data or identifiers beyond the hardware model.
public struct HardwareDiagnostics: Codable, Equatable, Sendable {
    public struct Fan: Codable, Equatable, Sendable {
        public let reading: FanReading
        public let label: String?
    }

    public let model: String?
    public let catalogModel: String?
    public let platform: SMCPlatform
    /// Static catalog predicates that hold for this model.
    public let modelFacts: [String]
    public let fans: [Fan]?
    public let fanError: String?
    public let control: FanControlStatus?
    public let cpu: TemperatureSensors.Discovery?
    public let cpuError: String?
    public let gpu: TemperatureSensors.Discovery?
    public let gpuError: String?
    public let catalog: String

    public static func collect(model: MacModel?, platform: SMCPlatform,
                               inventory: FanInventoryReader, sensors: TemperatureSensors) -> HardwareDiagnostics {
        let fans = Result { try inventory.read() }
        let cpu = Result { try sensors.readCPU() }, gpu = Result { try sensors.readGPU() }
        func failure<T>(_ result: Result<T, Error>) -> String? {
            if case .failure(let error) = result { return error.localizedDescription }
            return nil
        }
        var facts: [String] = []
        if let model {
            if model.requiresFtst { facts.append("requiresFtst") }
            if model.requiresLowercaseMode { facts.append("lowercaseModeKey") }
            if model.vendorReportsControlNotWorking { facts.append("vendorReportsControlNotWorking") }
            if model.hasNoFans { facts.append("fanlessModel") }
            if model.family == nil { facts.append("unknownFamily") }
        }
        let inventoryValue = try? fans.get()
        return HardwareDiagnostics(
            model: model?.identifier, catalogModel: model?.normalized, platform: platform, modelFacts: facts,
            fans: inventoryValue.map { $0.fans.map { Fan(reading: $0, label: HardwareCatalog.fanLabel(model: model, fan: $0.index)) } },
            fanError: failure(fans), control: inventoryValue?.control,
            cpu: sensors.discovery(.cpu), cpuError: failure(cpu),
            gpu: sensors.discovery(.gpu), gpuError: failure(gpu),
            catalog: HardwareCatalog.source)
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
