import Foundation

/// One pass over a fan's control registers (mode, Tg, Ac, Mn, Mx).
public struct FanRegisters: Sendable, Equatable {
    /// Raw mode byte. Observed on M4: 0 or 3 automatic, 1 manual. For the
    /// legacy FS! mask: 1 when the fan's bit is set, else 0.
    public let mode: UInt8
    public let targetRPM: Double
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public init(mode: UInt8, targetRPM: Double, actualRPM: Double, minimumRPM: Double, maximumRPM: Double) {
        self.mode = mode; self.targetRPM = targetRPM; self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM; self.maximumRPM = maximumRPM
    }
    public var automatic: Bool { mode == 0 || mode == 3 }
}

/// Single-key hardware access for one fan. Implementations perform exactly
/// one SMC operation per call; ordering and verification belong to the transaction.
public protocol FanRegisterAccess: AnyObject {
    func readRegisters() throws -> FanRegisters
    func writeTarget(rpm: Double) throws
    func writeMode(_ mode: UInt8) throws
}

/// Hardware access for every fan that takes part in a linked command.
public protocol FanBankAccess: AnyObject {
    /// Participating fan indices, ascending, 1...10 of them.
    var fanIndices: [Int] { get }
    /// The mode register's name in messages: "Md", "md" or "FS!".
    var modeKeyLabel: String { get }
    func readRegisters(fan: Int) throws -> FanRegisters
    func writeTarget(fan: Int, rpm: Double) throws
    /// 0 automatic or 1 manual, through the bank's mode scheme.
    func writeMode(fan: Int, _ mode: UInt8) throws
    /// Whether the scheme has an aggregate gate (Ftst) written after all
    /// per-fan mode writes and before any target write.
    var usesAggregateGate: Bool { get }
    /// Reads and validates the gate's exact type and length without writing.
    func preflightAggregateGate() throws
    /// 1 when any fan is manual, 0 when every fan is automatic.
    func writeAggregateGate(manual: Bool) throws
    func readAggregateGate() throws -> Bool?
}

public extension FanBankAccess {
    var usesAggregateGate: Bool { false }
    func preflightAggregateGate() throws {}
    func writeAggregateGate(manual: Bool) throws {}
    func readAggregateGate() throws -> Bool? { nil }
}

/// Adapts single-fan access (fan 0) to the bank interface.
final class SingleFanBank: FanBankAccess {
    let fan: FanRegisterAccess
    init(_ fan: FanRegisterAccess) { self.fan = fan }
    var fanIndices: [Int] { [0] }
    var modeKeyLabel: String { "Md" }
    func readRegisters(fan index: Int) throws -> FanRegisters { try fan.readRegisters() }
    func writeTarget(fan index: Int, rpm: Double) throws { try fan.writeTarget(rpm: rpm) }
    func writeMode(fan index: Int, _ mode: UInt8) throws { try fan.writeMode(mode) }
}

public enum FanWriteOrder: String, Sendable, CaseIterable {
    /// Stage F<n>Tg while Auto is active, then F<n>Md = 1. On Mac16,10 the
    /// staged target did not survive into manual mode (2026-10-23 field log).
    case targetThenMode
    /// F<n>Md = 1 first, then F<n>Tg. The order the established controller
    /// uses for constant targets (protocol observation, 2026-10-23).
    case modeThenTarget
}

/// The protocol a manual write follows. Change only from observed hardware
/// or protocol evidence; every field is bounded and covered by tests.
public struct FanWritePlan: Sendable, Equatable {
    public var order: FanWriteOrder
    /// How long readback may take to show the commanded state. Reads only.
    public var settle: TimeInterval
    public var pollInterval: TimeInterval
    /// Additional complete write sequences after a failed settle window.
    /// Zero until hardware evidence shows the firmware needs re-assertion.
    public var reassertions: Int
    /// Automatic-mode writes before reporting a failed restore. Restoring
    /// Auto is the fail-safe direction, so one repeat is always allowed.
    public var restoreAttempts: Int

    public init(order: FanWriteOrder, settle: TimeInterval, pollInterval: TimeInterval, reassertions: Int, restoreAttempts: Int) {
        self.order = order; self.settle = settle; self.pollInterval = pollInterval
        self.reassertions = max(0, min(5, reassertions)); self.restoreAttempts = max(1, min(5, restoreAttempts))
    }

    /// Modes first (every fan), then targets; passive readback only. No
    /// unlock key (Ftst is absent on Mac16,10) and no re-assertion without
    /// evidence for it.
    public static let standard = FanWritePlan(order: .modeThenTarget, settle: 1.5, pollInterval: 0.1, reassertions: 0, restoreAttempts: 2)

    /// Upper bound for one manual write, excluding individual SMC call time.
    /// All fans share each settle window, so the fan count does not multiply it.
    public var worstCaseWrite: TimeInterval { Double(reassertions + 1) * (settle + pollInterval) }
    /// Upper bound for one automatic restore.
    public var worstCaseRestore: TimeInterval { Double(restoreAttempts) * (settle + pollInterval) }
}

/// A compact, bounded record of what the transaction did and saw. It is
/// carried in error messages so a failed hardware run is diagnosable.
public struct FanWriteTrace: Sendable, CustomStringConvertible {
    private let start: Date
    private let labelsFans: Bool
    private let limit: Int
    public private(set) var events: [String] = []
    /// The most recent readback of any fan.
    public private(set) var last: FanRegisters?
    /// The most recent readback of each fan.
    public private(set) var lastByFan: [Int: FanRegisters] = [:]
    private var omitted = 0

    init(start: Date, fans: Int = 1) {
        self.start = start; labelsFans = fans > 1
        // Room for every write of a full multi-fan sequence plus transitions.
        limit = min(64, max(16, 6 * fans))
    }

    mutating func note(_ text: String, fan: Int? = nil, at time: Date) {
        let prefix = labelsFans ? fan.map { "F\($0) " } ?? "" : ""
        if events.count < limit { events.append("+\(Int((time.timeIntervalSince(start) * 1000).rounded()))ms \(prefix)\(text)") }
        else { omitted += 1 }
    }
    mutating func observe(_ registers: FanRegisters, fan: Int, at time: Date) {
        // Record transitions, not every identical poll.
        let previous = lastByFan[fan]
        if registers.mode != previous?.mode || abs(registers.targetRPM - (previous?.targetRPM ?? -1)) > FanWriteTransaction.rpmTolerance {
            note("read mode \(registers.mode) Tg \(Self.rpm(registers.targetRPM)) Ac \(Self.rpm(registers.actualRPM))", fan: fan, at: time)
        }
        last = registers; lastByFan[fan] = registers
    }
    /// A failed read makes any earlier readback of that fan stale: it must
    /// never count as verification later.
    mutating func invalidate(fan: Int) { lastByFan[fan] = nil }
    public var description: String { (events + (omitted > 0 ? ["… \(omitted) more"] : [])).joined(separator: "; ") }
    static func rpm(_ value: Double) -> String { value.isFinite ? String(Int(value.rounded())) : "invalid" }
}

/// A linked write across every participating fan: one percentage of each
/// fan's own maximum, clamped to each fan's real minimum.
///
/// Every fan is read and validated before the first write. Writes follow
/// the plan's order across all fans (all modes, then all targets), and one
/// shared settle window verifies all of them, so the time bound does not
/// grow with the fan count. Any failure throws with the trace; rollback is
/// the caller's (FanRecoveryController restores every fan to Auto once a
/// write was attempted).
public struct FanWriteTransaction {
    /// Float and fpe2 encodings are exact to well under one RPM.
    public static let rpmTolerance = 1.0

    private let bank: FanBankAccess
    private let plan: FanWritePlan
    private let clock: () -> Date
    private let sleep: (TimeInterval) -> Void

    public init(fan: FanRegisterAccess, plan: FanWritePlan = .standard, clock: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.init(bank: SingleFanBank(fan), plan: plan, clock: clock, sleep: sleep)
    }

    public init(bank: FanBankAccess, plan: FanWritePlan = .standard, clock: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.bank = bank; self.plan = plan; self.clock = clock; self.sleep = sleep
    }

    /// Physical target for a percentage of maximum, clamped to the firmware floor.
    public static func targetRPM(percent: Double, minimum: Double, maximum: Double) throws -> Double {
        guard percent.isFinite, (0...100).contains(percent), minimum.isFinite, maximum.isFinite,
              minimum >= 0, maximum > 0, minimum <= maximum else { throw FanControlError.invalidPercent }
        return max(minimum, min(maximum, maximum * percent / 100))
    }

    private var fans: [Int] { bank.fanIndices }
    private var multiple: Bool { fans.count > 1 }
    private func name(_ fan: Int) -> String { multiple ? "\(fan) " : "" }

    /// Writes manual control and returns only after readback shows every fan
    /// in manual mode at its commanded target.
    @discardableResult
    public func apply(percent: Double) throws -> FanWriteTrace {
        var trace = FanWriteTrace(start: clock(), fans: fans.count)
        try validateFans(trace)
        // Preflight: every fan readable, in a known mode, with valid limits.
        var targets: [Int: Double] = [:]
        for fan in fans {
            let before = try read(fan, &trace)
            guard [0, 1, 3].contains(before.mode) else { throw failure("Fan \(name(fan))mode \(before.mode) is not supported.", trace) }
            targets[fan] = try Self.targetRPM(percent: percent, minimum: before.minimumRPM, maximum: before.maximumRPM)
        }
        if bank.usesAggregateGate {
            do { try bank.preflightAggregateGate() } catch {
                trace.note("Ftst preflight failed: \(error.localizedDescription)", at: clock())
                throw failure("Fan control gate Ftst is not usable. Nothing was written.", trace)
            }
        }
        for attempt in 0...plan.reassertions {
            if attempt > 0 { trace.note("re-assert \(attempt)/\(plan.reassertions)", at: clock()) }
            // Per-fan modes in ascending order, then the aggregate gate, then targets.
            let modes = fans.map { Step.mode($0, 1) } + (bank.usesAggregateGate ? [Step.gate(true)] : [])
            let writes = fans.map { Step.target($0, targets[$0]!) }
            for step in plan.order == .targetThenMode ? writes + modes : modes + writes { try write(step, &trace) }
            if try settle(&trace, gate: true, until: { fan, registers in
                registers.mode == 1 && abs(registers.targetRPM - targets[fan]!) <= Self.rpmTolerance
            }) { return trace }
        }
        let observed = fans.compactMap { fan -> String? in
            let target = targets[fan]!
            if let last = trace.lastByFan[fan], last.mode == 1, abs(last.targetRPM - target) <= Self.rpmTolerance { return nil }
            let read = trace.lastByFan[fan].map { "mode \($0.mode), target \(FanWriteTrace.rpm($0.targetRPM)) RPM, actual \(FanWriteTrace.rpm($0.actualRPM)) RPM" } ?? "no readback"
            return "\(multiple ? "fan \(fan) " : "")expected manual mode 1 at \(FanWriteTrace.rpm(target)) RPM, read \(read)"
        }
        throw failure("Fan target did not verify after setting: \(observed.joined(separator: "; ")).", trace)
    }

    /// Writes automatic mode to every fan (then the aggregate gate, once every
    /// fan is commanded back) and waits for one fresh poll that shows
    /// firmware control on all of them. A rejected write or unreadable fan
    /// does not stop the others; failed fans are retried within
    /// `restoreAttempts`. Success needs that fresh poll: an earlier readback
    /// is never reused once a later read of the same fan failed.
    @discardableResult
    public func restoreAutomatic() throws -> FanWriteTrace {
        var trace = FanWriteTrace(start: clock(), fans: fans.count)
        try validateFans(trace)
        var pending = fans
        var gateCleared = !bank.usesAggregateGate
        for attempt in 1...plan.restoreAttempts {
            if attempt > 1 { trace.note("restore retry \(attempt)/\(plan.restoreAttempts)", at: clock()) }
            var accepted = 0
            for fan in pending {
                do { try write(.mode(fan, 0), &trace); accepted += 1 } catch { continue }
            }
            var progressed = accepted > 0
            if accepted == pending.count && !gateCleared {
                do {
                    try write(.gate(false), &trace)
                    // An acknowledged Ftst write is not verification. Keep
                    // retrying until a fresh read proves that the gate is 0.
                    gateCleared = (try bank.readAggregateGate()) == false
                    progressed = true
                } catch {}
            }
            // Nothing changed this attempt: retry the writes at once.
            if !progressed && attempt < plan.restoreAttempts { continue }
            if progressed, try settle(&trace, tolerateReadFailures: true, gate: false, until: { _, registers in registers.automatic }), gateCleared {
                return trace
            }
            pending = fans.filter { trace.lastByFan[$0]?.automatic != true }
        }
        var problems = pending.map { "fan \($0)" }
        if !gateCleared { problems.append("Ftst") }
        let names = multiple || !gateCleared ? " Not automatic: " + problems.joined(separator: ", ") + "." : ""
        throw failure("Automatic mode did not verify after restore.\(names)", trace)
    }

    private enum Step { case target(Int, Double), mode(Int, UInt8), gate(Bool) }

    private func validateFans(_ trace: FanWriteTrace) throws {
        guard !fans.isEmpty, fans.count <= FanInventoryReader.maximumFans, Set(fans).count == fans.count,
              fans.allSatisfy({ (0..<FanInventoryReader.maximumFans).contains($0) }) else {
            throw failure("No valid set of fans to control (\(fans)).", trace)
        }
    }

    private func write(_ step: Step, _ trace: inout FanWriteTrace) throws {
        let fan: Int?, label: String, key: String
        switch step {
        case let .target(index, rpm): fan = index; key = "Tg"; label = "Tg←\(FanWriteTrace.rpm(rpm))"
        case let .mode(index, mode): fan = index; key = bank.modeKeyLabel; label = "\(bank.modeKeyLabel)←\(mode)"
        case let .gate(manual): fan = nil; key = FtstGate.key; label = "Ftst←\(manual ? 1 : 0)"
        }
        do {
            switch step {
            case let .target(index, rpm): try bank.writeTarget(fan: index, rpm: rpm)
            case let .mode(index, mode): try bank.writeMode(fan: index, mode)
            case let .gate(manual): try bank.writeAggregateGate(manual: manual)
            }
        } catch {
            trace.note("\(key) write failed: \(error.localizedDescription)", fan: fan, at: clock())
            throw failure("Fan \(fan.map { name($0) } ?? "")\(key) write was rejected.", trace)
        }
        trace.note("\(label) ok", fan: fan, at: clock())
    }

    private func read(_ fan: Int, _ trace: inout FanWriteTrace) throws -> FanRegisters {
        do {
            let registers = try bank.readRegisters(fan: fan)
            trace.observe(registers, fan: fan, at: clock())
            return registers
        } catch {
            trace.note("read failed: \(error.localizedDescription)", fan: fan, at: clock())
            throw failure("Fan \(name(fan))readback failed.", trace)
        }
    }

    /// Polls every fan without writing until all satisfy `done` or the one
    /// shared settle deadline passes.
    private func settle(_ trace: inout FanWriteTrace, tolerateReadFailures: Bool = false, gate expectedGate: Bool? = nil,
                        until done: (Int, FanRegisters) -> Bool) throws -> Bool {
        let deadline = clock().addingTimeInterval(plan.settle)
        while true {
            var all = true
            if let expectedGate, bank.usesAggregateGate {
                do { all = try bank.readAggregateGate() == expectedGate && all }
                catch where tolerateReadFailures { all = false }
            }
            for fan in fans {
                do { if !done(fan, try read(fan, &trace)) { all = false } }
                catch where tolerateReadFailures { trace.invalidate(fan: fan); all = false }
            }
            if all { return true }
            if clock() >= deadline { return false }
            sleep(plan.pollInterval)
        }
    }

    private func failure(_ message: String, _ trace: FanWriteTrace) -> FanControlError {
        .hardwareFailure("\(message) [\(trace)]")
    }
}
