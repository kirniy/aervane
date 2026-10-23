import AppKit
import XCTest
@testable import Zephyr

/// The Dot Grid's all-speed wave, proven on screen: presentation layers are
/// sampled at irregular wall-clock intervals and compared with the velocity
/// the fan's *measured* speed should produce (`DotVitality`). Attaching an
/// animation is not enough to pass.
///
/// Effects are set explicitly (Expressive, Reduce Motion and Reduce
/// Transparency off) so results do not depend on the Mac's settings. The
/// window is ordered front so presentation layers exist.
@MainActor final class DotVitalityProgressionTests: XCTestCase {
    private let expressive = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
    private let maximum = 4900.0

    private func liveDotGrid() -> (NSWindow, PercentSlider) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let control = PercentSlider(frame: NSRect(x: 4, y: 24, width: 372, height: DotGridGeometry.frameHeight))
        window.contentView!.addSubview(control)
        control.style = .dotGrid
        control.effects = expressive
        control.minimumPercent = 21
        control.setPercent(76, animated: false)
        control.maximumRPM = maximum
        window.orderFrontRegardless()
        control.updateLayer()
        control.displayIfNeeded()
        pump(0.05)
        return (window, control)
    }
    private func pump(_ seconds: TimeInterval) {
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        CATransaction.flush()
    }
    private func wrapped(_ delta: Double, period: Double) -> Double {
        var d = delta.truncatingRemainder(dividingBy: period)
        if d > period / 2 { d -= period }
        if d <= -period / 2 { d += period }
        return d
    }

    /// Samples the wave at irregular intervals; each step must match the
    /// velocity for `rpm` (modulo one band). Returns the observed speed.
    @discardableResult
    private func assertWaveMoves(_ control: PercentSlider, rpm: Double, intervals: [TimeInterval], _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) -> Double {
        let expectedVelocity = DotVitality.velocity(fraction: DotVitality.fraction(rpm: rpm, maximumRPM: maximum))
        guard let probe = control.vitalityProbes.first, var last = probe.shown, let period = probe.period else {
            XCTFail("\(label): no presentation for the wave (layer tree not committed)", file: file, line: line); return 0
        }
        XCTAssertEqual(Double(probe.velocity ?? 0), expectedVelocity, accuracy: expectedVelocity * DotVitality.retimeTolerance + 0.01,
                       "\(label): the wave runs at the measured pace", file: file, line: line)
        var lastTime = CACurrentMediaTime(), travel = 0.0, elapsed = 0.0
        for interval in intervals {
            pump(interval)
            let now = CACurrentMediaTime()
            guard let value = control.vitalityProbes.first?.shown else { XCTFail("\(label): presentation vanished", file: file, line: line); return 0 }
            let step = wrapped(value - last, period: Double(period)), expected = expectedVelocity * (now - lastTime)
            XCTAssertEqual(step, expected, accuracy: max(1.5, expected * 0.35),
                           "\(label): wave moved \(step) pt in \(now - lastTime) s, expected \(expected)", file: file, line: line)
            travel += step; elapsed += now - lastTime; last = value; lastTime = now
        }
        XCTAssertGreaterThan(travel, 0, "\(label): the wave travels toward the handle", file: file, line: line)
        return elapsed > 0 ? travel / elapsed : 0
    }
    private func assertStill(_ control: PercentSlider, over seconds: TimeInterval, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        pump(0.05)
        XCTAssertFalse(control.isWaving, "\(label): the wave should stand still", file: file, line: line)
        let before = control.vitalityProbes.first?.shown
        pump(seconds)
        if let before, let after = control.vitalityProbes.first?.shown {
            XCTAssertEqual(after, before, accuracy: 1e-3, "\(label): the wave moved while it should stand still", file: file, line: line)
        }
    }

    /// Low, middle and high measured speeds: the wave visibly travels at
    /// each, and faster as the fan works harder.
    func testWaveTravelsAtTheMeasuredPaceAtLowMiddleAndHighSpeeds() {
        let (window, control) = liveDotGrid(); defer { window.orderOut(nil) }
        control.ambientActive = true
        var speeds: [Double] = []
        for rpm in [1000.0, 2900, 4900] {
            control.measuredRPM = rpm
            pump(0.05)
            XCTAssertTrue(control.isWaving, "\(Int(rpm)) RPM")
            speeds.append(assertWaveMoves(control, rpm: rpm, intervals: [0.11, 0.23, 0.07, 0.29, 0.16], "\(Int(rpm)) RPM"))
        }
        XCTAssertLessThan(speeds[0], speeds[1]); XCTAssertLessThan(speeds[1], speeds[2])
        XCTAssertGreaterThan(speeds[0], 15, "Even the firmware idle visibly moves")
    }

    /// Spin-up re-times without a jump; sample jitter does not re-time;
    /// Subtle keeps the same pace.
    func testWaveRetimesPhaseContinuouslyAndIgnoresJitter() {
        let (window, control) = liveDotGrid(); defer { window.orderOut(nil) }
        control.measuredRPM = 1200; control.ambientActive = true
        pump(0.1)
        let before = control.vitalityProbes.first?.shown
        control.measuredRPM = 4700
        CATransaction.flush()
        if let before, let after = control.vitalityProbes.first?.shown, let period = control.vitalityProbes.first?.period {
            XCTAssertEqual(wrapped(after - before, period: Double(period)), 0, accuracy: 3, "Re-timing must not jump the wave")
        }
        assertWaveMoves(control, rpm: 4700, intervals: [0.09, 0.14, 0.12], "spun up")
        let velocity = control.vitalityProbes.first?.velocity
        control.measuredRPM = 4720
        XCTAssertEqual(control.vitalityProbes.first?.velocity, velocity, "RPM jitter does not re-time the wave")
        assertWaveMoves(control, rpm: 4700, intervals: [0.1, 0.13], "after jitter")
        control.effects = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(control.vitalityProbes.first?.velocity, velocity, "Subtle changes presence, never the pace")
        assertWaveMoves(control, rpm: 4700, intervals: [0.12, 0.17], "Subtle")
    }

    /// Every reason to stop freezes the wave in place; reopening resumes it.
    func testWaveFreezesForEveryStopAndResumesOnReopen() {
        let (window, control) = liveDotGrid(); defer { window.orderOut(nil) }
        control.measuredRPM = 2900
        XCTAssertFalse(control.isWaving, "Hidden: nothing runs")
        control.ambientActive = true; pump(0.05)
        assertWaveMoves(control, rpm: 2900, intervals: [0.12, 0.2], "shown")

        control.prepareForHiding(); assertStill(control, over: 0.25, "hidden")
        control.ambientActive = true; pump(0.05)
        assertWaveMoves(control, rpm: 2900, intervals: [0.15, 0.1], "reopened")
        control.ambientActive = false; assertStill(control, over: 0.2, "Settings open")
        control.ambientActive = true; pump(0.05)

        control.measuredRPM = 0; assertStill(control, over: 0.2, "a stopped fan")
        control.measuredRPM = nil; assertStill(control, over: 0.2, "unknown speed")
        control.measuredRPM = 2900; pump(0.05); XCTAssertTrue(control.isWaving)
        control.isUnavailable = true; assertStill(control, over: 0.2, "stale telemetry")
        control.isUnavailable = false; control.isEnabled = false; assertStill(control, over: 0.2, "disabled")
        control.isEnabled = true
        control.effects = EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false); assertStill(control, over: 0.2, "Effects Off")
        control.effects = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false); assertStill(control, over: 0.2, "Reduce Motion")
        control.effects = expressive; pump(0.05)
        assertWaveMoves(control, rpm: 2900, intervals: [0.11, 0.19], "allowed again")
        control.removeFromSuperview(); XCTAssertFalse(control.isWaving, "Detached")
    }

    /// The Channel has no wave (its rotors carry the measured speed), and
    /// the Dot Grid keeps its existing full-cooling flow at 100%.
    func testWaveBelongsToTheDotGridAndCoexistsWithFullCoolingFlow() {
        let (window, control) = liveDotGrid(); defer { window.orderOut(nil) }
        control.measuredRPM = 4900; control.ambientActive = true
        control.setPercent(100, animated: false); pump(0.05)
        XCTAssertTrue(control.isWaving); XCTAssertTrue(control.isIceFlowing, "Frost and its flow only at 100%")
        control.setPercent(76, animated: false); pump(0.05)
        XCTAssertTrue(control.isWaving); XCTAssertFalse(control.isIceFlowing, "Below 100% the wave remains, the ice does not")
        control.style = .channel; pump(0.05)
        XCTAssertFalse(control.isWaving); XCTAssertTrue(control.vitalityProbes.isEmpty)
        XCTAssertTrue(control.isRotorSpinning)
    }
}
