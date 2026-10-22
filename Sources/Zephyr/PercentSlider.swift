import AppKit
import QuartzCore

/// A native keyboard- and VoiceOver-accessible control. Values always mean a
/// percentage of maximum physical speed. The region below `minimumPercent` is
/// the firmware floor: drawn as always running, never reachable by the thumb.
///
/// Pointer tracking uses plain mouseDown/mouseDragged/mouseUp, so the run loop
/// keeps delivering model updates mid-drag. Movement is rendered by Core
/// Animation layers; nothing ticks while the control is idle.
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
    var isUnavailable = false { didSet { alphaValue = isUnavailable ? 0.45 : 1 } }
    var preview: ((Double) -> Void)?
    var commit: ((Double) -> Void)?
    private(set) var dragging = false
    /// True while a drag or a debounced keyboard change has not been committed.
    var isInteracting: Bool { dragging || keyCommitPending }

    private var value: Double = 50
    private var dragStart: Double = 50
    private var grabOffset: CGFloat = 0
    private var hovered = false
    private var keyboardFocus = false
    private var keyCommitPending = false
    private var hoverArea: NSTrackingArea?
    private var lastCelebration = Date.distantPast
    private var fieldDirty = true
    private var renderedSize = NSSize.zero
    private var renderedScale: CGFloat = 0

    private let dimDots = CALayer(), litDots = CALayer(), litMask = CALayer(), floorTick = CALayer(), bloom = CALayer(), thumb = CALayer()

    private enum Metric {
        static let dot: CGFloat = 2, pitch: CGFloat = 3, rows = 5
        static let inset: CGFloat = 16            // thumb, hover and bloom room at both ends
        static let thumb = CGSize(width: 6, height: 20)
        static let grabSlop: CGFloat = 10         // pick the thumb up without a jump
        static let glide: CFTimeInterval = 0.18
        static let bloomReach = 5, bloomLift = 5  // in grid cells
    }

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

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled && dragging { cancelDrag() }
        }
    }

    // MARK: Layers

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        dimDots.opacity = 0.82
        litDots.mask = litMask
        litMask.backgroundColor = NSColor.black.cgColor; litMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        bloom.opacity = 0
        for layer in [dimDots, litDots, bloom] { layer.contentsGravity = .resize }
        [dimDots, litDots, floorTick, bloom, thumb].forEach(root.addSublayer)
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
        renderField(scale: scale)
        placeLayers(animated: false)
    }

    private var columns: Int { max(2, Int(((bounds.width - 2 * Metric.inset - Metric.dot) / Metric.pitch).rounded(.down)) + 1) }
    private var gridRect: NSRect {
        let width = CGFloat(columns - 1) * Metric.pitch + Metric.dot
        let height = CGFloat(Metric.rows - 1) * Metric.pitch + Metric.dot
        return NSRect(x: ((bounds.width - width) / 2).rounded(.down), y: ((bounds.height - height) / 2).rounded(.down), width: width, height: height)
    }
    private func x(for percent: Double) -> CGFloat {
        let grid = gridRect
        return grid.minX + Metric.dot / 2 + CGFloat(percent / 100) * (grid.width - Metric.dot)
    }
    private func percentage(at x: CGFloat) -> Double {
        let grid = gridRect
        return Double((x - grid.minX - Metric.dot / 2) / max(1, grid.width - Metric.dot)) * 100
    }
    private func clamp(_ v: Double) -> Double { max(minimumPercent, min(100, v.isFinite ? v : minimumPercent)) }

    /// Renders the dot field once per size/appearance/floor change into two
    /// bitmaps (resting and lit). The fill is a mask over the lit bitmap.
    private func renderField(scale: CGFloat) {
        guard bounds.width > 4 * Metric.inset, bounds.height > 0 else { return }
        fieldDirty = false; renderedSize = bounds.size; renderedScale = scale
        let grid = gridRect, cols = columns, floorValue = minimumPercent
        let reach = Metric.bloomReach, lift = Metric.bloomLift
        let bloomSize = CGSize(width: CGFloat(2 * reach) * Metric.pitch + Metric.dot, height: CGFloat(2 * lift) * Metric.pitch + Metric.dot)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = Theme.dark
            let rest = Theme.ink.withAlphaComponent(dark ? 0.14 : 0.12).cgColor
            let held = Theme.accent.withAlphaComponent(dark ? 0.30 : 0.26).cgColor
            let bright = Theme.accent.usingColorSpace(.sRGB) ?? Theme.accent
            func lit(_ v: Double) -> CGColor {
                let t = v / 100
                // Brightness tracks absolute speed. In dark mode the top 14%
                // warms toward white so 100% reads as "full", without glow.
                let tone = dark ? (bright.blended(withFraction: max(0, (t - 0.86) / 0.14) * 0.6, of: .white) ?? bright) : bright
                return tone.withAlphaComponent(0.36 + 0.64 * pow(t, 1.25)).cgColor
            }
            self.dimDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                ctx.setFillColor(rest)
                for c in 0..<cols { for r in 0..<Metric.rows { Self.dot(ctx, c, r) } }
            }
            self.litDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                for c in 0..<cols {
                    let v = Double(c) / Double(cols - 1) * 100
                    ctx.setFillColor(v < floorValue ? held : lit(v))
                    for r in 0..<Metric.rows { ctx.setAlpha(0.9 + 0.1 * Self.noise(c, r)); Self.dot(ctx, c, r) }
                }
            }
            // Sparse pixel burst on the same lattice, vertically symmetric so it
            // is independent of layer geometry flipping.
            self.bloom.contents = Self.bitmap(bloomSize, scale: scale) { ctx in
                ctx.setFillColor((dark ? NSColor.white : Theme.accent).cgColor)
                for dx in -reach...reach {
                    for dy in -lift...lift {
                        let d = (Double(dx * dx) + Double(dy * dy) * 1.6).squareRoot() / Double(reach)
                        guard d <= 1 else { continue }
                        let n = Double(Self.noise(abs(dx) + 17, abs(dy) + 31))
                        if d > 0.3 && n < d * 0.8 { continue }
                        ctx.setAlpha(CGFloat(pow(1 - d, 1.5) * (0.6 + 0.4 * n)))
                        Self.dot(ctx, dx + reach, dy + lift)
                    }
                }
            }
            self.floorTick.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.32 : 0.26).cgColor
            self.thumb.backgroundColor = NSColor.white.cgColor
            self.thumb.borderColor = NSColor.black.withAlphaComponent(dark ? 0.0 : 0.16).cgColor
            self.thumb.shadowColor = NSColor.black.cgColor
            self.thumb.shadowOpacity = dark ? 0.45 : 0.22
        }
        for layer in [dimDots, litDots, bloom] { layer.contentsScale = scale }
        dimDots.frame = grid; litDots.frame = grid
        litMask.bounds = CGRect(x: 0, y: 0, width: 0, height: grid.height); litMask.position = CGPoint(x: 0, y: grid.height / 2)
        bloom.bounds = CGRect(origin: .zero, size: bloomSize); bloom.position = CGPoint(x: x(for: 100), y: grid.midY)
        floorTick.isHidden = floorValue <= 0
        floorTick.frame = CGRect(x: (x(for: floorValue) - Metric.pitch / 2).rounded(), y: grid.minY - 4, width: 1, height: grid.height + 8)
        thumb.bounds = CGRect(origin: .zero, size: Metric.thumb)
        thumb.cornerRadius = Metric.thumb.width / 2; thumb.borderWidth = 0.5
        thumb.shadowRadius = 1.5; thumb.shadowOffset = .zero
        thumb.shadowPath = CGPath(roundedRect: thumb.bounds, cornerWidth: thumb.cornerRadius, cornerHeight: thumb.cornerRadius, transform: nil)
        CATransaction.commit()
    }

    /// Moves thumb and fill together. Animated moves start from the on-screen
    /// (presentation) position, so a new target interrupts an old one cleanly.
    private func placeLayers(animated: Bool) {
        let grid = gridRect, targetX = x(for: value), fill = max(0, targetX - grid.minX)
        let fromX = thumb.presentation()?.position.x ?? thumb.position.x
        let fromFill = litMask.presentation()?.bounds.width ?? litMask.bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.position = CGPoint(x: targetX, y: grid.midY)
        litMask.bounds = CGRect(x: 0, y: 0, width: fill, height: grid.height)
        if animated && !Theme.reduceMotion && abs(fromX - targetX) > 0.5 && window != nil {
            let move = CABasicAnimation(keyPath: "position.x"); move.fromValue = fromX; move.toValue = targetX
            let grow = CABasicAnimation(keyPath: "bounds.size.width"); grow.fromValue = fromFill; grow.toValue = fill
            for animation in [move, grow] { animation.duration = Metric.glide; animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }
            thumb.add(move, forKey: "glide"); litMask.add(grow, forKey: "glide")
        } else {
            thumb.removeAnimation(forKey: "glide"); litMask.removeAnimation(forKey: "glide")
        }
        CATransaction.commit()
    }

    private func updateThumbShape() {
        let target = dragging ? CATransform3DMakeScale(1.34, 1.12, 1) : hovered && isEnabled ? CATransform3DMakeScale(1.17, 1.05, 1) : CATransform3DIdentity
        let from = thumb.presentation()?.transform ?? thumb.transform
        let restOpacity: Float = hovered || dragging ? 1 : 0.82
        let fromOpacity = dimDots.presentation()?.opacity ?? dimDots.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.transform = target; dimDots.opacity = restOpacity
        if !Theme.reduceMotion && window != nil {
            let shape = CABasicAnimation(keyPath: "transform"); shape.fromValue = NSValue(caTransform3D: from); shape.toValue = NSValue(caTransform3D: target)
            let tone = CABasicAnimation(keyPath: "opacity"); tone.fromValue = fromOpacity; tone.toValue = restOpacity
            for animation in [shape, tone] { animation.duration = 0.15; animation.timingFunction = CAMediaTimingFunction(name: .easeOut) }
            thumb.add(shape, forKey: "shape"); dimDots.add(tone, forKey: "tone")
        }
        CATransaction.commit()
    }

    /// One short pixel bloom when a user action reaches 100%. Removed on
    /// completion; never repeats within a second; skipped with Reduce Motion.
    private func celebrate() {
        guard Date().timeIntervalSince(lastCelebration) > 1.2 else { return }
        lastCelebration = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        guard !Theme.reduceMotion, window != nil else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0.0, 1.0, 0.0]; fade.keyTimes = [0, 0.18, 1]
        let spread = CAKeyframeAnimation(keyPath: "transform.scale"); spread.values = [0.55, 1.0, 1.12]; spread.keyTimes = [0, 0.35, 1]
        let group = CAAnimationGroup(); group.animations = [fade, spread]; group.duration = 0.42
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bloom.add(group, forKey: "bloom")
    }

    // MARK: Value

    /// Sets the value. `celebrate` is for user-initiated changes only; model
    /// refreshes never trigger the 100% bloom.
    func setPercent(_ newValue: Double, animated: Bool, celebrate: Bool = false) {
        let previous = value
        value = clamp(newValue)
        updateAccessibility()
        placeLayers(animated: animated)
        if celebrate && previous < 100 && value >= 100 { self.celebrate() }
    }

    private func updateAccessibility() {
        let shown = Int(value.rounded())
        setAccessibilityValueDescription(minimumPercent > 0 && value <= minimumPercent ? "\(shown) percent, hardware minimum" : "\(shown) percent of maximum fan speed")
    }

    private func userChange(to target: Double, animated: Bool) {
        let next = clamp(target.rounded()), previous = value
        guard next != previous else { return }
        let low = min(previous, next), high = max(previous, next)
        if ([minimumPercent, 100] + detents).contains(where: { $0 >= low && $0 <= high && abs($0 - previous) >= 0.5 }) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
    func prepareForHiding() {
        cancelDrag(); flushKeyCommit()
        hovered = false; keyboardFocus = false; updateThumbShape()
        thumb.removeAllAnimations(); dimDots.removeAllAnimations(); bloom.removeAllAnimations()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        flushKeyCommit()
        if keyboardFocus { keyboardFocus = false; noteFocusRingMaskChanged() }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil), thumbX = x(for: value)
        dragStart = value; dragging = true; updateThumbShape()
        // Grabbing the thumb keeps its offset; clicking the track glides there.
        if abs(point.x - thumbX) <= Metric.grabSlop { grabOffset = point.x - thumbX }
        else { grabOffset = 0; userChange(to: percentage(at: point.x), animated: true) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        userChange(to: percentage(at: convert(event.locationInWindow, from: nil).x - grabOffset), animated: false)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        userChange(to: percentage(at: convert(event.locationInWindow, from: nil).x - grabOffset), animated: false)
        endDrag(commit: true)
    }
    private func endDrag(commit shouldCommit: Bool) {
        dragging = false; updateThumbShape()
        if shouldCommit && value != dragStart { sendCommit() } else { preview?(value) }   // lets the owner drop "Release to apply"
    }
    private func cancelDrag() {
        guard dragging else { return }
        dragging = false
        setPercent(dragStart, animated: true); preview?(dragStart); updateThumbShape()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { if dragging { endDrag(commit: true) }; flushKeyCommit() }
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
    /// Keys preview immediately and commit once typing pauses, so holding an
    /// arrow key does not queue a helper write per repeat.
    private func nudge(to target: Double) {
        guard isEnabled, !dragging else { return }
        userChange(to: target, animated: true)
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
        let grid = gridRect.insetBy(dx: -8, dy: -7)
        NSBezierPath(roundedRect: grid, xRadius: 6, yRadius: 6).fill()
    }

    // MARK: Drawing helpers

    private static func bitmap(_ size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded(.up))), height = max(1, Int((size.height * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        return ctx.makeImage()
    }
    private static func dot(_ ctx: CGContext, _ column: Int, _ row: Int) {
        let rect = CGRect(x: CGFloat(column) * Metric.pitch, y: CGFloat(row) * Metric.pitch, width: Metric.dot, height: Metric.dot)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil)); ctx.fillPath()
    }
    /// Deterministic per-dot variation: a faint LED-matrix texture, no motion.
    private static func noise(_ a: Int, _ b: Int) -> CGFloat {
        var h = UInt32(truncatingIfNeeded: (a &* 73_856_093) ^ (b &* 19_349_663))
        h ^= h >> 13; h = h &* 1_274_126_177; h ^= h >> 16
        return CGFloat(h & 0xffff) / 65_535
    }
}

final class TemperatureHistory: NSView {
    var samples: [Double] = [] { didSet { if samples != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        guard samples.count > 1 else { return }
        let r = bounds.insetBy(dx: 3, dy: 4), low = max(10, (samples.min() ?? 30) - 3), high = max(low + 6, (samples.max() ?? 60) + 3)
        let path = NSBezierPath(); path.lineWidth = 1.25; path.lineCapStyle = .round; path.lineJoinStyle = .round
        var last = NSPoint.zero
        for (i, value) in samples.enumerated() {
            last = NSPoint(x: r.minX + CGFloat(i) / CGFloat(max(1, samples.count - 1)) * r.width, y: r.minY + CGFloat((value - low) / (high - low)) * r.height)
            if i == 0 { path.move(to: last) } else { path.line(to: last) }
        }
        Theme.accent.withAlphaComponent(0.7).setStroke(); path.stroke()
        Theme.accent.setFill(); NSBezierPath(ovalIn: NSRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)).fill()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Recent temperature trend" }
}
