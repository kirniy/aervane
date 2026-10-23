import Foundation

/// The app's fan-command state, shared by `AppModel` and its tests. It owns
/// the serial command queue and gives every command an identity and an
/// origin, holds Smart's session, suspends Smart across sleep, versions
/// telemetry so a read begun before a mode change cannot drive Smart, and
/// keeps an honest notice of why Smart stopped and whether Auto is
/// confirmed. Pure and deterministic: AppModel feeds it events and sends the
/// tickets it returns. It never touches hardware, timers or defaults.
///
/// Precedence, in one place:
/// - A user speed or Auto ends Smart at once. Smart only ever sends with an
///   idle queue, so it can neither overtake nor replace a queued user command.
/// - A reply is matched to its ticket by identity. Replies for an older Smart
///   session (`epoch`) never count as the current session's, and only a
///   user's speed, applied while Smart is off, starts Return to Auto.
/// - Faults stop Smart and keep it off until the user turns it on again.
public struct FanCommandCoordinator: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// Slider, preset, Manual, Auto or Settings.
        case user
        /// Smart, in the session with this epoch.
        case smart(epoch: UInt64)
        /// Sleep, quit, Return to Auto or a sensor failure in manual control.
        case system
        /// Auto requested because Smart stopped.
        case smartStop
    }
    public struct Ticket: Equatable, Sendable {
        public let id: UInt64
        public let command: ControlRequestQueue.Command
        public fileprivate(set) var origin: Origin
    }
    public enum Outcome: Equatable, Sendable {
        /// The helper applied the command; `automatic` is the readback mode.
        case applied(automatic: Bool)
        case failed(String)
        /// The helper no longer holds a lease for this app.
        case notOwner
    }
    public struct Completion: Equatable, Sendable {
        public let ticket: Ticket
        /// Start (true) or cancel the manual Return to Auto timer after a set.
        public let startReturnTimer: Bool
        /// The next command to send, if any.
        public let next: Ticket?
    }
    /// Whether the fan is known to be back on firmware Auto after Smart stopped.
    public enum Restore: Equatable, Sendable {
        /// An Auto command is queued or in flight.
        case pending
        /// No command needed or possible; waiting for a readback to show Auto.
        case unconfirmed
        case verified
        case failed(String)
        /// From an earlier launch.
        case unknown
    }
    public struct Notice: Equatable, Sendable {
        public let reason: SmartStopReason
        public fileprivate(set) var restore: Restore
        public var message: String? {
            guard let explanation = reason.explanation else { return nil }
            switch restore {
            case .pending: return explanation + " Returning the fan to Auto…"
            case .unconfirmed: return explanation + " Waiting to confirm the fan is on Auto."
            case .verified: return explanation + " The fan is on Auto."
            case .failed(let message): return explanation + " Could not return the fan to Auto: " + message
            case .unknown: return explanation
            }
        }
    }

    public private(set) var queue = ControlRequestQueue()
    public private(set) var inFlight: Ticket?
    public private(set) var queued: Ticket?
    public private(set) var smart: SmartCoolingSession
    /// Asleep (or about to be): Smart sends nothing.
    public private(set) var suspended = false
    /// Telemetry begun under an older generation must not drive Smart.
    public private(set) var sampleGeneration: UInt64 = 0
    public private(set) var notice: Notice?
    private var nextID: UInt64 = 0

    public init(smartEnabled: Bool = false, previousStop: SmartStopReason? = nil, targetCelsius: Double? = nil, policy: SmartCoolingPolicy = .standard) {
        smart = SmartCoolingSession(enabled: smartEnabled, policy: policy.with(target: targetCelsius ?? policy.targetCelsius))
        if let previousStop, previousStop.isFault, !smartEnabled { notice = Notice(reason: previousStop, restore: .unknown) }
    }

    public var isBusy: Bool { queue.isBusy }
    public var pendingPercent: Double? { queue.pendingPercent }
    public var smartEnabled: Bool { smart.enabled }
    /// Smart is on and allowed to act now.
    public var smartActive: Bool { smart.enabled && !suspended }
    /// The temperature Smart works to stay under (kept while Smart is off).
    public var smartTarget: Double { smart.targetCelsius }
    /// Smart is at full speed and the temperature is still over its target.
    public var smartSaturated: Bool { smart.enabled && smart.lastStep?.saturated == true }

    // MARK: User intent

    /// A speed the user chose. Ends Smart first; the speed is queued behind
    /// anything in flight and replaces anything queued.
    public mutating func userSet(_ percent: Double) -> Ticket? {
        smart.stop(.manual); notice = nil
        return submit(.set(percent), .user)
    }
    /// The user chose Auto. Ends Smart; sends Auto when Aervane owns the fan
    /// or a command in flight may be about to take it.
    public mutating func userAutomatic(owns: Bool) -> Ticket? {
        smart.stop(.automatic); notice = nil
        guard owns || isBusy else { return nil }
        return submit(.automatic, .user)
    }
    /// Turns Smart on, starting from the fan's present speed so a fast fan
    /// eases down instead of dropping. `applied` means Aervane already owns
    /// the fan at `seed`.
    public mutating func enableSmart(seed: Double?, applied: Bool) {
        guard !smart.enabled else { return }
        smart.enable(seed: seed, applied: applied); notice = nil
        sampleGeneration &+= 1
    }
    /// A new target. It never turns Smart on. While Smart is on, the next
    /// reading applies it: a lower target raises the speed at once, a higher
    /// one hands the speed down in steps. Commands already in flight keep
    /// their identity and epoch; nothing about them changes.
    public mutating func setSmartTarget(_ celsius: Double) { smart.setTarget(celsius) }
    /// The user took hold of the slider (or its keys). Smart ends at once,
    /// with no command: the fan stays where it is until the user's own speed
    /// is committed, so Smart can never fight the drag.
    public mutating func userBeganAdjusting() {
        guard smart.stop(.manual) else { return }
        notice = nil; sampleGeneration &+= 1
    }
    /// Ends Smart for `reason`; returns an Auto command when one is needed.
    public mutating func stopSmart(_ reason: SmartStopReason, owns: Bool) -> Ticket? {
        guard smart.stop(reason) else { return nil }
        sampleGeneration &+= 1
        let restoring = reason.restoresAutomatic && (owns || isBusy)
        let ticket = restoring ? submit(.automatic, .smartStop) : nil
        notice = reason.isFault ? Notice(reason: reason, restore: restoring ? .pending : .unconfirmed) : nil
        return ticket
    }
    public mutating func dismissNotice() { notice = nil }

    // MARK: System events

    /// Auto for sleep, quit, Return to Auto or a manual sensor failure.
    public mutating func systemRestore(owns: Bool) -> Ticket? {
        guard owns || isBusy else { return nil }
        return submit(.automatic, .system)
    }
    /// The Mac is going to sleep. Smart stays on but sends nothing, forgets
    /// its history, and any reading already under way is void. Auto follows
    /// anything in flight, which may be about to take the fan.
    public mutating func sleep(owns: Bool) -> Ticket? {
        suspended = true; sampleGeneration &+= 1; smart.suspend()
        return systemRestore(owns: owns)
    }
    /// Awake: Smart resumes only from readings begun after this point.
    public mutating func wake() { suspended = false; sampleGeneration &+= 1 }
    /// The helper connection was replaced or lost: replies to anything sent
    /// on it will be ignored. Returns whether Auto had been requested.
    @discardableResult public mutating func resetConnection() -> Bool {
        let wantedAuto = queue.reset(); inFlight = nil; queued = nil
        smart.suspend(); sampleGeneration &+= 1
        return wantedAuto
    }
    /// A readback showed the fan's mode. Auto confirms a pending restore once
    /// nothing is in flight.
    public mutating func observe(automatic: Bool) {
        guard automatic, !isBusy, var current = notice else { return }
        switch current.restore {
        case .pending, .unconfirmed: current.restore = .verified; notice = current
        default: break
        }
    }

    // MARK: Smart

    /// One fresh reading from a poll begun under `generation`. Returns Smart's
    /// command, if any. Smart sends only with an idle queue and a ready
    /// helper; `current` is the fan's present speed for a fresh session.
    public mutating func sample(_ reading: SmartCoolingReading, generation: UInt64, at time: TimeInterval, floor: Double,
                                ready: Bool, current: Double?) -> Ticket? {
        guard generation == sampleGeneration, smartActive else { return nil }
        guard let percent = smart.evaluate(reading, at: time, floor: floor, canCommand: ready && !isBusy, current: current) else { return nil }
        return submit(.set(percent), .smart(epoch: smart.epoch))
    }

    // MARK: Replies

    /// A reply arrived for ticket `id`. Nil when it is not the command in
    /// flight (a late reply from a replaced connection).
    public mutating func complete(id: UInt64, outcome: Outcome) -> Completion? {
        guard let done = inFlight, done.id == id else { return nil }
        _ = queue.finish()
        inFlight = queue.inFlight == nil ? nil : queued
        queued = nil
        var next = inFlight
        var startTimer = false
        switch (done.command, outcome) {
        case (.set, .applied(let automatic)):
            startTimer = !automatic && done.origin == .user && !smart.enabled
        case (.set, _):
            // Smart's own failed write stops it; Auto follows (the helper has
            // already rolled the write back), never another automated try.
            if case .smart(let epoch) = done.origin, smart.enabled, epoch == smart.epoch {
                smart.stop(.writeFailed); sampleGeneration &+= 1
                if next == nil { next = submit(.automatic, .smartStop) }
                else if next?.command == .automatic { inFlight?.origin = .smartStop; next = inFlight }
                notice = Notice(reason: .writeFailed, restore: next?.command == .automatic ? .pending : .unconfirmed)
            }
        case (.automatic, let result) where done.origin == .smartStop:
            if var current = notice {
                switch result {
                case .applied(let automatic): current.restore = automatic ? .verified : .unconfirmed
                case .failed(let message): current.restore = .failed(message)
                case .notOwner: current.restore = .unconfirmed
                }
                notice = current
            }
        case (.automatic, _):
            break
        }
        return Completion(ticket: done, startReturnTimer: startTimer, next: next)
    }

    /// Queues a command. Returns the ticket to send now, if any.
    private mutating func submit(_ command: ControlRequestQueue.Command, _ origin: Origin) -> Ticket? {
        nextID &+= 1
        let ticket = Ticket(id: nextID, command: command, origin: origin)
        if queue.submit(command) != nil { inFlight = ticket; queued = nil; return ticket }
        if queue.queued == command { queued = ticket }
        else {
            // The same as the command in flight: the newest intent adopts it.
            queued = nil; inFlight?.origin = origin
        }
        return nil
    }
}
