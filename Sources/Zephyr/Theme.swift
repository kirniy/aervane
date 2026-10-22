import AppKit

/// Design tokens. Colours are dynamic so a light/dark switch never leaves a
/// stale grey behind; spacing follows the 4/8 pt grid described in DESIGN.md.
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
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func number(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
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

enum Glyph: String { case airflow, quiet, balance, boost, settings, close, plus, back, power }

enum Glyphs {
    static func image(_ glyph: Glyph, size: CGFloat = 18, color: NSColor = .labelColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
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
            }
            p.stroke(); return true
        }
    }
}

/// Compact native-feeling button. `quiet` buttons have no resting fill (icon
/// and text actions); `detail` renders a right-aligned figure (preset %).
/// Press feedback is a fill change, not a scale, matching AppKit buttons.
final class SoftButton: NSButton {
    var actionBlock: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var prominent = false { didSet { if prominent != oldValue { needsDisplay = true } } }
    var quiet = false { didSet { if quiet != oldValue { needsDisplay = true } } }
    var detail: String? { didSet { if detail != oldValue { needsDisplay = true } } }
    var glyph: Glyph?
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(_ title: String, glyph: Glyph? = nil, action: @escaping () -> Void) {
        self.glyph = glyph; self.actionBlock = action
        super.init(frame: .zero); self.title = title; self.isBordered = false
        self.font = Theme.font(12, .medium); target = self; self.action = #selector(invoke)
        wantsLayer = true
        setAccessibilityLabel(title); focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?() }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var radius: CGFloat { min(8, bounds.height / 2) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }; let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self); addTrackingArea(t); tracking = t }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func resetHover() { hovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resetHover() }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = isEnabled && cell?.isHighlighted == true, hover = isEnabled && hovered
        let active = selected || prominent
        let fill: NSColor
        if active { fill = Theme.accent.withAlphaComponent(pressed ? 0.28 : hover ? 0.22 : 0.16) }
        else if quiet { fill = Theme.ink.withAlphaComponent(pressed ? 0.12 : hover ? 0.07 : 0) }
        else { fill = Theme.ink.withAlphaComponent(pressed ? 0.13 : hover ? 0.085 : 0.05) }
        fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let base: NSColor = active ? Theme.accent : quiet ? (title.isEmpty ? (hover ? Theme.ink : Theme.secondary) : Theme.accent) : Theme.ink
        let tint = base.withAlphaComponent(isEnabled ? 1 : 0.3)
        let font = self.font ?? Theme.font(12, .medium), inset: CGFloat = 10
        if let detail {
            let figure = NSAttributedString(string: detail, attributes: [.font: Theme.number(11), .foregroundColor: (active ? Theme.accent : Theme.secondary).withAlphaComponent(isEnabled ? 1 : 0.3)])
            let figureSize = figure.size()
            figure.draw(at: NSPoint(x: bounds.maxX - inset - figureSize.width, y: (bounds.height - figureSize.height) / 2))
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            let name = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: tint, .paragraphStyle: style])
            let height = name.size().height
            name.draw(with: NSRect(x: inset, y: (bounds.height - height) / 2, width: max(0, bounds.width - 2 * inset - figureSize.width - 6), height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: tint])
        let textSize = title.isEmpty ? .zero : text.size()
        let icon: CGFloat = glyph == nil ? 0 : 16, gap: CGFloat = glyph != nil && !title.isEmpty ? 6 : 0
        var x = ((bounds.width - textSize.width - icon - gap) / 2).rounded()
        if let glyph {
            Glyphs.image(glyph, size: 16, color: tint).draw(in: NSRect(x: x, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += icon + gap
        }
        if !title.isEmpty { text.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2)) }
    }
}
