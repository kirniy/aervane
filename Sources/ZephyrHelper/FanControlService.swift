import Foundation
import ZephyrCore

final class FanControlService: NSObject, FanControlXPCProtocol {
    private let sessionID = UUID()
    private let controller = FanControlController.shared

    func clientDisconnected() { controller.disconnected(sessionID) }
    func start() {}
    func snapshot(withReply reply: @escaping (Data?, Error?) -> Void) { controller.snapshot(reply) }
    func setFanPercent(_ percent: Double, withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.set(percent: percent, session: sessionID, reply: reply)
    }
    func restoreAutomatic(withReply reply: @escaping (Data?, Error?) -> Void) {
        controller.restore(session: sessionID, reply: reply)
    }
    func heartbeat(withReply reply: @escaping (Error?) -> Void) {
        controller.heartbeat(session: sessionID, reply: reply)
    }
}

private final class FanControlController {
    static let shared = FanControlController()
    private let driver: FanHardwareDriver
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.kirniy.zephyr.helper.state")
    private var state = FanRecoveryState()
    private var lastHeartbeat: Date?
    private var timer: DispatchSourceTimer?

    init(driver: FanHardwareDriver = SMCFanDriver(), now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.now = now
    }

    func disconnected(_ session: UUID) {
        queue.async { [weak self] in
            guard let self, self.state.owns(session) else { return }
            self.state.requestRestore(session)
            self.lastHeartbeat = nil
            self.armRetryTimer()
            _ = self.attemptRestore(session)
        }
    }

    func snapshot(_ reply: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(nil, FanControlError.unavailable); return }
            do { reply(try JSONEncoder().encode(self.readSnapshot()), nil) }
            catch { reply(nil, error) }
        }
    }

    func set(percent: Double, session: UUID, reply: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(nil, FanControlError.unavailable); return }
            do {
                let requested = try FanSafety.validate(percent: percent)
                let wasOwner = self.state.owns(session)
                guard self.state.claim(session), !self.state.restorePending else {
                    throw FanControlError.unavailable
                }
                let before = try self.readSnapshot()
                guard !FanSafety.shouldRestoreAutomatic(snapshot: before, now: self.now(), lastHeartbeat: self.lastHeartbeat ?? self.now()) else {
                    if !wasOwner { self.state.restoreConfirmed(session) }
                    throw FanControlError.staleSensor
                }
                self.lastHeartbeat = self.now()
                do {
                    try self.driver.set(percent: requested)
                    let after = try self.readSnapshot()
                    guard !after.automatic,
                          FanSafety.matchesRequestedPercent(after.targetPercent, expected: requested) else {
                        throw FanControlError.hardwareFailure("Fan target did not verify after setting.")
                    }
                    self.state.didSetManual(session)
                    self.armRetryTimer()
                    reply(try JSONEncoder().encode(after), nil)
                } catch {
                    // A write may have succeeded before readback failed. Keep
                    // ownership and retry automatic restoration until verified.
                    self.state.requestRestore(session)
                    self.armRetryTimer()
                    _ = self.attemptRestore(session)
                    reply(nil, error)
                }
            } catch {
                if !self.state.manual && self.state.owns(session) { self.state.restoreConfirmed(session) }
                reply(nil, error)
            }
        }
    }

    func restore(session: UUID, reply: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.state.owns(session) else { reply(nil, FanControlError.unavailable); return }
            self.state.requestRestore(session)
            self.armRetryTimer()
            guard self.attemptRestore(session) else {
                reply(nil, FanControlError.hardwareFailure("Automatic mode did not verify after restore."))
                return
            }
            do { reply(try JSONEncoder().encode(self.readSnapshot()), nil) }
            catch { reply(nil, error) }
        }
    }

    func heartbeat(session: UUID, reply: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.state.owns(session), self.state.manual, !self.state.restorePending else {
                reply(nil)
                return
            }
            self.lastHeartbeat = self.now()
            reply(nil)
        }
    }

    @discardableResult
    private func attemptRestore(_ session: UUID) -> Bool {
        guard state.owns(session), state.restorePending else { return false }
        do {
            try driver.automatic()
            guard try driver.snapshot().automatic else { return false }
            state.restoreConfirmed(session)
            lastHeartbeat = nil
            stopRetryTimer()
            return true
        } catch { return false }
    }

    private func safetyTick() {
        guard let owner = state.owner, state.manual || state.restorePending else {
            stopRetryTimer()
            return
        }
        if state.restorePending {
            _ = attemptRestore(owner)
            return
        }
        guard let snapshot = try? readSnapshot() else {
            state.requestRestore(owner)
            _ = attemptRestore(owner)
            return
        }
        if FanSafety.shouldRestoreAutomatic(snapshot: snapshot, now: now(), lastHeartbeat: lastHeartbeat) {
            state.requestRestore(owner)
            _ = attemptRestore(owner)
        }
    }

    private func readSnapshot() throws -> FanSnapshot {
        let reading = try driver.snapshot()
        let temperature = try FanSafety.validateTemperature(driver.hottestTemperature())
        return FanSnapshot(currentRPM: reading.currentRPM, minimumRPM: reading.minimumRPM,
                           maximumRPM: reading.maximumRPM, targetPercent: reading.targetPercent,
                           automatic: reading.automatic, temperatureCelsius: temperature)
    }

    private func armRetryTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + FanSafety.heartbeatInterval,
                       repeating: FanSafety.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.safetyTick() }
        timer.resume()
        self.timer = timer
    }

    private func stopRetryTimer() {
        timer?.cancel()
        timer = nil
    }
}
