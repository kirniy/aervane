import AppKit
import QuartzCore

/// A native keyboard- and VoiceOver-accessible control. Values always mean a
/// percentage of maximum physical speed. The region below `minimumPercent` is
/// the firmware floor: drawn as always running, never reachable by the thumb.
///
/// The control renders cooling power as frost on glass. One energy curve
/// (`SliderEnergy`) drives everything progressive: lit dots cool from mint
/// through glacier cyan to ice white and grow denser, a white-hot head trails
/// the thumb, a halo gathers around it, and above ~45% fine hoarfrost grains
/// cling to the lit edges. At full cooling the lattice itself crystallises:
/// a freezing front runs back from the thumb with a single glint riding it,
/// then the crystals stay as static artwork until the value drops and they
/// melt away.
///
/// Pointer tracking uses plain mouseDown/mouseDragged/mouseUp, so the run loop
/// keeps delivering model updates mid-drag. All artwork is rendered into
/// cached bitmaps once per size, scale, appearance or floor change; movement
/// only repositions, masks or fades layers. Nothing animates while idle.
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
    /// Measured fan speed as a percentage of maximum. Shown as a ghost mark
    /// on the track when it differs from the requested value.
    var measuredPercent: Double? { didSet { if measuredPercent != oldValue { placeMeasured(animated: true); updateAccessibility() } } }
    /// Decoration ceiling (user level, lowered by system accessibility).
    var effects = Theme.effects { didSet { if effects != oldValue { applyDecor(animated: false, userAction: false) } } }
    var preview: ((Double) -> Void)?
    var commit: ((Double) -> Void)?
    private(set) var dragging = false
    /// True while a drag or a debounced keyboard change has not been committed.
    var isInteracting: Bool { dragging || keyCommitPending }
    /// The full-cooling ice crown is present (static once formed).
    private(set) var isIceFormed = false

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

    private let dimDots = CALayer(), litDots = CALayer(), litMask = CALayer()
    private let sparkDots = CALayer(), headMask = CAGradientLayer()
    private let frost = CALayer(), frostMask = CALayer()
    private let floorTick = CALayer(), measuredMark = CALayer(), halo = CAGradientLayer()
    private let crownFringe = CALayer(), crownMask = CAGradientLayer()
    private let crownGlint = CALayer(), glintMask = CAGradientLayer()
    private let bloom = CALayer(), thumb = CALayer()

    private enum Metric {
        static let dot: CGFloat = 2, pitch: CGFloat = 3, rows = 5
        static let inset: CGFloat = 16            // thumb, halo and crown room at both ends
        static let thumb = CGSize(width: 6, height: 20)
        static let grabSlop: CGFloat = 10         // pick the thumb up without a jump
        static let glide: CFTimeInterval = 0.2
        static let bloomReach = 5, bloomLift = 5  // in grid cells
        static let frostFringe: CGFloat = 8       // grain room above and below the dots
        static let crownFringe: CGFloat = 3       // facets overhang the dots slightly
        static let glintBand: CGFloat = 30
        static let head: CGFloat = 120
        /// Freezing front: one stroke from the thumb to the crystal onset.
        static let form: CFTimeInterval = 0.62
        static let melt: CFTimeInterval = 0.28
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
        // The head is a horizontal light falloff that peaks just behind the
        // thumb; it lives inside the lit layer so it can never light dots
        // ahead of the value.
        sparkDots.mask = headMask; litDots.addSublayer(sparkDots)
        headMask.startPoint = CGPoint(x: 0, y: 0.5); headMask.endPoint = CGPoint(x: 1, y: 0.5)
        headMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        headMask.locations = [0, 0.86, 1]; headMask.anchorPoint = CGPoint(x: 0.86, y: 0.5)
        frost.mask = frostMask
        frostMask.backgroundColor = NSColor.black.cgColor; frostMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        halo.type = .radial; halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        // The crown reveals from the thumb end leftward as it forms.
        crownFringe.mask = crownMask
        crownMask.startPoint = CGPoint(x: 1, y: 0.5); crownMask.endPoint = CGPoint(x: 0, y: 0.5)
        crownMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        crownMask.locations = [0, 1, 1]
        // The glint is the same facets in white, seen through a narrow band.
        crownGlint.mask = glintMask
        glintMask.startPoint = CGPoint(x: 0, y: 0.5); glintMask.endPoint = CGPoint(x: 1, y: 0.5)
        glintMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        glintMask.locations = [0, 0.5, 1]
        for layer in [sparkDots, frost, halo, crownFringe, crownGlint, measuredMark, bloom] { layer.opacity = 0 }
        for layer in [dimDots, litDots, sparkDots, frost, crownFringe, crownGlint, bloom] { layer.contentsGravity = .resize }
        [dimDots, litDots, frost, floorTick, measuredMark, halo, crownFringe, crownGlint, bloom, thumb].forEach(root.addSublayer)
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
        applyDecor(animated: false, userAction: false)
        placeMeasured(animated: false)
    }

    private var columns: Int { Self.columns(width: bounds.width) }
    private var gridRect: NSRect { Self.grid(in: bounds) }
    private static func columns(width: CGFloat) -> Int { max(2, Int(((width - 2 * Metric.inset - Metric.dot) / Metric.pitch).rounded(.down)) + 1) }
    private static func grid(in bounds: NSRect) -> NSRect {
        let width = CGFloat(columns(width: bounds.width) - 1) * Metric.pitch + Metric.dot
        let height = CGFloat(Metric.rows - 1) * Metric.pitch + Metric.dot
        return NSRect(x: ((bounds.width - width) / 2).rounded(.down), y: ((bounds.height - height) / 2).rounded(.down), width: width, height: height)
    }
    /// Horizontal position of a value inside a slider of the given width;
    /// lets the owner align scale marks before the slider is laid out.
    static func trackX(percent: Double, width: CGFloat) -> CGFloat {
        let grid = grid(in: NSRect(x: 0, y: 0, width: width, height: 1))
        return grid.minX + Metric.dot / 2 + CGFloat(max(0, min(100, percent)) / 100) * (grid.width - Metric.dot)
    }
    private func x(for percent: Double) -> CGFloat { Self.trackX(percent: percent, width: bounds.width) }
    private func percentage(at x: CGFloat) -> Double {
        let grid = gridRect
        return Double((x - grid.minX - Metric.dot / 2) / max(1, grid.width - Metric.dot)) * 100
    }
    private func clamp(_ v: Double) -> Double { max(minimumPercent, min(100, v.isFinite ? v : minimumPercent)) }
    /// Rounds to the device pixel grid so hairline marks stay crisp at 1×.
    private func snap(_ v: CGFloat) -> CGFloat { let s = renderedScale > 0 ? renderedScale : 2; return (v * s).rounded() / s }

    // MARK: Artwork (rendered once per geometry/appearance)

    private func renderField(scale: CGFloat) {
        guard bounds.width > 4 * Metric.inset, bounds.height > 0 else { return }
        fieldDirty = false; renderedSize = bounds.size; renderedScale = scale
        let grid = gridRect, cols = columns, floorValue = minimumPercent
        let reach = Metric.bloomReach, lift = Metric.bloomLift
        let bloomSize = CGSize(width: CGFloat(2 * reach) * Metric.pitch + Metric.dot, height: CGFloat(2 * lift) * Metric.pitch + Metric.dot)
        let frostSize = CGSize(width: grid.width, height: grid.height + 2 * Metric.frostFringe)
        let crownSize = CGSize(width: grid.width, height: grid.height + 2 * Metric.crownFringe)
        func columnPercent(_ c: Int) -> Double { Double(c) / Double(cols - 1) * 100 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = Theme.dark
            let rest = Theme.ink.withAlphaComponent(dark ? 0.14 : 0.12).cgColor
            let held = Theme.iceLow.withAlphaComponent(dark ? 0.30 : 0.26).cgColor
            let low = Theme.iceLow.usingColorSpace(.sRGB) ?? Theme.iceLow
            let mid = Theme.iceMid.usingColorSpace(.sRGB) ?? Theme.iceMid
            let high = Theme.iceHigh.usingColorSpace(.sRGB) ?? Theme.iceHigh
            let rime = Theme.rime.usingColorSpace(.sRGB) ?? Theme.rime
            /// Cooling ramp: mint → glacier cyan → ice white; alpha rises with it.
            func lit(_ v: Double) -> CGColor {
                let t = v / 100
                let tone = t < 0.6 ? (low.blended(withFraction: t / 0.6, of: mid) ?? mid)
                                   : (mid.blended(withFraction: (t - 0.6) / 0.4, of: high) ?? high)
                return tone.withAlphaComponent(0.38 + 0.62 * pow(t, 1.1)).cgColor
            }
            self.dimDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                ctx.setFillColor(rest)
                for c in 0..<cols { for r in 0..<Metric.rows { Self.dot(ctx, c, r, size: Metric.dot) } }
            }
            self.litDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                for c in 0..<cols {
                    let v = columnPercent(c), below = v < floorValue
                    ctx.setFillColor(below ? held : lit(v))
                    let size = below ? Metric.dot : CGFloat(SliderEnergy.dotSize(percent: v))
                    for r in 0..<Metric.rows { ctx.setAlpha(0.9 + 0.1 * Self.noise(c, r)); Self.dot(ctx, c, r, size: size) }
                }
            }
            self.sparkDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                ctx.setFillColor((dark ? NSColor.white : high).cgColor)
                for c in 0..<cols { for r in 0..<Metric.rows { Self.dot(ctx, c, r, size: CGFloat(SliderEnergy.dotSize(percent: columnPercent(c))) + 0.2) } }
            }
            // Hoarfrost: fine grains crowd the lit edges from the frost onset,
            // thicker and reaching further toward full cooling, with a few
            // needles near the top. Rendered once; the mask reveals it.
            self.frost.contents = Self.bitmap(frostSize, scale: scale) { ctx in
                ctx.setFillColor(rime.cgColor); ctx.setStrokeColor(rime.cgColor); ctx.setLineCap(.round)
                let reach = Metric.frostFringe - 1
                for c in 0..<cols {
                    let v = columnPercent(c), w = CGFloat(Frost.amount(percent: v))
                    guard w > 0.02, v >= floorValue else { continue }
                    let x = CGFloat(c) * Metric.pitch + Metric.dot / 2
                    for (side, up) in [(0, true), (1, false)] {
                        let edge = up ? Metric.frostFringe + grid.height + 0.3 : Metric.frostFringe - 0.3
                        for k in 0..<Frost.grains(amount: Double(w), noise: Double(Self.noise(c, 41 + side))) {
                            let seed = c * 7 + k
                            let d = pow(Self.noise(seed, 53 + side), 1.7) * (1.2 + (reach - 1.2) * w)
                            let size = (0.95 - 0.4 * d / reach) * (0.75 + 0.25 * Self.noise(seed, 61 + side))
                            let cx = x + (Self.noise(seed, 59 + side) - 0.5) * 2.4, cy = up ? edge + d : edge - d
                            ctx.setAlpha((0.22 + 0.6 * w) * (1 - 0.55 * d / reach))
                            ctx.fillEllipse(in: CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
                        }
                        if w > 0.45, Self.noise(c, 67 + side) < (w - 0.45) * 0.7 {
                            let length = (1.6 + 3.2 * w) * (0.6 + 0.4 * Self.noise(c, 71 + side))
                            let dir = Self.rotate(CGVector(dx: 0, dy: up ? 1 : -1), (Self.noise(c, 73 + side) - 0.5) * 0.7)
                            ctx.setAlpha(0.3 + 0.5 * w); ctx.setLineWidth(0.5)
                            ctx.move(to: CGPoint(x: x, y: edge)); ctx.addLine(to: CGPoint(x: x + dir.dx * length, y: edge + dir.dy * length))
                            ctx.strokePath()
                        }
                    }
                }
            }
            // The crown: the top of the lattice crystallises. Each lit dot
            // becomes a faceted diamond that touches its neighbours, so the
            // track reads as one sheet of ice, with a hairline rim on both
            // edges. The glint layer holds the same facets in white.
            func facets(_ ctx: CGContext, glint: Bool) {
                for c in 0..<cols {
                    let v = columnPercent(c), w = CGFloat(Frost.crystal(percent: v))
                    guard w > 0.01, v >= floorValue else { continue }
                    let cx = CGFloat(c) * Metric.pitch + Metric.dot / 2
                    for r in 0..<Metric.rows {
                        let cy = CGFloat(r) * Metric.pitch + Metric.dot / 2 + Metric.crownFringe
                        let s = (1.05 + 0.5 * w) * (0.9 + 0.1 * Self.noise(c, r + 83))
                        ctx.setAlpha(glint ? w : (0.3 + 0.62 * w) * (0.82 + 0.18 * Self.noise(c, r + 89)))
                        ctx.move(to: CGPoint(x: cx, y: cy + s)); ctx.addLine(to: CGPoint(x: cx + s, y: cy))
                        ctx.addLine(to: CGPoint(x: cx, y: cy - s)); ctx.addLine(to: CGPoint(x: cx - s, y: cy)); ctx.closePath()
                        ctx.fillPath()
                    }
                }
            }
            let onset = Self.trackX(percent: Frost.crystalOnset, width: self.bounds.width) - grid.minX
            self.crownFringe.contents = Self.bitmap(crownSize, scale: scale) { ctx in
                ctx.setFillColor(rime.cgColor); facets(ctx, glint: false); ctx.setAlpha(1)
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                             colors: [rime.withAlphaComponent(0).cgColor, rime.withAlphaComponent(0.75).cgColor] as CFArray, locations: [0, 1]) {
                    for y in [Metric.crownFringe + grid.height + 1.2, Metric.crownFringe - 1.7] {
                        ctx.saveGState(); ctx.clip(to: CGRect(x: onset, y: y, width: grid.width - onset, height: 0.5))
                        ctx.drawLinearGradient(gradient, start: CGPoint(x: onset, y: 0), end: CGPoint(x: grid.width, y: 0), options: [])
                        ctx.restoreGState()
                    }
                }
            }
            self.crownGlint.contents = Self.bitmap(crownSize, scale: scale) { ctx in
                ctx.setFillColor(NSColor.white.cgColor); facets(ctx, glint: true)
            }
            // Sparse ice glints on the same lattice, vertically symmetric so it
            // is independent of layer geometry flipping.
            self.bloom.contents = Self.bitmap(bloomSize, scale: scale) { ctx in
                ctx.setFillColor((dark ? NSColor.white : rime).cgColor)
                for dx in -reach...reach {
                    for dy in -lift...lift {
                        let d = (Double(dx * dx) + Double(dy * dy) * 1.6).squareRoot() / Double(reach)
                        guard d <= 1 else { continue }
                        let n = Double(Self.noise(abs(dx) + 17, abs(dy) + 31))
                        if d > 0.3 && n < d * 0.8 { continue }
                        ctx.setAlpha(CGFloat(pow(1 - d, 1.5) * (0.6 + 0.4 * n)))
                        Self.dot(ctx, dx + reach, dy + lift, size: Metric.dot)
                    }
                }
            }
            self.halo.colors = [Theme.iceMid.withAlphaComponent(dark ? 0.55 : 0.32).cgColor, Theme.iceMid.withAlphaComponent(0).cgColor]
            self.measuredMark.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.5 : 0.42).cgColor
            self.floorTick.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.32 : 0.26).cgColor
            self.thumb.backgroundColor = NSColor.white.cgColor
            self.thumb.shadowColor = NSColor.black.cgColor
            self.thumb.shadowOpacity = dark ? 0.45 : 0.22
        }
        for layer in [dimDots, litDots, sparkDots, frost, crownFringe, crownGlint, bloom] { layer.contentsScale = scale }
        dimDots.frame = grid; litDots.frame = grid
        sparkDots.frame = CGRect(origin: .zero, size: grid.size)
        headMask.bounds = CGRect(x: 0, y: 0, width: Metric.head, height: grid.height)
        litMask.bounds = CGRect(x: 0, y: 0, width: 0, height: grid.height); litMask.position = CGPoint(x: 0, y: grid.height / 2)
        frost.frame = grid.insetBy(dx: 0, dy: -Metric.frostFringe)
        frostMask.bounds = CGRect(x: 0, y: 0, width: 0, height: frost.bounds.height); frostMask.position = CGPoint(x: 0, y: frost.bounds.height / 2)
        crownFringe.frame = grid.insetBy(dx: 0, dy: -Metric.crownFringe)
        crownMask.frame = crownFringe.bounds
        crownGlint.frame = crownFringe.frame
        glintMask.bounds = CGRect(x: 0, y: 0, width: Metric.glintBand, height: crownGlint.bounds.height)
        glintMask.position = CGPoint(x: x(for: 100) - grid.minX, y: crownGlint.bounds.height / 2)
        // Compact halo: the crystals carry full cooling, not a wider glow.
        halo.bounds = CGRect(x: 0, y: 0, width: 52, height: 34)
        measuredMark.bounds = CGRect(x: 0, y: 0, width: 2, height: grid.height + 4); measuredMark.cornerRadius = 1
        bloom.bounds = CGRect(origin: .zero, size: bloomSize); bloom.position = CGPoint(x: x(for: 100), y: grid.midY)
        floorTick.isHidden = floorValue <= 0
        floorTick.frame = CGRect(x: (x(for: floorValue) - Metric.pitch / 2).rounded(), y: grid.minY - 4, width: 1, height: grid.height + 8)
        thumb.bounds = CGRect(origin: .zero, size: Metric.thumb)
        thumb.cornerRadius = Metric.thumb.width / 2
        thumb.shadowRadius = 1.5; thumb.shadowOffset = .zero
        thumb.shadowPath = CGPath(roundedRect: thumb.bounds, cornerWidth: thumb.cornerRadius, cornerHeight: thumb.cornerRadius, transform: nil)
        styleThumb()
        CATransaction.commit()
    }

    private func styleThumb() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Frozen thumb: an icy rim while the crown is present.
            self.thumb.borderColor = self.isIceFormed ? Theme.rime.withAlphaComponent(0.95).cgColor : NSColor.black.withAlphaComponent(Theme.dark ? 0 : 0.16).cgColor
        }
        thumb.borderWidth = isIceFormed ? 1 : 0.5
    }

    // MARK: Placement and progressive decoration

    /// Sets a layer property and, when animated, eases from what is on
    /// screen now, so a new target interrupts an old one cleanly. Key paths
    /// are whole properties (position, bounds, opacity, transform), which
    /// are always KVC-readable on CALayer.
    private func change(_ layer: CALayer, _ keyPath: String, animated: Bool, duration: CFTimeInterval = Metric.glide,
                        timing: CAMediaTimingFunction = Theme.Ease.out, _ apply: () -> Void) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        apply()
        guard animated, let from else { layer.removeAnimation(forKey: keyPath); return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from; animation.toValue = layer.value(forKeyPath: keyPath)
        animation.duration = duration; animation.timingFunction = timing
        layer.add(animation, forKey: keyPath)
    }

    /// Moves thumb, fill, frost reveal, head and halo together.
    private func placeLayers(animated: Bool) {
        let grid = gridRect, targetX = x(for: value), fill = max(0, targetX - grid.minX)
        let glide = animated && effects.animates && window != nil && abs((thumb.presentation() ?? thumb).position.x - targetX) > 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(thumb, "position", animated: glide) { thumb.position = CGPoint(x: targetX, y: grid.midY) }
        change(halo, "position", animated: glide) { halo.position = CGPoint(x: targetX, y: grid.midY) }
        change(litMask, "bounds", animated: glide) { litMask.bounds = CGRect(x: 0, y: 0, width: fill, height: grid.height) }
        change(frostMask, "bounds", animated: glide) { frostMask.bounds = CGRect(x: 0, y: 0, width: fill, height: frost.bounds.height) }
        change(headMask, "position", animated: glide) { headMask.position = CGPoint(x: fill, y: grid.height / 2) }
        CATransaction.commit()
    }

    /// Intensities derived from the value: glow, head length, frost and the
    /// crown. `userAction` distinguishes a person reaching full cooling from
    /// a model refresh (which never plays the formation).
    private func applyDecor(animated: Bool, userAction: Bool) {
        let energy = SliderEnergy.level(percent: value), amount = Frost.amount(percent: value)
        let interaction = dragging ? 1.0 : hovered ? 0.85 : 0.7
        let animate = animated && effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(halo, "opacity", animated: animate, duration: 0.25) { halo.opacity = Float(effects.glow * (0.12 + 0.88 * energy) * interaction) }
        change(halo, "transform", animated: animate, duration: 0.25) {
            let s = CGFloat(0.7 + 0.4 * energy); halo.transform = CATransform3DMakeScale(s, s, 1)
        }
        change(sparkDots, "opacity", animated: animate, duration: 0.25) { sparkDots.opacity = Float(effects.glow * (0.1 + 0.9 * energy) * interaction) }
        change(headMask, "transform", animated: animate, duration: 0.25) { headMask.transform = CATransform3DMakeScale(CGFloat(0.3 + energy), 1, 1) }
        change(frost, "opacity", animated: animate, duration: 0.3) { frost.opacity = Float(amount > 0 ? effects.frost * (0.3 + 0.7 * amount) : 0) }
        let crowned = Frost.crowned(percent: value) && effects.frost > 0
        // A drag tracks instantly but may still form/melt the decorative
        // crown. Keyboard changes have neither a drag nor animated travel.
        let animateCrown = (animated || userAction && dragging) && effects.animates && window != nil
        // A gliding thumb lands before the ice forms around it; under a drag
        // the thumb is already there.
        if crowned != isIceFormed { setCrown(crowned, form: userAction && animateCrown && effects.forms, animated: animateCrown, delay: animated ? Metric.glide * 0.5 : 0) }
        else if crowned { crownFringe.opacity = Float(effects.frost) }
        CATransaction.commit()
    }

    /// Forms (or melts) the ice crown. The formed state is static artwork:
    /// model values hold it after any transition finishes.
    ///
    /// Formation is one stroke: the thumb's rim freezes, a front of crystals
    /// runs back from the thumb to the crystal onset, and a single glint rides
    /// that front. Melting freezes the front wherever it is and fades it, so
    /// a drag that touches 100% and leaves never snaps to a full crown.
    private func setCrown(_ shown: Bool, form: Bool, animated: Bool, delay: CFTimeInterval = 0) {
        isIceFormed = shown
        let opacity = Float(shown ? effects.frost : 0)
        let grid = gridRect, thumbX = x(for: 100) - grid.minX
        CATransaction.begin(); CATransaction.setDisableActions(true)
        styleThumb()
        crownGlint.removeAllAnimations(); glintMask.removeAllAnimations(); crownGlint.opacity = 0
        if shown {
            crownMask.removeAllAnimations(); crownMask.locations = [0, 1, 1]
            glintMask.position = CGPoint(x: thumbX, y: crownGlint.bounds.height / 2)
        }
        if shown && form {
            crownFringe.opacity = opacity
            crownFringe.removeAnimation(forKey: "opacity")
            // The crystals occupy the top of the range; the front crosses
            // exactly that span, so its speed is what the eye follows.
            let span = Double(max(0.05, min(1, (thumbX - (Self.trackX(percent: Frost.crystalOnset, width: bounds.width) - grid.minX)) / max(1, grid.width))))
            let spread = CABasicAnimation(keyPath: "locations")
            spread.fromValue = [0, 0, 0.05]; spread.toValue = [0, span, span + 0.06]
            spread.duration = Metric.form; spread.timingFunction = Theme.Ease.out
            let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = 0; appear.toValue = opacity; appear.duration = 0.12
            let ride = CABasicAnimation(keyPath: "position.x")
            ride.fromValue = thumbX; ride.toValue = thumbX - CGFloat(span) * grid.width
            ride.duration = Metric.form; ride.timingFunction = Theme.Ease.out
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 0.9 * opacity, 0]; flash.keyTimes = [0, 0.2, 1]; flash.duration = Metric.form
            let start = CACurrentMediaTime() + delay
            for animation in [spread, appear, ride, flash] as [CAAnimation] { animation.beginTime = start; animation.fillMode = .backwards }
            crownMask.add(spread, forKey: "form"); crownFringe.add(appear, forKey: "appear")
            glintMask.add(ride, forKey: "glint"); crownGlint.add(flash, forKey: "glint")
        } else {
            if !shown, let current = (crownMask.presentation() ?? crownMask).locations {
                crownMask.removeAllAnimations(); crownMask.locations = current
            }
            change(crownFringe, "opacity", animated: animated, duration: shown ? 0.2 : Metric.melt, timing: shown ? Theme.Ease.out : Theme.Ease.inOut) { crownFringe.opacity = opacity }
            crownFringe.removeAnimation(forKey: "appear")
        }
        CATransaction.commit()
    }

    private func placeMeasured(animated: Bool) {
        guard measuredMark.superlayer != nil, bounds.width > 4 * Metric.inset else { return }
        let grid = gridRect
        let visible = measuredPercent.map { $0.isFinite && abs($0 - value) >= 3 } ?? false
        let animate = animated && effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Pixel-snapped, so sample-to-sample RPM jitter usually leaves the
        // mark where it is and adds no animation.
        if let measured = measuredPercent, measured.isFinite {
            let position = CGPoint(x: snap(x(for: measured)), y: grid.midY)
            if position != measuredMark.position {
                change(measuredMark, "position", animated: animate && measuredMark.opacity > 0, duration: 0.45, timing: Theme.Ease.inOut) {
                    measuredMark.position = position
                }
            }
        }
        if measuredMark.opacity != (visible ? 1 : 0) {
            change(measuredMark, "opacity", animated: animate, duration: 0.2) { measuredMark.opacity = visible ? 1 : 0 }
        }
        CATransaction.commit()
        toolTip = visible ? measuredPercent.map { "Fan now \(Int($0.rounded()))%" } : nil
    }

    private func updateThumbShape() {
        let target = dragging ? CATransform3DMakeScale(1.34, 1.12, 1) : hovered && isEnabled ? CATransform3DMakeScale(1.17, 1.05, 1) : CATransform3DIdentity
        let restOpacity: Float = hovered || dragging ? 1 : 0.82
        let animate = effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(thumb, "transform", animated: animate, duration: 0.15) { thumb.transform = target }
        change(dimDots, "opacity", animated: animate, duration: 0.15) { dimDots.opacity = restOpacity }
        CATransaction.commit()
        applyDecor(animated: true, userAction: false)
    }

    /// Acknowledges a pointer release: a short pulse of light runs from the
    /// thumb back along the lit dots toward the fan's start.
    private func sweep() {
        guard effects.sweep, window != nil, value > minimumPercent + 1 else { return }
        let current = (sparkDots.presentation() ?? sparkDots).opacity
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = headMask.position.x; travel.toValue = -Metric.head * 0.2
        travel.duration = 0.55; travel.timingFunction = Theme.Ease.out
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [current, min(1, current + 0.55), current]; flash.keyTimes = [0, 0.22, 1]; flash.duration = 0.55
        headMask.add(travel, forKey: "sweep"); sparkDots.add(flash, forKey: "sweep")
    }

    /// One haptic when a user action reaches 100%, plus a short bloom where
    /// no formation plays. Never repeats within a second; the bloom is
    /// skipped for keyboard changes and with Reduce Motion.
    private func celebrate(animated: Bool) {
        guard Date().timeIntervalSince(lastCelebration) > 1.2 else { return }
        lastCelebration = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // Where the crown forms, the formation is the acknowledgement; the
        // bloom is the lighter one for Subtle.
        guard animated, effects.bloom, !effects.forms, window != nil else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0.0, 1.0, 0.0]; fade.keyTimes = [0, 0.18, 1]
        let spread = CAKeyframeAnimation(keyPath: "transform.scale"); spread.values = [0.55, 1.0, 1.15]; spread.keyTimes = [0, 0.35, 1]
        let group = CAAnimationGroup(); group.animations = [fade, spread]; group.duration = 0.48
        group.timingFunction = Theme.Ease.out
        bloom.add(group, forKey: "bloom")
    }

    // MARK: Value

    /// Sets the value. `celebrate` marks user-initiated changes; model
    /// refreshes never form the ice crown or glint. Keyboard callers pass
    /// `animated: false` so keys are always instant.
    func setPercent(_ newValue: Double, animated: Bool, celebrate: Bool = false) {
        let previous = value
        value = clamp(newValue)
        if value != previous {
            headMask.removeAnimation(forKey: "sweep"); sparkDots.removeAnimation(forKey: "sweep")
            if value < 100 { bloom.removeAllAnimations() }
        }
        updateAccessibility()
        placeLayers(animated: animated)
        applyDecor(animated: animated, userAction: celebrate)
        placeMeasured(animated: false)
        if celebrate && previous < 100 && value >= 100 { self.celebrate(animated: animated) }
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
    /// Ends interaction and settles every transient animation, leaving only
    /// static state (including a formed crown) for the next time it shows.
    func prepareForHiding() {
        cancelDrag(); flushKeyCommit()
        hovered = false; keyboardFocus = false; updateThumbShape()
        allLayers.forEach { $0.removeAllAnimations() }
    }
    private var allLayers: [CALayer] { [thumb, dimDots, litDots, litMask, sparkDots, headMask, frost, frostMask, floorTick, halo, measuredMark, crownFringe, crownMask, crownGlint, glintMask, bloom] }
    /// Running transient animations across the control (lifecycle tests).
    var transientAnimationCount: Int { allLayers.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        flushKeyCommit()
        if keyboardFocus { keyboardFocus = false; noteFocusRingMaskChanged() }
        window?.makeFirstResponder(self)
        headMask.removeAnimation(forKey: "sweep"); sparkDots.removeAnimation(forKey: "sweep")
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
        if shouldCommit && value != dragStart { sweep(); sendCommit() } else { preview?(value) }   // lets the owner drop the preview state
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
    /// Keys and VoiceOver change the value instantly (no glide, no ice
    /// formation) and commit once input pauses, so holding an arrow key
    /// does not queue a helper write per repeat.
    private func nudge(to target: Double) {
        guard isEnabled, !dragging else { return }
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
    /// One lattice dot, centred in its 2 pt cell so larger dots grow evenly.
    private static func dot(_ ctx: CGContext, _ column: Int, _ row: Int, size: CGFloat) {
        let cx = CGFloat(column) * Metric.pitch + Metric.dot / 2, cy = CGFloat(row) * Metric.pitch + Metric.dot / 2
        let rect = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.3, cornerHeight: size * 0.3, transform: nil)); ctx.fillPath()
    }
    private static func rotate(_ v: CGVector, _ angle: CGFloat) -> CGVector {
        CGVector(dx: v.dx * cos(angle) - v.dy * sin(angle), dy: v.dx * sin(angle) + v.dy * cos(angle))
    }
    /// Deterministic per-dot variation: a faint LED-matrix texture, no motion.
    private static func noise(_ a: Int, _ b: Int) -> CGFloat {
        var h = UInt32(truncatingIfNeeded: (a &* 73_856_093) ^ (b &* 19_349_663))
        h ^= h >> 13; h = h &* 1_274_126_177; h ^= h >> 16
        return CGFloat(h & 0xffff) / 65_535
    }
}
