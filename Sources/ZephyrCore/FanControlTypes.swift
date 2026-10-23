import Foundation

public struct FanPreset: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var percent: Double
    public init(id: UUID = UUID(), name: String, percent: Double) { self.id = id; self.name = name; self.percent = percent }
}

/// A fan's control state as read from its mode register.
public enum FanModeState: String, Codable, Sendable {
    /// Firmware control (mode 0 or 3, mask bit clear), or a Mac with no
    /// mode register at all, where firmware control is the only mode.
    case automatic
    case manual
    /// A mode value or register Aervane does not recognize.
    case unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// One fan's actual readings, never interpolated or substituted.
public struct FanReading: Codable, Sendable, Equatable {
    /// Highest plausible fan speed; larger register values are corrupt.
    public static let plausibleRPM = 25_000.0

    public let index: Int
    public let currentRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    /// F<n>Tg in manual mode. Automatic mode hides the firmware's own target.
    public let targetRPM: Double?
    public let mode: FanModeState

    public init(index: Int, currentRPM: Double, minimumRPM: Double, maximumRPM: Double, targetRPM: Double?, mode: FanModeState) {
        self.index = index; self.currentRPM = currentRPM; self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM; self.targetRPM = targetRPM; self.mode = mode
    }

    public var automatic: Bool { mode == .automatic }
    /// Target as a percentage of this fan's own maximum.
    public var targetPercent: Double? {
        guard let targetRPM, maximumRPM > 0 else { return nil }
        return max(0, min(100, targetRPM / maximumRPM * 100))
    }
    /// The lowest percentage this fan can run at (its firmware minimum).
    public var floorPercent: Double { maximumRPM > 0 ? max(0, min(100, minimumRPM / maximumRPM * 100)) : 0 }
    public var isValid: Bool {
        (0...9).contains(index)
            && currentRPM.isFinite && (0...Self.plausibleRPM).contains(currentRPM)
            && minimumRPM.isFinite && minimumRPM >= 0
            && maximumRPM.isFinite && maximumRPM > 0 && maximumRPM <= Self.plausibleRPM && minimumRPM <= maximumRPM
            && (targetRPM.map { $0.isFinite && $0 >= 0 && $0 <= maximumRPM * 1.02 } ?? true)
    }
}

/// How a Mac's fans are switched between firmware and manual control.
public enum FanModeScheme: String, Codable, Sendable, CaseIterable {
    /// Per-fan ui8 `F<n>Md`: 0 automatic, 1 manual, 3 firmware-managed.
    case uppercase = "Md"
    /// Per-fan ui8 `F<n>md`, the newer spelling of the same register.
    case lowercase = "md"
    /// Legacy Intel ui16 `FS! `: bit n set forces fan n to manual.
    case legacyMask = "FS!"

    public func key(fan: Int) -> String {
        switch self {
        case .uppercase: return "F\(fan)Md"
        case .lowercase: return "F\(fan)md"
        case .legacyMask: return "FS! "
        }
    }
}

/// Whether Aervane can control this Mac's fans, and through which registers.
/// Unknown paths stay explicit: nothing is written without a scheme.
public struct FanControlStatus: Codable, Sendable, Equatable {
    public enum Blocker: String, Codable, Sendable {
        case noFans, requiresFtst, missingModeKey, inconsistentModeKeys, invalidModeRegister, invalidTargetRegister, undetermined
    }
    public let scheme: FanModeScheme?
    public let blocker: Blocker?
    /// The register or model fact behind a blocker.
    public let detail: String?
    /// The transaction also writes the one-byte aggregate `Ftst` gate: 1
    /// after the per-fan mode writes when any fan is manual, 0 once every
    /// fan is commanded back to Auto (models matching
    /// requiresNewSMCKeyForManualControl, REA-confirmed order and values).
    public let usesFtst: Bool

    public static func supported(_ scheme: FanModeScheme, ftst: Bool = false) -> FanControlStatus {
        FanControlStatus(scheme: scheme, blocker: nil, detail: nil, usesFtst: ftst)
    }
    public static func unavailable(_ blocker: Blocker, _ detail: String? = nil) -> FanControlStatus {
        FanControlStatus(scheme: nil, blocker: blocker, detail: detail, usesFtst: false)
    }
    private init(scheme: FanModeScheme?, blocker: Blocker?, detail: String?, usesFtst: Bool) {
        self.scheme = scheme; self.blocker = blocker; self.detail = detail; self.usesFtst = usesFtst
    }

    public var isSupported: Bool { scheme != nil && blocker == nil }

    public var message: String? {
        guard let blocker else { return scheme == nil ? Self.text(.undetermined, detail) : nil }
        return Self.text(blocker, detail)
    }
    private static func text(_ blocker: Blocker, _ detail: String?) -> String {
        let suffix = detail.map { " (\($0))" } ?? ""
        switch blocker {
        case .noFans: return "This Mac has no fans."
        case .requiresFtst: return "Fan control on this Mac model needs the Ftst register, which is missing or has an unexpected format\(suffix). Aervane shows fan speeds only."
        case .missingModeKey: return "No supported fan mode register was found\(suffix). Aervane shows fan speeds only."
        case .inconsistentModeKeys: return "This Mac's fans report different mode registers\(suffix). Aervane shows fan speeds only."
        case .invalidModeRegister: return "A fan mode register has an unexpected format\(suffix). Aervane shows fan speeds only."
        case .invalidTargetRegister: return "A fan target register is missing or has an unexpected format\(suffix). Aervane shows fan speeds only."
        case .undetermined: return "Fan control support could not be determined yet\(suffix)."
        }
    }

    /// Unknown values from a newer sender decode as undetermined, never as supported.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scheme = (try? c.decodeIfPresent(FanModeScheme.self, forKey: .scheme)) ?? nil
        let blocker = (try? c.decodeIfPresent(Blocker.self, forKey: .blocker)) ?? nil
        let unrecognized = c.contains(.blocker) && blocker == nil
        self.scheme = unrecognized ? nil : scheme
        self.blocker = unrecognized ? .undetermined : (scheme == nil ? (blocker ?? .undetermined) : blocker)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        usesFtst = (try? c.decodeIfPresent(Bool.self, forKey: .usesFtst)) ?? false
    }
}

public struct FanSnapshot: Codable, Sendable, Equatable {
    public let fanCount: Int
    /// Means over `fans`, so `currentRPM / maximumRPM` is the share of the
    /// fans' combined maximum in use and `currentRPM` is a typical fan's speed.
    public let currentRPM: Double; public let minimumRPM: Double; public let maximumRPM: Double
    /// The one percentage all fans follow (each clamped to its own floor);
    /// nil unless every fan is manual with a target. See `linkedPercent`.
    public let targetPercent: Double?
    /// True only when every fan is under firmware control.
    public let automatic: Bool
    public let temperatureCelsius: Double; public let sampledAt: Date
    /// Every fan's actual readings. A snapshot from an older helper carries
    /// none; it decodes as one fan when it reports exactly one.
    public let fans: [FanReading]
    /// Nil when the sender does not report control support.
    public let control: FanControlStatus?
    /// The aggregate Ftst gate, when this control path uses one. Nil keeps
    /// snapshots from older helpers and Macs without Ftst compatible.
    public let aggregateGate: Bool?

    /// One fan described by its aggregate values (older senders, tests).
    public init(currentRPM: Double, minimumRPM: Double, maximumRPM: Double, targetPercent: Double?, automatic: Bool, temperatureCelsius: Double, sampledAt: Date = .now, fanCount: Int = 1) {
        self.currentRPM = currentRPM; self.minimumRPM = minimumRPM; self.maximumRPM = maximumRPM
        self.targetPercent = targetPercent; self.automatic = automatic
        self.temperatureCelsius = temperatureCelsius; self.sampledAt = sampledAt; self.fanCount = fanCount
        fans = fanCount == 1 ? [Self.single(currentRPM, minimumRPM, maximumRPM, targetPercent, automatic)] : []
        control = nil
        aggregateGate = nil
    }

    public init(fans: [FanReading], temperatureCelsius: Double, sampledAt: Date = .now, control: FanControlStatus?, aggregateGate: Bool? = nil) {
        let aggregate = FanAggregate(fans)
        self.fans = fans; fanCount = fans.count; self.control = control
        currentRPM = aggregate.currentRPM; minimumRPM = aggregate.minimumRPM; maximumRPM = aggregate.maximumRPM
        targetPercent = aggregate.targetPercent; automatic = aggregate.automatic && aggregateGate != true
        self.temperatureCelsius = temperatureCelsius; self.sampledAt = sampledAt
        self.aggregateGate = aggregateGate
    }

    enum CodingKeys: String, CodingKey {
        case fanCount, currentRPM, minimumRPM, maximumRPM, targetPercent, automatic, temperatureCelsius, sampledAt, fans, control, aggregateGate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fanCount = try c.decode(Int.self, forKey: .fanCount)
        currentRPM = try c.decode(Double.self, forKey: .currentRPM)
        minimumRPM = try c.decode(Double.self, forKey: .minimumRPM)
        maximumRPM = try c.decode(Double.self, forKey: .maximumRPM)
        targetPercent = try c.decodeIfPresent(Double.self, forKey: .targetPercent)
        automatic = try c.decode(Bool.self, forKey: .automatic)
        temperatureCelsius = try c.decode(Double.self, forKey: .temperatureCelsius)
        sampledAt = try c.decode(Date.self, forKey: .sampledAt)
        control = (try? c.decodeIfPresent(FanControlStatus.self, forKey: .control)) ?? nil
        aggregateGate = try c.decodeIfPresent(Bool.self, forKey: .aggregateGate)
        if let fans = try c.decodeIfPresent([FanReading].self, forKey: .fans) { self.fans = fans }
        else { fans = fanCount == 1 ? [Self.single(currentRPM, minimumRPM, maximumRPM, targetPercent, automatic)] : [] }
    }

    static func single(_ current: Double, _ minimum: Double, _ maximum: Double, _ percent: Double?, _ automatic: Bool) -> FanReading {
        FanReading(index: 0, currentRPM: current, minimumRPM: minimum, maximumRPM: maximum,
                   targetRPM: automatic ? nil : percent.map { $0 * maximum / 100 }, mode: automatic ? .automatic : .manual)
    }

    /// The linked slider's floor: the lowest percentage at which any fan
    /// still responds. Fans with a higher floor stay at their own minimum.
    public var floorPercent: Double {
        if let lowest = fans.map(\.floorPercent).min() { return lowest }
        return maximumRPM > 0 ? max(0, min(100, minimumRPM / maximumRPM * 100)) : 0
    }

    /// Per-fan readings exist for every reported fan, once each, all valid.
    public var isConsistent: Bool {
        (0...10).contains(fanCount) && fans.count == fanCount
            && Set(fans.map(\.index)).count == fans.count && fans.allSatisfy(\.isValid)
    }
}

/// A fan-only readback (no temperature), used to verify restores.
public struct FanReadback: Sendable, Equatable {
    public let currentRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetPercent: Double?
    public let automatic: Bool
    public let aggregateGate: Bool?
    public let fans: [FanReading]

    public init(currentRPM: Double, minimumRPM: Double, maximumRPM: Double,
                targetPercent: Double?, automatic: Bool, aggregateGate: Bool? = nil) {
        self.currentRPM = currentRPM; self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM; self.targetPercent = targetPercent
        self.automatic = automatic && aggregateGate != true
        self.aggregateGate = aggregateGate
        fans = [FanSnapshot.single(currentRPM, minimumRPM, maximumRPM, targetPercent, automatic)]
    }

    public init(fans: [FanReading], aggregateGate: Bool? = nil) {
        let aggregate = FanAggregate(fans)
        self.fans = fans
        currentRPM = aggregate.currentRPM; minimumRPM = aggregate.minimumRPM; maximumRPM = aggregate.maximumRPM
        targetPercent = aggregate.targetPercent; automatic = aggregate.automatic && aggregateGate != true
        self.aggregateGate = aggregateGate
    }
}

/// The honest aggregate of several fans for the single linked control.
struct FanAggregate {
    let currentRPM: Double, minimumRPM: Double, maximumRPM: Double
    let targetPercent: Double?
    let automatic: Bool

    init(_ fans: [FanReading]) {
        let count = Double(max(1, fans.count))
        currentRPM = fans.map(\.currentRPM).reduce(0, +) / count
        minimumRPM = fans.map(\.minimumRPM).reduce(0, +) / count
        maximumRPM = fans.map(\.maximumRPM).reduce(0, +) / count
        automatic = fans.allSatisfy(\.automatic)
        targetPercent = Self.linkedPercent(fans)
    }

    /// The percentage P a linked command produces: every fan at max(P, its
    /// floor), so any fan above its floor shows P. When manual targets do
    /// not fit one P (another controller set them separately), the mean
    /// target is reported instead.
    static func linkedPercent(_ fans: [FanReading]) -> Double? {
        let targets = fans.compactMap { $0.mode == .manual ? $0.targetPercent : nil }
        guard !fans.isEmpty, targets.count == fans.count, let lowest = targets.min() else { return nil }
        let aboveFloor = fans.compactMap { fan in fan.targetPercent.flatMap { $0 > fan.floorPercent + 1.0 ? $0 : nil } }
        let linked = aboveFloor.min() ?? lowest
        let fits = fans.allSatisfy { abs(($0.targetPercent ?? -1) - max(linked, $0.floorPercent)) <= 1.0 }
        return fits ? linked : targets.reduce(0, +) / Double(targets.count)
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
    /// Settle windows are shared by all fans, so this does not grow with the fan count.
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
        max(requested, snapshot.floorPercent)
    }
    /// What one fan's target reads after a linked command of `requested`.
    public static func expectedPercent(_ requested: Double, fan: FanReading) -> Double {
        max(requested, fan.floorPercent)
    }
    public static func hasReliableReading(_ snapshot: FanSnapshot, now: Date = .now) -> Bool {
        snapshot.temperatureCelsius.isFinite && (-20...130).contains(snapshot.temperatureCelsius)
            && (-1...staleSampleAge).contains(now.timeIntervalSince(snapshot.sampledAt))
    }
    /// `fanIndices` is the fan set a lease was taken on; a different set is
    /// a topology change and ends manual control.
    public static func shouldRestoreAutomatic(snapshot: FanSnapshot, now: Date = .now, lastHeartbeat: Date?, fanIndices: [Int]? = nil) -> Bool {
        guard hasReliableReading(snapshot, now: now), snapshot.isConsistent, !snapshot.fans.isEmpty,
              fanIndices.map({ $0 == snapshot.fans.map(\.index) }) ?? true,
              snapshot.fans.allSatisfy({ fan in
                  fan.mode == .automatic || (fan.mode == .manual && (fan.targetPercent.map { $0.isFinite && (0...100).contains($0) } ?? false))
              }),
              let lastHeartbeat,
              now.timeIntervalSince(lastHeartbeat) <= leaseTimeout else { return true }
        return false
    }
}
