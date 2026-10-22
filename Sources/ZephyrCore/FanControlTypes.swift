import Foundation

public struct FanPreset: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var percent: Double
    public init(id: UUID = UUID(), name: String, percent: Double) { self.id = id; self.name = name; self.percent = percent }
}

public struct FanSnapshot: Codable, Sendable, Equatable {
    public let currentRPM: Double; public let minimumRPM: Double; public let maximumRPM: Double
    public let targetPercent: Double?; public let automatic: Bool; public let temperatureCelsius: Double; public let sampledAt: Date
    public init(currentRPM: Double, minimumRPM: Double, maximumRPM: Double, targetPercent: Double?, automatic: Bool, temperatureCelsius: Double, sampledAt: Date = .now) { self.currentRPM=currentRPM; self.minimumRPM=minimumRPM; self.maximumRPM=maximumRPM; self.targetPercent=targetPercent; self.automatic=automatic; self.temperatureCelsius=temperatureCelsius; self.sampledAt=sampledAt }
}

public struct FanReadback: Sendable, Equatable {
    public let currentRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetPercent: Double?
    public let automatic: Bool
    public init(currentRPM: Double, minimumRPM: Double, maximumRPM: Double,
                targetPercent: Double?, automatic: Bool) {
        self.currentRPM = currentRPM; self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM; self.targetPercent = targetPercent
        self.automatic = automatic
    }
}

public enum FanControlError: Error, Codable, LocalizedError, Sendable {
    case invalidPercent, unavailable, staleSensor, hardwareFailure(String), unauthorized
    public var errorDescription: String? { switch self { case .invalidPercent: return "Fan percentage must be between 0 and 100."; case .unavailable: return "Fan control is unavailable on this Mac."; case .staleSensor: return "Cannot change fan speed while temperature data is unavailable, stale, or too hot."; case .hardwareFailure(let m): return m; case .unauthorized: return "The requesting app is not authorized." } }
}

@objc public protocol FanControlXPCProtocol: NSObjectProtocol {
    func snapshot(withReply reply: @escaping (Data?, Error?) -> Void)
    func setFanPercent(_ percent: Double, withReply reply: @escaping (Data?, Error?) -> Void)
    func restoreAutomatic(withReply reply: @escaping (Data?, Error?) -> Void)
    func heartbeat(withReply reply: @escaping (Error?) -> Void)
}

public enum FanSafety {
    public static let heartbeatInterval: TimeInterval = 5
    public static let leaseTimeout: TimeInterval = 15
    public static let staleSampleAge: TimeInterval = 10
    public static let criticalTemperatureCelsius: Double = 95
    public static func validate(percent: Double) throws -> Double { guard percent.isFinite, (0...100).contains(percent) else { throw FanControlError.invalidPercent }; return percent.rounded() }
    public static func validateTemperature(_ temperature: Double) throws -> Double {
        guard temperature.isFinite, (-20...130).contains(temperature) else {
            throw FanControlError.hardwareFailure("Temperature sensor returned an invalid sample.")
        }
        return temperature
    }
    public static func matchesRequestedPercent(_ actual: Double?, expected: Double, tolerance: Double = 1.0) -> Bool {
        guard let actual, actual.isFinite else { return false }
        return abs(actual - expected) <= tolerance
    }
    public static func hardwareFloorClampedPercent(_ requested: Double, snapshot: FanSnapshot) -> Double {
        guard snapshot.maximumRPM.isFinite, snapshot.maximumRPM > 0,
              snapshot.minimumRPM.isFinite else { return requested }
        let floor = max(0, min(100, snapshot.minimumRPM / snapshot.maximumRPM * 100))
        return max(requested, floor)
    }
    public static func shouldRestoreAutomatic(snapshot: FanSnapshot, now: Date = .now, lastHeartbeat: Date?) -> Bool { if !snapshot.temperatureCelsius.isFinite || snapshot.temperatureCelsius < -20 || snapshot.temperatureCelsius >= criticalTemperatureCelsius || now.timeIntervalSince(snapshot.sampledAt) > staleSampleAge { return true }; if let lastHeartbeat { return now.timeIntervalSince(lastHeartbeat) > leaseTimeout }; return true }
}
