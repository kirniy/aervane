import Foundation

// Smart cooling: an opt-in, deterministic fan policy that works toward a
// temperature the user chooses.
//
// It is a plain function of the temperature samples it is given (and when
// they were taken, only to estimate how fast heat is rising): no learning,
// no randomness, no waiting periods. The policy only *suggests* speeds.
// Every suggestion still travels through the app's serial command queue and
// the authenticated helper, which keep their own validation, lease and
// rollback rules. See docs/smart-cooling.md.

/// The temperature Smart follows for one sample.
public struct SmartCoolingReading: Equatable, Sendable {
    /// Hottest CPU core, °C. Required: without it there is no reading.
    public var cpuHottest: Double?
    /// GPU, °C: the average of the GPU sensors mapped for this Mac (as the
    /// reader reports it), when there are any. Optional.
    public var gpu: Double?

    public init(cpuHottest: Double?, gpu: Double? = nil) { self.cpuHottest = cpuHottest; self.gpu = gpu }

    /// Plausible sensor range, matching the app's and helper's validation.
    public static let validRange: Range<Double> = -20..<130

    /// The hottest CPU core, or the GPU average when it is valid and hotter.
    /// Nil without a valid CPU reading; an absent or invalid GPU is ignored
    /// here (the controller bridges a GPU that drops out, see `gpuGrace`).
    public var celsius: Double? {
        guard let cpu = validCPU else { return nil }
        return max(cpu, validGPU ?? cpu)
    }
    public var validCPU: Double? { cpuHottest.flatMap { $0.isFinite && Self.validRange.contains($0) ? $0 : nil } }
    public var validGPU: Double? { gpu.flatMap { $0.isFinite && Self.validRange.contains($0) ? $0 : nil } }
}

/// Which measurement Smart used for a step. The panel shows exactly this
/// while Smart runs, so the figure, its tag and Smart's status agree.
public enum SmartTemperatureSource: String, Equatable, Sendable {
    /// The hottest CPU core.
    case cpuPeak
    /// The GPU average, hotter than every CPU core.
    case gpu
    /// The GPU's last valid average, still within `gpuGrace` after the
    /// sensor stopped reading, and hotter than every CPU core.
    case gpuHeld

    /// Compact tag beside the temperature.
    public var tag: String {
        switch self { case .cpuPeak: return "CPU PEAK"; case .gpu: return "GPU"; case .gpuHeld: return "GPU HELD" }
    }
    /// Spoken and tooltip description.
    public var detail: String {
        switch self {
        case .cpuPeak: return "Hottest CPU core, the temperature Smart regulates"
        case .gpu: return "GPU average, hotter than every CPU core; Smart regulates it"
        case .gpuHeld: return "Last GPU average, kept briefly while the GPU sensor is not reading"
        }
    }
}

/// The temperature Smart works to stay under, and how it is shown and kept.
public enum SmartTarget {
    public static let range: ClosedRange<Double> = 60...95
    public static let standard = 80.0
    /// A stored or typed value made safe: finite, within range, else standard.
    public static func clamp(_ celsius: Double?) -> Double {
        guard let celsius, celsius.isFinite else { return standard }
        return min(range.upperBound, max(range.lowerBound, celsius))
    }
    /// Whole degrees in the user's unit.
    public static func display(_ celsius: Double, fahrenheit: Bool) -> Int {
        Int((fahrenheit ? clamp(celsius) * 1.8 + 32 : clamp(celsius)).rounded())
    }
    /// The display range in the user's unit (60–95 °C is 140–203 °F).
    public static func displayRange(fahrenheit: Bool) -> ClosedRange<Int> {
        display(range.lowerBound, fahrenheit: fahrenheit)...display(range.upperBound, fahrenheit: fahrenheit)
    }
    /// A whole display value back to °C, clamped. Every display step maps to
    /// one stored value, so stepping in °F never jumps or sticks.
    public static func celsius(fromDisplay value: Double, fahrenheit: Bool) -> Double {
        guard value.isFinite else { return standard }
        let whole = value.rounded()
        return clamp(fahrenheit ? (whole - 32) / 1.8 : whole)
    }
}

/// Every number Smart uses. The curve is relative to the target, so the
/// target genuinely drives the speed: change it and the whole response moves.
public struct SmartCoolingPolicy: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        /// Degrees relative to the target (negative is below it).
        public let offset: Double
        public let percent: Double
        public init(_ offset: Double, _ percent: Double) { self.offset = offset; self.percent = percent }
    }

    /// The working temperature Smart regulates around, °C (`SmartTarget.range`).
    public var targetCelsius: Double
    /// Speed (% of maximum) by distance from the target: moderate cooling at
    /// the target itself, rising more steeply above it, full speed only a few
    /// degrees over it (or when a rising trend projects there).
    public var curve: [Point]
    /// Input smoothing against sensor noise, seconds. The weighting uses the
    /// elapsed time between samples; it is a short measurement filter, not a
    /// waiting period.
    public var smoothingTimeConstant: TimeInterval
    /// Smoothing of the temperature trend (°C/s), seconds.
    public var trendTimeConstant: TimeInterval
    /// A rising trend is projected this far ahead, seconds...
    public var lookahead: TimeInterval
    /// ...but never by more than this, °C. A falling trend is not projected.
    public var maximumAnticipation: Double
    /// Going down, the speed follows the curve as if it were this much
    /// warmer: the thermal deadband that stops the fan hunting, °C.
    public var hysteresis: Double
    /// A reading this far above the target, confirmed by the previous one
    /// being at least `confirmOvershoot` above it, is full speed at once —
    /// the curve's own value there, without waiting for the filter. A first
    /// reading needs no confirmation.
    public var immediateOvershoot: Double
    public var confirmOvershoot: Double
    /// Smallest change worth a fan command, percentage points. Reaching full
    /// speed or the hardware floor is always allowed.
    public var commandStep: Double
    /// A gap between samples longer than this (sleep, a stalled poll)
    /// discards the history and starts again from the current reading.
    public var resetGap: TimeInterval
    /// When a GPU that was readable stops reading, its last value is kept
    /// this long, so losing an optional sensor never lowers demand at once.
    public var gpuGrace: TimeInterval

    public init(targetCelsius: Double = SmartTarget.standard, curve: [Point], smoothingTimeConstant: TimeInterval, trendTimeConstant: TimeInterval,
                lookahead: TimeInterval, maximumAnticipation: Double, hysteresis: Double, immediateOvershoot: Double,
                confirmOvershoot: Double, commandStep: Double, resetGap: TimeInterval, gpuGrace: TimeInterval) {
        self.targetCelsius = SmartTarget.clamp(targetCelsius); self.curve = curve
        self.smoothingTimeConstant = smoothingTimeConstant; self.trendTimeConstant = trendTimeConstant
        self.lookahead = lookahead; self.maximumAnticipation = maximumAnticipation; self.hysteresis = hysteresis
        self.immediateOvershoot = immediateOvershoot; self.confirmOvershoot = confirmOvershoot; self.commandStep = commandStep
        self.resetGap = resetGap; self.gpuGrace = gpuGrace
    }

    /// At the target the fan runs at 70 % (70–79 % within the deadband): a
    /// working level, not a ceiling. Below it the gain is about 3–4 points
    /// per °C; above it 6 points per °C, reaching 100 % at target + 5 °C.
    public static let standard = SmartCoolingPolicy(
        curve: [Point(-18, 0), Point(-9, 38), Point(-4, 57), Point(0, 70), Point(3, 88), Point(5, 100)],
        smoothingTimeConstant: 2, trendTimeConstant: 6, lookahead: 8, maximumAnticipation: 5,
        hysteresis: 1.5, immediateOvershoot: 5, confirmOvershoot: 3, commandStep: 4, resetGap: 30, gpuGrace: 30)

    public func with(target celsius: Double) -> SmartCoolingPolicy { var copy = self; copy.targetCelsius = SmartTarget.clamp(celsius); return copy }

    /// Temperature where the curve reaches full speed (above the target).
    public var fullSpeedCelsius: Double { targetCelsius + (curve.last?.offset ?? 0) }
    /// Temperature below which the fan rests at the hardware floor.
    public var restCelsius: Double { targetCelsius + (curve.first?.offset ?? 0) }
    /// The curve's speed at the target itself.
    public var targetPercent: Double { percent(atCelsius: targetCelsius) }

    /// Curve speed for a temperature, 0...100 (before the hardware floor).
    public func percent(atCelsius celsius: Double) -> Double {
        guard celsius.isFinite, let first = curve.first, let last = curve.last else { return 0 }
        let offset = celsius - targetCelsius
        if offset <= first.offset { return first.percent }
        if offset >= last.offset { return last.percent }
        for (a, b) in zip(curve, curve.dropFirst()) where offset <= b.offset {
            guard b.offset > a.offset else { return b.percent }
            return a.percent + (b.percent - a.percent) * (offset - a.offset) / (b.offset - a.offset)
        }
        return last.percent
    }
}

/// The Smart policy's state machine. Feed it one sample at a time; it
/// returns at most one speed to command. It assumes every speed it returns
/// is applied; callers `reset()` it whenever that is not true.
///
/// The speed always lies in a band set by temperature alone: at least the
/// curve at the (smoothed, trend-projected) temperature, at most the curve
/// as if it were `hysteresis` warmer. A warmer reading raises it at once; a
/// cooler one that leaves the band lowers it at once; a steady one keeps it.
/// There is no over-target flag that overrides the curve, and no timer,
/// waiting period, rate limit or per-reading step: mode entry, a new target
/// and a gap are all resolved by the same band on the next valid reading.
public struct SmartCoolingController: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        /// Speed to command now, or nil to leave the fan alone.
        public let command: Double?
        /// The temperature used for this step (the current measurement).
        public let celsius: Double?
        /// Where `celsius` came from.
        public let source: SmartTemperatureSource?
        /// Smoothed temperature plus the bounded trend projection.
        public let effectiveCelsius: Double?
        /// The speed Smart wants now (hardware floor applied).
        public let target: Double?
        /// Requested full speed while the current measurement is over the
        /// target: the fan cannot be asked for more. (The rotor may still be
        /// spooling up; this is about the request, not the tachometer.)
        public let saturated: Bool
    }

    public private(set) var policy: SmartCoolingPolicy
    public private(set) var filtered: Double?
    /// Smoothed slope of the filtered temperature, °C/s.
    public private(set) var trend: Double = 0
    /// Continuous wanted speed before rounding and the hardware floor.
    public private(set) var output: Double?
    /// The last speed handed out (or already applied when seeded).
    public private(set) var commanded: Double?
    private var seedPercent: Double?
    private var lastTime: TimeInterval?
    private var recent: [Double] = []
    private var lastGPU: (celsius: Double, time: TimeInterval)?

    public init(policy: SmartCoolingPolicy = .standard) { self.policy = policy }

    public static func == (a: Self, b: Self) -> Bool {
        a.policy == b.policy && a.filtered == b.filtered && a.trend == b.trend && a.output == b.output && a.commanded == b.commanded
            && a.seedPercent == b.seedPercent && a.lastTime == b.lastTime && a.recent == b.recent
            && a.lastGPU?.celsius == b.lastGPU?.celsius && a.lastGPU?.time == b.lastGPU?.time && a.lastSource == b.lastSource
    }

    /// Which reading the last step used: kept with the step it produced.
    private var lastSource: SmartTemperatureSource?

    /// No sample, seed or command yet.
    public var isFresh: Bool { filtered == nil && seedPercent == nil && commanded == nil }

    /// Forgets all history (keeps the policy); the next sample starts afresh.
    public mutating func reset() { self = SmartCoolingController(policy: policy) }

    /// Starts from the fan's current speed instead of from nothing. The first
    /// reading keeps it if the temperature's band allows, otherwise moves it
    /// to the band. `applied` means that speed is already commanded, so it
    /// is not resent.
    public mutating func seed(percent: Double?, applied: Bool) {
        guard filtered == nil else { return }
        let percent = percent.flatMap { $0.isFinite ? max(0, min(100, $0)) : nil }
        seedPercent = percent
        commanded = applied ? percent?.rounded() : nil
    }

    /// A new target. The next reading moves the speed into the new band at
    /// once: up for a lower target, down to the new curve for a higher one.
    public mutating func retarget(_ celsius: Double) { policy = policy.with(target: celsius) }

    /// Processes one sample taken at `time` (monotonic seconds). `floor` is
    /// the hardware minimum in percent. With `canCommand` false the state
    /// still follows the temperature but nothing is commanded.
    public mutating func update(_ reading: SmartCoolingReading, at time: TimeInterval, floor: Double, canCommand: Bool = true) -> Step {
        let floor = floor.isFinite ? max(0, min(100, floor)) : 0
        // A missing or implausible CPU reading changes nothing: the caller's
        // staleness rules decide what happens to the fan.
        guard time.isFinite, let cpu = reading.validCPU else { return hold(floor) }
        // After a long gap (either way) the history no longer describes the
        // machine. The speed already applied is the seed for the next band.
        if let last = lastTime, abs(time - last) > policy.resetGap {
            let kept = commanded; reset(); seed(percent: kept, applied: kept != nil)
        }
        // The GPU, when readable, counts; one that drops out is bridged with
        // its last value for `gpuGrace`, so losing it never lowers demand.
        let liveGPU = reading.validGPU
        var gpu = liveGPU
        if let liveGPU { lastGPU = (liveGPU, time) } else if let held = lastGPU, time - held.time <= policy.gpuGrace, time >= held.time { gpu = held.celsius }
        let raw = max(cpu, gpu ?? cpu)
        lastSource = gpu.map { $0 > cpu ? (liveGPU == nil ? .gpuHeld : .gpu) : .cpuPeak } ?? .cpuPeak
        let target = policy.targetCelsius
        // A large overshoot acts at once when the previous reading confirms
        // it (or there is none): the curve is at full speed there anyway; this
        // only skips the filter's lag. One isolated spike is not confirmed.
        let confirmed = (recent.last ?? raw) >= target + policy.confirmOvershoot
        let overshoot = raw >= target + policy.immediateOvershoot && confirmed

        if let last = lastTime, time <= last {
            // Not a new sample (repeated or out-of-order timestamp): nothing
            // updates, except a confirmed large overshoot.
            guard overshoot, let current = output, current < 100 else { return hold(floor, celsius: raw) }
            output = 100
            return decide(floor: floor, raw: raw, canCommand: canCommand)
        }
        // Noise rejection both ways: a warmer reading counts only as far as
        // the previous reading agrees (so one high spike cannot speed the
        // fan up); a cooler one counts as the median of the last three (so
        // one low outlier cannot slow it).
        let previousRaw = recent.last
        recent.append(raw); if recent.count > 3 { recent.removeFirst(recent.count - 3) }
        let median = recent.sorted()[recent.count / 2]

        if let previous = filtered, let last = lastTime, let current = output {
            let dt = time - last
            let input = raw > previous ? max(previous, min(raw, previousRaw ?? raw)) : median
            let next = previous + (input - previous) * (1 - exp(-dt / policy.smoothingTimeConstant))
            trend += ((next - previous) / dt - trend) * (1 - exp(-dt / policy.trendTimeConstant))
            filtered = next; lastTime = time
            let projected = next + min(policy.maximumAnticipation, max(0, trend) * policy.lookahead)
            output = overshoot ? 100 : band(current, projected: projected)
        } else {
            filtered = raw; trend = 0; lastTime = time
            // The first reading is placed on the curve directly (full speed
            // only if it is already far over the target); a seed is kept only
            // if this temperature's band allows it.
            output = band(seedPercent ?? 0, projected: raw)
        }
        return decide(floor: floor, raw: raw, canCommand: canCommand)
    }

    /// The deadband: never below the curve at `projected`, never above the
    /// curve at `projected + hysteresis`. The curve alone decides full speed.
    private func band(_ speed: Double, projected: Double) -> Double {
        let low = policy.percent(atCelsius: projected), high = policy.percent(atCelsius: projected + policy.hysteresis)
        return min(max(speed, low), high)
    }

    private mutating func decide(floor: Double, raw: Double, canCommand: Bool) -> Step {
        let desired = target(floor: floor)!
        // Judged on the measurement itself, not the filter.
        let saturated = desired >= 100 && raw > policy.targetCelsius
        guard canCommand else { return Step(command: nil, celsius: raw, source: lastSource, effectiveCelsius: effective, target: desired, saturated: saturated) }
        var command: Double?
        if let last = commanded {
            let change = abs(desired - last)
            if change > 0, change >= policy.commandStep || desired >= 100 || desired <= floor { command = desired }
        } else {
            command = desired
        }
        if let command { commanded = command }
        return Step(command: command, celsius: raw, source: lastSource, effectiveCelsius: effective, target: desired, saturated: saturated)
    }
    private func hold(_ floor: Double, celsius: Double? = nil) -> Step {
        let desired = target(floor: floor)
        return Step(command: nil, celsius: celsius, source: celsius == nil ? nil : lastSource, effectiveCelsius: effective, target: desired,
                    saturated: (desired ?? 0) >= 100 && (celsius ?? -.infinity) > policy.targetCelsius)
    }
    private var effective: Double? {
        filtered.map { $0 + min(policy.maximumAnticipation, max(0, trend) * policy.lookahead) }
    }
    private func target(floor: Double) -> Double? {
        output.map { max(floor, min(100, $0.rounded())) }
    }
}

/// Why Smart turned off. User choices are silent; faults are reported and
/// keep Smart off until the user turns it on again, so it never silently
/// reasserts control.
public enum SmartStopReason: String, Equatable, Sendable, CaseIterable {
    /// Turned off in Settings.
    case user
    /// A manual speed (slider, preset, Manual) replaced it.
    case manual
    /// The user chose Auto.
    case automatic
    case writeFailed, controlLost, sensorFailed, helperDisconnected, competingController

    /// Whether Aervane should hand the fan back to firmware Auto. A manual
    /// choice brings its own command; Auto is the user's own command.
    public var restoresAutomatic: Bool { ![.manual, .automatic].contains(self) }
    public var isFault: Bool { ![.user, .manual, .automatic].contains(self) }
    /// What happened, without claiming what the fan is doing now.
    public var explanation: String? {
        switch self {
        case .user, .manual, .automatic: return nil
        case .writeFailed: return "Smart cooling stopped: a fan command failed."
        case .controlLost: return "Smart cooling stopped: the helper ended Aervane's control."
        case .sensorFailed: return "Smart cooling stopped: no valid CPU temperature."
        case .helperDisconnected: return "Smart cooling stopped: the fan helper disconnected."
        case .competingController: return "Smart cooling stopped: another fan controller is running."
        }
    }
}

/// Smart as a mode: whether it is on, why it last stopped, and its policy
/// state. Each time it is turned on it gets a new `epoch`, so commands sent
/// by an earlier session can never be mistaken for the current one's.
/// Smart as a mode: whether it is on, why it last stopped, its target and
/// policy state. Each time it is turned on it gets a new `epoch`, so commands
/// sent by an earlier session can never be mistaken for the current one's.
/// The target is kept while Smart is off; editing it never turns Smart on.
public struct SmartCoolingSession: Equatable, Sendable {
    public private(set) var enabled: Bool
    public private(set) var controller: SmartCoolingController
    public private(set) var lastStop: SmartStopReason?
    public private(set) var epoch: UInt64 = 0
    /// The most recent evaluation (for display).
    public private(set) var lastStep: SmartCoolingController.Step?
    /// Counts evaluations, so a caller can tell whether `lastStep` came from
    /// the sample it just offered (a stale-generation sample is not evaluated).
    public private(set) var evaluations: UInt64 = 0
    public var targetCelsius: Double { controller.policy.targetCelsius }

    public init(enabled: Bool = false, policy: SmartCoolingPolicy = .standard) {
        self.enabled = enabled; controller = SmartCoolingController(policy: policy)
        if enabled { epoch = 1 }
    }

    /// Turns Smart on, starting from the fan's current speed (see `seed`).
    public mutating func enable(seed: Double?, applied: Bool) {
        enabled = true; lastStop = nil; lastStep = nil; epoch &+= 1
        controller.reset(); controller.seed(percent: seed, applied: applied)
    }
    /// Ends Smart. Returns false when it was already off.
    @discardableResult public mutating func stop(_ reason: SmartStopReason) -> Bool {
        guard enabled else { return false }
        enabled = false; lastStop = reason; lastStep = nil; controller.reset()
        return true
    }
    /// Sleep or a new connection: forget the history but stay on.
    public mutating func suspend() { lastStep = nil; controller.reset() }
    /// A new target, on or off. While on, the next reading applies it.
    public mutating func setTarget(_ celsius: Double) { controller.retarget(celsius) }

    /// Evaluates one sample. Returns a speed to send, or nil. `current` seeds
    /// a fresh controller (e.g. after wake) with the fan's present speed.
    public mutating func evaluate(_ reading: SmartCoolingReading, at time: TimeInterval, floor: Double, canCommand: Bool, current: Double? = nil) -> Double? {
        guard enabled else { return nil }
        if controller.isFresh { controller.seed(percent: current, applied: false) }
        let step = controller.update(reading, at: time, floor: floor, canCommand: canCommand)
        lastStep = step; evaluations &+= 1
        return step.command
    }
}
