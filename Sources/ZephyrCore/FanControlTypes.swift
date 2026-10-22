import Foundation

public struct FanPreset: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var percent: Double
    public init(id: UUID = UUID(), name: String, percent: Double) { self.id = id; self.name = name; self.percent = percent }
}

public struct FanSnapshot: Codable, Sendable, Equatable {
    public let fanCount: Int
    public let currentRPM: Double; public let minimumRPM: Double; public let maximumRPM: Double
    public let targetPercent: Double?; public let automatic: Bool; public let temperatureCelsius: Double; public let sampledAt: Date
    public init(currentRPM: Double, minimumRPM: Double, maximumRPM: Double, targetPercent: Double?, automatic: Bool, temperatureCelsius: Double, sampledAt: Date = .now, fanCount: Int = 1) { self.currentRPM=currentRPM; self.minimumRPM=minimumRPM; self.maximumRPM=maximumRPM; self.targetPercent=targetPercent; self.automatic=automatic; self.temperatureCelsius=temperatureCelsius; self.sampledAt=sampledAt; self.fanCount=fanCount }
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
    case invalidPercent, unavailable, staleSensor, hardwareFailure(String), unauthorized, tooHot(Double)
    public var errorDescription: String? { switch self { case .invalidPercent: return "Fan percentage must be between 0 and 100."; case .unavailable: return "Fan control is unavailable on this Mac."; case .staleSensor: return "Cannot change fan speed without a fresh, valid temperature reading."; case .hardwareFailure(let m): return m; case .unauthorized: return "The requesting app is not authorized."; case .tooHot(let temperature): return "Hottest CPU core: \(Int(temperature.rounded()))°C. Keep Auto or choose 100% cooling until it cools." } }
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
    public static func hasReliableReading(_ snapshot: FanSnapshot, now: Date = .now) -> Bool {
        snapshot.temperatureCelsius.isFinite && (-20...130).contains(snapshot.temperatureCelsius)
            && (-1...staleSampleAge).contains(now.timeIntervalSince(snapshot.sampledAt))
    }
    public static func isMaximumCooling(_ snapshot: FanSnapshot) -> Bool {
        guard snapshot.fanCount == 1, !snapshot.automatic, snapshot.maximumRPM.isFinite,
              snapshot.maximumRPM > 0, let target = snapshot.targetPercent, target.isFinite else { return false }
        // One RPM covers float/fpe2 rounding; the normal 1% write tolerance
        // must not permit 99% to count as maximum cooling while hot.
        return target >= 100 - 100 / snapshot.maximumRPM && target <= 100
    }
    public static func shouldRestoreAutomatic(snapshot: FanSnapshot, now: Date = .now, lastHeartbeat: Date?) -> Bool {
        guard hasReliableReading(snapshot, now: now), let lastHeartbeat,
              now.timeIntervalSince(lastHeartbeat) <= leaseTimeout else { return true }
        return snapshot.temperatureCelsius >= criticalTemperatureCelsius && !isMaximumCooling(snapshot)
    }
}
