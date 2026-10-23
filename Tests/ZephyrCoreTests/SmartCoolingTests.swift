import XCTest
@testable import ZephyrCore

/// Drives a controller through a temperature trace and records every
/// command, so tests read like the fan's history.
private struct Run {
    var controller: SmartCoolingController
    var floor = 21.0
    private(set) var commands: [(time: Double, percent: Double)] = []
    private(set) var steps: [SmartCoolingController.Step] = []

    init(target: Double = 80) { controller = SmartCoolingController(policy: SmartCoolingPolicy.standard.with(target: target)) }

    @discardableResult mutating func feed(_ celsius: Double?, at time: Double, gpu: Double? = nil, canCommand: Bool = true) -> Double? {
        let step = controller.update(SmartCoolingReading(cpuHottest: celsius, gpu: gpu), at: time, floor: floor, canCommand: canCommand)
        steps.append(step)
        if let command = step.command { commands.append((time, command)) }
        return step.command
    }
    /// Holds a temperature from `start` for `duration` seconds, sampling every `every`.
    mutating func hold(_ celsius: Double, from start: Double, for duration: Double, every: Double = 2) {
        var t = start
        while t < start + duration { feed(celsius, at: t); t += every }
    }
    var applied: Double? { commands.last?.percent }
    var wanted: Double? { steps.last?.target }
}

final class SmartTargetTests: XCTestCase {
    func testTargetIsValidatedAndShownInTheUsersUnit() {
        XCTAssertEqual(SmartTarget.standard, 80)
        XCTAssertEqual(SmartTarget.clamp(nil), 80)
        XCTAssertEqual(SmartTarget.clamp(.nan), 80)
        XCTAssertEqual(SmartTarget.clamp(40), 60)
        XCTAssertEqual(SmartTarget.clamp(120), 95)
        XCTAssertEqual(SmartTarget.clamp(72.5), 72.5)
        XCTAssertEqual(SmartTarget.display(80, fahrenheit: false), 80)
        XCTAssertEqual(SmartTarget.display(80, fahrenheit: true), 176)
        XCTAssertEqual(SmartTarget.displayRange(fahrenheit: false), 60...95)
        XCTAssertEqual(SmartTarget.displayRange(fahrenheit: true), 140...203)
    }

    /// Every whole display step in °F maps to its own stored value and back,
    /// so the setting never jumps or sticks; the boundaries stay inside 60–95 °C.
    func testFahrenheitStepsRoundTrip() {
        for f in 140...203 {
            let c = SmartTarget.celsius(fromDisplay: Double(f), fahrenheit: true)
            XCTAssertTrue(SmartTarget.range.contains(c))
            XCTAssertEqual(SmartTarget.display(c, fahrenheit: true), f)
        }
        for c in 60...95 { XCTAssertEqual(SmartTarget.celsius(fromDisplay: Double(c), fahrenheit: false), Double(c)) }
        XCTAssertEqual(SmartTarget.celsius(fromDisplay: 300, fahrenheit: true), 95)
        XCTAssertEqual(SmartTarget.celsius(fromDisplay: 20, fahrenheit: false), 60)
        XCTAssertEqual(SmartTarget.celsius(fromDisplay: .nan, fahrenheit: true), 80)
    }
}

final class SmartCoolingPolicyTests: XCTestCase {
    /// The target is a working point: moderate cooling at it, steeper above,
    /// full speed only a few degrees over it. Every target shifts the curve.
    func testCurveRegulatesAroundTheTarget() {
        for target in [60.0, 73, 80, 95] {
            let policy = SmartCoolingPolicy.standard.with(target: target)
            let samples = stride(from: 20.0, through: 130, by: 0.25).map { policy.percent(atCelsius: $0) }
            XCTAssertEqual(samples, samples.sorted(), "Monotonic")
            XCTAssertEqual(policy.percent(atCelsius: target), 70, "Moderate at the target")
            XCTAssertTrue((65...75).contains(policy.targetPercent))
            XCTAssertLessThan(policy.percent(atCelsius: target + 4), 100)
            XCTAssertEqual(policy.percent(atCelsius: target + 5), 100, "Full speed only over the target")
            XCTAssertEqual(policy.fullSpeedCelsius, target + 5)
            XCTAssertEqual(policy.percent(atCelsius: target - 18), 0)
            // A settled reading at the target can never be pinned at 100 %.
            XCTAssertLessThan(policy.percent(atCelsius: target + policy.hysteresis), 100)
            // Steeper above the target than below it.
            let below = policy.percent(atCelsius: target) - policy.percent(atCelsius: target - 2)
            let above = policy.percent(atCelsius: target + 2) - policy.percent(atCelsius: target)
            XCTAssertGreaterThan(above, below)
        }
        let low = SmartCoolingPolicy.standard.with(target: 70), high = SmartCoolingPolicy.standard.with(target: 90)
        XCTAssertGreaterThan(low.percent(atCelsius: 75), high.percent(atCelsius: 75), "Targets shift the operating response")
        XCTAssertEqual(SmartCoolingPolicy.standard.percent(atCelsius: .nan), 0)
    }

    func testReadingUsesHottestCoreAndOptionalGPU() {
        XCTAssertEqual(SmartCoolingReading(cpuHottest: 71, gpu: nil).celsius, 71)
        XCTAssertEqual(SmartCoolingReading(cpuHottest: 71, gpu: 78).celsius, 78)
        XCTAssertEqual(SmartCoolingReading(cpuHottest: 71, gpu: .nan).celsius, 71)
        XCTAssertNil(SmartCoolingReading(cpuHottest: nil, gpu: 80).celsius, "The CPU reading is required")
    }
}

final class SmartCoolingControllerTests: XCTestCase {
    func testFirstSampleIsPlacedOnTheCurve() {
        var cool = Run()
        XCTAssertEqual(cool.feed(45, at: 0), 21, "Cool: the hardware floor, never a fake 0%")
        var at = Run(target: 80)
        XCTAssertEqual(at.feed(80, at: 0), 70, "At the target: a working level, not full speed")
        var over = Run(target: 75)
        XCTAssertEqual(over.feed(80, at: 0), 100, "Far over the target on the first reading: full speed at once")
        XCTAssertTrue(over.steps.last!.saturated)
    }

    /// The user's live case (read-only probe: hottest core 79.5 °C, target
    /// 73 °C): that is 6.5 °C over the target, so full speed is genuine and
    /// reported as saturation. Back at the target the request is 70 %.
    func testReportedCase() {
        var hot = Run(target: 73)
        hot.hold(79.5, from: 0, for: 20)
        XCTAssertEqual(hot.applied, 100)
        XCTAssertTrue(hot.steps.last!.saturated)
        var at = Run(target: 73)
        at.hold(73, from: 0, for: 20)
        XCTAssertEqual(at.wanted, 70)
        XCTAssertFalse(at.steps.last!.saturated)
    }

    /// The reported case: target 73, the hottest core near the target. The
    /// request is moderate, not maximum, and steady readings keep it there.
    func testSteadyAtTheTargetIsModerateAndStable() {
        var run = Run(target: 73)
        var seed: UInt32 = 99
        func noise() -> Double { seed = seed &* 1_103_515_245 &+ 12345; return Double((seed >> 16) & 0x7fff) / 32767 * 1.6 - 0.8 }
        var t = 0.0
        while t < 600 { run.feed(73 + noise(), at: t); t += 2 }
        let settled = run.steps.suffix(200).compactMap(\.target)
        XCTAssertTrue(settled.allSatisfy { (60...82).contains($0) }, "\(Set(settled))")
        XCTAssertLessThan(settled.max()!, 100)
        XCTAssertLessThanOrEqual(run.commands.filter { $0.time > 30 }.count, 3, "No alternating high/low commands")
        XCTAssertFalse(run.steps.contains { $0.saturated })
    }

    /// Start at 100 % while hot; cool through and below the target. After the
    /// measurement filter settles the request drops below 100 % — no 20 s
    /// hold, no command-count gate — and keeps falling with temperature.
    func testCoolingFromFullSpeedFollowsTemperature() {
        var run = Run(target: 75)
        run.hold(84, from: 0, for: 20)
        XCTAssertEqual(run.applied, 100)
        var t = 20.0, below100At: Double?
        for celsius in stride(from: 83.0, through: 66, by: -1) {
            run.feed(celsius, at: t)
            if below100At == nil, let wanted = run.wanted, wanted < 100 { below100At = celsius }
            t += 2
        }
        XCTAssertNotNil(below100At)
        XCTAssertGreaterThanOrEqual(below100At!, 75, "Below 100 % by the time the temperature is back at the target")
        XCTAssertLessThan(run.wanted!, 60, "Well below the target: well below the target level")
        let falling = run.commands.filter { $0.time >= 20 }.map(\.percent)
        XCTAssertEqual(falling, falling.sorted(by: >))
    }

    /// Seeded at 100 % at an exact, steady target: the band requires less at
    /// once, and identical readings then change nothing.
    func testSeededFullSpeedAtTheTargetDropsAtOnce() {
        var c = SmartCoolingController(policy: SmartCoolingPolicy.standard.with(target: 73))
        c.seed(percent: 100, applied: true)
        let first = c.update(SmartCoolingReading(cpuHottest: 73), at: 0, floor: 21)
        XCTAssertNotNil(first.command)
        XCTAssertLessThan(first.command!, 100)
        XCTAssertGreaterThanOrEqual(first.command!, 70)
        for t in stride(from: 2.0, through: 120, by: 2) {
            XCTAssertNil(c.update(SmartCoolingReading(cpuHottest: 73), at: t, floor: 21).command, "No hidden ramp")
        }
    }

    /// From cold, a fast rise raises demand ahead of the target (trend
    /// projection); a meaningful overshoot reaches 100 %.
    func testRapidRiseIsAnticipatedAndOvershootReachesFullSpeed() {
        var ramp = Run(target: 80)
        var t = 0.0
        for celsius in stride(from: 55.0, through: 79, by: 1.5) { ramp.feed(celsius, at: t); t += 2 }
        let anticipated = ramp.wanted!
        var steady = Run(target: 80)
        steady.hold(79, from: 0, for: 60)
        XCTAssertGreaterThan(anticipated, steady.wanted!, "A rising approach asks for more than the same temperature held steady")
        var over = Run(target: 80)
        over.hold(80, from: 0, for: 20)
        over.feed(86, at: 20)
        over.feed(86, at: 22)
        XCTAssertEqual(over.applied, 100, "A confirmed overshoot of 6 °C: full speed")
        XCTAssertTrue(over.steps.last!.saturated)
    }

    /// One isolated reading, high or low, moves nothing.
    func testIsolatedSpikesAreRejected() {
        var run = Run(target: 80)
        run.hold(78, from: 0, for: 30)
        let before = run.applied!
        let count = run.commands.count
        run.feed(88, at: 30)
        run.feed(78, at: 32)
        run.feed(66, at: 34)
        run.feed(78, at: 36)
        run.hold(78, from: 38, for: 20)
        XCTAssertEqual(run.commands.count, count, "\(run.commands)")
        XCTAssertEqual(run.applied, before)
    }

    /// Lowering the target raises the speed on the next reading; raising it
    /// lowers the request straight to the new curve's band. Once settled,
    /// identical readings change nothing at all.
    func testTargetChangesWhileActive() {
        var run = Run(target: 80)
        run.hold(74, from: 0, for: 20)
        let at80 = run.applied!
        run.controller.retarget(70)
        run.feed(74, at: 20)
        XCTAssertGreaterThan(run.applied!, at80)
        run.controller.retarget(95)
        run.feed(74, at: 22)
        XCTAssertLessThan(run.applied!, at80)
        let settled = run.commands.count
        run.hold(74, from: 24, for: 120)
        XCTAssertEqual(run.commands.count, settled, "No hidden per-reading countdown")
    }

    func testSeedIsResolvedByTheBandOnce() {
        var kept = SmartCoolingController()
        kept.seed(percent: 72, applied: true)
        for t in stride(from: 0.0, through: 120, by: 2) {
            XCTAssertNil(kept.update(SmartCoolingReading(cpuHottest: 80), at: t, floor: 21).command, "72 % is inside the band at 80 °C")
        }
        var high = SmartCoolingController()
        high.seed(percent: 85, applied: true)
        XCTAssertEqual(high.update(SmartCoolingReading(cpuHottest: 60), at: 0, floor: 21).command, 21)
        for t in stride(from: 2.0, through: 120, by: 2) {
            XCTAssertNil(high.update(SmartCoolingReading(cpuHottest: 60), at: t, floor: 21).command)
        }
    }

    /// Inside the 1.5 °C deadband nothing changes; through it, the request
    /// follows at once.
    func testDeadbandCrossingLowersWithoutAGate() {
        var run = Run(target: 80)
        run.hold(78, from: 0, for: 60)
        let start = run.commands.count
        run.hold(77, from: 60, for: 60)
        XCTAssertEqual(run.commands.count, start, "1 °C cooler is inside the deadband")
        run.hold(70, from: 120, for: 10)
        XCTAssertGreaterThan(run.commands.count, start)
        let count = run.commands.count
        run.hold(70, from: 130, for: 600)
        XCTAssertEqual(run.commands.count, count)
    }

    func testFloorAndBoundaryTargets() {
        var run = Run(target: 60)
        run.floor = 30
        XCTAssertEqual(run.feed(40, at: 0), 30)
        XCTAssertEqual(Run(target: 60).controller.policy.targetCelsius, 60)
        var hot = Run(target: 95)
        XCTAssertEqual(hot.feed(95, at: 0), 70)
        run.floor = .nan
        run.feed(40, at: 2)
        XCTAssertTrue(run.commands.allSatisfy { (0...100).contains($0.percent) })
    }

    func testInvalidSamplesChangeNothing() {
        var run = Run()
        run.hold(75, from: 0, for: 30)
        let before = run.controller
        XCTAssertNil(run.feed(nil, at: 30))
        XCTAssertNil(run.feed(.nan, at: 32))
        XCTAssertNil(run.feed(75, at: .nan))
        XCTAssertEqual(run.controller, before)
    }

    /// A repeated timestamp is not a new sample; only a confirmed large
    /// overshoot acts on one.
    func testDuplicateTimestamps() {
        var run = Run(target: 80)
        run.hold(70, from: 0, for: 10)
        let before = run.controller
        XCTAssertNil(run.feed(84, at: 8))
        XCTAssertEqual(run.controller.output, before.output)
        var hot = Run(target: 80)
        hot.hold(84, from: 0, for: 4)
        hot.feed(86, at: 2)
        XCTAssertEqual(hot.wanted, 100)
    }

    func testAfterAGapTheBandDecidesAtOnce() {
        var run = Run(target: 80)
        run.hold(86, from: 0, for: 20)
        XCTAssertEqual(run.applied, 100)
        XCTAssertEqual(run.feed(50, at: 600), 21)
        XCTAssertNil(run.feed(50, at: 602))
    }

    /// Saturation needs both: full speed requested and the current
    /// measurement over the target. A projected (anticipatory) 100 % below
    /// the target is not saturation.
    func testSaturationNeedsMeasuredOvershootAndFullSpeed() {
        var run = Run(target: 80)
        run.hold(87, from: 0, for: 20)
        XCTAssertTrue(run.steps.last!.saturated)
        run.feed(79, at: 20)
        XCTAssertFalse(run.steps.last!.saturated, "Measured under the target now")
        var rising = Run(target: 80)
        var t = 0.0
        for celsius in stride(from: 60.0, through: 79.5, by: 2.5) { rising.feed(celsius, at: t); t += 1 }
        XCTAssertFalse(rising.steps.contains { $0.saturated }, "Never saturated below the target")
    }

    /// Smart reports which measurement it used, including a held GPU value.
    func testSourceIsReported() {
        var run = Run(target: 80)
        run.feed(70, at: 0)
        XCTAssertEqual(run.steps.last?.source, .cpuPeak)
        run.feed(70, at: 2, gpu: 74)
        XCTAssertEqual(run.steps.last?.source, .gpu)
        XCTAssertEqual(run.steps.last?.celsius, 74)
        run.feed(70, at: 4, gpu: nil)
        XCTAssertEqual(run.steps.last?.source, .gpuHeld)
        XCTAssertEqual(run.steps.last?.celsius, 74, "The held value is what Smart used")
        run.feed(70, at: 60, gpu: nil)
        XCTAssertEqual(run.steps.last?.source, .cpuPeak, "After the grace, CPU only")
        run.feed(72, at: 62, gpu: 65)
        XCTAssertEqual(run.steps.last?.source, .cpuPeak, "A cooler GPU is not the source")
        XCTAssertNil(run.feed(nil, at: 64))
        XCTAssertNil(run.steps.last?.source)
    }

    func testVanishingGPUDoesNotLowerDemandAtOnce() {
        var run = Run()
        for t in stride(from: 0.0, through: 20, by: 2) { run.feed(60, at: t, gpu: 78) }
        let withGPU = run.controller.output!
        for t in stride(from: 22.0, through: 48, by: 2) { run.feed(60, at: t, gpu: nil) }
        XCTAssertEqual(run.controller.output!, withGPU, accuracy: 0.5)
        for t in stride(from: 50.0, through: 120, by: 2) { run.feed(60, at: t, gpu: .nan) }
        XCTAssertLessThan(run.controller.output!, withGPU)
    }

    func testDeterministic() {
        var a = Run(), b = Run()
        for (i, celsius) in [52.0, 58, 66, 74, 79, 81, 77, 70, 62, 55].enumerated() {
            XCTAssertEqual(a.feed(celsius, at: Double(i) * 3), b.feed(celsius, at: Double(i) * 3))
        }
        XCTAssertEqual(a.controller, b.controller)
    }
}

final class SmartCoolingSessionTests: XCTestCase {
    private let warm = SmartCoolingReading(cpuHottest: 70)

    func testOffByDefaultAndNeverCommandsWhenOff() {
        var session = SmartCoolingSession()
        XCTAssertNil(session.evaluate(warm, at: 0, floor: 21, canCommand: true))
    }

    /// The target is kept while Smart is off, and setting it never turns
    /// Smart on.
    func testTargetPersistsWhileOffAndDoesNotEnable() {
        var session = SmartCoolingSession()
        session.setTarget(72)
        XCTAssertFalse(session.enabled)
        XCTAssertEqual(session.targetCelsius, 72)
        session.enable(seed: nil, applied: false)
        XCTAssertEqual(session.targetCelsius, 72)
        XCTAssertTrue(session.stop(.user))
        XCTAssertEqual(session.targetCelsius, 72)
        session.setTarget(10)
        XCTAssertEqual(session.targetCelsius, 60)
    }

    func testEachEnableIsANewEpochAndStopsReportTheirReason() {
        var session = SmartCoolingSession()
        session.enable(seed: nil, applied: false)
        let first = session.epoch
        XCTAssertTrue(session.stop(.sensorFailed))
        XCTAssertFalse(session.stop(.user))
        XCTAssertEqual(session.lastStop, .sensorFailed)
        session.enable(seed: nil, applied: false)
        XCTAssertGreaterThan(session.epoch, first)
    }

    func testStopReasonsAreHonestAboutTheFan() {
        for reason in SmartStopReason.allCases where reason.isFault {
            XCTAssertFalse(reason.explanation!.contains("is back on Auto"))
        }
        XCTAssertFalse(SmartStopReason.manual.restoresAutomatic)
    }
}
