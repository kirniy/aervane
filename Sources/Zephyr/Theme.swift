import AppKit
import QuartzCore

/// Design tokens. Colours are dynamic so a light/dark switch never leaves a
/// stale grey behind; spacing follows the 4/8 pt grid described in DESIGN.md.
///
/// Two colour families never mix: **ice** (cyan → white) is cooling power on
/// the slider; **heat** (amber → coral) is the measured temperature.
enum Theme {
    /// Resolves against the appearance currently drawing (a view's own
    /// appearance inside draw/updateLayer), falling back to the app's.
    static var dark: Bool { NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static var ink: NSColor { .labelColor }
    static var secondary: NSColor { dynamic(light: NSColor(white: 0.36, alpha: 1), dark: NSColor(white: 0.68, alpha: 1)) }
    /// Muted mint: calm in dark mode, a deep readable spruce in light mode.
    static var accent: NSColor { dynamic(light: NSColor(srgbRed: 0.07, green: 0.42, blue: 0.34, alpha: 1), dark: NSColor(srgbRed: 0.56, green: 0.86, blue: 0.76, alpha: 1)) }
    /// "Not applied" / attention. Warm, desaturated; never alarm red.
    static var caution: NSColor { dynamic(light: NSColor(srgbRed: 0.64, green: 0.39, blue: 0.04, alpha: 1), dark: NSColor(srgbRed: 0.95, green: 0.75, blue: 0.42, alpha: 1)) }
    static var faint: NSColor { ink.withAlphaComponent(0.065) }
    static var hairline: NSColor { ink.withAlphaComponent(0.10) }

    // Cooling power (slider). Low speeds start at the brand mint and cool
    // through glacier cyan to ice white at full cooling.
    static var iceLow: NSColor { accent }
    static var iceMid: NSColor { dynamic(light: NSColor(srgbRed: 0.04, green: 0.47, blue: 0.62, alpha: 1), dark: NSColor(srgbRed: 0.42, green: 0.84, blue: 0.96, alpha: 1)) }
    static var iceHigh: NSColor { dynamic(light: NSColor(srgbRed: 0.02, green: 0.40, blue: 0.66, alpha: 1), dark: NSColor(srgbRed: 0.86, green: 0.98, blue: 1.0, alpha: 1)) }
    /// Frost crystals: bright rime on dark glass, deep glacier ink on light.
    static var rime: NSColor { dynamic(light: NSColor(srgbRed: 0.10, green: 0.46, blue: 0.64, alpha: 1), dark: NSColor(srgbRed: 0.93, green: 0.99, blue: 1.0, alpha: 1)) }

    /// Measured temperature bands. Cool and normal stay neutral so colour
    /// appears only when it says something.
    static func heat(_ state: ThermalState) -> NSColor {
        switch state {
        case .unknown: return secondary
        case .cool: return accent
        case .steady: return ink
        case .warm: return dynamic(light: NSColor(srgbRed: 0.60, green: 0.42, blue: 0.0, alpha: 1), dark: NSColor(srgbRed: 0.96, green: 0.80, blue: 0.42, alpha: 1))
        case .hot: return dynamic(light: NSColor(srgbRed: 0.72, green: 0.33, blue: 0.04, alpha: 1), dark: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.34, alpha: 1))
        case .peak: return dynamic(light: NSColor(srgbRed: 0.74, green: 0.16, blue: 0.12, alpha: 1), dark: NSColor(srgbRed: 1.0, green: 0.47, blue: 0.42, alpha: 1))
        }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    /// The current ceiling for decoration and motion (user level, lowered by
    /// Reduce Motion / Reduce Transparency).
    static var effects: EffectsProfile {
        EffectsProfile(level: PresentationPreferences.shared.effects, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
    }

    /// Strong ease-out for responses, ease-in-out for on-screen travel.
    enum Ease {
        static let out = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        static let inOut = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func number(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }
    /// Resolves a dynamic colour for a layer under a view's appearance.
    static func cg(_ color: NSColor, _ appearance: NSAppearance) -> CGColor {
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = Theme.font(size, weight); view.textColor = color == .secondaryLabelColor ? Theme.secondary : color
    view.lineBreakMode = .byTruncatingTail
    return view
}

enum Glyph: String { case airflow, quiet, balance, boost, settings, close, plus, back, power, github }

enum Glyphs {
    /// The GitHub mark, parsed once from bundled path data (y-down, 16 pt box).
    private static let githubMark: NSBezierPath = {
        let path = NSBezierPath()
        for segment in VectorPath.parse(VectorPath.githubMark) {
            switch segment {
            case .move(let p): path.move(to: p)
            case .line(let p): path.line(to: p)
            case .curve(let c1, let c2, let p): path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
            case .close: path.close()
            }
        }
        path.windingRule = .evenOdd
        return path
    }()

    static func image(_ glyph: Glyph, size: CGFloat = 18, color: NSColor = .labelColor) -> NSImage {
        if glyph == .github {
            // Filled mark, drawn in its own y-down box with a small optical
            // inset so it matches the stroked glyphs' visual weight.
            let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
                let transform = NSAffineTransform(); transform.translateX(by: size * 0.08, yBy: size * 0.08)
                transform.scale(by: size * 0.84 / 16); transform.concat()
                color.setFill(); githubMark.fill(); return true
            }
            image.accessibilityDescription = "GitHub"
            return image
        }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let transform = NSAffineTransform(); transform.scale(by: size / 24); transform.concat()
            color.setStroke(); color.setFill()
            let p = NSBezierPath(); p.lineWidth = 1.65; p.lineCapStyle = .round; p.lineJoinStyle = .round
            switch glyph {
            case .airflow:
                // Three streamlines: an upper curl, a long straight stream and a
                // lower curl. Reads as moving air at 14 pt in the menu bar.
                p.lineWidth = 2
                p.move(to: .init(x: 3, y: 15)); p.line(to: .init(x: 15, y: 15))
                p.appendArc(withCenter: .init(x: 15, y: 18), radius: 3, startAngle: -90, endAngle: 180, clockwise: false)
                p.move(to: .init(x: 5, y: 11)); p.line(to: .init(x: 20, y: 11))
                p.move(to: .init(x: 3, y: 7)); p.line(to: .init(x: 13, y: 7))
                p.appendArc(withCenter: .init(x: 13, y: 4.5), radius: 2.5, startAngle: 90, endAngle: -180, clockwise: true)
            case .quiet:
                p.move(to: .init(x: 3, y: 8)); p.curve(to: .init(x: 21, y: 8), controlPoint1: .init(x: 9, y: 14), controlPoint2: .init(x: 14, y: 2))
                p.move(to: .init(x: 3, y: 15)); p.curve(to: .init(x: 21, y: 15), controlPoint1: .init(x: 9, y: 21), controlPoint2: .init(x: 14, y: 9))
            case .balance:
                for (x, a, b) in [(6.0, 5.0, 15.0), (12.0, 8.0, 20.0), (18.0, 5.0, 15.0)] { p.move(to: .init(x: x, y: a)); p.line(to: .init(x: x, y: b)) }
            case .boost:
                p.move(to: .init(x: 13, y: 22)); p.line(to: .init(x: 5, y: 11)); p.line(to: .init(x: 11, y: 11)); p.line(to: .init(x: 10, y: 2)); p.line(to: .init(x: 20, y: 14)); p.line(to: .init(x: 13, y: 14)); p.close()
            case .settings:
                for (y, x) in [(6.0, 8.0), (12.0, 16.0), (18.0, 10.0)] {
                    p.move(to: .init(x: 3, y: y)); p.line(to: .init(x: x - 2, y: y)); p.move(to: .init(x: x + 2, y: y)); p.line(to: .init(x: 21, y: y)); p.appendOval(in: .init(x: x - 2, y: y - 2, width: 4, height: 4))
                }
            case .close: p.move(to: .init(x: 7, y: 7)); p.line(to: .init(x: 17, y: 17)); p.move(to: .init(x: 7, y: 17)); p.line(to: .init(x: 17, y: 7))
            case .plus: p.move(to: .init(x: 5, y: 12)); p.line(to: .init(x: 19, y: 12)); p.move(to: .init(x: 12, y: 5)); p.line(to: .init(x: 12, y: 19))
            case .back: p.move(to: .init(x: 15, y: 5)); p.line(to: .init(x: 8, y: 12)); p.line(to: .init(x: 15, y: 19))
            case .power: p.appendArc(withCenter: .init(x: 12, y: 11), radius: 8, startAngle: 55, endAngle: 125, clockwise: true); p.move(to: .init(x: 12, y: 14)); p.line(to: .init(x: 12, y: 23))
            case .github: break
            }
            p.stroke(); return true
        }
    }
}

/// Compact native-feeling button. The fill lives on the backing layer so
/// selection, hover and press changes cross-fade; the content is drawn.
/// Press feedback is a short scale-down with a spring release.
/// `quiet` buttons have no resting fill; `chromeless` buttons never draw a
/// fill (a container such as ModeSwitch supplies it); `detail` stacks a
/// figure under the title (preset percentages).
final class SoftButton: NSButton {
    var actionBlock: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { refreshFill(animated: true); needsDisplay = true } } }
    var prominent = false { didSet { if prominent != oldValue { refreshFill(animated: false); needsDisplay = true } } }
    var quiet = false { didSet { if quiet != oldValue { refreshFill(animated: false); needsDisplay = true } } }
    var chromeless = false { didSet { if chromeless != oldValue { refreshFill(animated: false); needsDisplay = true } } }
    /// Selected text and fill colour; accent by default.
    var selectedTint: NSColor? { didSet { refreshFill(animated: false); needsDisplay = true } }
    var detail: String? { didSet { if detail != oldValue { needsDisplay = true } } }
    var glyph: Glyph? { didSet { if glyph != oldValue { needsDisplay = true } } }
    /// Builds a context menu when the button is right-clicked.
    var contextMenu: (() -> NSMenu?)?
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(_ title: String, glyph: Glyph? = nil, action: @escaping () -> Void) {
        self.glyph = glyph; self.actionBlock = action
        super.init(frame: .zero); self.title = title; self.isBordered = false
        self.font = Theme.font(12, .medium); target = self; self.action = #selector(invoke)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityLabel(title); focusRingType = .exterior
        refreshFill(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?() }
    override func accessibilityValue() -> Any? {
        if accessibilityRole() == .radioButton { return NSNumber(value: selected) }
        return super.accessibilityValue()
    }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { refreshFill(animated: true); needsDisplay = true } } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var radius: CGFloat { min(9, bounds.height / 2) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layer?.cornerRadius = radius }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }; let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self); addTrackingArea(t); tracking = t }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshFill(animated: true); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshFill(animated: true); needsDisplay = true }
    func resetHover() {
        hovered = false; pressed = false
        layer?.removeAllAnimations(); layer?.transform = CATransform3DIdentity
        refreshFill(animated: false); needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resetHover() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }
    /// Shows that a keyboard shortcut pressed this button: the fill flashes
    /// to its pressed tone and back, without movement (keyboard actions are
    /// never animated spatially).
    func acknowledge() {
        guard let layer, window != nil, !chromeless else { return }
        let rest = Theme.cg(fillColor, effectiveAppearance)
        pressed = true; let flash = Theme.cg(fillColor, effectiveAppearance); pressed = false
        let pulse = CAKeyframeAnimation(keyPath: "backgroundColor")
        pulse.values = [flash, flash, rest]; pulse.keyTimes = [0, 0.3, 1]; pulse.duration = 0.24
        pulse.timingFunction = Theme.Ease.out
        layer.add(pulse, forKey: "acknowledge")
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshFill(animated: false); needsDisplay = true }

    /// NSButton tracks the press inside `super.mouseDown`, which returns on
    /// release (after the action has run for a click inside).
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { super.mouseDown(with: event); return }
        setPressed(true)
        super.mouseDown(with: event)
        setPressed(false)
    }

    private var tint: NSColor { selectedTint ?? Theme.accent }
    private var fillColor: NSColor {
        if chromeless { return .clear }
        let active = selected || prominent, hover = isEnabled && hovered
        if active { return tint.withAlphaComponent(pressed ? 0.30 : hover ? 0.23 : 0.17) }
        if quiet { return Theme.ink.withAlphaComponent(pressed ? 0.12 : hover ? 0.07 : 0) }
        return Theme.ink.withAlphaComponent(!isEnabled ? 0.03 : pressed ? 0.13 : hover ? 0.085 : 0.05)
    }
    private func refreshFill(animated: Bool) {
        guard let layer else { return }
        let target = Theme.cg(fillColor, effectiveAppearance)
        let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.backgroundColor = target; layer.cornerRadius = radius
        if animated, window != nil, Theme.effects.animates, let from {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = from; fade.toValue = target
            fade.duration = pressed ? 0.08 : 0.18; fade.timingFunction = Theme.Ease.out
            layer.add(fade, forKey: "fill")
        }
        CATransaction.commit()
    }
    /// Scale about the visual centre whatever anchor AppKit gave the layer.
    private func scaled(_ scale: CGFloat) -> CATransform3D {
        guard let layer, scale != 1 else { return CATransform3DIdentity }
        let cx = bounds.width * (0.5 - layer.anchorPoint.x), cy = bounds.height * (0.5 - layer.anchorPoint.y)
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(cx, cy, 0), scale, scale, 1), -cx, -cy, 0)
    }
    private func setPressed(_ down: Bool) {
        pressed = down; refreshFill(animated: true); needsDisplay = true
        guard let layer, window != nil else { return }
        let target = scaled(down ? (bounds.width > 120 ? 0.985 : 0.96) : 1)
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = target
        if Theme.effects.animates {
            let animation: CABasicAnimation
            if down {
                animation = CABasicAnimation(keyPath: "transform"); animation.duration = 0.09; animation.timingFunction = Theme.Ease.out
            } else {
                let spring = CASpringAnimation(keyPath: "transform")
                spring.mass = 1; spring.stiffness = 420; spring.damping = 17
                spring.duration = spring.settlingDuration; animation = spring
            }
            animation.fromValue = NSValue(caTransform3D: from); animation.toValue = NSValue(caTransform3D: target)
            layer.add(animation, forKey: "press")
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = selected || prominent, hover = isEnabled && hovered
        let base: NSColor
        if chromeless { base = selected ? tint : (hover ? Theme.ink : Theme.secondary) }
        else if active { base = tint }
        else if quiet { base = title.isEmpty ? (hover ? Theme.ink : Theme.secondary) : Theme.accent }
        else { base = Theme.ink }
        let color = base.withAlphaComponent(isEnabled ? 1 : 0.3)
        let font = self.font ?? Theme.font(12, .medium), inset: CGFloat = 11
        if let detail {
            // Preset: name above, effective percentage below, left aligned.
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            let name = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            let figure = NSAttributedString(string: detail, attributes: [.font: Theme.number(11, .medium), .foregroundColor: (active ? tint : Theme.secondary).withAlphaComponent(isEnabled ? (active ? 0.85 : 1) : 0.3)])
            let nameHeight = name.size().height, figureHeight = figure.size().height
            let top = ((bounds.height - nameHeight - figureHeight + 1) / 2).rounded()
            name.draw(with: NSRect(x: inset, y: top, width: max(0, bounds.width - 2 * inset), height: nameHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            figure.draw(at: NSPoint(x: inset, y: top + nameHeight - 1))
            return
        }
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        let textSize = title.isEmpty ? .zero : text.size()
        let icon: CGFloat = glyph == nil ? 0 : 16, gap: CGFloat = glyph != nil && !title.isEmpty ? 6 : 0
        var x = ((bounds.width - textSize.width - icon - gap) / 2).rounded()
        if let glyph {
            Glyphs.image(glyph, size: 16, color: color).draw(in: NSRect(x: x, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += icon + gap
        }
        if !title.isEmpty { text.draw(at: NSPoint(x: x, y: ((bounds.height - textSize.height) / 2).rounded())) }
    }
}

/// Auto · Smart · Manual as one control. A pill springs to the active mode
/// and changes material with it: neutral glass for Auto, a cool ice gradient
/// for Smart (sand when Smart is saturated: full speed and still over its
/// target), mint for applied Manual and sand for a Manual preview that is
/// not applied. Choosing Smart plays one finite flourish — a light sweep
/// across the pill and a brief cold bloom — when effects allow; nothing
/// animates at rest. Each button keeps its own accessibility label and is a
/// radio button for VoiceOver.
final class ModeSwitch: FlippedView {
    enum Mode: Equatable, CaseIterable { case automatic, smart, manual, none }
    let autoButton: SoftButton
    let smartButton: SoftButton
    let manualButton: SoftButton
    private let track = FlippedView()
    private let bloom = CAGradientLayer()
    private let pill = CALayer()
    private let ice = CAGradientLayer()
    private let sheen = CAGradientLayer()

    var mode: Mode = .none { didSet { if mode != oldValue { refresh(animated: true, entering: mode == .smart) } } }
    /// Manual is shown but nothing is applied yet.
    var pending = false { didSet { if pending != oldValue { refresh(animated: true) } } }
    /// Smart is requesting full speed and the temperature is still over its
    /// target: the Smart pill takes the attention tone.
    var saturated = false { didSet { if saturated != oldValue { refresh(animated: true) } } }

    init(auto: SoftButton, smart: SoftButton, manual: SoftButton) {
        autoButton = auto; smartButton = smart; manualButton = manual
        super.init(frame: .zero)
        wantsLayer = true; track.wantsLayer = true
        bloom.type = .radial; bloom.startPoint = CGPoint(x: 0.5, y: 0.5); bloom.endPoint = CGPoint(x: 1, y: 1); bloom.opacity = 0
        pill.masksToBounds = true
        ice.startPoint = CGPoint(x: 0, y: 0.5); ice.endPoint = CGPoint(x: 1, y: 0.5); ice.opacity = 0
        sheen.startPoint = CGPoint(x: 0, y: 0.5); sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sheen.opacity = 0
        pill.addSublayer(ice); pill.addSublayer(sheen)
        track.layer?.addSublayer(bloom); track.layer?.addSublayer(pill)
        addSubview(track)
        for button in [auto, smart, manual] {
            button.chromeless = true
            button.setAccessibilityRole(.radioButton)
            addSubview(button)
        }
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var buttons: [SoftButton] { [autoButton, smartButton, manualButton] }
    override func layout() {
        super.layout()
        track.frame = bounds
        for (i, button) in buttons.enumerated() { button.frame = segment(i) }
        refresh(animated: false)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh(animated: false) }

    /// Equal thirds, on whole points.
    private func segment(_ index: Int) -> NSRect {
        let a = (bounds.width * CGFloat(index) / 3).rounded(), b = (bounds.width * CGFloat(index + 1) / 3).rounded()
        return NSRect(x: a, y: 0, width: b - a, height: bounds.height)
    }
    private var index: Int? {
        switch mode { case .automatic: return 0; case .smart: return 1; case .manual: return 2; case .none: return nil }
    }
    private var pillColor: NSColor {
        switch mode {
        case .automatic: return Theme.ink.withAlphaComponent(0.13)
        case .smart: return (saturated ? Theme.caution : Theme.iceMid).withAlphaComponent(0.1)
        case .manual: return (pending ? Theme.caution : Theme.accent).withAlphaComponent(0.22)
        case .none: return .clear
        }
    }
    private func refresh(animated: Bool, entering: Bool = false) {
        guard let trackLayer = track.layer else { return }
        let appearance = effectiveAppearance
        trackLayer.backgroundColor = Theme.cg(Theme.ink.withAlphaComponent(0.055), appearance)
        trackLayer.cornerRadius = bounds.height / 2
        let inset: CGFloat = 2
        let frame = segment(index ?? 0).insetBy(dx: inset, dy: inset)
        let color = Theme.cg(pillColor, appearance)
        let from = (pill.presentation() ?? pill)
        let fromPosition = from.position, fromColor = from.backgroundColor, fromOpacity = from.opacity
        let fromIce = (ice.presentation() ?? ice).opacity
        let smart = mode == .smart
        let effects = Theme.effects, live = animated && window != nil && effects.animates && bounds.width > 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pill.bounds = CGRect(origin: .zero, size: frame.size)
        pill.cornerRadius = frame.height / 2
        if mode != .none { pill.position = CGPoint(x: frame.midX, y: frame.midY); pill.backgroundColor = color }
        pill.opacity = mode == .none ? 0 : 1
        pill.borderWidth = smart ? 0.5 : 0
        pill.borderColor = Theme.cg((saturated ? Theme.caution : Theme.iceMid).withAlphaComponent(0.5), appearance)
        // Smart's material: a cool gradient through the pill (sand when the
        // fan cannot do more).
        ice.frame = pill.bounds
        let a = saturated ? Theme.caution : Theme.iceLow, b = saturated ? Theme.caution : Theme.iceMid
        ice.colors = [Theme.cg(a.withAlphaComponent(0.26), appearance), Theme.cg(b.withAlphaComponent(0.34), appearance)]
        ice.opacity = smart ? 1 : 0
        sheen.bounds = CGRect(x: 0, y: 0, width: 26, height: frame.height); sheen.position = CGPoint(x: -13, y: frame.height / 2)
        bloom.bounds = CGRect(origin: .zero, size: CGSize(width: frame.width + 24, height: frame.height + 18))
        bloom.position = pill.position
        bloom.colors = [Theme.cg(Theme.iceMid.withAlphaComponent(0.45), appearance), Theme.cg(Theme.iceMid.withAlphaComponent(0), appearance)]
        if live {
            let slide = CASpringAnimation(keyPath: "position")
            slide.mass = 1; slide.stiffness = 300; slide.damping = 24
            slide.fromValue = NSValue(point: fromPosition); slide.toValue = NSValue(point: pill.position)
            slide.duration = slide.settlingDuration
            let tone = CABasicAnimation(keyPath: "backgroundColor"); tone.fromValue = fromColor; tone.toValue = pill.backgroundColor
            tone.duration = 0.2; tone.timingFunction = Theme.Ease.out
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = fromOpacity; fade.toValue = pill.opacity
            fade.duration = 0.16
            pill.add(slide, forKey: "slide"); pill.add(tone, forKey: "tone"); pill.add(fade, forKey: "fade")
            let iceFade = CABasicAnimation(keyPath: "opacity"); iceFade.fromValue = fromIce; iceFade.toValue = ice.opacity
            iceFade.duration = 0.3; iceFade.timingFunction = Theme.Ease.out
            ice.add(iceFade, forKey: "fade")
            bloom.add(slide, forKey: "slide")
            if entering, effects.bloom {
                // One flourish: light runs across the pill as it lands, and a
                // cold bloom breathes once behind it.
                let sweep = CABasicAnimation(keyPath: "position.x"); sweep.fromValue = -13; sweep.toValue = frame.width + 13
                sweep.duration = 0.7; sweep.timingFunction = Theme.Ease.inOut; sweep.beginTime = CACurrentMediaTime() + 0.12; sweep.fillMode = .backwards
                let shine = CAKeyframeAnimation(keyPath: "opacity"); shine.values = [0, 1, 0]; shine.keyTimes = [0, 0.4, 1]
                shine.duration = 0.7; shine.beginTime = sweep.beginTime; shine.fillMode = .backwards
                sheen.add(sweep, forKey: "sweep"); sheen.add(shine, forKey: "shine")
                let breathe = CAKeyframeAnimation(keyPath: "opacity"); breathe.values = [0, 0.9 * effects.glow, 0]; breathe.keyTimes = [0, 0.35, 1]
                breathe.duration = 0.9; breathe.timingFunction = Theme.Ease.out
                bloom.add(breathe, forKey: "breathe")
            }
        }
        CATransaction.commit()
        autoButton.selectedTint = Theme.ink; autoButton.selected = mode == .automatic
        smartButton.selectedTint = saturated ? Theme.caution : Theme.iceMid; smartButton.selected = smart
        manualButton.selectedTint = pending ? Theme.caution : Theme.accent; manualButton.selected = mode == .manual
    }
    /// Ends any flourish or slide at once (panel hiding).
    func settle() { for layer in [pill, ice, sheen, bloom] { layer.removeAllAnimations() } }
}
