import Foundation

/// Every fan the SMC reports, read in one pass, with the control path.
public struct FanInventory: Sendable, Equatable {
    public let fans: [FanReading]
    public let control: FanControlStatus
    public let aggregateGate: Bool?

    public init(fans: [FanReading], control: FanControlStatus, aggregateGate: Bool? = nil) { self.fans = fans; self.control = control; self.aggregateGate = aggregateGate }

    public var isEmpty: Bool { fans.isEmpty }
    public func snapshot(temperatureCelsius: Double, sampledAt: Date = .now) -> FanSnapshot {
        FanSnapshot(fans: fans, temperatureCelsius: temperatureCelsius, sampledAt: sampledAt, control: control, aggregateGate: aggregateGate)
    }
}

public enum FanInventoryError: Error, Equatable, LocalizedError {
    /// FNum changed; the new count is used only once it repeats.
    case topologyUnconfirmed(previous: Int, reported: Int)
    case invalidRegister(String, String)

    public var errorDescription: String? {
        switch self {
        case let .topologyUnconfirmed(previous, reported):
            return "The SMC reported \(reported) fan\(reported == 1 ? "" : "s") after \(previous); waiting for a consistent reading."
        case let .invalidRegister(key, reason): return "Fan register \(key) is invalid: \(reason)."
        }
    }
}

/// Reads all fans (0...10) and resolves how they are controlled.
///
/// A read failure of any fan fails the whole read: a transient error never
/// shrinks the inventory. A different valid FNum is accepted only after it
/// is read `topologyConfirmations` times in a row. The mode registers are
/// probed once per fan count; transient probe failures are not cached, and
/// once a strategy is selected a later probe never silently switches it.
public final class FanInventoryReader: @unchecked Sendable {
    public static let maximumFans = 10

    private enum ModeSource: Equatable {
        case perFan(FanModeScheme), mask, none
        case inconsistent(String), invalid(String)
    }
    private struct Resolution { let count: Int; let source: ModeSource; let targetIssue: String?; let ftstIssue: String? }

    private let smc: SMCKeyReading
    public let model: MacModel?
    public let platform: SMCPlatform?
    private let confirmations: Int
    private let lock = NSLock()
    private var acceptedCount: Int?
    private var pendingCount: (count: Int, seen: Int)?
    private var resolution: Resolution?
    /// The first strategy ever selected. A topology change re-probes, but a
    /// different answer then blocks control instead of switching.
    private var selectedSource: ModeSource?

    public init(smc: SMCKeyReading, model: MacModel?, platform: SMCPlatform? = nil, topologyConfirmations: Int = 2) {
        self.smc = smc; self.model = model; self.platform = platform; confirmations = max(1, topologyConfirmations)
    }

    public func read() throws -> FanInventory {
        lock.lock(); defer { lock.unlock() }
        let count = try confirmedCount()
        guard count > 0 else { return FanInventory(fans: [], control: .unavailable(.noFans)) }
        let resolution = try resolve(count)
        var mask: UInt16?
        if resolution.source == .mask { mask = try SMCDecoder.uint16(smc.read(FanModeScheme.legacyMask.key(fan: 0))) }
        let fans = try (0..<count).map { try readFan($0, source: resolution.source, mask: mask) }
        let control = status(resolution)
        let gate: Bool?
        if control.usesFtst {
            gate = try FtstGate.value(smc.read(FtstGate.key)) == 1
        } else { gate = nil }
        return FanInventory(fans: fans, control: control, aggregateGate: gate)
    }

    // MARK: Count

    /// FNum as a validated ui8 in 0...10. A missing FNum means no fans only
    /// when fan 0 has no speed register either.
    func fanCount() throws -> Int {
        do {
            let count = try SMCDecoder.uint8(smc.read("FNum"))
            guard Int(count) <= Self.maximumFans else { throw FanInventoryError.invalidRegister("FNum", "\(count) fans") }
            return Int(count)
        } catch SMCAccessError.notFound {
            do {
                _ = try smc.read("F0Ac")
                throw FanInventoryError.invalidRegister("FNum", "missing while F0Ac exists")
            } catch SMCAccessError.notFound {
                return 0
            }
        }
    }

    private func confirmedCount() throws -> Int {
        let count = try fanCount()
        if let accepted = acceptedCount, accepted != count {
            let seen = pendingCount?.count == count ? pendingCount!.seen + 1 : 1
            pendingCount = (count, seen)
            guard seen >= confirmations else { throw FanInventoryError.topologyUnconfirmed(previous: accepted, reported: count) }
        }
        if acceptedCount != count { resolution = nil }
        acceptedCount = count; pendingCount = nil
        return count
    }

    // MARK: Mode registers

    private enum Presence { case present, absent, invalid(String) }

    private func presence(_ key: String, _ decode: (SMCValue) throws -> Void) throws -> Presence {
        do { try decode(smc.read(key)); return .present }
        catch SMCAccessError.notFound { return .absent }
        catch SMCAccessError.invalidData(_, let reason) { return .invalid("\(key): \(reason)") }
    }

    private func resolve(_ count: Int) throws -> Resolution {
        if let resolution, resolution.count == count { return resolution }
        var source = try modeSource(count)
        switch (selectedSource, source) {
        case (nil, .perFan), (nil, .mask): selectedSource = source
        case let (previous?, current) where previous != current:
            source = .inconsistent("strategy changed from \(Self.name(previous)) to \(Self.name(current))")
        default: break
        }
        var ftstIssue: String?
        if model?.requiresFtst == true {
            switch try presence(FtstGate.key, { _ = try FtstGate.value($0) }) {
            case .present: break
            case .absent: ftstIssue = "Ftst missing"
            case .invalid(let reason): ftstIssue = reason
            }
        }
        var targetIssue: String?
        for fan in 0..<count where targetIssue == nil {
            switch try presence("F\(fan)Tg", { _ = try SMCDecoder.fanSpeed($0) }) {
            case .present: break
            case .absent: targetIssue = "F\(fan)Tg missing"
            case .invalid(let reason): targetIssue = reason
            }
        }
        let resolved = Resolution(count: count, source: source, targetIssue: targetIssue, ftstIssue: ftstIssue)
        resolution = resolved
        return resolved
    }

    private static func name(_ source: ModeSource) -> String {
        switch source {
        case .perFan(let scheme): return scheme.key(fan: 0)
        case .mask: return "FS!"
        case .none: return "none"
        case .inconsistent, .invalid: return "invalid"
        }
    }

    /// Intel (REA-confirmed): a valid FS! aggregate wins even when per-fan
    /// keys also exist; per-fan keys are used only without it. Elsewhere,
    /// per-fan keys first, the model's own spelling (`F<n>md`) probed first.
    private func modeSource(_ count: Int) throws -> ModeSource {
        if platform == .intel {
            switch try presence(FanModeScheme.legacyMask.key(fan: 0), { _ = try SMCDecoder.uint16($0) }) {
            case .present: return .mask
            case .absent, .invalid: break
            }
        }
        let spellings: [FanModeScheme] = model?.requiresLowercaseMode == true ? [.lowercase, .uppercase] : [.uppercase, .lowercase]
        for spelling in spellings {
            let found = try (0..<count).map { try presence(spelling.key(fan: $0), { _ = try SMCDecoder.uint8($0) }) }
            if case .invalid(let reason)? = found.first(where: { if case .invalid = $0 { return true }; return false }) { return .invalid(reason) }
            let present = found.filter { if case .present = $0 { return true }; return false }.count
            if present == count { return .perFan(spelling) }
            if present > 0 { return .inconsistent("\(spelling.key(fan: 0).dropFirst(2)) on \(present) of \(count) fans") }
        }
        switch try presence(FanModeScheme.legacyMask.key(fan: 0), { _ = try SMCDecoder.uint16($0) }) {
        case .present: return .mask
        case .absent: return .none
        case .invalid(let reason): return .invalid(reason)
        }
    }

    private func status(_ resolution: Resolution) -> FanControlStatus {
        let ftst = model?.requiresFtst == true
        switch resolution.source {
        case .perFan(let scheme):
            if model?.requiresLowercaseMode == true && scheme != .lowercase { return .unavailable(.missingModeKey, "F0md") }
            if let issue = resolution.targetIssue { return .unavailable(.invalidTargetRegister, issue) }
            if let issue = resolution.ftstIssue { return .unavailable(.requiresFtst, issue) }
            return .supported(scheme, ftst: ftst)
        case .mask:
            if let issue = resolution.targetIssue { return .unavailable(.invalidTargetRegister, issue) }
            // The Ftst gate is an Apple Silicon per-fan-mode step; it is never combined with FS!.
            if ftst { return .unavailable(.requiresFtst, "FS! with an Ftst model") }
            return .supported(.legacyMask)
        case .none: return .unavailable(.missingModeKey, "no F0Md, F0md or FS!")
        case .inconsistent(let detail): return .unavailable(.inconsistentModeKeys, detail)
        case .invalid(let detail): return .unavailable(.invalidModeRegister, detail)
        }
    }

    // MARK: Fans

    private func speed(_ key: String) throws -> Double { try SMCDecoder.fanSpeed(smc.read(key)) }

    private func readFan(_ index: Int, source: ModeSource, mask: UInt16?) throws -> FanReading {
        let current = try speed("F\(index)Ac"), minimum = try speed("F\(index)Mn"), maximum = try speed("F\(index)Mx")
        let mode: FanModeState
        switch source {
        case .perFan(let scheme):
            switch try SMCDecoder.uint8(smc.read(scheme.key(fan: index))) {
            case 0, 3: mode = .automatic
            case 1: mode = .manual
            default: mode = .unknown
            }
        case .mask: mode = FanModeMask.isManual(mask ?? 0, fan: index) ? .manual : .automatic
        // With no mode register at all, firmware control is the only mode.
        case .none: mode = .automatic
        case .inconsistent, .invalid: mode = .unknown
        }
        var target: Double?
        if mode == .manual { target = try speed("F\(index)Tg") }
        let reading = FanReading(index: index, currentRPM: current, minimumRPM: minimum, maximumRPM: maximum, targetRPM: target, mode: mode)
        guard reading.isValid else {
            throw FanInventoryError.invalidRegister("F\(index)", "Ac \(current), Mn \(minimum), Mx \(maximum)\(target.map { ", Tg \($0)" } ?? "")")
        }
        return reading
    }
}

/// The legacy Intel `FS! ` register: bit n forces fan n to manual. Other
/// bits belong to other fans (or are reserved) and are always preserved.
public enum FanModeMask {
    public static func isManual(_ mask: UInt16, fan: Int) -> Bool {
        guard (0..<16).contains(fan) else { return false }
        return mask & (1 << UInt16(fan)) != 0
    }
    public static func updating(_ mask: UInt16, fan: Int, manual: Bool) -> UInt16 {
        precondition((0..<FanInventoryReader.maximumFans).contains(fan))
        let bit: UInt16 = 1 << UInt16(fan)
        return manual ? mask | bit : mask & ~bit
    }
}
