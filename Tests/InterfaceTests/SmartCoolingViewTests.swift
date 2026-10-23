import AppKit
import XCTest
import ZephyrCore
@testable import Zephyr

@MainActor final class SmartCoolingViewTests: XCTestCase {
    /// VoiceOver hears the speeds this Mac will actually run: never below its
    /// hardware floor (the curve's 0% at rest is the floor here), at the
    /// temperatures the chosen target implies.
    func testSpokenCurveFollowsTheTargetAndTheHardwareFloor() {
        let curve = SmartCurveView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        curve.floor = 21
        XCTAssertTrue(curve.summary.contains("62°C 21%"), curve.summary)
        XCTAssertFalse(curve.summary.contains(" 0%"))
        XCTAssertTrue(curve.summary.contains("80°C 70%"), "A working level at the target")
        XCTAssertTrue(curve.summary.contains("85°C 100%"))
        XCTAssertTrue(curve.summary.hasSuffix("target 80°C"))
        curve.policy = SmartCoolingPolicy.standard.with(target: 70)
        XCTAssertTrue(curve.summary.contains("75°C 100%"), "The target genuinely moves the curve")
        curve.fahrenheit = true
        XCTAssertTrue(curve.summary.hasSuffix("target 158°F"))
    }

    /// The explanation names the real target, headroom and band, in the
    /// user's unit, and never promises a hard cap or a timed cooldown.
    func testExplanationIsTargetDrivenAndHonest() {
        let explainer = SmartCoolingExplainer(frame: NSRect(x: 0, y: 0, width: 312, height: 160))
        explainer.update(policy: SmartCoolingPolicy.standard.with(target: 85), celsius: nil, target: nil, floor: 21, fahrenheit: false)
        let text = explainer.accessibilityValue() as? String ?? ""
        XCTAssertTrue(text.contains("around 85°C"))
        XCTAssertTrue(text.contains("About 70% at the target"))
        XCTAssertTrue(text.contains("full speed 5° above it"))
        XCTAssertTrue(text.contains("1.5° band"))
        XCTAssertFalse(text.contains("before the target"), "Full speed is not reached before the target any more")
        XCTAssertTrue(text.contains("no fan can hold the target"))
        XCTAssertFalse(text.contains(" s "), "No timed cooldown")
        explainer.update(policy: SmartCoolingPolicy.standard.with(target: 85), celsius: nil, target: nil, floor: 21, fahrenheit: true)
        let fahrenheit = explainer.accessibilityValue() as? String ?? ""
        XCTAssertTrue(fahrenheit.contains("185°F"))
        XCTAssertTrue(fahrenheit.contains("full speed 9° above it"))
        XCTAssertTrue(fahrenheit.contains("2.7° band"))
    }

    /// Model refreshes arrive every second while the panel is open; an
    /// unchanged reading or policy must not redraw the graph.
    func testUnchangedInputsDoNotRedraw() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 312, height: 140), styleMask: .borderless, backing: .buffered, defer: false)
        let explainer = SmartCoolingExplainer(frame: NSRect(x: 0, y: 0, width: 312, height: 140))
        window.contentView = explainer
        explainer.layout()
        explainer.update(policy: .standard, celsius: 71.04, target: 46, floor: 21, fahrenheit: false)
        let curve = explainer.subviews.compactMap { $0 as? SmartCurveView }.first!
        curve.displayIfNeeded()
        XCTAssertFalse(curve.needsDisplay)
        explainer.update(policy: .standard, celsius: 71.02, target: 46, floor: 21, fahrenheit: false)
        XCTAssertFalse(curve.needsDisplay, "Same tenth of a degree, same policy: nothing to draw")
        explainer.update(policy: .standard, celsius: 74, target: 52, floor: 21, fahrenheit: false)
        XCTAssertTrue(curve.needsDisplay)
        XCTAssertGreaterThan(explainer.fittingHeight(width: 312), 58)
        XCTAssertLessThan(explainer.fittingHeight(width: 312), 160, "Compact enough for short displays")
    }
}
