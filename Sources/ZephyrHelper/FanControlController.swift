import Foundation
import ZephyrCore

protocol FanRawTargetReader {
    /// Fan 0's raw F0Tg as a percentage of its maximum, in any mode.
    func rawTargetPercent() throws -> Double
    /// Every fan's raw target, keyed by fan index. Automatic mode hides the
    /// firmware's target from snapshots; the journal records it before the
    /// first write so a restart mid-transaction can still attribute it.
    func rawTargetPercents() throws -> [Int: Double]
}

extension FanRawTargetReader {
    func rawTargetPercents() throws -> [Int: Double] { [0: try rawTargetPercent()] }
}

/// The helper's serial state: the recovery policy, the crash journal and
/// the watchdog timer. Hardware access goes through `FanRecoveryDriver`.
final class FanControlController {
    static let shared = FanControlController()

    private let policy: FanRecoveryController
    private let journalURL: URL
    private let requireRootJournal: Bool
    private let retryInterval: TimeInterval
    private let queue = DispatchQueue(label: "dev.kirniy.zephyr.helper.state")
    private var timer: DispatchSourceTimer?
    private var journalPending = false

    init(driver: FanRecoveryDriver? = nil, now: @escaping () -> Date = Date.init,
         journalURL: URL = LeaseJournal.defaultURL, requireRootJournal: Bool = true,
         retryInterval: TimeInterval = FanSafety.heartbeatInterval) {
        self.journalURL = journalURL
        self.requireRootJournal = requireRootJournal
        self.retryInterval = retryInterval
        policy = FanRecoveryController(driver: driver ?? SMCRecoveryDriver(), now: now)
        queue.sync { recoverJournal(); armRetryTimerIfNeeded() }
    }

    deinit { timer?.cancel() }

    static func initialize() { _ = shared }

    func disconnected(_ session: UUID) {
        queue.async { [weak self] in
            guard let self, self.policy.state.owns(session) else { return }
            self.policy.disconnect(session)
            self.removeJournalIfAutomatic()
            self.armRetryTimerIfNeeded()
        }
    }

    func snapshot(_ reply: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(nil, FanControlError.unavailable); return }
            do { reply(try JSONEncoder().encode(self.policy.driver.snapshot()), nil) }
            catch { reply(nil, error) }
        }
    }

    func set(percent: Double, session: UUID, reply: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(nil, FanControlError.unavailable); return }
            do {
                guard !self.journalPending else { throw FanControlError.unavailable }
                let requested = try FanSafety.validate(percent: percent)
                var record: LeaseJournal?
                let snapshot = try self.policy.set(percent: percent, session: session) { before in
                    // Journal every participating fan before the first write.
                    let journal = LeaseJournal(sessionID: session, requestedPercent: requested, phase: .beforeWrite,
                                               processID: getpid(), fans: before.fans,
                                               previousTargets: try self.previousTargets(before.fans),
                                               aggregateGate: before.aggregateGate)
                    try journal.write(to: self.journalURL, requireRootOwner: self.requireRootJournal)
                    record = journal
                }
                // The write and readback succeeded; retain the journal as an
                // after-write record until automatic mode is confirmed.
                if let record {
                    try? LeaseJournal(sessionID: record.sessionID, previousTargetPercent: record.previousTargetPercent,
                                      intendedPercent: record.intendedPercent, phase: .afterWrite, processID: record.processID,
                                      schemaVersion: record.schemaVersion, fans: record.fans,
                                      aggregateGate: record.aggregateGate)
                        .write(to: self.journalURL, requireRootOwner: self.requireRootJournal)
                }
                self.armRetryTimerIfNeeded()
                reply(try JSONEncoder().encode(snapshot), nil)
            } catch {
                if self.policy.state.owner == nil,
                   let journal = try? LeaseJournal.read(from: self.journalURL, requireRootOwner: self.requireRootJournal), journal.sessionID == session {
                    try? LeaseJournal.remove(at: self.journalURL, requireRootOwner: self.requireRootJournal)
                }
                self.armRetryTimerIfNeeded()
                reply(nil, error)
            }
        }
    }

    /// Manual fans report their target; automatic fans need the raw register.
    /// Any fan without a readable previous target blocks the write.
    private func previousTargets(_ fans: [FanReading]) throws -> [Int: Double] {
        var targets: [Int: Double] = [:]
        let hidden = fans.filter { $0.mode != .manual || $0.targetPercent == nil }
        if !hidden.isEmpty {
            guard let rawReader = policy.driver as? FanRawTargetReader else { throw FanControlError.unavailable }
            let raw = try rawReader.rawTargetPercents()
            for fan in hidden {
                guard let value = raw[fan.index], value.isFinite, (0...100).contains(value) else { throw FanControlError.unavailable }
                targets[fan.index] = value
            }
        }
        for fan in fans where targets[fan.index] == nil { targets[fan.index] = fan.targetPercent }
        return targets
    }

    func restore(session: UUID, reply: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(nil, FanControlError.unavailable); return }
            do {
                let snapshot = try self.policy.restore(session)
                try? LeaseJournal.remove(at: self.journalURL, requireRootOwner: self.requireRootJournal)
                self.stopRetryTimer()
                reply(try JSONEncoder().encode(snapshot), nil)
            } catch {
                self.armRetryTimerIfNeeded()
                reply(nil, error)
            }
        }
    }

    func heartbeat(session: UUID, reply: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.policy.state.owns(session), self.policy.state.manual,
                  !self.policy.state.restorePending else { reply(FanControlError.notOwner); return }
            self.policy.heartbeat(session)
            reply(nil)
        }
    }

    private func safetyTick() {
        if journalPending {
            recoverJournal()
            if journalPending { armRetryTimerIfNeeded(); return }
        }
        policy.tick()
        removeJournalIfAutomatic()
        armRetryTimerIfNeeded()
    }

    enum Attribution: Equatable {
        /// Every journaled fan still present is automatic or at a target
        /// this lease set (or held just before it), and at least one is manual.
        case owned
        /// A journaled fan is manual at a target this lease never set.
        case foreign
        /// Nothing manual is left that the record describes.
        case unattributed
    }

    /// Judges only fans present now: a fan that vanished cannot be restored,
    /// and its absence is not evidence about the others.
    static func attribution(_ records: [FanLeaseRecord], phase: LeaseJournalPhase, fans: [FanReading]) -> Attribution {
        attribution(records, phase: phase, fans: fans, aggregateGate: nil)
    }

    static func attribution(_ records: [FanLeaseRecord], phase: LeaseJournalPhase, fans: [FanReading], aggregateGate: Bool?) -> Attribution {
        let recorded = Set(records.map(\.index))
        // A fan outside the journal is safe only while it is known Auto. An
        // unknown or manual extra fan could belong to another controller.
        if fans.contains(where: { !recorded.contains($0.index) && $0.mode != .automatic }) { return .foreign }
        var owned = false
        for record in records {
            guard let fan = fans.first(where: { $0.index == record.index }), !fan.automatic else { continue }
            let intended = FanSafety.matchesRequestedPercent(fan.targetPercent, expected: max(record.intendedTargetPercent, fan.floorPercent))
            let previous = phase == .beforeWrite && (record.previousTargetPercent.map {
                FanSafety.matchesRequestedPercent(fan.targetPercent, expected: $0)
            } ?? false)
            guard intended || previous else { return .foreign }
            owned = true
        }
        if owned { return .owned }
        // A crash after all per-fan modes reached Auto can leave Ftst set.
        // The journal still identifies the fans whose transaction owned the
        // gate, so recover it and clear the gate with a fresh read.
        return aggregateGate == true && !records.isEmpty && records.allSatisfy { recorded.contains($0.index) } ? .owned : .unattributed
    }

    private func recoverJournal() {
        guard let journal = try? LeaseJournal.read(from: journalURL, requireRootOwner: requireRootJournal) else {
            // Never interpret malformed or untrusted data as hardware ownership.
            journalPending = FileManager.default.fileExists(atPath: journalURL.path)
            return
        }
        // A transient read failure is not a topology change: keep the record.
        guard let readback = try? policy.driver.fanSnapshot() else {
            journalPending = true
            return
        }
        if readback.automatic && readback.aggregateGate != true {
            try? LeaseJournal.remove(at: journalURL, requireRootOwner: requireRootJournal)
            journalPending = false
            return
        }
        // A schema 1 record on any topology but one fan, another controller's
        // target, or nothing left to attribute: relinquish the obsolete record
        // without altering any setting or later claiming a coincidence.
        guard let records = journal.records(currentFanCount: readback.fans.count),
              Self.attribution(records, phase: journal.phase, fans: readback.fans, aggregateGate: readback.aggregateGate) == .owned else {
            try? LeaseJournal.remove(at: journalURL, requireRootOwner: requireRootJournal)
            journalPending = false
            return
        }
        // Restore only fans attributed to this journal. Extra Auto fans are
        // harmless; extra manual/unknown fans were rejected above.
        let owned = records.map(\.index).filter { recordIndex in
            readback.fans.contains { fan in fan.index == recordIndex }
        }
        policy.recoverOwnedLease(journal.sessionID, fans: owned)
        journalPending = false
        policy.tick()
        removeJournalIfAutomatic()
    }

    private func removeJournalIfAutomatic() {
        guard policy.state.owner == nil, !journalPending else { return }
        try? LeaseJournal.remove(at: journalURL, requireRootOwner: requireRootJournal)
    }

    private func armRetryTimerIfNeeded() {
        guard journalPending || (policy.state.owner != nil && (policy.state.manual || policy.state.restorePending)) else {
            stopRetryTimer()
            return
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval)
        timer.setEventHandler { [weak self] in self?.safetyTick() }
        timer.resume()
        self.timer = timer
    }

    private func stopRetryTimer() {
        timer?.cancel()
        timer = nil
    }
}
