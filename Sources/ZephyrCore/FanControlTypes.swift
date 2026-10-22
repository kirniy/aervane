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
    case invalidPercent, unavailable, staleSensor, hardwareFailure(String), unauthorized, timedOut, notOwner
    public var errorDescription: String? { switch self { case .timedOut: return "The fan helper did not answer in time. Reconnecting; the helper returns a dropped connection's fan to Auto."; case .notOwner: return "Aervane no longer controls the fan."; case .invalidPercent: return "Fan percentage must be between 0 and 100."; case .unavailable: return "Fan control is unavailable on this Mac."; case .staleSensor: return "Cannot change fan speed without a fresh, valid temperature reading."; case .hardwareFailure(let m): return m; case .unauthorized: return "The requesting app is not authorized." } }
}

/// The helper sends errors as plain NSErrors (domain, code, message) so
/// they survive XPC secure coding. One table serves both directions.
public extension FanControlError {
    static let wireDomain = "dev.kirniy.aervane.FanControl"
    var wireCode: Int {
        switch self {
        case .invalidPercent: return 1
        case .unavailable: return 2
        case .staleSensor: return 3
        case .hardwareFailure: return 4
        case .unauthorized: return 5
        case .timedOut: return 7
        case .notOwner: return 8
        }
    }
    /// Unknown and retired wire codes retain their original NSError message.
    static func fromWire(domain: String, code: Int, message: String) -> FanControlError? {
        guard domain == wireDomain else { return nil }
        switch code {
        case 1: return .invalidPercent
        case 2: return .unavailable
        case 3: return .staleSensor
        case 4: return .hardwareFailure(message)
        case 5: return .unauthorized
        case 7: return .timedOut
        case 8: return .notOwner
        default: return nil
        }
    }
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
    /// Client deadline for snapshots. The helper answers these from one read.
    public static let statusReplyTimeout: TimeInterval = 5
    /// Client deadline for set, restore and heartbeat. Heartbeats share the
    /// helper's serial queue, so they can wait behind a complete command: a
    /// failed write plus its rollback, journal I/O and SMC call overhead.
    public static let commandReplyTimeout: TimeInterval = 12
    public static var commandWorstCase: TimeInterval { FanWritePlan.standard.worstCaseWrite + FanWritePlan.standard.worstCaseRestore }
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
    public static func shouldRestoreAutomatic(snapshot: FanSnapshot, now: Date = .now, lastHeartbeat: Date?) -> Bool {
        guard hasReliableReading(snapshot, now: now), snapshot.fanCount == 1,
              snapshot.currentRPM.isFinite, snapshot.currentRPM >= 0,
              snapshot.minimumRPM.isFinite, snapshot.minimumRPM >= 0,
              snapshot.maximumRPM.isFinite, snapshot.maximumRPM > 0,
              snapshot.minimumRPM <= snapshot.maximumRPM,
              (snapshot.automatic || (snapshot.targetPercent.map { $0.isFinite && (0...100).contains($0) } ?? false)),
              let lastHeartbeat,
              now.timeIntervalSince(lastHeartbeat) <= leaseTimeout else { return true }
        return false
    }
}
