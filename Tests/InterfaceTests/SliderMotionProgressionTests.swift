import AppKit
import XCTest
@testable import Zephyr

/// Proves that continuous slider motion actually *moves on screen*: these
/// tests sample presentation layers at irregular wall-clock intervals while
/// pumping the run loop, and compare the observed travel with the rate the
/// motion should have. Attaching an animation is not enough to pass.
///
/// Effects are set explicitly to Expressive with Reduce Motion and Reduce
/// Transparency OFF, so the result does not depend on the Mac's own
/// accessibility settings (with Reduce Motion on, the slider is meant to be
/// still, which `testReduceMotionStandsEverythingStill` checks).
///
/// The window is ordered front (borderless, 380×100) so the layer tree is
/// committed and presentation layers exist; each test orders it out again.
@MainActor final class SliderMotionProgressionTests: XCTestCase {
    private let expressive = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)

    private func liveSlider(style: SliderStyle) -> (NSWindow, PercentSlider) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let control = PercentSlider(frame: NSRect(x: 4, y: 24, width: 372, height: 52))
        window.contentView!.addSubview(control)
        control.style = style
        control.effects = expressive
        control.minimumPercent = 21
        window.orderFrontRegardless()
        control.updateLayer()
        control.displayIfNeeded()
        pump(0.05)
        return (window, control)
    }
    /// Lets Core Animation commit and time pass.
    private func pump(_ seconds: TimeInterval) {
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        CATransaction.flush()
    }
    /// Signed difference wrapped into (−period/2, period/2].
    private func wrapped(_ delta: Double, period: Double) -> Double {
        var d = delta.truncatingRemainder(dividingBy: period)
        if d > period / 2 { d -= period }
        if d <= -period / 2 { d += period }
        return d
    }
    /// Samples the rotor angle at irregular intervals and checks each step
    /// against `rps`. Returns the total travel in radians.
    @discardableResult
    private func assertRotorTurns(_ control: PercentSlider, rps: Double, intervals: [TimeInterval], _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard var last = control.rotorShownAngle else {
            XCTFail("\(label): no presentation layer for the rotors (layer tree not committed)", file: file, line: line); return 0
        }
        var lastTime = CACurrentMediaTime(), travel = 0.0
        for interval in intervals {
            pump(interval)
            let now = CACurrentMediaTime()
            guard let angle = control.rotorShownAngle else { XCTFail("\(label): presentation vanished", file: file, line: line); return travel }
            let step = wrapped(angle - last, period: 2 * .pi), expected = 2 * .pi * rps * (now - lastTime)
            XCTAssertEqual(step, expected, accuracy: max(0.1, expected * 0.35),
                           "\(label): rotor stepped \(step) rad in \(now - lastTime) s, expected \(expected)", file: file, line: line)
            travel += step; last = angle; lastTime = now
        }
        return travel
    }
    /// Samples every flow loop at irregular intervals: each scroll must
    /// travel at its velocity (modulo its tile), and the breathing loops
    /// must visibly change opacity over the run.
    private func assertFlowMoves(_ control: PercentSlider, intervals: [TimeInterval], _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let first = control.flowProbes
        XCTAssertFalse(first.isEmpty, "\(label): no flow loops", file: file, line: line)
        guard first.allSatisfy({ $0.shown != nil }) else {
            XCTFail("\(label): flow layers have no presentation (layer tree not committed)", file: file, line: line); return
        }
        var last = first, lastTime = CACurrentMediaTime()
        var low = first.map { $0.shown! }, high = low
        for interval in intervals {
            pump(interval)
            let now = CACurrentMediaTime(), probes = control.flowProbes
            for (i, probe) in probes.enumerated() {
                guard let value = probe.shown, let previous = last[i].shown else { XCTFail("\(label): presentation vanished", file: file, line: line); return }
                low[i] = min(low[i], value); high[i] = max(high[i], value)
                if let period = probe.period, let velocity = probe.velocity {
                    let step = wrapped(value - previous, period: Double(period)), expected = Double(velocity) * (now - lastTime)
                    XCTAssertEqual(step, expected, accuracy: max(1.5, abs(expected) * 0.35),
                                   "\(label): \(probe.keyPath) loop \(i) moved \(step) pt in \(now - lastTime) s, expected \(expected)", file: file, line: line)
                }
            }
            last = probes; lastTime = now
        }
        // A breath takes 2–3 s (longer on Subtle): only a long enough run
        // must show one changing.
        for (i, probe) in first.enumerated() where probe.period == nil && intervals.reduce(0, +) >= 1.2 {
            XCTAssertGreaterThan(high[i] - low[i], 0.15, "\(label): breathing loop \(i) never visibly changed", file: file, line: line)
        }
    }
    private func assertStill(_ control: PercentSlider, over seconds: TimeInterval, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        // Commit the stop before sampling. Presentation values can still
        // reflect the preceding frame; twinkles intentionally settle to
        // their resting opacity when a loop is removed.
        pump(0.05)
        let angle = control.rotorShownAngle, flow = control.flowProbes.map(\.shown)
        pump(seconds)
        if let angle, let now = control.rotorShownAngle {
            XCTAssertEqual(now, angle, accuracy: 1e-3, "\(label): rotors moved while they should stand still", file: file, line: line)
        }
        for (before, after) in zip(flow, control.flowProbes.map(\.shown)) {
            if let before, let after { XCTAssertEqual(after, before, accuracy: 1e-3, "\(label): flow moved while it should stand still", file: file, line: line) }
        }
    }

    // MARK: Rotors (Channel)

    /// The Channel's rotors visibly turn at RPM/2000 rev/s, re-time without a
    /// jump when the hardware speeds up, are not reset by redundant updates,
    /// freeze in place on hide and resume from there on reopen.
    func testChannelRotorsVisiblyTurnAtTheMeasuredRateAndSurviveReopen() {
        let (window, control) = liveSlider(style: .channel); defer { window.orderOut(nil) }
        XCTAssertEqual(control.effects.ambient, 1, "Explicit Expressive, Reduce Motion off")
        control.setPercent(60, animated: false)
        control.measuredRPM = 1000; control.ambientActive = true
        pump(0.05)
        let travel = assertRotorTurns(control, rps: 0.5, intervals: [0.13, 0.31, 0.07, 0.22, 0.17], "1000 RPM")
        XCTAssertGreaterThan(travel, 2 * .pi * 0.5 * 0.9 * 0.7, "The rotors visibly turned over ~0.9 s")

        // Spin-up: the phase carries on (no jump), then the new rate holds.
        let before = control.rotorShownAngle
        control.measuredRPM = 3000
        CATransaction.flush()
        if let before, let after = control.rotorShownAngle {
            XCTAssertEqual(wrapped(after - before, period: 2 * .pi), 0, accuracy: 0.15, "Re-timing must not jump the phase")
        }
        assertRotorTurns(control, rps: 1.5, intervals: [0.09, 0.14, 0.06, 0.11], "3000 RPM")

        // Redundant model refreshes (same RPM, same value, same visibility)
        // must not restart the animation: motion stays on prediction.
        control.measuredRPM = 3000; control.ambientActive = true; control.setPercent(60, animated: true)
        assertRotorTurns(control, rps: 1.5, intervals: [0.1, 0.13], "after redundant updates")

        // Hide: frozen in place. Reopen: resumes from there at the rate.
        control.prepareForHiding()
        assertStill(control, over: 0.25, "hidden")
        let frozen = control.rotorShownAngle
        control.ambientActive = true
        CATransaction.flush()
        if let frozen, let resumed = control.rotorShownAngle {
            XCTAssertEqual(wrapped(resumed - frozen, period: 2 * .pi), 0, accuracy: 0.15, "Reopening resumes from the frozen angle")
        }
        assertRotorTurns(control, rps: 1.5, intervals: [0.12, 0.08, 0.19], "after reopen")

        // A stopped fan stands the rotors still.
        control.measuredRPM = 0
        assertStill(control, over: 0.2, "0 RPM")
    }

    // MARK: Full-cooling flow (both styles)

    /// At 100% the ice visibly flows in both styles: every scroll travels
    /// at its velocity and every breathing loop changes; hiding freezes it,
    /// reopening resumes it, and a redundant 100% refresh does not reset it.
    func testFullCoolingIceVisiblyFlowsInBothStylesAndSurvivesReopen() {
        for style in SliderStyle.allCases {
            let (window, control) = liveSlider(style: style); defer { window.orderOut(nil) }
            control.setPercent(100, animated: false)
            control.measuredRPM = 4800; control.ambientActive = true
            pump(0.05)
            XCTAssertTrue(control.isIceFlowing, "\(style)")
            assertFlowMoves(control, intervals: [0.11, 0.27, 0.09, 0.33, 0.18, 0.41, 0.15], "\(style) at 100%")

            control.setPercent(100, animated: true); control.ambientActive = true; control.measuredRPM = 4800
            assertFlowMoves(control, intervals: [0.12, 0.2], "\(style) after redundant updates")

            control.prepareForHiding()
            XCTAssertTrue(control.isIceFormed)
            assertStill(control, over: 0.3, "\(style) hidden")
            control.ambientActive = true
            assertFlowMoves(control, intervals: [0.16, 0.24, 0.13, 0.35, 0.21, 0.4], "\(style) after reopen")

            // Subtle flows calmer: the scroll velocity drops with the pace.
            let expressiveSpeed = control.flowProbes.compactMap(\.velocity).map { abs($0) }.max() ?? 0
            control.effects = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
            let subtleSpeed = control.flowProbes.compactMap(\.velocity).map { abs($0) }.max() ?? 0
            XCTAssertLessThan(subtleSpeed, expressiveSpeed * 0.7, "\(style): Subtle is calmer")
            assertFlowMoves(control, intervals: [0.2, 0.3], "\(style) Subtle")
        }
    }

    /// With Reduce Motion the slider is meant to be still: no rotor turns,
    /// no ice flows (the ice itself stays). This is the system setting the
    /// installed app honours.
    func testReduceMotionStandsEverythingStill() {
        for style in SliderStyle.allCases {
            let (window, control) = liveSlider(style: style); defer { window.orderOut(nil) }
            control.setPercent(100, animated: false)
            control.measuredRPM = 4800; control.ambientActive = true
            pump(0.05)
            control.effects = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: true)
            XCTAssertTrue(control.isIceFormed, "\(style): the ice stays")
            XCTAssertFalse(control.isIceFlowing); XCTAssertFalse(control.isRotorSpinning)
            assertStill(control, over: 0.35, "\(style) Reduce Motion")
        }
    }
}
