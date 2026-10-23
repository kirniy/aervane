import AppKit
import QuartzCore

/// A native keyboard- and VoiceOver-accessible control. Values always mean a
/// percentage of maximum physical speed. The region below `minimumPercent` is
/// the firmware floor: drawn as held (always running), never reachable.
///
/// The control owns everything with meaning: the value and its floor,
/// pointer, keyboard and VoiceOver input, drag speed, haptics, previews and
/// commits, accessibility and focus. How it looks is a `SliderSkin` chosen by
/// `style`: the coolant channel (`ChannelSkin`, default) or the original dot
/// grid (`DotGridSkin`). Both run through this one input path, and changing
/// the style is presentation-only: it settles transients, keeps the value,
/// enabled/stale and focus state, and never previews or commits.
///
/// The value tracks the pointer and keys immediately. Transient effects are
/// finite Core Animation reactions; miniature rotors follow measured speed
/// only while visible. Pointer
/// tracking uses plain mouseDown/mouseDragged/mouseUp, so the run loop keeps
/// delivering model updates mid-drag. Artwork is cached per size, scale,
/// appearance, floor and style. Hiding freezes the rotors and settles every
/// transient.
final class PercentSlider: NSControl {
    var percent: Double {
        get { value }
        set { setPercent(newValue, animated: false) }
    }
    var minimumPercent: Double = 0 {
        didSet {
            guard minimumPercent != oldValue else { return }
            fieldDirty = true; needsDisplay = true; setAccessibilityMinValue(minimumPercent)
            setPercent(value, animated: false)
        }
    }
    /// Values that give a haptic tick while dragging (e.g. preset speeds).
    var detents: [Double] = []
    var isUnavailable = false { didSet { alphaValue = isUnavailable ? 0.45 : 1; if isUnavailable != oldValue { updateAmbient() } } }
    /// Measured fan speed as a percentage of maximum. Shown as a ghost mark
    /// on the track when it differs from the requested value.
    var measuredPercent: Double? { didSet { if measuredPercent != oldValue { placeMeasured(animated: true); updateAccessibility() } } }
    /// The fan's actual speed from the hardware (RPM), nil when unknown or
    /// stale. Drives only the Channel's miniature rotors (`RotorMotion`); it
    /// never affects the value, commits or fan policy.
    var measuredRPM: Double? { didSet { if measuredRPM != oldValue { updateAmbient() } } }
    /// The fan's firmware maximum (RPM), with `measuredRPM` the Dot Grid's
    /// wave pace (`DotVitality`). Presentation only.
    var maximumRPM: Double? { didSet { if maximumRPM != oldValue { updateAmbient() } } }
    /// Decoration ceiling (user level, lowered by system accessibility).
    var effects = Theme.effects { didSet { if effects != oldValue { skin.decorate(animated: false, userAction: false); updateAmbient() } } }
    /// The slider is on screen (panel shown, Settings closed). Continuous
    /// motion (rotors, full-cooling flow) runs only then; the owner sets it
    /// on show and clears it on hide.
    var ambientActive = false { didSet { if ambientActive != oldValue { updateAmbient() } } }
    /// Rotor rate now (revolutions per second), 0 when frozen (tests).
    var rotorRate: Double { skin.rotors?.rate ?? 0 }
    var isRotorSpinning: Bool { skin.rotors?.isSpinning ?? false }
    /// Repeating rotor animations attached (tests: bounded, none when hidden).
    var rotorAnimationCount: Int { skin.rotors?.animationCount ?? 0 }
    /// The full-cooling flow is running, and its repeating loops (tests).
    var isIceFlowing: Bool { skin.flow?.isRunning ?? false }
    var flowAnimationCount: Int { skin.flow?.animationCount ?? 0 }
    /// Read-only motion probes (tests and diagnostics): what is on screen
    /// now, sampled over time to prove movement rather than attachment.
    var rotorShownAngle: Double? { skin.rotors?.shownAngle }
    var flowProbes: [LoopSet.Probe] { skin.flow?.probes ?? [] }
    /// The all-speed wave (Dot Grid): running, its loops, and what is shown.
    var isWaving: Bool { skin.vitality?.isRunning ?? false }
    var vitalityProbes: [LoopSet.Probe] { skin.vitality?.probes ?? [] }
    /// How the control is drawn. Presentation only (see the type comment).
    var style: SliderStyle = .channel {
        didSet {
            guard style != oldValue else { return }
            skin.uninstall()
            skin = Self.makeSkin(for: style, host: self)
            skin.layers.forEach { layer?.addSublayer($0) }
            fieldDirty = true; needsDisplay = true
            if layer != nil { updateLayer() }
            // Carry the hover/held shape over without playing anything.
            skin.shapeThumb(.settle); skin.settle()
            updateAmbient()
            noteFocusRingMaskChanged()
        }
    }
    var preview: ((Double) -> Void)?
    /// The user took hold of the control (pointer down, first key or
    /// VoiceOver change). The owner selects Manual at once.
    var began: (() -> Void)?
    /// Travel time for a value set from outside the control (Smart changing
    /// the fan): long enough to see, eased, and interrupted by the next value.
    static let externalGlide: CFTimeInterval = 0.85
    var commit: ((Double) -> Void)?
    private(set) var dragging = false
    private(set) var hovered = false
    /// Drag speed in points per second of thumb travel (smoothed).
    private(set) var velocity = 0.0
    /// True while a drag or a debounced keyboard change has not been committed.
    var isInteracting: Bool { dragging || keyCommitPending }
    /// The full-cooling ice is present (static once formed).
    var isIceFormed: Bool { skin.isIceFormed }
    /// Resting size of the channel thumb (its layer bounds; reactions are transforms).
    static var thumbSize: CGSize { SliderGeometry.thumb }
    /// Resting thumb size for the current style.
    var currentThumbSize: CGSize { skin.thumbSize }

    private lazy var skin: SliderSkin = PercentSlider.makeSkin(for: style, host: self)
    private var value: Double = 50
    private var dragStart: Double = 50
    private var grabOffset: CGFloat = 0
    private var keyboardFocus = false
    private var keyCommitPending = false
    private var hoverArea: NSTrackingArea?
    private var lastCelebration = Date.distantPast
    private var fieldDirty = true
    private var renderedSize = NSSize.zero
    private var renderedScale: CGFloat = 0
    private var trackedX: CGFloat = 0
    private var trackedTime: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Fan speed")
        setAccessibilityMinValue(0); setAccessibilityMaxValue(100)
        focusRingType = .exterior
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func makeSkin(for style: SliderStyle, host: PercentSlider) -> SliderSkin {
        switch style {
        case .channel: return ChannelSkin(host: host)
        case .dotGrid: return DotGridSkin(host: host)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled && dragging { cancelDrag() }
            updateAmbient()
        }
    }

    // MARK: Layers

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        skin.layers.forEach(root.addSublayer)
        return root
    }
    override var wantsUpdateLayer: Bool { true }
    override var frame: NSRect {
        didSet {
            guard frame.size != oldValue.size else { return }
            // AppKit can assign a complete frame without calling setFrameSize.
            // Populate the layers once real geometry replaces the initial zero rect.
            if layer != nil { updateLayer() }
        }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); fieldDirty = true; needsDisplay = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }

    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard fieldDirty || renderedSize != bounds.size || renderedScale != scale else { return }
        if skin.render(scale: scale) { fieldDirty = false; renderedSize = bounds.size; renderedScale = scale }
        skin.place(animated: false, userAction: false)
        skin.decorate(animated: false, userAction: false)
        placeMeasured(animated: false)
        updateAmbient()
    }
    /// Continuous motion. The rotors follow the actual fan RPM while the
    /// slider is shown (`RotorMotion`); the full-cooling flow runs while the
    /// formed ice is shown (`IceFlow`). Otherwise both stand still where they
    /// are. Idempotent and cheap: called on every relevant change.
    private func updateAmbient() {
        let visible = ambientActive && window != nil
        let spins = RotorMotion.spins(visible: visible, enabled: isEnabled, available: !isUnavailable, rpm: measuredRPM, effects: effects)
        skin.spinRotors(at: spins ? RotorMotion.revolutionsPerSecond(rpm: measuredRPM) : 0)
        skin.setFlow(IceFlow.runs(visible: visible, enabled: isEnabled, available: !isUnavailable, frozen: skin.isIceFormed, effects: effects))
        // The wave follows the actual fan at every speed. Hidden: frozen as it
        // was. Shown but stopped (stale, disabled, 0 RPM, Off, Reduce
        // Motion): frozen and faded out.
        let fraction = DotVitality.fraction(rpm: measuredRPM, maximumRPM: maximumRPM)
        if !visible {
            skin.setVitality(velocity: 0, amplitude: nil)
        } else if DotVitality.runs(visible: visible, enabled: isEnabled, available: !isUnavailable, rpm: measuredRPM, maximumRPM: maximumRPM, effects: effects) {
            skin.setVitality(velocity: DotVitality.velocity(fraction: fraction), amplitude: DotVitality.amplitude(fraction: fraction, effects: effects))
        } else {
            skin.setVitality(velocity: 0, amplitude: 0)
        }
    }

    /// Horizontal position of a value inside a slider of the given width and
    /// style; lets the owner align scale marks before the slider is laid out.
    static func trackX(percent: Double, width: CGFloat, style: SliderStyle = .channel) -> CGFloat { style.x(percent: percent, width: width) }
    private func x(for percent: Double) -> CGFloat { style.x(percent: percent, width: bounds.width) }
    private func percentage(at x: CGFloat) -> Double { style.percent(atX: x, width: bounds.width) }
    private func clamp(_ v: Double) -> Double { max(minimumPercent, min(100, v.isFinite ? v : minimumPercent)) }

    private func placeMeasured(animated: Bool) {
        let visible = measuredPercent.map { $0.isFinite && abs($0 - value) >= 3 } ?? false
        skin.placeMeasured(visible: visible, animated: animated)
        toolTip = visible ? measuredPercent.map { "Fan now \(Int($0.rounded()))%" } : nil
    }
    /// Thumb shape for hover, grab and release, then the light that follows it.
    private func updateThumbShape(_ gesture: ThumbGesture = .settle) {
        skin.shapeThumb(gesture)
        skin.decorate(animated: true, userAction: false)
    }
    /// Follows drag speed from the pointer, clamped to the reachable range so
    /// pushing past an end is not speed.
    private func track(pointerX: CGFloat, time: TimeInterval) {
        let reached = min(max(pointerX, x(for: minimumPercent)), x(for: 100))
        let interval = time > trackedTime ? time - trackedTime : 1.0 / 60
        velocity = SliderMotion.smoothed(previous: velocity, sample: Double(reached - trackedX) / interval, interval: interval)
        trackedX = reached; trackedTime = time
        skin.react()
    }
    /// One haptic when a user action reaches 100% (never within a second of
    /// the last), then the style's own acknowledgement.
    private func celebrate(animated: Bool, delay: CFTimeInterval) {
        guard Date().timeIntervalSince(lastCelebration) > 1.2 else { return }
        lastCelebration = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        skin.celebrate(animated: animated, delay: delay)
    }

    // MARK: Value

    /// Sets the value. `celebrate` marks user-initiated changes; model
    /// refreshes never form the ice sheet, glint or wake. Keyboard callers
    /// pass `animated: false` so keys are always instant. `glide` lengthens
    /// the travel for a value set from outside (Smart); each new value
    /// retargets from what is on screen, so rapid updates never pile up.
    /// Ignored while the user is dragging, and with Reduce Motion.
    func setPercent(_ newValue: Double, animated: Bool, celebrate: Bool = false, glide: CFTimeInterval? = nil) {
        let previous = value
        value = clamp(newValue)
        if value != previous { skin.interrupt() }
        updateAccessibility()
        if let glide, !dragging { skin.glideDuration = glide }
        defer { skin.glideDuration = SliderSkin.glide }
        skin.place(animated: animated, userAction: celebrate)
        skin.decorate(animated: animated, userAction: celebrate)
        placeMeasured(animated: false)
        updateAmbient()
        if celebrate && previous < 100 && value >= 100 { self.celebrate(animated: animated || dragging, delay: animated ? SliderSkin.glide * 0.5 : 0) }
    }

    private func updateAccessibility() {
        let shown = Int(value.rounded())
        var text = minimumPercent > 0 && value <= minimumPercent ? "\(shown) percent, hardware minimum" : "\(shown) percent of maximum fan speed"
        if let measured = measuredPercent, measured.isFinite, abs(measured - value) >= 3 { text += ", fan now \(Int(measured.rounded())) percent" }
        setAccessibilityValueDescription(text)
    }

    private func userChange(to target: Double, animated: Bool) {
        let next = clamp(target.rounded()), previous = value
        guard next != previous else { return }
        let low = min(previous, next), high = max(previous, next)
        let crossed = ([minimumPercent, 100] + detents).filter { $0 >= low && $0 <= high && abs($0 - previous) >= 0.5 }
        if let detent = crossed.min(by: { abs($0 - next) < abs($1 - next) }) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            // The ripple marks the stop the hand just felt; 100% has its own.
            if dragging && detent < 100 { skin.ripple(at: detent, strength: 0.45, wide: false) }
        }
        setPercent(next, animated: animated, celebrate: true)
        preview?(next)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateThumbShape() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateThumbShape() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = false; updateThumbShape() }
    /// Ends interaction and settles every transient animation, leaving only
    /// static state (including a formed sheet) for the next time it shows.
    func prepareForHiding() {
        cancelDrag(); flushKeyCommit()
        hovered = false; keyboardFocus = false; updateThumbShape()
        ambientActive = false
        settleTransients()
    }
    private func settleTransients() {
        skin.settle()
        velocity = 0
    }
    /// Running transient animations across the control (lifecycle tests).
    /// The repeating rotor spin and full-cooling flow are counted separately
    /// (`rotorAnimationCount`, `flowAnimationCount`).
    var transientAnimationCount: Int { skin.allLayers.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        flushKeyCommit()
        if keyboardFocus { keyboardFocus = false; noteFocusRingMaskChanged() }
        window?.makeFirstResponder(self)
        skin.interrupt()
        began?()
        let point = convert(event.locationInWindow, from: nil), thumbX = x(for: value)
        dragStart = value; dragging = true; velocity = 0
        // Grabbing the thumb keeps its offset; clicking the track glides there.
        let grabbed = abs(point.x - thumbX) <= skin.grabSlop
        grabOffset = grabbed ? point.x - thumbX : 0
        trackedX = min(max(point.x - grabOffset, x(for: minimumPercent)), x(for: 100)); trackedTime = event.timestamp
        updateThumbShape(.grab)
        if !grabbed { userChange(to: percentage(at: point.x), animated: true) }
        skin.ripple(at: value, strength: 0.55, wide: false)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let pointerX = convert(event.locationInWindow, from: nil).x - grabOffset
        userChange(to: percentage(at: pointerX), animated: false)
        track(pointerX: pointerX, time: event.timestamp)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        userChange(to: percentage(at: convert(event.locationInWindow, from: nil).x - grabOffset), animated: false)
        endDrag(commit: true)
    }
    private func endDrag(commit shouldCommit: Bool) {
        dragging = false; velocity = 0; updateThumbShape(.release)
        if shouldCommit && value != dragStart {
            skin.ripple(at: value, strength: 0.35 + 0.5 * SliderEnergy.level(percent: value), wide: true)
            skin.sweep(); sendCommit()
        } else { preview?(value) }   // lets the owner drop the preview state
    }
    private func cancelDrag() {
        guard dragging else { return }
        dragging = false; velocity = 0
        setPercent(dragStart, animated: true); preview?(dragStart); updateThumbShape()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { if dragging { endDrag(commit: true) }; flushKeyCommit(); ambientActive = false; settleTransients() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Keyboard and VoiceOver

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            if event.keyCode == 53 { window?.cancelOperation(self) }
            return
        }
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123, 125: nudge(to: value - step)
        case 124, 126: nudge(to: value + step)
        case 121: nudge(to: value - 10)        // page down
        case 116: nudge(to: value + 10)        // page up
        case 115: nudge(to: minimumPercent)    // home
        case 119: nudge(to: 100)               // end
        case 53: if dragging { cancelDrag() } else { flushKeyCommit(); window?.cancelOperation(self) }
        default: super.keyDown(with: event)
        }
    }
    /// Keys and VoiceOver change the value instantly (no glide, no ice
    /// formation, no wake) and commit once input pauses, so holding an arrow
    /// key does not queue a helper write per repeat.
    private func nudge(to target: Double) {
        guard isEnabled, !dragging else { return }
        if !keyCommitPending { began?() }
        userChange(to: target, animated: false)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fireKeyCommit), object: nil)
        keyCommitPending = true
        perform(#selector(fireKeyCommit), with: nil, afterDelay: 0.35)
    }
    @objc private func fireKeyCommit() { guard keyCommitPending else { return }; keyCommitPending = false; sendCommit() }
    private func flushKeyCommit() {
        guard keyCommitPending else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fireKeyCommit), object: nil)
        fireKeyCommit()
    }
    private func sendCommit() {
        commit?(value)
        if let action { _ = sendAction(action, to: target) }
    }
    override func accessibilityValue() -> Any? { NSNumber(value: Int(value.rounded())) }
    override func setAccessibilityValue(_ newValue: Any?) {
        guard isEnabled, let number = newValue as? NSNumber, number.doubleValue.isFinite else { return }
        nudge(to: number.doubleValue)
    }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; nudge(to: value + 5); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; nudge(to: value - 5); return true }

    // MARK: Focus ring (keyboard focus only, as with native sliders)

    override func becomeFirstResponder() -> Bool {
        guard isEnabled else { return false }
        keyboardFocus = NSApp.currentEvent?.type == .keyDown; noteFocusRingMaskChanged()
        return true
    }
    override func resignFirstResponder() -> Bool {
        flushKeyCommit(); keyboardFocus = false; noteFocusRingMaskChanged()
        return true
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        guard keyboardFocus else { return }
        skin.focusRing().fill()
    }
}
