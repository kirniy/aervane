import Foundation

/// Model-aware CPU and GPU temperatures from AppleSMC.
///
/// Each kind is discovered once from its `SensorPlan`, then the whole
/// discovered set is required on every sample: a failing hot core must make
/// the sample fail rather than silently leave the safety maximum. Discovery
/// work is bounded: one pass over the plan per attempt, at most
/// `discoveryAttempts` attempts while reads fail transiently, and a pause of
/// `emptyRetryInterval` after a pass that found nothing.
public final class TemperatureSensors: @unchecked Sendable {
    public static let validRange = -20.0..<130.0
    public static let discoveryAttempts = 3
    public static let emptyRetryInterval: TimeInterval = 30

    /// Read-only Apple Silicon HID temperature adapter. Implementations own
    /// service discovery and event polling; the core keeps source selection
    /// deterministic and testable.
    public protocol HIDSource: AnyObject, Sendable {
        func hasSensors(for kind: SensorKind) -> Bool
        func read(_ kind: SensorKind) throws -> [Double]
        func sensorNames(for kind: SensorKind) -> [String]
    }

    /// What discovery settled on, for diagnostics and tests.
    public struct Discovery: Codable, Equatable, Sendable {
        public let kind: SensorKind
        public let source: SensorPlan.Source
        /// Keys every sample requires.
        public let keys: [String]
        /// `add_no_fail` keys: used when readable, skipped otherwise.
        public let optionalKeys: [String]
        /// Candidates that were present but not used, with the reason.
        public let skipped: [String: String]
        public let candidates: Int
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable(SensorKind)
        case discovering(SensorKind, attempt: Int)
        case invalidSample(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable(let kind): return "\(kind.rawValue.uppercased()) temperature is unavailable on this Mac."
            case let .discovering(kind, attempt): return "\(kind.rawValue.uppercased()) sensors are still being identified (attempt \(attempt) of \(TemperatureSensors.discoveryAttempts))."
            case .invalidSample(let key): return "Temperature sensor \(key) returned an invalid sample."
            }
        }
    }

    private struct State {
        let plan: SensorPlan
        var discovery: Discovery?
        var attempts = 0
        var retryAfter: Date?
        var retryFailure: Failure?
    }

    private let smc: SMCKeyReading
    private let hid: HIDSource?
    private let clock: () -> Date
    private let lock = NSLock()
    private var states: [SensorKind: State]

    public init(smc: SMCKeyReading, model: MacModel?, platform: SMCPlatform, hid: HIDSource? = nil, clock: @escaping () -> Date = Date.init) {
        self.smc = smc; self.clock = clock
        self.hid = platform == .appleSilicon ? hid : nil
        states = Dictionary(uniqueKeysWithValues: SensorKind.allCases.map { ($0, State(plan: .make(kind: $0, model: model, platform: platform))) })
    }

    public func plan(_ kind: SensorKind) -> SensorPlan { lock.lock(); defer { lock.unlock() }; return states[kind]!.plan }
    public func discovery(_ kind: SensorKind) -> Discovery? { lock.lock(); defer { lock.unlock() }; return states[kind]?.discovery }

    /// Mean and hottest CPU sensor from one read of the discovered set.
    public func readCPU() throws -> (average: Double, hottest: Double) {
        let values = try samples(.cpu)
        return (values.reduce(0, +) / Double(values.count), values.max()!)
    }

    /// Mean of the discovered GPU sensors.
    public func readGPU() throws -> Double {
        let values = try samples(.gpu)
        return values.reduce(0, +) / Double(values.count)
    }

    /// Control uses the hottest GPU die/cluster, never their average. Once
    /// an optional cluster has actually been discovered, losing it must not
    /// silently lower the control temperature.
    public func readGPUHottest() throws -> Double {
        try samples(.gpu, requireDiscoveredOptional: true).max()!
    }

    private func samples(_ kind: SensorKind, requireDiscoveredOptional: Bool = false) throws -> [Double] {
        lock.lock(); defer { lock.unlock() }
        if let hid, hid.hasSensors(for: kind) {
            let values = try hid.read(kind)
            guard !values.isEmpty else { throw Failure.unavailable(kind) }
            guard values.allSatisfy(Self.validRange.contains) else { throw Failure.invalidSample("Apple Silicon HID \(kind.rawValue)") }
            let names = hid.sensorNames(for: kind)
            states[kind]?.discovery = Discovery(kind: kind, source: .hid, keys: names,
                                                optionalKeys: [], skipped: [:], candidates: names.count)
            return values
        }
        let discovery = try discovered(kind)
        var values = try discovery.keys.map { key -> Double in
            let value = try SMCDecoder.temperature(smc.read(key))
            guard Self.validRange.contains(value) else { throw Failure.invalidSample(key) }
            return value
        }
        for key in discovery.optionalKeys {
            if requireDiscoveredOptional {
                let value = try SMCDecoder.temperature(smc.read(key))
                guard Self.validRange.contains(value) else { throw Failure.invalidSample(key) }
                values.append(value)
            } else if let value = try? SMCDecoder.temperature(smc.read(key)), Self.validRange.contains(value) { values.append(value) }
        }
        guard !values.isEmpty else { throw Failure.unavailable(kind) }
        return values
    }

    private func discovered(_ kind: SensorKind) throws -> Discovery {
        var state = states[kind]!
        if let discovery = state.discovery { return discovery }
        if let retryAfter = state.retryAfter, clock() < retryAfter { throw state.retryFailure ?? Failure.unavailable(kind) }
        state.attempts += 1
        defer { states[kind] = state }

        var found: [SensorPlan.Candidate] = [], skipped: [String: String] = [:], retry: [String: String] = [:]
        for tier in [true, false] {
            for candidate in state.plan.candidates where candidate.perCore == tier {
                do {
                    let value = try SMCDecoder.temperature(smc.read(candidate.key))
                    if !Self.validRange.contains(value) { retry[candidate.key] = "out of range (\(value) °C)" }
                    // Some Intel boards keep registers for cores they lack, reading exactly zero.
                    else if value == 0 { skipped[candidate.key] = "reads 0 °C (unpopulated)" }
                    else { found.append(candidate) }
                } catch SMCAccessError.notFound {
                    continue
                } catch SMCAccessError.invalidData(_, let reason) {
                    skipped[candidate.key] = reason
                } catch {
                    retry[candidate.key] = "read failed: \(error.localizedDescription)"
                }
            }
            // Per-core sensors (present or still uncertain) win over package sensors.
            if tier && (!found.isEmpty || !retry.isEmpty) { break }
        }

        if !retry.isEmpty {
            let failure = Failure.discovering(kind, attempt: state.attempts)
            if state.attempts >= Self.discoveryAttempts {
                state.attempts = 0
                state.retryAfter = clock().addingTimeInterval(Self.emptyRetryInterval)
                state.retryFailure = failure
            }
            // Never permanently exclude an uncertain core merely because a
            // bounded discovery pass expired. Back off, then discover again.
            throw failure
        }
        state.retryAfter = nil
        state.retryFailure = nil
        guard !found.isEmpty else {
            state.attempts = 0
            state.retryAfter = clock().addingTimeInterval(Self.emptyRetryInterval)
            throw Failure.unavailable(kind)
        }
        var used = found
        if !found.contains(where: \.perCore) {
            // Package level: one sensor, the best ranked (catalog order breaks ties).
            used = [found.enumerated().min { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }!.element]
            for other in found where other.key != used[0].key { skipped[other.key] = "lower-ranked package sensor" }
        }
        let required = used.filter { !$0.optional }.map(\.key), optional = used.filter(\.optional).map(\.key)
        let discovery = Discovery(kind: kind, source: state.plan.source, keys: required, optionalKeys: optional,
                                  skipped: skipped, candidates: state.plan.candidates.count)
        state.discovery = discovery
        return discovery
    }
}

public extension TemperatureSensors.HIDSource {
    func sensorNames(for kind: SensorKind) -> [String] { [] }
}
