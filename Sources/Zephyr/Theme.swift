import AppKit

enum Theme {
    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static var ink: NSColor { .labelColor }
    static var secondary: NSColor { dark ? NSColor(white: 0.66, alpha: 1) : NSColor(white: 0.38, alpha: 1) }
    static var accent: NSColor { dark ? NSColor(srgbRed: 0.57, green: 0.91, blue: 0.80, alpha: 1) : NSColor(srgbRed: 0.02, green: 0.39, blue: 0.32, alpha: 1) }
    static var faint: NSColor { ink.withAlphaComponent(0.065) }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func number(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
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
                for i in 0..<3 {
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform(); t.translateX(by: 12, yBy: 12); t.rotate(byDegrees: CGFloat(i) * 120); t.translateX(by: -12, yBy: -12); t.concat()
                    let blade = NSBezierPath(); blade.move(to: .init(x: 11, y: 12)); blade.curve(to: .init(x: 13, y: 22), controlPoint1: .init(x: 2, y: 16), controlPoint2: .init(x: 5, y: 23)); blade.curve(to: .init(x: 14, y: 12), controlPoint1: .init(x: 20, y: 21), controlPoint2: .init(x: 19, y: 13)); blade.close(); blade.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
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
            case .close: p.move(to: .init(x: 6, y: 6)); p.line(to: .init(x: 18, y: 18)); p.move(to: .init(x: 6, y: 18)); p.line(to: .init(x: 18, y: 6))
            case .plus: p.move(to: .init(x: 5, y: 12)); p.line(to: .init(x: 19, y: 12)); p.move(to: .init(x: 12, y: 5)); p.line(to: .init(x: 12, y: 19))
            case .back: p.move(to: .init(x: 15, y: 5)); p.line(to: .init(x: 8, y: 12)); p.line(to: .init(x: 15, y: 19))
            case .power: p.appendArc(withCenter: .init(x: 12, y: 11), radius: 8, startAngle: 55, endAngle: 125, clockwise: true); p.move(to: .init(x: 12, y: 14)); p.line(to: .init(x: 12, y: 23))
            }
            p.stroke(); return true
        }
    }
}

final class SoftButton: NSButton {
    var actionBlock: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var prominent = false
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
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if !Theme.reduceMotion { layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1) }
        super.mouseDown(with: event)
        layer?.transform = CATransform3DIdentity
        if !Theme.reduceMotion {
            let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = 0.97; spring.toValue = 1; spring.mass = 1; spring.stiffness = 430; spring.damping = 29; spring.duration = 0.22
            layer?.add(spring, forKey: "press")
        }
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }; let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self); addTrackingArea(t); tracking = t }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let active = selected || prominent
        let fill = active ? Theme.accent.withAlphaComponent(Theme.dark ? 0.18 : 0.12) : Theme.ink.withAlphaComponent(hovered ? 0.10 : 0.045)
        fill.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).fill()
        if cell?.isHighlighted == true { Theme.ink.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill() }
        let color = (active ? Theme.accent : Theme.ink).withAlphaComponent(isEnabled ? 1 : 0.32)
        let text = NSAttributedString(string: title, attributes: [.font: font ?? Theme.font(12), .foregroundColor: color])
        let textSize = text.size(), iconWidth: CGFloat = glyph == nil ? 0 : 22
        let origin = (bounds.width - textSize.width - iconWidth) / 2
        if let glyph { Glyphs.image(glyph, size: 16, color: color).draw(in: .init(x: origin, y: (bounds.height - 16)/2, width: 16, height: 16)) }
        text.draw(at: .init(x: origin + iconWidth, y: (bounds.height - textSize.height)/2))
    }
}
