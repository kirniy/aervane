import Foundation
import OSLog
import ZephyrCore

final class FanControlService: NSObject, FanControlXPCProtocol {
    private static let logger = Logger(subsystem: "dev.kirniy.aervane.helper", category: "fan-control")
    private let sessionID = UUID()
    private let controller = FanControlController.shared
    static func bootstrap() { FanControlController.initialize() }

    func clientDisconnected() { controller.disconnected(sessionID) }
    func start() {}
    func snapshot(withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.snapshot { data, error in reply(data, error.map(Self.xpcError)) }
    }
    func setFanPercent(_ percent: Double, withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.set(percent: percent, session: sessionID) { data, error in
            if let error {
                Self.logger.error("Fan set failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.info("Fan set succeeded")
            }
            reply(data, error.map(Self.xpcError))
        }
    }
    func restoreAutomatic(withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.restore(session: sessionID) { data, error in
            if let error {
                Self.logger.error("Automatic restore failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.info("Automatic restore succeeded")
            }
            reply(data, error.map(Self.xpcError))
        }
    }
    func heartbeat(withReply reply: @escaping (Error?) -> Void) {
        controller.heartbeat(session: sessionID) { error in reply(error.map(Self.xpcError)) }
    }

    static func xpcError(_ error: Error) -> NSError {
        if let error = error as? FanControlError {
            return NSError(domain: FanControlError.wireDomain, code: error.wireCode,
                           userInfo: [NSLocalizedDescriptionKey: error.errorDescription ?? "Fan control failed."])
        }
        let nsError = error as NSError
        return NSError(domain: nsError.domain, code: nsError.code,
                       userInfo: [NSLocalizedDescriptionKey: nsError.localizedDescription])
    }
}

protocol FanRawTargetReader {
    func rawTargetPercent() throws -> Double
}

private final class SMCRecoveryDriver: FanRecoveryDriver, FanRawTargetReader {
    private let hardware = SMCFanDriver()

    func snapshot() throws -> FanSnapshot {
        let reading = try hardware.snapshot()
        let temperature = try FanSafety.validateTemperature(hardware.hottestTemperature())
        return FanSnapshot(currentRPM: reading.currentRPM, minimumRPM: reading.minimumRPM,
                           maximumRPM: reading.maximumRPM, targetPercent: reading.targetPercent,
                           automatic: reading.automatic, temperatureCelsius: temperature, fanCount: reading.fanCount)
    }

    func fanSnapshot() throws -> FanReadback {
        let reading = try hardware.snapshot()
        return FanReadback(currentRPM: reading.currentRPM, minimumRPM: reading.minimumRPM,
                           maximumRPM: reading.maximumRPM, targetPercent: reading.targetPercent,
                           automatic: reading.automatic)
    }
    func rawTargetPercent() throws -> Double { try hardware.rawTargetPercent() }

    func set(percent: Double) throws { try hardware.set(percent: percent) }
    func restoreAutomatic() throws { try hardware.automatic() }
    func automatic() throws -> Bool { try fanSnapshot().automatic }
}

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
                var previousTarget: Double?
                let snapshot = try self.policy.set(percent: percent, session: session) { before in
                    // In Auto, FanSnapshot intentionally omits F0Tg. Read the
                    // raw firmware target before the mode-first transaction so
                    // a restart between mode and target writes can still be
                    // attributed to this lease.
                    if before.automatic {
                        guard let rawReader = self.policy.driver as? FanRawTargetReader else {
                            throw FanControlError.unavailable
                        }
                        previousTarget = try rawReader.rawTargetPercent()
                    } else {
                        previousTarget = before.targetPercent
                    }
                    try LeaseJournal(sessionID: session, previousTargetPercent: previousTarget,
                                     intendedPercent: try FanSafety.validate(percent: percent),
                                     phase: .beforeWrite, processID: getpid()).write(to: self.journalURL, requireRootOwner: self.requireRootJournal)
                }
                // The write and readback succeeded; retain the journal as an
                // after-write record until automatic mode is confirmed.
                try? LeaseJournal(sessionID: session, previousTargetPercent: previousTarget,
                                  intendedPercent: try FanSafety.validate(percent: percent),
                                  phase: .afterWrite, processID: getpid()).write(to: self.journalURL, requireRootOwner: self.requireRootJournal)
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

    private func recoverJournal() {
        guard let journal = try? LeaseJournal.read(from: journalURL, requireRootOwner: requireRootJournal) else {
            // Never interpret malformed or untrusted data as hardware ownership.
            journalPending = FileManager.default.fileExists(atPath: journalURL.path)
            return
        }
        guard let snapshot = try? policy.driver.fanSnapshot() else {
            journalPending = true
            return
        }
        if snapshot.automatic {
            try? LeaseJournal.remove(at: journalURL, requireRootOwner: requireRootJournal)
            journalPending = false
            return
        }
        let floor = max(0, min(100, snapshot.minimumRPM / snapshot.maximumRPM * 100))
        let intended = FanSafety.matchesRequestedPercent(snapshot.targetPercent, expected: max(journal.intendedPercent, floor))
        let previous = journal.phase == .beforeWrite && (journal.previousTargetPercent.map {
            FanSafety.matchesRequestedPercent(snapshot.targetPercent, expected: $0)
        } ?? false)
        guard intended || previous else {
            // Another controller changed the target. Relinquish our obsolete
            // record without altering its setting or later claiming a coincidence.
            try? LeaseJournal.remove(at: journalURL, requireRootOwner: requireRootJournal)
            journalPending = false
            return
        }
        policy.recoverOwnedLease(journal.sessionID)
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
