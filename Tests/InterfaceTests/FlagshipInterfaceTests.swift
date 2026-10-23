import AppKit
import XCTest
@testable import Zephyr

/// Smart's target on the trend: a fixed mapping for the whole gesture, the
/// scale frozen while dragging, one commit on release (never during the
/// drag), keyboard and VoiceOver steps, and inspection unchanged.
@MainActor final class SmartTargetChartTests: XCTestCase {
    private func chart(target: Double? = 80, samples: [Double] = [62, 64, 66, 65]) -> (TemperatureHistory, () -> [Double]) {
        let view = TemperatureHistory(frame: NSRect(x: 0, y: 0, width: 144, height: 46 + TemperatureHistory.readoutBand))
        view.samples = samples
        view.smartTarget = target
        var commits: [Double] = []
        view.targetCommitted = { commits.append($0) }
        return (view, { commits })
    }

    func testTargetLineIsGrabbableAndAdjustableForVoiceOver() {
        let (view, _) = chart()
        XCTAssertFalse(view.handleFrame.isEmpty)
        XCTAssertTrue(view.grabsTarget(at: NSPoint(x: view.handleFrame.midX, y: view.handleFrame.midY)))
        XCTAssertFalse(view.grabsTarget(at: NSPoint(x: 20, y: view.handleFrame.midY + 20)), "Away from the line the chart stays an inspector")
        XCTAssertEqual(view.accessibilityRole(), .group)
        let element = view.accessibilityChildren()?.first as? NSAccessibilityElement
        XCTAssertEqual(element?.accessibilityRole(), .slider)
        XCTAssertEqual(element?.accessibilityLabel(), "Smart target")
        XCTAssertEqual(element?.isAccessibilityEnabled(), true)
        XCTAssertEqual(element?.accessibilityValueDescription(), "80 degrees Celsius")
        XCTAssertEqual(view.accessibilityLabel(), "Recent temperature, 62 to 66 °C, now 65", "The trend's description is unchanged")
    }

    /// Dragging writes nothing until release; the scale stays frozen while
    /// samples arrive; release commits once.
    func testDragCommitsOnceOnReleaseWithAFrozenScale() {
        let (view, commits) = chart()
        let y = view.handleFrame.midY
        view.beginScrub(at: y, target: 80)
        view.moveScrub(to: y + 8)
        XCTAssertEqual(view.draggedTarget, 82)
        view.moveScrub(to: y + 60)
        XCTAssertEqual(view.draggedTarget, 95, "Clamped to Smart's range")
        XCTAssertTrue(commits().isEmpty, "Nothing is stored during the drag")
        let frame = view.handleFrame
        view.samples = [88, 92, 99, 101]
        XCTAssertEqual(view.handleFrame, frame, "A new sample never rescales the chart under the pointer")
        XCTAssertFalse(view.isInspecting, "Inspection pauses while dragging")
        view.endScrub()
        XCTAssertEqual(commits(), [95])
        XCTAssertNil(view.draggedTarget)
    }

    func testAGrabWithoutAChangeStoresNothingAndHidingAbandons() {
        let (view, commits) = chart()
        view.beginScrub(at: 10, target: 80); view.moveScrub(to: 11); view.endScrub()
        XCTAssertTrue(commits().isEmpty)
        view.beginScrub(at: 10, target: 80); view.moveScrub(to: 30)
        view.endInspection()
        XCTAssertNil(view.draggedTarget); XCTAssertTrue(commits().isEmpty, "Hiding mid-drag stores nothing")
    }

    func testKeysVoiceOverAndFahrenheitStepWholeDegrees() {
        let (view, commits) = chart()
        view.stepTarget(by: 1)
        XCTAssertEqual(commits(), [81])
        let element = view.accessibilityChildren()?.first as? NSAccessibilityElement
        XCTAssertEqual(element?.accessibilityPerformDecrement(), true)
        XCTAssertEqual(commits(), [81, 79])
        view.fahrenheit = true
        XCTAssertEqual(element?.accessibilityValueDescription(), "176 degrees Fahrenheit")
        view.stepTarget(by: 1)
        XCTAssertEqual(commits().last!, (177 - 32) / 1.8, accuracy: 1e-9)
    }

    func testTargetRepositionsWhenSamplesRescaleTheGraph() {
        let (view, _) = chart()
        let previousY = view.handleFrame.midY
        view.samples = [85, 90, 94]
        XCTAssertLessThan(view.handleFrame.midY, previousY, "The line and the newly scaled plot must agree")
    }

    func testModeOrUnitChangeCancelsDragAndAXIsNumeric() {
        let (view, commits) = chart()
        let element = view.accessibilityChildren()?.first as? NSAccessibilityElement
        XCTAssertEqual((element?.accessibilityValue() as? NSNumber)?.intValue, 80)
        element?.setAccessibilityValue(NSNumber(value: 83))
        XCTAssertEqual(commits(), [83])
        view.beginScrub(at: 10, target: 80); view.moveScrub(to: 30)
        view.smartTarget = nil; view.endScrub()
        XCTAssertNil(view.shownTarget)
        XCTAssertEqual(commits(), [83])
        view.smartTarget = 80
        view.beginScrub(at: 10, target: 80); view.moveScrub(to: 30)
        view.fahrenheit = true; view.endScrub()
        XCTAssertEqual(commits(), [83])
    }

    /// Smart off: no line, nothing to grab, the original image element, and
    /// inspection exactly as before.
    func testWithoutSmartTheChartIsUnchanged() {
        let (view, commits) = chart(target: nil)
        XCTAssertTrue(view.handleFrame.isEmpty)
        XCTAssertFalse(view.grabsTarget(at: NSPoint(x: 70, y: 20)))
        XCTAssertEqual(view.accessibilityRole(), .image)
        XCTAssertNil(view.accessibilityChildren())
        view.stepTarget(by: 1)
        XCTAssertTrue(commits().isEmpty)
        view.inspect(atX: 3)
        XCTAssertEqual(view.inspectedIndex, 0)
    }
}

/// The introduction's cards and the key hints.
@MainActor final class OnboardingCardTests: XCTestCase {
    func testWelcomeOffersTwoChoices() {
        var chosen: [String] = []
        let card = WelcomeCard(control: { chosen.append("control") }, temperatureOnly: { chosen.append("temperature") })
        card.frame = NSRect(x: 0, y: 0, width: 312, height: WelcomeCard.height); card.layout()
        XCTAssertLessThanOrEqual(card.controlButton.frame.maxX, card.temperatureButton.frame.minX)
        card.controlButton.performClick(nil); card.temperatureButton.performClick(nil)
        XCTAssertEqual(chosen, ["control", "temperature"])
    }

    /// The glance shows only a real reading.
    func testGlanceShowsTheMeasuredSpeedOrNothing() {
        let glance = FanGlance(frame: NSRect(x: 0, y: 0, width: 312, height: 44))
        glance.show(measuredPercent: 34.4, animated: false)
        XCTAssertEqual(glance.accessibilityValue() as? String, "34 percent")
        glance.show(measuredPercent: nil, animated: false)
        XCTAssertEqual(glance.accessibilityValue() as? String, "unavailable")
    }

    /// Approval names the real action; "Connected" carries the measured
    /// speed; each mode's button does its own thing.
    func testSetupCardSaysWhatToDoThenConnected() {
        let card = SetupCard(frame: NSRect(x: 0, y: 0, width: 312, height: SetupCard.height))
        var events: [String] = []
        card.open = { events.append("open") }; card.done = { events.append("done") }
        card.show(.approval(connecting: false))
        XCTAssertEqual(card.accessibilityLabel(), "Allow in Login Items, Waiting for approval")
        card.actionButton.performClick(nil)
        card.show(.connected(measuredPercent: 34))
        XCTAssertEqual(card.accessibilityLabel(), "Connected, Fan 34%")
        card.actionButton.performClick(nil)
        XCTAssertEqual(events, ["open", "done"])
    }

    func testApprovalInstructionFitsTheCompactPanel() {
        let card = SetupCard(frame: NSRect(x: 0, y: 0, width: 312, height: SetupCard.height))
        card.show(.approval(connecting: false)); card.layout()
        for label in card.subviews.compactMap({ $0 as? NSTextField }) {
            XCTAssertLessThanOrEqual(label.attributedStringValue.size().width, label.frame.width)
        }
    }

    func testKeyHintsAppearAndClear() {
        let hints = KeyHintsView(frame: NSRect(x: 0, y: 0, width: 344, height: 300))
        hints.show([(NSRect(x: 10, y: 10, width: 60, height: 28), "A"), (NSRect(x: 80, y: 10, width: 60, height: 28), "S")])
        XCTAssertEqual(hints.shown, ["A", "S"])
        XCTAssertNil(hints.hitTest(NSPoint(x: 20, y: 20)), "Hints never take the pointer")
        hints.show([])
        XCTAssertTrue(hints.shown.isEmpty)
    }
}

@MainActor final class MonitoringPanelTests: XCTestCase {
    func testTemperatureOnlyCannotFocusOrAdjustTheHiddenFanSlider() {
        let name = "Aervane.MonitoringPanelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults, startsServices: false)
        let reader = TelemetryReader(cpu: { (68, 74) }, fan: { .single(current: 2000, minimum: 1000, maximum: 4900) }, gpu: { 60 })
        model.acceptTelemetry(reader.read(wantsGPU: false), sensor: "CPU")
        let flow = OnboardingFlow(store: OnboardingStore(defaults: defaults), helperRegistered: false)
        flow.handle(.chooseTemperatureOnly)
        let panel = PanelView(model: model, onboarding: flow)
        XCTAssertTrue(panel.preferredFirstResponder === panel)
        XCTAssertTrue(panel.acceptsFirstResponder)
        func sliders(_ view: NSView) -> [PercentSlider] {
            (view as? PercentSlider).map { [$0] } ?? view.subviews.flatMap(sliders)
        }
        let slider = sliders(panel).first!
        XCTAssertFalse(slider.isEnabled)
        slider.setAccessibilityValue(NSNumber(value: 100))
        XCTAssertNil(model.requestedPercent)
    }
}
