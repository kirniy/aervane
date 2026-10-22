import Foundation

/// One pass over a fan's control registers (F<n>Md, Tg, Ac, Mn, Mx).
public struct FanRegisters: Sendable, Equatable {
    /// Raw mode byte. Observed on M4: 0 or 3 automatic, 1 manual.
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

/// Single-key hardware access. Implementations perform exactly one SMC
/// operation per call; ordering and verification belong to the transaction.
public protocol FanRegisterAccess: AnyObject {
    func readRegisters() throws -> FanRegisters
    func writeTarget(rpm: Double) throws
    func writeMode(_ mode: UInt8) throws
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

    /// Mode first, then target; passive readback only. No unlock key (Ftst
    /// is absent on Mac16,10) and no re-assertion without evidence for it.
    public static let standard = FanWritePlan(order: .modeThenTarget, settle: 1.5, pollInterval: 0.1, reassertions: 0, restoreAttempts: 2)

    /// Upper bound for one manual write, excluding individual SMC call time.
    public var worstCaseWrite: TimeInterval { Double(reassertions + 1) * (settle + pollInterval) }
    /// Upper bound for one automatic restore.
    public var worstCaseRestore: TimeInterval { Double(restoreAttempts) * (settle + pollInterval) }
}

/// A compact, bounded record of what the transaction did and saw. It is
/// carried in error messages so a failed hardware run is diagnosable.
public struct FanWriteTrace: Sendable, CustomStringConvertible {
    private let start: Date
    public private(set) var events: [String] = []
    public private(set) var last: FanRegisters?
    private var omitted = 0
    private static let limit = 16

    init(start: Date) { self.start = start }

    mutating func note(_ text: String, at time: Date) {
        if events.count < Self.limit { events.append("+\(Int((time.timeIntervalSince(start) * 1000).rounded()))ms \(text)") }
        else { omitted += 1 }
    }
    mutating func observe(_ registers: FanRegisters, at time: Date) {
        // Record transitions, not every identical poll.
        if registers.mode != last?.mode || abs(registers.targetRPM - (last?.targetRPM ?? -1)) > FanWriteTransaction.rpmTolerance {
            note("read mode \(registers.mode) Tg \(Self.rpm(registers.targetRPM)) Ac \(Self.rpm(registers.actualRPM))", at: time)
        }
        last = registers
    }
    public var description: String { (events + (omitted > 0 ? ["… \(omitted) more"] : [])).joined(separator: "; ") }
    static func rpm(_ value: Double) -> String { value.isFinite ? String(Int(value.rounded())) : "invalid" }
}

public struct FanWriteTransaction {
    /// Float and fpe2 encodings are exact to well under one RPM.
    public static let rpmTolerance = 1.0

    private let fan: FanRegisterAccess
    private let plan: FanWritePlan
    private let clock: () -> Date
    private let sleep: (TimeInterval) -> Void

    public init(fan: FanRegisterAccess, plan: FanWritePlan = .standard, clock: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.fan = fan; self.plan = plan; self.clock = clock; self.sleep = sleep
    }

    /// Physical target for a percentage of maximum, clamped to the firmware floor.
    public static func targetRPM(percent: Double, minimum: Double, maximum: Double) throws -> Double {
        guard percent.isFinite, (0...100).contains(percent), minimum.isFinite, maximum.isFinite,
              minimum >= 0, maximum > 0, minimum <= maximum else { throw FanControlError.invalidPercent }
        return max(minimum, min(maximum, maximum * percent / 100))
    }

    /// Writes manual control and returns only after readback shows manual
    /// mode at the commanded target. Throws with the trace on any failed
    /// step or readback. Rollback is the caller's: FanRecoveryController
    /// restores Auto after every failure once a write was attempted, so a
    /// mode accepted before a rejected target never stays manual.
    @discardableResult
    public func apply(percent: Double) throws -> FanWriteTrace {
        var trace = FanWriteTrace(start: clock())
        let before = try read(&trace)
        guard [0, 1, 3].contains(before.mode) else { throw failure("Fan mode \(before.mode) is not supported.", trace) }
        let target = try Self.targetRPM(percent: percent, minimum: before.minimumRPM, maximum: before.maximumRPM)
        for attempt in 0...plan.reassertions {
            if attempt > 0 { trace.note("re-assert \(attempt)/\(plan.reassertions)", at: clock()) }
            let steps: [Step] = plan.order == .targetThenMode ? [.target(target), .mode(1)] : [.mode(1), .target(target)]
            for step in steps { try write(step, &trace) }
            if try settle(&trace, until: { $0.mode == 1 && abs($0.targetRPM - target) <= Self.rpmTolerance }) { return trace }
        }
        let last = trace.last
        let observed = last.map { "mode \($0.mode), target \(FanWriteTrace.rpm($0.targetRPM)) RPM, actual \(FanWriteTrace.rpm($0.actualRPM)) RPM" } ?? "no readback"
        throw failure("Fan target did not verify after setting: expected manual mode 1 at \(FanWriteTrace.rpm(target)) RPM, read \(observed).", trace)
    }

    /// Writes automatic mode and waits for readback to show firmware control.
    @discardableResult
    public func restoreAutomatic() throws -> FanWriteTrace {
        var trace = FanWriteTrace(start: clock())
        for attempt in 1...plan.restoreAttempts {
            if attempt > 1 { trace.note("restore retry \(attempt)/\(plan.restoreAttempts)", at: clock()) }
            do { try write(.mode(0), &trace) } catch where attempt < plan.restoreAttempts { continue }
            if try settle(&trace, until: { $0.automatic }) { return trace }
        }
        throw failure("Automatic mode did not verify after restore.", trace)
    }

    private enum Step { case target(Double), mode(UInt8) }

    private func write(_ step: Step, _ trace: inout FanWriteTrace) throws {
        let label: String
        do {
            switch step {
            case .target(let rpm): label = "Tg←\(FanWriteTrace.rpm(rpm))"; try fan.writeTarget(rpm: rpm)
            case .mode(let mode): label = "Md←\(mode)"; try fan.writeMode(mode)
            }
        } catch {
            let name: String
            switch step { case .target: name = "Tg"; case .mode: name = "Md" }
            trace.note("\(name) write failed: \(error.localizedDescription)", at: clock())
            throw failure("Fan \(name) write was rejected.", trace)
        }
        trace.note("\(label) ok", at: clock())
    }

    private func read(_ trace: inout FanWriteTrace) throws -> FanRegisters {
        do {
            let registers = try fan.readRegisters()
            trace.observe(registers, at: clock())
            return registers
        } catch {
            trace.note("read failed: \(error.localizedDescription)", at: clock())
            throw failure("Fan readback failed.", trace)
        }
    }

    /// Polls readback without writing until `done` or the settle deadline.
    private func settle(_ trace: inout FanWriteTrace, until done: (FanRegisters) -> Bool) throws -> Bool {
        let deadline = clock().addingTimeInterval(plan.settle)
        while true {
            if done(try read(&trace)) { return true }
            if clock() >= deadline { return false }
            sleep(plan.pollInterval)
        }
    }

    private func failure(_ message: String, _ trace: FanWriteTrace) -> FanControlError {
        .hardwareFailure("\(message) [\(trace)]")
    }
}
