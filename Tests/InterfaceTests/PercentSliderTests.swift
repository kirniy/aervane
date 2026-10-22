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
        // Resting dots first, thumb always topmost.
        XCTAssertEqual(control.layer?.sublayers?.count, 10)
        XCTAssertNotNil(control.layer?.sublayers?.first?.contents)
        XCTAssertEqual(control.layer?.sublayers?.last?.bounds.size, NSSize(width: 6, height: 20))
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
