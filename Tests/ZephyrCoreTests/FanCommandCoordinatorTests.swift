import XCTest
@testable import ZephyrCore

/// The orchestration AppModel runs, driven event by event: the same reducer,
/// with the helper's replies supplied by the test. Nothing here touches
/// sensors, the helper, timers or defaults.
final class FanCommandCoordinatorTests: XCTestCase {
    private typealias C = FanCommandCoordinator
    private let warm = SmartCoolingReading(cpuHottest: 80)
    private let hot = SmartCoolingReading(cpuHottest: 99)

    /// Enables Smart and lets it send its first command.
    private func smartInFlight(_ c: inout C, seed: Double? = nil) -> C.Ticket {
        c.enableSmart(seed: seed, applied: false)
        let ticket = c.sample(warm, generation: c.sampleGeneration, at: 0, floor: 21, ready: true, current: nil)!
        XCTAssertEqual(ticket.origin, .smart(epoch: c.smart.epoch))
        return ticket
    }

    func testSmartIsOffByDefaultAndSendsNothing() {
        var c = C()
        XCTAssertFalse(c.smartEnabled)
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 0, floor: 21, ready: true, current: nil))
    }

    /// A slider or preset during Smart's in-flight write wins: Smart ends,
    /// the user's speed runs next, nothing automated follows, and only the
    /// user's own reply starts Return to Auto.
    func testManualDuringSmartWriteWinsWithoutStaleAutomatedWrites() {
        var c = C()
        let smart = smartInFlight(&c)
        XCTAssertNil(c.userSet(76), "Queued behind the write in flight")
        XCTAssertFalse(c.smartEnabled)
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 2, floor: 21, ready: true, current: nil))
        let first = c.complete(id: smart.id, outcome: .applied(automatic: false))!
        XCTAssertFalse(first.startReturnTimer, "Smart's reply never starts the manual timer")
        XCTAssertEqual(first.next?.command, .set(76))
        XCTAssertEqual(first.next?.origin, .user)
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 4, floor: 21, ready: true, current: nil))
        let second = c.complete(id: first.next!.id, outcome: .applied(automatic: false))!
        XCTAssertTrue(second.startReturnTimer)
        XCTAssertNil(second.next)
        XCTAssertNil(c.notice, "A user choice is not a fault")
    }

    func testAutoDuringSmartWriteRunsNextAndSmartStaysOff() {
        var c = C()
        let smart = smartInFlight(&c)
        XCTAssertNil(c.userAutomatic(owns: false), "A set in flight may take the fan, so Auto is queued")
        let done = c.complete(id: smart.id, outcome: .applied(automatic: false))!
        XCTAssertEqual(done.next?.command, .automatic)
        XCTAssertFalse(done.startReturnTimer)
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 3, floor: 21, ready: true, current: nil))
    }

    /// Smart on, off, on with the first session's write still in flight: the
    /// queued Auto is never replaced by an automated tick, the old reply is
    /// not the new session's, and nothing starts the manual timer.
    func testRapidToggleWithOldWriteInFlight() {
        var c = C()
        let old = smartInFlight(&c)
        XCTAssertNil(c.stopSmart(.user, owns: false), "Auto queued behind the write")
        XCTAssertEqual(c.queued?.command, .automatic)
        c.enableSmart(seed: nil, applied: false)
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 1, floor: 21, ready: true, current: nil), "Busy: Smart waits")
        XCTAssertEqual(c.queued?.command, .automatic, "Auto is not replaced")
        let done = c.complete(id: old.id, outcome: .failed("rolled back"))!
        XCTAssertTrue(c.smartEnabled, "An old session's failure does not stop the new one")
        XCTAssertNil(c.notice)
        XCTAssertFalse(done.startReturnTimer)
        XCTAssertEqual(done.next?.command, .automatic)
        XCTAssertNil(c.complete(id: done.next!.id, outcome: .applied(automatic: true))!.next)
        XCTAssertNotNil(c.sample(hot, generation: c.sampleGeneration, at: 4, floor: 21, ready: true, current: 21))
    }

    /// Review regression: a user's speed in flight, then Smart turned on. The
    /// user's reply must not start Return to Auto while Smart is on.
    func testUserReplyAfterSmartEnabledDoesNotStartTheTimer() {
        var c = C()
        let user = c.userSet(60)!
        c.enableSmart(seed: 60, applied: false)
        let done = c.complete(id: user.id, outcome: .applied(automatic: false))!
        XCTAssertFalse(done.startReturnTimer)
    }

    /// A user speed equal to Smart's write in flight adopts that write: its
    /// reply is the user's (Smart has ended).
    func testUserIntentEqualToSmartWriteAdoptsIt() {
        var c = C()
        let smart = smartInFlight(&c)
        guard case .set(let value) = smart.command else { return XCTFail() }
        XCTAssertNil(c.userSet(value))
        XCTAssertNil(c.queued)
        XCTAssertEqual(c.inFlight?.origin, .user)
        XCTAssertTrue(c.complete(id: smart.id, outcome: .applied(automatic: false))!.startReturnTimer)
    }

    /// Smart's own failed write stops it with an honest notice: Auto is
    /// pending until the helper confirms it, and confirmation does not erase
    /// the reason.
    func testWriteFailureStopsSmartAndReportsTheRestoreTruthfully() {
        var c = C()
        let smart = smartInFlight(&c)
        let done = c.complete(id: smart.id, outcome: .failed("target not reached"))!
        XCTAssertFalse(c.smartEnabled)
        XCTAssertEqual(done.next?.command, .automatic)
        XCTAssertEqual(c.notice?.restore, .pending)
        XCTAssertTrue(c.notice!.message!.contains("Returning the fan to Auto"))
        XCTAssertFalse(c.notice!.message!.contains("is on Auto"))
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 2, floor: 21, ready: true, current: nil), "Never retries on its own")
        _ = c.complete(id: done.next!.id, outcome: .applied(automatic: true))
        XCTAssertEqual(c.notice?.restore, .verified)
        XCTAssertEqual(c.notice?.reason, .writeFailed, "The reason stays after Auto succeeds")
        XCTAssertTrue(c.notice!.message!.hasSuffix("The fan is on Auto."))
        _ = c.userSet(50)
        XCTAssertNil(c.notice, "The next mode choice clears it")
    }

    func testFailedOrUnownedRestoreIsReportedAsSuch() {
        var c = C()
        _ = smartInFlight(&c)
        var d = c
        let restore = c.stopSmart(.sensorFailed, owns: true)
        XCTAssertNil(restore, "Queued behind the write in flight")
        XCTAssertEqual(c.notice?.restore, .pending)
        let next = c.complete(id: c.inFlight!.id, outcome: .applied(automatic: false))!.next!
        _ = c.complete(id: next.id, outcome: .failed("timeout"))
        XCTAssertEqual(c.notice?.restore, .failed("timeout"))
        XCTAssertTrue(c.notice!.message!.contains("Could not return the fan to Auto: timeout"))
        // The helper had already released the lease: not yet confirmed.
        _ = d.stopSmart(.competingController, owns: true)
        let auto = d.complete(id: d.inFlight!.id, outcome: .applied(automatic: false))!.next!
        _ = d.complete(id: auto.id, outcome: .notOwner)
        XCTAssertEqual(d.notice?.restore, .unconfirmed)
        d.observe(automatic: true)
        XCTAssertEqual(d.notice?.restore, .verified)
    }

    func testHelperDisconnectStopsSmartAndWaitsForAReadback() {
        var c = C()
        let old = smartInFlight(&c)
        c.resetConnection()
        XCTAssertNil(c.stopSmart(.helperDisconnected, owns: false))
        XCTAssertEqual(c.notice?.restore, .unconfirmed)
        XCTAssertNil(c.complete(id: old.id, outcome: .applied(automatic: false)), "A reply from the old connection is ignored")
        c.observe(automatic: false)
        XCTAssertEqual(c.notice?.restore, .unconfirmed)
        c.observe(automatic: true)
        XCTAssertEqual(c.notice?.restore, .verified)
    }

    /// Sleep with Smart's write in flight: Auto follows it, telemetry begun
    /// before sleep (or during it) is void, and Smart resumes only from a
    /// reading begun after wake, seeded from the fan's present speed.
    func testSleepAndWakeGateSmart() {
        var c = C()
        let write = smartInFlight(&c)
        let beforeSleep = c.sampleGeneration
        XCTAssertNil(c.sleep(owns: false), "Queued: the write may be about to take the fan")
        XCTAssertTrue(c.smartEnabled)
        let done = c.complete(id: write.id, outcome: .applied(automatic: false))!
        XCTAssertEqual(done.next?.command, .automatic)
        XCTAssertEqual(done.next?.origin, .system)
        XCTAssertNil(c.complete(id: done.next!.id, outcome: .applied(automatic: true))!.next)
        XCTAssertNil(c.sample(hot, generation: beforeSleep, at: 5, floor: 21, ready: true, current: nil), "Pre-sleep reading")
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 6, floor: 21, ready: true, current: nil), "Asleep")
        let duringSleep = c.sampleGeneration
        c.wake()
        XCTAssertNil(c.sample(hot, generation: duringSleep, at: 7, floor: 21, ready: true, current: nil), "Begun before wake")
        XCTAssertEqual(c.sample(SmartCoolingReading(cpuHottest: 50), generation: c.sampleGeneration, at: 8, floor: 21, ready: true, current: 35)?.command,
                       .set(21), "Resumes from the fan's present speed, resolved by this reading's band")
    }

    func testSleepWhileOwningSendsAutoAtOnce() {
        var c = C()
        let write = smartInFlight(&c)
        _ = c.complete(id: write.id, outcome: .applied(automatic: false))
        XCTAssertEqual(c.sleep(owns: true)?.command, .automatic)
    }

    /// A poll begun before Smart was turned on (CPU-only, no GPU) cannot
    /// initialise the new session.
    func testOldTelemetryCannotDriveANewSession() {
        var c = C()
        let before = c.sampleGeneration
        c.enableSmart(seed: nil, applied: false)
        XCTAssertNil(c.sample(hot, generation: before, at: 0, floor: 21, ready: true, current: nil))
        XCTAssertNil(c.smart.lastStep)
        XCTAssertNotNil(c.sample(hot, generation: c.sampleGeneration, at: 1, floor: 21, ready: true, current: nil))
    }

    func testSmartNeverSendsUnlessReadyAndIdle() {
        var c = C()
        c.enableSmart(seed: nil, applied: false)
        XCTAssertNil(c.sample(warm, generation: c.sampleGeneration, at: 0, floor: 21, ready: false, current: nil))
        let user = c.systemRestore(owns: true)!
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 2, floor: 21, ready: true, current: nil))
        _ = c.complete(id: user.id, outcome: .applied(automatic: true))
        XCTAssertNotNil(c.sample(hot, generation: c.sampleGeneration, at: 4, floor: 21, ready: true, current: nil))
    }

    /// Enabling Smart at a high manual speed: the first valid reading's band
    /// decides the request at once; repeated identical readings never step it
    /// further (no handover countdown).
    func testEnablingAtHighManualSpeedIsResolvedByTemperature() {
        var c = C()
        c.enableSmart(seed: 85, applied: true)
        var commands: [Double] = []
        var t = 0.0
        while t < 120 {
            if let ticket = c.sample(SmartCoolingReading(cpuHottest: 60), generation: c.sampleGeneration, at: t, floor: 21, ready: true, current: 85) {
                guard case .set(let v) = ticket.command else { return XCTFail() }
                commands.append(v)
                _ = c.complete(id: ticket.id, outcome: .applied(automatic: false))
            }
            t += 2
        }
        XCTAssertEqual(commands, [21])
        // Under heat the same entry rises at once.
        var hot = C()
        hot.enableSmart(seed: 40, applied: true)
        XCTAssertEqual(hot.sample(SmartCoolingReading(cpuHottest: 79), generation: hot.sampleGeneration, at: 0, floor: 21, ready: true, current: 40)?.command,
                       .set(SmartCoolingPolicy.standard.percent(atCelsius: 79).rounded()), "Rises at once to the curve")
    }

    /// A target change while Smart's write is in flight: that write keeps its
    /// identity, nothing is sent until it completes, then the new target
    /// applies. An old reply never starts the manual timer.
    func testTargetChangeDuringInFlightSmartWrite() {
        var c = C()
        c.enableSmart(seed: nil, applied: false)
        let first = c.sample(SmartCoolingReading(cpuHottest: 64), generation: c.sampleGeneration, at: 0, floor: 21, ready: true, current: 21)!
        let epoch = c.smart.epoch
        c.setSmartTarget(66)
        XCTAssertEqual(c.inFlight?.id, first.id)
        XCTAssertEqual(c.inFlight?.origin, .smart(epoch: epoch))
        XCTAssertNil(c.sample(SmartCoolingReading(cpuHottest: 64), generation: c.sampleGeneration, at: 2, floor: 21, ready: true, current: 21), "One command at a time")
        XCTAssertFalse(c.complete(id: first.id, outcome: .applied(automatic: false))!.startReturnTimer)
        let next = c.sample(SmartCoolingReading(cpuHottest: 64), generation: c.sampleGeneration, at: 4, floor: 21, ready: true, current: 21)
        XCTAssertEqual(next?.command, .set(SmartCoolingPolicy.standard.with(target: 66).percent(atCelsius: 64).rounded()),
                       "The new target applies on the next reading (it was the floor under 80 °C)")
        XCTAssertEqual(c.smartTarget, 66)
    }

    /// Raising the target while active lowers the request to the new band on
    /// the next reading; after that, identical readings send nothing.
    func testRaisingTheTargetWhileActive() {
        var c = C(targetCelsius: 70)
        c.enableSmart(seed: nil, applied: false)
        var commands: [Double] = [], t = 0.0
        func step() {
            if let ticket = c.sample(SmartCoolingReading(cpuHottest: 68), generation: c.sampleGeneration, at: t, floor: 21, ready: true, current: commands.last) {
                if case .set(let v) = ticket.command { commands.append(v) }
                _ = c.complete(id: ticket.id, outcome: .applied(automatic: false))
            }
            t += 2
        }
        for _ in 0..<5 { step() }
        XCTAssertEqual(commands.last, SmartCoolingPolicy.standard.with(target: 70).percent(atCelsius: 68).rounded())
        c.setSmartTarget(95)
        step()
        let lowered = commands.last!
        XCTAssertLessThan(lowered, commands[commands.count - 2])
        let count = commands.count
        for _ in 0..<30 { step() }
        XCTAssertEqual(commands.count, count, "Settled: no further commands at a steady temperature")
    }

    /// Editing the target while Smart is off keeps it and never enables Smart.
    func testTargetEditWhileOffNeverEnables() {
        var c = C()
        c.setSmartTarget(72)
        XCTAssertFalse(c.smartEnabled)
        XCTAssertNil(c.sample(SmartCoolingReading(cpuHottest: 90), generation: c.sampleGeneration, at: 0, floor: 21, ready: true, current: nil))
        c.enableSmart(seed: nil, applied: false)
        XCTAssertEqual(c.smartTarget, 72)
        XCTAssertEqual(C(targetCelsius: 10).smartTarget, 60, "Persisted values are validated")
    }

    /// Taking hold of the slider ends Smart at once with no command, so Smart
    /// cannot fight the drag; Smart's late reply does not start the timer and
    /// the user's committed speed does.
    func testGrabbingTheSliderSelectsManualWithoutFighting() {
        var c = C()
        let smart = smartInFlight(&c)
        let generation = c.sampleGeneration
        c.userBeganAdjusting()
        XCTAssertFalse(c.smartEnabled)
        XCTAssertNil(c.notice)
        XCTAssertGreaterThan(c.sampleGeneration, generation)
        XCTAssertNil(c.queued, "No command until the user commits")
        XCTAssertNil(c.sample(hot, generation: c.sampleGeneration, at: 2, floor: 21, ready: true, current: nil))
        XCTAssertFalse(c.complete(id: smart.id, outcome: .applied(automatic: false))!.startReturnTimer)
        let user = c.userSet(64)!
        XCTAssertTrue(c.complete(id: user.id, outcome: .applied(automatic: false))!.startReturnTimer)
    }

    func testSaturationIsReportedOnlyWhileSmartRuns() {
        var c = C(targetCelsius: 75)
        c.enableSmart(seed: nil, applied: false)
        let ticket = c.sample(SmartCoolingReading(cpuHottest: 82), generation: c.sampleGeneration, at: 0, floor: 21, ready: true, current: 21)!
        XCTAssertEqual(ticket.command, .set(100))
        XCTAssertTrue(c.smartSaturated)
        _ = c.stopSmart(.user, owns: true)
        XCTAssertFalse(c.smartSaturated)
    }

    func testStopNoticeFromAnEarlierLaunchMakesNoClaimAboutTheFan() {
        let c = C(smartEnabled: false, previousStop: .sensorFailed)
        XCTAssertEqual(c.notice?.message, SmartStopReason.sensorFailed.explanation)
        XCTAssertNil(C(smartEnabled: false, previousStop: .manual).notice)
        XCTAssertNil(C(smartEnabled: true, previousStop: .sensorFailed).notice)
    }

    func testLateRepliesAreIgnoredByIdentity() {
        var c = C()
        let first = c.userSet(40)!
        _ = c.userSet(50)
        XCTAssertNil(c.complete(id: first.id + 99, outcome: .applied(automatic: false)))
        let done = c.complete(id: first.id, outcome: .applied(automatic: false))!
        XCTAssertNil(c.complete(id: first.id, outcome: .applied(automatic: false)), "A duplicate reply is not the command in flight")
        XCTAssertEqual(done.next?.command, .set(50))
    }
}
