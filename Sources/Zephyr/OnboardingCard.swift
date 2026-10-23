import AppKit
import QuartzCore
import ServiceManagement

/// A small, truthful glance at the fan for the introduction: a dot lattice
/// lit to the fan's *measured* speed, with that figure beside it. On first
/// appearance the lit dots cascade in from the left once (a finite reveal);
/// afterwards each new reading eases the lit length. No fake values: without
/// a reading nothing is lit and the figure is a dash.
final class FanGlance: NSView {
    private static let rows = 4, pitch: CGFloat = 6, dot: CGFloat = 3
    private let tray = CALayer(), dim = CALayer(), lit = CALayer(), litMask = CALayer()
    private let figure = label("—", size: 13, weight: .semibold, color: .secondaryLabelColor)
    private var fraction: Double = 0, floor: Double = 0, rendered = NSSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [tray, dim, lit] { layer.contentsGravity = .resize; self.layer?.addSublayer(layer) }
        lit.mask = litMask; litMask.backgroundColor = NSColor.black.cgColor; litMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        figure.font = Theme.number(13, .semibold); figure.alignment = .right
        addSubview(figure)
        setAccessibilityElement(true); setAccessibilityRole(.levelIndicator); setAccessibilityLabel("Fan now")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rendered = .zero; needsLayout = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); rendered = .zero; needsLayout = true }

    private var latticeRect: NSRect { NSRect(x: 0, y: 0, width: max(0, bounds.width - 52), height: bounds.height) }

    override func layout() {
        super.layout()
        figure.frame = NSRect(x: bounds.width - 48, y: (bounds.height - 17) / 2, width: 48, height: 17)
        guard bounds.size != rendered, bounds.width > 60 else { return }
        rendered = bounds.size
        let scale = window?.backingScaleFactor ?? 2, area = latticeRect
        let columns = max(2, Int((area.width - 16) / Self.pitch))
        let width = CGFloat(columns - 1) * Self.pitch + Self.dot, height = CGFloat(Self.rows - 1) * Self.pitch + Self.dot
        let origin = CGPoint(x: area.minX + (area.width - width) / 2, y: (area.height - height) / 2)
        func dots(_ ctx: CGContext, color: (Int) -> CGColor) {
            for c in 0..<columns {
                ctx.setFillColor(color(c))
                for r in 0..<Self.rows {
                    let x = origin.x + CGFloat(c) * Self.pitch, y = origin.y + CGFloat(r) * Self.pitch
                    ctx.fillEllipse(in: CGRect(x: x, y: y, width: Self.dot, height: Self.dot))
                }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = Theme.dark
            self.tray.contents = SliderSkin.bitmap(area.size, scale: scale) { ctx in
                let path = CGPath(roundedRect: CGRect(origin: .zero, size: area.size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: 9, cornerHeight: 9, transform: nil)
                ctx.addPath(path); ctx.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.22 : 0.045).cgColor); ctx.fillPath()
                ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.4 : 0.1).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
            }
            let rest = Theme.ink.withAlphaComponent(dark ? 0.2 : 0.16).cgColor
            self.dim.contents = SliderSkin.bitmap(area.size, scale: scale) { ctx in dots(ctx) { _ in rest } }
            let low = Theme.iceLow.usingColorSpace(.sRGB) ?? Theme.iceLow, mid = Theme.iceMid.usingColorSpace(.sRGB) ?? Theme.iceMid
            self.lit.contents = SliderSkin.bitmap(area.size, scale: scale) { ctx in
                dots(ctx) { c in (low.blended(withFraction: CGFloat(c) / CGFloat(max(1, columns - 1)), of: mid) ?? mid).cgColor }
            }
        }
        for layer in [tray, dim, lit] { layer.frame = area; layer.contentsScale = scale }
        litMask.bounds = CGRect(x: 0, y: 0, width: litWidth, height: area.height); litMask.position = CGPoint(x: 0, y: area.height / 2)
        CATransaction.commit()
    }
    private var litWidth: CGFloat { latticeRect.width * CGFloat(max(0, min(1, fraction))) }

    /// The fan's measured speed (percent of maximum), nil without a reading.
    func show(measuredPercent: Double?, animated: Bool) {
        let next = (measuredPercent?.rounded() ?? 0) / 100
        figure.stringValue = measuredPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        setAccessibilityValue(measuredPercent.map { "\(Int($0.rounded())) percent" } ?? "unavailable")
        guard next != fraction else { return }
        fraction = next
        let from = (litMask.presentation() ?? litMask).bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        litMask.bounds = CGRect(x: 0, y: 0, width: litWidth, height: latticeRect.height)
        if animated && Theme.effects.animates && window != nil {
            let ease = CABasicAnimation(keyPath: "bounds"); ease.fromValue = from; ease.toValue = litMask.bounds
            ease.duration = 0.6; ease.timingFunction = Theme.Ease.inOut
            litMask.add(ease, forKey: "bounds")
        }
        CATransaction.commit()
    }
    /// The first appearance: the lit dots cascade in from the left to the
    /// fan's measured speed, once.
    func reveal() {
        guard Theme.effects.animates, window != nil, fraction > 0 else { return }
        let grow = CABasicAnimation(keyPath: "bounds")
        grow.fromValue = CGRect(x: 0, y: 0, width: 0, height: latticeRect.height); grow.toValue = litMask.bounds
        grow.duration = 0.9; grow.timingFunction = Theme.Ease.out
        litMask.add(grow, forKey: "bounds")
    }
}

/// The two-step setup picture: System Settings, then Aervane's switch in
/// Login Items. The switch shows the real state: off while macOS waits for
/// approval, on once the helper has answered.
final class ApprovalGlyph: NSView {
    private let gear = NSImageView(), arrow = NSImageView()
    private let track = CALayer(), knob = CALayer()
    var on = false { didSet { if on != oldValue { place(animated: true) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gear.image = Glyphs.image(.settings, size: 16, color: Theme.secondary); gear.imageScaling = .scaleNone
        arrow.image = Glyphs.image(.back, size: 12, color: Theme.secondary); arrow.imageScaling = .scaleNone
        arrow.frameCenterRotation = 180
        [gear, arrow].forEach { addSubview($0); $0.setAccessibilityElement(false) }
        track.cornerRadius = 7; knob.cornerRadius = 5.5
        layer?.addSublayer(track); track.addSublayer(knob)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); place(animated: false) }
    override func layout() {
        super.layout()
        gear.frame = NSRect(x: 0, y: (bounds.height - 18) / 2, width: 18, height: 18)
        arrow.frame = NSRect(x: 21, y: (bounds.height - 14) / 2, width: 14, height: 14)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 38, y: (bounds.height - 14) / 2, width: 24, height: 14)
        CATransaction.commit()
        place(animated: false)
    }
    private func place(animated: Bool) {
        let from = (knob.presentation() ?? knob).position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.track.backgroundColor = (self.on ? Theme.accent : Theme.ink.withAlphaComponent(0.16)).cgColor
            self.knob.backgroundColor = NSColor.white.cgColor
            self.knob.shadowColor = NSColor.black.cgColor; self.knob.shadowOpacity = 0.25; self.knob.shadowRadius = 1; self.knob.shadowOffset = CGSize(width: 0, height: 0.5)
        }
        knob.bounds = CGRect(x: 0, y: 0, width: 11, height: 11)
        knob.position = CGPoint(x: on ? 24 - 7 : 7, y: 7)
        if animated && Theme.effects.animates && window != nil {
            let slide = CABasicAnimation(keyPath: "position"); slide.fromValue = from; slide.toValue = knob.position
            slide.duration = 0.24; slide.timingFunction = Theme.Ease.out
            knob.add(slide, forKey: "position")
        }
        CATransaction.commit()
    }
}

/// The introduction's first screen, below the live temperature: the fan as
/// it is right now, and one choice.
final class WelcomeCard: FlippedView {
    let glance = FanGlance()
    let controlButton: SoftButton, temperatureButton: SoftButton
    static let height: CGFloat = 44 + 14 + 32

    init(control: @escaping () -> Void, temperatureOnly: @escaping () -> Void) {
        controlButton = SoftButton("Control the fan", glyph: .airflow, action: control)
        temperatureButton = SoftButton("Temperature only", action: temperatureOnly)
        super.init(frame: .zero)
        wantsLayer = true
        controlButton.prominent = true; temperatureButton.quiet = true
        controlButton.setAccessibilityLabel("Control the fan")
        temperatureButton.setAccessibilityLabel("Show only the temperature")
        [glance, controlButton, temperatureButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let w = bounds.width
        glance.frame = NSRect(x: 0, y: 0, width: w, height: 44)
        let half = ((w - 8) / 2).rounded(.down)
        controlButton.frame = NSRect(x: 0, y: 44 + 14, width: half, height: 32)
        temperatureButton.frame = NSRect(x: w - half, y: 44 + 14, width: half, height: 32)
    }
    /// The card settles in once (rises a few points as it fades up), then
    /// the glance reveals the fan's measured speed.
    func playEntrance() {
        guard Theme.effects.animates, window != nil, let layer else { return }
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 8, 0)); rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        rise.duration = 0.36; rise.timingFunction = Theme.Ease.out
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.24; fade.timingFunction = Theme.Ease.out
        layer.add(rise, forKey: "rise"); layer.add(fade, forKey: "fade")
        glance.reveal()
    }
}

/// Setup in progress, in the fan section: what to do in System Settings
/// while macOS waits for approval, then "Connected" with the fan's measured
/// speed once the helper has answered.
final class SetupCard: FlippedView {
    enum Mode: Equatable { case approval(connecting: Bool), connected(measuredPercent: Double?) }
    private let glyph = ApprovalGlyph()
    private let title = label("", size: 12, weight: .semibold)
    private let detail = label("", size: 11, color: .secondaryLabelColor)
    private let action: SoftButton
    var open: (() -> Void)?, done: (() -> Void)?
    private(set) var mode: Mode = .approval(connecting: false)
    private var hasShownMode = false
    static let height: CGFloat = 44

    override init(frame: NSRect) {
        var trigger: (() -> Void)?
        action = SoftButton("Open") { trigger?() }
        super.init(frame: frame)
        trigger = { [weak self] in self?.perform() }
        wantsLayer = true
        layer?.cornerRadius = 10
        action.quiet = true
        [glyph, title, detail, action].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        show(.approval(connecting: false))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() { layer?.backgroundColor = Theme.faint.cgColor }
    override var wantsUpdateLayer: Bool { true }
    private func perform() {
        switch mode { case .approval: open?(); case .connected: done?() }
    }
    func show(_ next: Mode) {
        guard !hasShownMode || next != mode else { return }
        hasShownMode = true; mode = next
        switch next {
        case .approval(let connecting):
            glyph.on = false
            title.stringValue = "Allow in Login Items"
            title.toolTip = "Turn on Aervane in System Settings → Login Items."
            detail.stringValue = connecting ? "Connecting…" : "Waiting for approval"
            action.title = "Open"; action.selected = false; action.quiet = true
            action.setAccessibilityLabel("Open Login Items in System Settings")
        case .connected(let measured):
            glyph.on = true
            title.stringValue = "Connected"
            title.toolTip = nil
            detail.stringValue = measured.map { "Fan \(Int($0.rounded()))%" } ?? ""
            action.title = "Done"; action.quiet = false; action.selected = true
            action.setAccessibilityLabel("Done")
        }
        setAccessibilityLabel([title.stringValue, detail.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let h = bounds.height
        glyph.frame = NSRect(x: 10, y: 0, width: 62, height: h)
        let actionWidth: CGFloat = 64
        action.frame = NSRect(x: bounds.width - actionWidth - 8, y: (h - 28) / 2, width: actionWidth, height: 28)
        let textX: CGFloat = 80, textWidth = max(0, action.frame.minX - 8 - textX)
        title.frame = NSRect(x: textX, y: h / 2 - 16, width: textWidth, height: 16)
        detail.frame = NSRect(x: textX, y: h / 2 + 1, width: textWidth, height: 14)
    }
    var actionButton: SoftButton { action }
}
