import AppKit
import XCTest
@testable import Zephyr

@MainActor final class PercentSliderTests: XCTestCase {
    func testLayerContentSurvivesZeroSizeThenLayout() {
        _ = NSApplication.shared
        let control = PercentSlider(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSView(frame: window.contentView!.bounds)
        host.wantsLayer = true
        window.contentView = host
        host.addSubview(control)
        control.updateLayer()
        control.frame = NSRect(x: 4, y: 30, width: 372, height: 32)
        host.layoutSubtreeIfNeeded()
        control.displayIfNeeded()
        // The channel first, thumb always topmost.
        XCTAssertEqual(control.layer?.sublayers?.count, 12)
        XCTAssertNotNil(control.layer?.sublayers?.first?.contents)
        XCTAssertEqual(control.layer?.sublayers?.last?.bounds.size, PercentSlider.thumbSize)
        XCTAssertEqual(PercentSlider.thumbSize, NSSize(width: 12, height: 24))
    }

    func testPointerTrackingPreviewsContinuouslyAndCommitsOnceOnRelease() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let control = PercentSlider(frame: NSRect(x: 4, y: 30, width: 372, height: 32))
        window.contentView!.addSubview(control)
        control.minimumPercent = 21
        control.percent = 60
        var previews: [Double] = [], commits: [Double] = []
        control.preview = { previews.append($0) }
        control.commit = { commits.append($0) }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: control.convert(NSPoint(x: x, y: 16), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        control.mouseDown(with: event(.leftMouseDown, 180))
        control.mouseDragged(with: event(.leftMouseDragged, 280))
        XCTAssertTrue(control.dragging)
        XCTAssertGreaterThan(control.percent, 70)
        XCTAssertTrue(commits.isEmpty)
        control.mouseDragged(with: event(.leftMouseDragged, -20))
        XCTAssertEqual(control.percent, 21)
        control.mouseUp(with: event(.leftMouseUp, -20))
        XCTAssertFalse(control.dragging)
        XCTAssertEqual(commits, [21])
        XCTAssertGreaterThanOrEqual(previews.count, 3)
    }

    func testAccessibilityValueCommitsAndRespectsHardwareFloor() {
        let control = PercentSlider(frame: NSRect(x: 0, y: 0, width: 372, height: 32))
        control.minimumPercent = 21
        var commits: [Double] = []
        control.commit = { commits.append($0) }
        control.setAccessibilityValue(NSNumber(value: 0))
        XCTAssertEqual(control.accessibilityValue() as? NSNumber, 21)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(commits, [21])
        control.isEnabled = false
        control.setAccessibilityValue(NSNumber(value: 100))
        XCTAssertEqual(control.percent, 21)
    }

    private func hostedSlider() -> (NSWindow, PercentSlider) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let control = PercentSlider(frame: NSRect(x: 4, y: 30, width: 372, height: 34))
        window.contentView!.addSubview(control)
        control.effects = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
        control.minimumPercent = 21
        control.displayIfNeeded()
        return (window, control)
    }

    func testIceCrownFormsAtMaximumAndMeltsWhenLowered() {
        let (window, control) = hostedSlider(); _ = window
        control.setPercent(99, animated: false)
        XCTAssertFalse(control.isIceFormed)
        control.setPercent(100, animated: true, celebrate: true)
        XCTAssertTrue(control.isIceFormed)
        XCTAssertGreaterThan(control.transientAnimationCount, 0, "A user reaching full cooling plays the formation")
        control.setPercent(70, animated: false)
        XCTAssertFalse(control.isIceFormed)
    }

    func testPointerDragToMaximumFormsIceWithoutLaggingTheThumb() {
        let (window, control) = hostedSlider()
        control.setPercent(60, animated: false)
        func event(_ type: NSEvent.EventType, percent: Double) -> NSEvent {
            let x = PercentSlider.trackX(percent: percent, width: control.bounds.width)
            return NSEvent.mouseEvent(with: type, location: control.convert(NSPoint(x: x, y: 17), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        control.mouseDown(with: event(.leftMouseDown, percent: 60))
        control.mouseDragged(with: event(.leftMouseDragged, percent: 100))
        XCTAssertEqual(control.percent, 100)
        XCTAssertNil(control.layer?.sublayers?.last?.animation(forKey: "position"), "Pointer tracking must remain immediate")
        XCTAssertTrue(control.layer?.sublayers?.contains { $0.mask?.animation(forKey: "form") != nil } == true,
                      "Reaching full cooling by dragging should form ice, just like choosing Boost")
        control.mouseDragged(with: event(.leftMouseDragged, percent: 70))
        XCTAssertFalse(control.isIceFormed)
        control.mouseUp(with: event(.leftMouseUp, percent: 70))
    }

    /// Keyboard and VoiceOver changes are instant: no glide, no formation.
    func testKeyboardReachesMaximumInstantly() {
        let (window, control) = hostedSlider(); _ = window
        control.setPercent(95, animated: false)
        control.prepareForHiding()
        XCTAssertTrue(control.accessibilityPerformIncrement())
        XCTAssertEqual(control.percent, 100)
        XCTAssertTrue(control.isIceFormed)
        XCTAssertEqual(control.transientAnimationCount, 0)
    }

    func testModelRefreshShowsIceWithoutFormationAnimation() {
        let (window, control) = hostedSlider(); _ = window
        control.prepareForHiding()
        control.setPercent(100, animated: true, celebrate: false)
        XCTAssertTrue(control.isIceFormed)
        control.prepareForHiding()
        XCTAssertTrue(control.isIceFormed, "Formed ice is static state and survives hiding")
        XCTAssertEqual(control.transientAnimationCount, 0)
    }

    func testEffectsOffOrReducedMotionGovernIce() {
        let (window, control) = hostedSlider(); _ = window
        control.setPercent(100, animated: false)
        XCTAssertTrue(control.isIceFormed)
        control.effects = EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false)
        XCTAssertFalse(control.isIceFormed, "Turning effects off melts the crown immediately")
        control.setPercent(60, animated: false); control.setPercent(100, animated: true, celebrate: true)
        XCTAssertFalse(control.isIceFormed)
        control.effects = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false)
        control.setPercent(60, animated: false); control.prepareForHiding()
        control.setPercent(100, animated: true, celebrate: true)
        XCTAssertTrue(control.isIceFormed, "Reduce Motion keeps the ice, without movement")
        XCTAssertEqual(control.transientAnimationCount, 0)
    }

    /// The formation is one sequence (front + glint) that hiding settles,
    /// leaving the formed crystals as static state.
    func testFormationGlintIsTransientAndHidingSettlesIt() {
        let (window, control) = hostedSlider(); _ = window
        control.setPercent(80, animated: false)
        control.setPercent(100, animated: true, celebrate: true)
        XCTAssertTrue(control.layer?.sublayers?.contains { $0.animation(forKey: "glint") != nil } == true)
        control.prepareForHiding()
        XCTAssertTrue(control.isIceFormed)
        XCTAssertEqual(control.transientAnimationCount, 0)
        // A refresh at 100% while hidden never replays the formation.
        control.setPercent(100, animated: false)
        XCTAssertEqual(control.transientAnimationCount, 0)
    }

    private func drag(_ control: PercentSlider, in window: NSWindow, _ path: [(percent: Double, time: TimeInterval)]) {
        func event(_ type: NSEvent.EventType, _ percent: Double, _ time: TimeInterval) -> NSEvent {
            let x = PercentSlider.trackX(percent: percent, width: control.bounds.width)
            return NSEvent.mouseEvent(with: type, location: control.convert(NSPoint(x: x, y: 17), to: nil), modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        guard let first = path.first else { return }
        control.mouseDown(with: event(.leftMouseDown, first.percent, first.time))
        for step in path.dropFirst() { control.mouseDragged(with: event(.leftMouseDragged, step.percent, step.time)) }
    }
    private func thumbTilt(_ control: PercentSlider) -> CALayer? { control.layer?.sublayers?.last?.sublayers?.first }

    /// A fast drag leans the thumb and leaves a wake, yet the value and the
    /// thumb position are already where the pointer is.
    func testFastDragReactsWithoutLaggingTheValue() {
        let (window, control) = hostedSlider()
        control.setPercent(40, animated: false); control.prepareForHiding()
        drag(control, in: window, [(40, 10.0), (55, 10.016), (70, 10.032)])
        XCTAssertEqual(control.percent, 70)
        XCTAssertNil(control.layer?.sublayers?.last?.animation(forKey: "position"))
        XCTAssertNotNil(thumbTilt(control)?.animation(forKey: "surge.lean"), "Speed leans the thumb")
        XCTAssertTrue(control.layer?.sublayers?.contains { $0.animation(forKey: "wake") != nil } == true, "A fast thumb leaves a wake")
        control.prepareForHiding()
        XCTAssertEqual(control.transientAnimationCount, 0)
        XCTAssertFalse(control.dragging)
    }

    func testSlowDragStaysStill() {
        let (window, control) = hostedSlider()
        control.setPercent(40, animated: false); control.prepareForHiding()
        // One percent per 100 ms is ~33 pt/s: below the speed dead zone.
        drag(control, in: window, [(40, 1.0), (41, 1.1), (42, 1.2)])
        XCTAssertEqual(control.percent, 42)
        XCTAssertNil(thumbTilt(control)?.animation(forKey: "surge.lean"))
        XCTAssertFalse(control.layer?.sublayers?.contains { $0.animation(forKey: "wake") != nil } == true)
        control.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: control.convert(NSPoint(x: PercentSlider.trackX(percent: 42, width: control.bounds.width), y: 17), to: nil), modifierFlags: [], timestamp: 1.3, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    func testEffectsLevelsScaleDragReactions() {
        let (window, control) = hostedSlider()
        control.effects = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
        control.setPercent(40, animated: false); control.prepareForHiding()
        drag(control, in: window, [(40, 2.0), (60, 2.016)])
        XCTAssertNotNil(thumbTilt(control)?.animation(forKey: "surge.lean"), "Subtle keeps a gentler lean")
        XCTAssertFalse(control.layer?.sublayers?.contains { $0.animation(forKey: "wake") != nil || $0.animation(forKey: "ripple") != nil } == true,
                       "Wake and ripples are Expressive only")
        control.prepareForHiding()
        control.effects = EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false)
        drag(control, in: window, [(40, 3.0), (60, 3.016)])
        XCTAssertEqual(control.percent, 60)
        XCTAssertNil(thumbTilt(control)?.animation(forKey: "surge.lean"), "Off has no speed reactions")
        control.prepareForHiding()
        control.effects = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false)
        drag(control, in: window, [(40, 4.0), (60, 4.016), (90, 4.032)])
        XCTAssertEqual(control.percent, 90)
        XCTAssertEqual(control.transientAnimationCount, 0, "Reduce Motion: the value moves, nothing else does")
        control.prepareForHiding()
    }

    /// Lowering by drag melts frost back behind the thumb; the coolant (the
    /// requested value) never lags.
    func testFrostMeltsBehindALoweringDragWhileCoolantTracks() {
        let (window, control) = hostedSlider()
        control.setPercent(90, animated: false); control.prepareForHiding()
        drag(control, in: window, [(90, 5.0), (60, 5.05)])
        let animatedMasks = control.layer?.sublayers?.filter { $0.mask?.animation(forKey: "bounds") != nil } ?? []
        XCTAssertEqual(animatedMasks.count, 1, "Only the frost reveal trails; the coolant fill is immediate")
        control.prepareForHiding()
        XCTAssertEqual(control.transientAnimationCount, 0)
    }

    // MARK: Slider styles

    /// Dot Grid restores the original layer stack: lattice first, the slim
    /// 6×20 white handle on top.
    func testDotGridRestoresTheOriginalLattice() {
        let (window, control) = hostedSlider(); _ = window
        control.style = .dotGrid
        XCTAssertEqual(control.layer?.sublayers?.count, 10)
        XCTAssertNotNil(control.layer?.sublayers?.first?.contents)
        XCTAssertEqual(control.layer?.sublayers?.last?.bounds.size, NSSize(width: 6, height: 20))
        XCTAssertEqual(control.currentThumbSize, DotGridGeometry.thumb)
        XCTAssertEqual(control.layer?.sublayers?.last?.position.x, PercentSlider.trackX(percent: control.percent, width: control.bounds.width, style: .dotGrid))
        control.style = .channel
        XCTAssertEqual(control.layer?.sublayers?.count, 12)
        XCTAssertEqual(control.layer?.sublayers?.last?.bounds.size, PercentSlider.thumbSize)
    }

    /// Switching style is presentation-only: no preview, no commit, the same
    /// value, floor, measured mark, enabled state and accessibility, no
    /// leftover animation, and full-cooling ice shown statically.
    func testSwitchingStyleNeverCommandsTheFanAndKeepsState() {
        let (window, control) = hostedSlider(); _ = window
        var previews: [Double] = [], commits: [Double] = []
        control.preview = { previews.append($0) }; control.commit = { commits.append($0) }
        control.setPercent(64, animated: false)
        control.measuredPercent = 90
        let spoken = control.accessibilityValueDescription(), tip = control.toolTip
        for style in [SliderStyle.dotGrid, .channel, .dotGrid] {
            control.style = style
            XCTAssertEqual(control.percent, 64)
            XCTAssertEqual(control.minimumPercent, 21)
            XCTAssertEqual(control.accessibilityValueDescription(), spoken)
            XCTAssertEqual(control.toolTip, tip)
            XCTAssertEqual(control.transientAnimationCount, 0, "Switching settles every transient")
        }
        control.setPercent(100, animated: true, celebrate: true)
        control.style = .channel
        XCTAssertTrue(control.isIceFormed, "Formed ice carries over as static state")
        XCTAssertEqual(control.transientAnimationCount, 0)
        control.isEnabled = false; control.isUnavailable = true
        control.style = .dotGrid
        XCTAssertFalse(control.isEnabled); XCTAssertEqual(control.alphaValue, 0.45)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(previews.isEmpty); XCTAssertTrue(commits.isEmpty, "A style change must never reach the hardware")
    }

    /// Both styles share one input path: the same drag previews, commits once
    /// and respects the hardware floor; keys stay instant.
    func testDotGridSharesInputAndIceRules() {
        let (window, control) = hostedSlider()
        control.style = .dotGrid
        control.setPercent(60, animated: false)
        var commits: [Double] = []
        control.commit = { commits.append($0) }
        func event(_ type: NSEvent.EventType, percent: Double) -> NSEvent {
            let x = PercentSlider.trackX(percent: percent, width: control.bounds.width, style: .dotGrid)
            return NSEvent.mouseEvent(with: type, location: control.convert(NSPoint(x: x, y: 17), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        control.mouseDown(with: event(.leftMouseDown, percent: 60))
        control.mouseDragged(with: event(.leftMouseDragged, percent: 100))
        XCTAssertEqual(control.percent, 100)
        XCTAssertNil(control.layer?.sublayers?.last?.animation(forKey: "position"))
        XCTAssertTrue(control.layer?.sublayers?.contains { $0.mask?.animation(forKey: "form") != nil } == true)
        control.mouseDragged(with: event(.leftMouseDragged, percent: 0))
        XCTAssertEqual(control.percent, 21)
        control.mouseUp(with: event(.leftMouseUp, percent: 0))
        XCTAssertEqual(commits, [21])
        control.prepareForHiding()
        XCTAssertEqual(control.transientAnimationCount, 0)
        control.setPercent(95, animated: false)
        XCTAssertTrue(control.accessibilityPerformIncrement())
        XCTAssertEqual(control.percent, 100)
        XCTAssertTrue(control.isIceFormed)
        XCTAssertEqual(control.transientAnimationCount, 0, "Keys stay instant in every style")
    }

    func testMeasuredSpeedIsSpokenWhenItDiffersFromTheRequest() {
        let (window, control) = hostedSlider(); _ = window
        control.setPercent(60, animated: false)
        control.measuredPercent = 97
        XCTAssertEqual(control.accessibilityValueDescription(), "60 percent of maximum fan speed, fan now 97 percent")
        XCTAssertEqual(control.toolTip, "Fan now 97%")
        control.measuredPercent = 61
        XCTAssertNil(control.toolTip)
    }
}

@MainActor final class ModeSwitchTests: XCTestCase {
    func testPillFollowsModeAndButtonsKeepTheirLabels() {
        let auto = SoftButton("Auto") {}, manual = SoftButton("Manual") {}
        auto.setAccessibilityLabel("Restore automatic fan control"); manual.setAccessibilityLabel("Manual fan control")
        let control = ModeSwitch(auto: auto, manual: manual)
        control.frame = NSRect(x: 0, y: 0, width: 128, height: 28); control.layout()
        control.mode = .automatic
        XCTAssertTrue(auto.selected); XCTAssertFalse(manual.selected)
        XCTAssertEqual(auto.accessibilityRole(), .radioButton)
        XCTAssertEqual(auto.accessibilityValue() as? NSNumber, true)
        XCTAssertEqual(manual.accessibilityValue() as? NSNumber, false)
        control.mode = .manual; control.pending = true
        XCTAssertTrue(manual.selected); XCTAssertFalse(auto.selected)
        XCTAssertEqual(auto.accessibilityValue() as? NSNumber, false)
        XCTAssertEqual(manual.accessibilityValue() as? NSNumber, true)
        control.mode = .none
        XCTAssertFalse(auto.selected || manual.selected)
        XCTAssertEqual(auto.accessibilityLabel(), "Restore automatic fan control")
        XCTAssertEqual(manual.accessibilityLabel(), "Manual fan control")
    }
}

@MainActor final class TemperatureHistoryTests: XCTestCase {
    private func chart(_ samples: [Double]) -> TemperatureHistory {
        let view = TemperatureHistory(frame: NSRect(x: 0, y: 0, width: 124, height: 40 + TemperatureHistory.readoutBand))
        view.samples = samples
        return view
    }

    func testInspectionReadsTheNearestSampleAndFollowsNewSamples() {
        let view = chart([60, 61, 62, 98.8, 63])
        view.inspect(atX: 0)
        XCTAssertEqual(view.inspectedIndex, 0)
        view.inspect(atX: 124)
        XCTAssertEqual(view.inspectedIndex, 4)
        view.inspect(atX: 3 + 118 * 0.75)
        XCTAssertEqual(view.inspectedIndex, 3, "Pointing at the spike reads the spike")
        // The pointer stays put while history scrolls; the readout follows the data under it.
        view.samples = [61, 62, 98.8, 63, 64]
        XCTAssertEqual(view.inspectedIndex, 3)
        view.inspect(atX: nil)
        XCTAssertFalse(view.isInspecting)
    }

    func testNothingToInspectWithoutATrendAndHidingEndsInspection() {
        let view = chart([70])
        view.inspect(atX: 60)
        XCTAssertFalse(view.isInspecting, "A single sample has no trend to inspect")
        view.samples = [70, 71]
        view.inspect(atX: 60)
        XCTAssertTrue(view.isInspecting)
        view.endInspection()
        XCTAssertFalse(view.isInspecting)
        view.samples = []
        XCTAssertFalse(view.isInspecting)
    }

    func testTrendIsDescribedForVoiceOver() {
        let view = chart([64.2, 78.4, 73.1])
        XCTAssertEqual(view.accessibilityLabel(), "Recent temperature, 64 to 78 °C, now 73")
        view.fahrenheit = true
        XCTAssertEqual(view.accessibilityLabel(), "Recent temperature, 148 to 173 °F, now 164")
        XCTAssertEqual(chart([]).accessibilityLabel(), "Recent temperature trend")
    }
}

@MainActor final class PresetEditorRowTests: XCTestCase {
    func testRowLaysOutLongNamesWithoutCoveringTheSpeedOrDelete() {
        let row = PresetEditorRow(index: 0) {}
        row.frame = NSRect(x: 0, y: 0, width: 312, height: PresetEditorRow.height)
        row.configure(name: "An overnight render", percent: 100, position: 1)
        row.layout()
        XCTAssertLessThanOrEqual(row.name.frame.maxX, row.value.frame.minX)
        XCTAssertLessThanOrEqual(row.value.frame.maxX, row.remove.frame.minX)
        XCTAssertLessThanOrEqual(row.remove.frame.maxX, row.bounds.maxX)
        XCTAssertGreaterThanOrEqual(row.value.frame.width, ceil(("100" as NSString).size(withAttributes: [.font: Theme.number(12, .medium)]).width))
        XCTAssertEqual(row.remove.accessibilityLabel(), "Delete An overnight render")
        XCTAssertEqual(row.value.accessibilityLabel(), "Preset 1 speed")
    }

    func testFloorWarningIsShownAndCleared() {
        let row = PresetEditorRow(index: 0) {}
        row.showFloorWarning(true, minimum: 21)
        XCTAssertEqual(row.value.toolTip, "Hardware minimum 21%")
        row.showFloorWarning(false, minimum: 21)
        XCTAssertNil(row.value.toolTip)
    }
}
