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
        XCTAssertEqual(control.layer?.sublayers?.count, 15)
        XCTAssertNotNil(control.layer?.sublayers?.first?.contents)
        XCTAssertEqual(control.layer?.sublayers?.last?.bounds.size, PercentSlider.thumbSize)
        XCTAssertEqual(PercentSlider.thumbSize, NSSize(width: 20, height: 38))
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
        // Hidden test windows do not schedule AppKit display; create cached artwork explicitly.
        control.updateLayer()
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

    /// The formation plays for any crossing the person can watch, including
    /// Smart gliding to 100% while the panel is open. Hidden or startup
    /// refreshes (unanimated), keys and unchanged 100% polling never play it.
    func testOnlyVisibleCrossingsPlayTheFormation() {
        for style in SliderStyle.allCases {
            let (window, control) = hostedSlider(); _ = window
            control.style = style
            control.prepareForHiding() // Exclude the style-switch thumb reaction from the initial baseline.
            func forming() -> Bool { control.layer?.sublayers?.contains { $0.mask?.animation(forKey: "form") != nil } == true }
            control.setPercent(100, animated: false)
            XCTAssertTrue(control.isIceFormed); XCTAssertFalse(forming(), "\(style): a hidden refresh shows the ice at once")
            XCTAssertEqual(control.transientAnimationCount, 0)
            control.setPercent(100, animated: true, glide: PercentSlider.externalGlide)
            XCTAssertFalse(forming(), "\(style): polling at an unchanged 100% never replays it")
            control.setPercent(80, animated: false); control.prepareForHiding()
            control.setPercent(100, animated: true, glide: PercentSlider.externalGlide)
            XCTAssertTrue(forming(), "\(style): Smart reaching 100% in view forms the ice")
            control.prepareForHiding()
            XCTAssertTrue(control.isIceFormed, "Formed ice is static state and survives hiding")
            XCTAssertEqual(control.transientAnimationCount, 0)
            control.setPercent(95, animated: false); control.prepareForHiding()
            XCTAssertTrue(control.accessibilityPerformIncrement())
            XCTAssertTrue(control.isIceFormed); XCTAssertFalse(forming(), "\(style): keys stay instant")
            XCTAssertEqual(control.transientAnimationCount, 0)
        }
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

    /// The Dot Grid's layer stack: the tray first, the 9×38 glass handle on
    /// top, a fixed number of root layers.
    func testDotGridIsTallWithItsHandleOnTop() {
        let (window, control) = hostedSlider(); _ = window
        control.style = .dotGrid
        XCTAssertEqual(control.layer?.sublayers?.count, 11)
        XCTAssertNotNil(control.layer?.sublayers?.first?.contents)
        XCTAssertEqual(control.layer?.sublayers?.last?.bounds.size, NSSize(width: 9, height: 38))
        XCTAssertEqual(control.currentThumbSize, DotGridGeometry.thumb)
        XCTAssertEqual(control.layer!.sublayers!.last!.position.x, PercentSlider.trackX(percent: control.percent, width: control.bounds.width, style: .dotGrid), accuracy: 0.5 / window.backingScaleFactor, "Placement snaps to the physical pixel grid")
        control.style = .channel
        XCTAssertEqual(control.layer?.sublayers?.count, 15)
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

    // MARK: Smart moving the slider

    /// A value set from outside (Smart) glides visibly in every style, eased,
    /// and each newer value retargets the same animations instead of piling
    /// up. Hiding settles them.
    func testExternalValuesGlideVisiblyAndRetarget() {
        for style in SliderStyle.allCases {
            let (window, control) = hostedSlider(); _ = window
            control.style = style
            control.setPercent(40, animated: false); control.prepareForHiding()
            control.setPercent(70, animated: true, glide: PercentSlider.externalGlide)
            let thumb = control.layer?.sublayers?.last
            let first = thumb?.animation(forKey: "position")
            XCTAssertNotNil(first, "\(style)")
            XCTAssertEqual(first?.duration ?? 0, PercentSlider.externalGlide, accuracy: 0.001, "Long enough to see")
            let count = control.transientAnimationCount
            for value in [74.0, 79, 83, 88] { control.setPercent(value, animated: true, glide: PercentSlider.externalGlide) }
            XCTAssertLessThanOrEqual(control.transientAnimationCount, count + 2, "Rapid updates do not accumulate")
            XCTAssertEqual(control.percent, 88, "The latest value is the final position")
            XCTAssertEqual((thumb?.animation(forKey: "position") as? CABasicAnimation)?.toValue as? NSValue,
                           NSValue(point: thumb!.position), "Animates toward the newest value")
            // A user's own change is the short glide again.
            control.setPercent(50, animated: true)
            XCTAssertEqual(thumb?.animation(forKey: "position")?.duration ?? 0, SliderSkin.glide, accuracy: 0.001)
            control.prepareForHiding()
            XCTAssertEqual(control.transientAnimationCount, 0)
        }
    }

    /// Reduce Motion: external values jump, with nothing animating.
    func testExternalValuesJumpWithReduceMotion() {
        let (window, control) = hostedSlider(); _ = window
        control.effects = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false)
        control.prepareForHiding()
        control.setPercent(90, animated: true, glide: PercentSlider.externalGlide)
        XCTAssertEqual(control.percent, 90)
        XCTAssertEqual(control.transientAnimationCount, 0)
    }

    /// Taking hold of the slider reports it at once (the owner selects
    /// Manual), and a drag is never lengthened by an external glide.
    func testGrabReportsBeganAndDragStaysImmediate() {
        let (window, control) = hostedSlider()
        var began = 0
        control.began = { began += 1 }
        control.setPercent(60, animated: false)
        func event(_ type: NSEvent.EventType, _ percent: Double) -> NSEvent {
            let x = PercentSlider.trackX(percent: percent, width: control.bounds.width)
            return NSEvent.mouseEvent(with: type, location: control.convert(NSPoint(x: x, y: 17), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        control.mouseDown(with: event(.leftMouseDown, 60))
        XCTAssertEqual(began, 1)
        control.setPercent(90, animated: true, glide: PercentSlider.externalGlide)   // a stale external update mid-drag
        control.mouseDragged(with: event(.leftMouseDragged, 70))
        XCTAssertEqual(control.percent, 70)
        XCTAssertNil(control.layer?.sublayers?.last?.animation(forKey: "position"), "The thumb follows the hand directly")
        control.mouseUp(with: event(.leftMouseUp, 70))
        XCTAssertTrue(control.accessibilityPerformIncrement())
        XCTAssertEqual(began, 2, "The first key of a burst counts as taking hold")
        XCTAssertTrue(control.accessibilityPerformIncrement())
        XCTAssertEqual(began, 2)
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
    // MARK: Miniature rotors

    /// The Channel's rotors turn in proportion to the fan's actual RPM only
    /// while the slider is shown: they retime phase-continuously without
    /// stacking animations, ignore the requested value, and stand still for
    /// a stopped fan, stale telemetry, Effects Off, Reduce Motion, a disabled
    /// control, hiding and detaching.
    func testChannelRotorsFollowActualRPMOnlyWhileShown() {
        let (window, control) = hostedSlider(); _ = window
        let expressive = control.effects
        control.measuredRPM = 1200
        XCTAssertFalse(control.isRotorSpinning, "A hidden panel costs nothing")
        XCTAssertEqual(control.rotorAnimationCount, 0)
        control.ambientActive = true
        XCTAssertTrue(control.isRotorSpinning)
        let count = control.rotorAnimationCount
        XCTAssertEqual(control.rotorRate, 0.6, accuracy: 1e-9, "1200 RPM → 0.6 rev/s")
        XCTAssertGreaterThan(count, 0); XCTAssertLessThanOrEqual(count, 14, "One repeating rotation per rotor, bounded")
        // The request never drives the rotors: only the hardware does.
        control.setPercent(100, animated: false); control.setPercent(40, animated: false)
        XCTAssertEqual(control.rotorRate, 0.6, accuracy: 1e-9, "The slider value never changes rotor speed")
        control.measuredRPM = 4800
        XCTAssertEqual(control.rotorRate, 2.4, accuracy: 1e-9, "Spin-up follows the hardware")
        XCTAssertEqual(control.rotorAnimationCount, count, "Retiming never stacks or restarts animations")
        control.measuredRPM = 4800
        XCTAssertEqual(control.rotorAnimationCount, count, "An unchanged sample changes nothing")
        control.measuredRPM = 2000
        XCTAssertEqual(control.rotorRate, 1, accuracy: 1e-9, "Spin-down follows the hardware")
        func repeatingAnimations(_ layer: CALayer) -> Int {
            let own = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.filter { $0.repeatCount > 0 }.count
            return own + (layer.sublayers ?? []).reduce(0) { $0 + repeatingAnimations($1) }
                + (layer.mask.map { repeatingAnimations($0) } ?? 0)
        }
        // Below full cooling only the rotors repeat; finite feedback (the
        // ghost marker) is legitimate.
        XCTAssertEqual(repeatingAnimations(control.layer!), count)
        control.effects = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(control.rotorRate, 1, accuracy: 1e-9, "Subtle changes appearance, never the RPM scale")

        func assertStill(_ message: String) {
            XCTAssertFalse(control.isRotorSpinning, message); XCTAssertEqual(control.rotorAnimationCount, 0, message)
            XCTAssertEqual(control.rotorRate, 0, message)
        }
        control.effects = EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false); assertStill("Effects Off")
        control.effects = expressive; XCTAssertTrue(control.isRotorSpinning)
        control.effects = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false); assertStill("Reduce Motion")
        control.effects = expressive
        control.measuredRPM = 0; assertStill("A stopped fan")
        control.measuredRPM = 1500; XCTAssertTrue(control.isRotorSpinning)
        control.isUnavailable = true; assertStill("Stale data")
        control.isUnavailable = false; XCTAssertTrue(control.isRotorSpinning)
        control.measuredRPM = nil; assertStill("Unknown RPM")
        control.measuredRPM = 1500
        control.isEnabled = false; assertStill("Disabled")
        control.isEnabled = true; XCTAssertTrue(control.isRotorSpinning)
        control.prepareForHiding(); assertStill("Hidden")
        XCTAssertEqual(control.transientAnimationCount, 0)
        control.ambientActive = true; XCTAssertTrue(control.isRotorSpinning, "Shown again, the row resumes")
        control.ambientActive = false; assertStill("Settings open hides the slider")
        control.ambientActive = true
        control.removeFromSuperview(); assertStill("Detached")
    }

    /// Switching style never commands the fan. Only the Channel has rotors;
    /// the Dot Grid has no fan graphics and no repeating motion below 100%.
    func testRotorsBelongToTheChannelAndStyleSwitchNeverCommands() {
        let (window, control) = hostedSlider(); _ = window
        var commits: [Double] = []
        control.commit = { commits.append($0) }
        control.measuredRPM = 3000; control.ambientActive = true
        for style in [SliderStyle.dotGrid, .channel, .dotGrid, .channel] {
            control.style = style
            if style == .channel {
                XCTAssertTrue(control.isRotorSpinning); XCTAssertEqual(control.rotorRate, 1.5, accuracy: 1e-9)
            } else {
                XCTAssertFalse(control.isRotorSpinning); XCTAssertEqual(control.rotorAnimationCount, 0)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(commits.isEmpty)
    }

    /// At 100% the formed ice keeps flowing while shown, in both styles: a
    /// small fixed set of compositor loops that freeze on hide, Settings,
    /// stale or disabled data, Effects Off, Reduce Motion and leaving 100%,
    /// and resume without restarting the transients.
    func testFullCoolingFlowsOnlyWhileShownAndAllowed() {
        for style in SliderStyle.allCases {
            let (window, control) = hostedSlider(); _ = window
            control.style = style
            control.setPercent(100, animated: false)
            XCTAssertTrue(control.isIceFormed)
            XCTAssertFalse(control.isIceFlowing, "\(style): hidden, nothing loops")
            control.ambientActive = true
            XCTAssertTrue(control.isIceFlowing, "\(style): formed and shown, the ice flows")
            let loops = control.flowAnimationCount
            XCTAssertGreaterThan(loops, 0); XCTAssertLessThanOrEqual(loops, 4, "\(style): a small fixed set")
            control.setPercent(100, animated: true)
            XCTAssertEqual(control.flowAnimationCount, loops, "\(style): polling at 100% never restarts or stacks it")
            func assertFrozen(_ message: String) {
                XCTAssertFalse(control.isIceFlowing, "\(style): \(message)"); XCTAssertEqual(control.flowAnimationCount, 0, "\(style): \(message)")
            }
            control.ambientActive = false; assertFrozen("Settings open or hidden")
            control.ambientActive = true; XCTAssertTrue(control.isIceFlowing)
            control.isUnavailable = true; assertFrozen("stale")
            control.isUnavailable = false; control.isEnabled = false; assertFrozen("disabled")
            control.isEnabled = true
            control.effects = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false); assertFrozen("Reduce Motion")
            XCTAssertTrue(control.isIceFormed, "\(style): Reduce Motion keeps the ice, still")
            control.effects = EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false); assertFrozen("Effects Off")
            control.effects = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
            XCTAssertTrue(control.isIceFlowing, "\(style): Subtle flows, calmer")
            control.setPercent(80, animated: false); assertFrozen("below full cooling")
            control.setPercent(100, animated: false); XCTAssertTrue(control.isIceFlowing)
            control.prepareForHiding(); assertFrozen("hidden")
            XCTAssertEqual(control.transientAnimationCount, 0)
            control.ambientActive = true; control.removeFromSuperview(); assertFrozen("detached")
        }
    }

    /// Total frost: reaching 100% by drag crawls the ice in, and leaving it
    /// recedes it from what is on screen in both styles.
    func testTotalFrostCrawlsInAndRecedes() {
        for style in SliderStyle.allCases {
            let (window, control) = hostedSlider(); _ = window
            control.style = style
            control.setPercent(100, animated: true, celebrate: true)
            XCTAssertTrue(control.isIceFormed, "\(style)")
            XCTAssertTrue(control.layer?.sublayers?.contains { $0.mask?.animation(forKey: "form") != nil } == true, "\(style): the front crawls")
            control.prepareForHiding()
            XCTAssertTrue(control.isIceFormed, "\(style): formed ice is static state")
            control.setPercent(60, animated: true)
            XCTAssertFalse(control.isIceFormed)
            XCTAssertTrue(control.layer?.sublayers?.contains { $0.mask?.animation(forKey: "melt") != nil } == true, "\(style): the front recedes")
            control.prepareForHiding()
            XCTAssertEqual(control.transientAnimationCount, 0)
        }
    }
}

@MainActor final class ModeSwitchTests: XCTestCase {
    private func make() -> (ModeSwitch, SoftButton, SoftButton, SoftButton) {
        let auto = SoftButton("Auto") {}, smart = SoftButton("Smart") {}, manual = SoftButton("Manual") {}
        auto.setAccessibilityLabel("Restore automatic fan control"); smart.setAccessibilityLabel("Smart cooling"); manual.setAccessibilityLabel("Manual fan control")
        let control = ModeSwitch(auto: auto, smart: smart, manual: manual)
        control.frame = NSRect(x: 0, y: 0, width: 186, height: 28); control.layout()
        return (control, auto, smart, manual)
    }

    /// Exactly three choices, in order, each a radio button with its own label;
    /// one selection at a time.
    func testThreeChoicesInOrderWithOneSelection() {
        let (control, auto, smart, manual) = make()
        XCTAssertLessThan(auto.frame.minX, smart.frame.minX)
        XCTAssertLessThan(smart.frame.minX, manual.frame.minX)
        XCTAssertEqual(manual.frame.maxX, 186)
        for (mode, chosen) in [(ModeSwitch.Mode.automatic, auto), (.smart, smart), (.manual, manual)] {
            control.mode = mode
            for button in [auto, smart, manual] {
                XCTAssertEqual(button.accessibilityRole(), .radioButton)
                XCTAssertEqual(button.accessibilityValue() as? NSNumber, NSNumber(value: button === chosen))
            }
        }
        control.mode = .none
        XCTAssertFalse(auto.selected || smart.selected || manual.selected)
        XCTAssertEqual(smart.accessibilityLabel(), "Smart cooling")
    }

    /// Choosing Smart plays one finite flourish; nothing keeps running, and
    /// Reduce Motion (no window here, or effects off) plays nothing.
    func testSmartFlourishIsFiniteAndOnlyOnEntry() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        let (control, _, _, _) = make()
        control.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        window.contentView!.addSubview(control)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.contentView!.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        control.mode = .automatic
        control.mode = .smart
        func animations(_ layer: CALayer?) -> [CAAnimation] {
            guard let layer else { return [] }
            return (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } + (layer.sublayers ?? []).flatMap { animations($0) }
        }
        let running = animations(control.layer)
        if Theme.effects.animates {
            XCTAssertFalse(running.isEmpty)
            XCTAssertTrue(running.allSatisfy { $0.duration.isFinite && $0.duration > 0 && $0.duration < 2 && $0.repeatCount == 0 }, "Finite, never looping")
        }
        control.saturated = true
        XCTAssertTrue(control.smartButton.selected)
    }

    func testPendingManualAndSaturatedSmartTints() {
        let (control, _, smart, manual) = make()
        control.mode = .manual; control.pending = true
        XCTAssertTrue(manual.selected)
        control.mode = .smart; control.saturated = true
        XCTAssertTrue(smart.selected); XCTAssertFalse(manual.selected)
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
