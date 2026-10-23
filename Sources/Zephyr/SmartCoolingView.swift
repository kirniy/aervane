import AppKit
import ZephyrCore

/// Settings → Smart target, expanded: the actual curve Smart uses for the
/// chosen target, where the machine is on it right now, and a few short lines
/// on how it behaves and what a fan cannot do.
/// Drawn on demand (only while open, only when the reading changes).
final class SmartCoolingExplainer: FlippedView {
    private let curve = SmartCurveView()
    private let text = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.font = Theme.font(11); text.textColor = Theme.secondary
        text.maximumNumberOfLines = 0; text.isSelectable = false
        addSubview(curve); addSubview(text)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("About Smart cooling")
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let curveHeight: CGFloat = 58
    /// Height for a width, from the actual wrapped text, so the expanded
    /// Settings page grows only as much as it must.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let textHeight = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 400)).height ?? 60
        return Self.curveHeight + 4 + ceil(textHeight)
    }

    /// Called on every model refresh while expanded; it only touches what
    /// changed, so an unchanged reading draws nothing.
    func update(policy: SmartCoolingPolicy, celsius: Double?, target: Double?, floor: Double, fahrenheit: Bool) {
        curve.policy = policy; curve.floor = floor; curve.fahrenheit = fahrenheit
        // Tenths are all the dot can show; finer noise would only redraw.
        curve.celsius = celsius.map { ($0 * 10).rounded() / 10 }; curve.target = target
        let target = Self.degrees(policy.targetCelsius, fahrenheit)
        let over = Self.span(policy.fullSpeedCelsius - policy.targetCelsius, fahrenheit)
        let band = Self.span(policy.hysteresis, fahrenheit)
        let level = Int(policy.targetPercent.rounded())
        let explanation = """
        Regulates the hottest CPU core (or hotter GPU) around \(target).
        About \(level)% at the target; full speed \(over) above it. Anticipates heat; eases down through a \(band) band. No waiting timer.
        Under some loads no fan can hold the target.
        """
        if text.stringValue != explanation { text.stringValue = explanation; setAccessibilityValue(explanation) }
        let summary = curve.summary
        if curve.accessibilityLabel() != summary { curve.setAccessibilityLabel(summary) }
    }
    override func layout() {
        super.layout()
        curve.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.curveHeight)
        text.frame = NSRect(x: 0, y: Self.curveHeight + 4, width: bounds.width, height: max(0, bounds.height - Self.curveHeight - 4))
    }
    /// A temperature difference in the user's unit ("3°", "5°").
    static func span(_ celsius: Double, _ fahrenheit: Bool) -> String {
        let value = fahrenheit ? celsius * 1.8 : celsius
        return value == value.rounded() ? "\(Int(value))°" : String(format: "%.1f°", value)
    }
    static func degrees(_ celsius: Double, _ fahrenheit: Bool) -> String {
        "\(Int((fahrenheit ? celsius * 1.8 + 32 : celsius).rounded()))\(fahrenheit ? "°F" : "°C")"
    }
}

/// The policy curve for the chosen target: temperature across, fan speed
/// up, the hardware floor as a band, the target as a line, and the current
/// reading as a dot. The axis is placed around the target, so moving the
/// target moves the whole picture with it.
final class SmartCurveView: NSView {
    var policy = SmartCoolingPolicy.standard { didSet { if policy != oldValue { needsDisplay = true } } }
    var celsius: Double? { didSet { if celsius != oldValue { needsDisplay = true } } }
    var target: Double? { didSet { if target != oldValue { needsDisplay = true } } }
    var floor: Double = 0 { didSet { if floor != oldValue { needsDisplay = true } } }
    var fahrenheit = false { didSet { if fahrenheit != oldValue { needsDisplay = true } } }
    private var range: ClosedRange<Double> { (policy.targetCelsius - 30)...(policy.targetCelsius + 8) }

    override var isFlipped: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Spoken as the fan will actually run: never below this Mac's floor.
    var summary: String {
        let points = policy.curve.map { "\(SmartCoolingExplainer.degrees(policy.targetCelsius + $0.offset, fahrenheit)) \(Int(max(floor, $0.percent).rounded()))%" }
        return "Smart cooling curve: \(points.joined(separator: ", ")); target \(SmartCoolingExplainer.degrees(policy.targetCelsius, fahrenheit))"
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 1, dy: 0).divided(atDistance: 13, from: .minYEdge).remainder.insetBy(dx: 0, dy: 3)
        func x(_ c: Double) -> CGFloat { plot.minX + CGFloat((min(range.upperBound, max(range.lowerBound, c)) - range.lowerBound) / (range.upperBound - range.lowerBound)) * plot.width }
        func y(_ p: Double) -> CGFloat { plot.minY + CGFloat(max(0, min(100, p)) / 100) * plot.height }
        let speed = { (c: Double) in max(self.floor, self.policy.percent(atCelsius: c)) }

        // Frame and floor band.
        Theme.ink.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6).fill()
        if floor > 0 {
            Theme.ink.withAlphaComponent(0.06).setFill()
            NSBezierPath(rect: NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: y(floor) - plot.minY)).fill()
        }
        // Area and line, cool to hot.
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x(range.lowerBound), y: y(speed(range.lowerBound))))
        for c in stride(from: range.lowerBound, through: range.upperBound, by: 0.5) { line.line(to: NSPoint(x: x(c), y: y(speed(c)))) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: plot.maxX, y: plot.minY)); area.line(to: NSPoint(x: plot.minX, y: plot.minY)); area.close()
        NSGraphicsContext.saveGraphicsState()
        area.addClip()
        NSGradient(starting: Theme.iceLow.withAlphaComponent(0.05), ending: Theme.iceMid.withAlphaComponent(0.28))?.draw(in: plot, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        line.lineWidth = 1.5; line.lineJoinStyle = .round
        Theme.iceMid.setStroke(); line.stroke()
        // The target.
        let hot = x(policy.targetCelsius)
        let mark = NSBezierPath(); mark.move(to: NSPoint(x: hot, y: plot.minY)); mark.line(to: NSPoint(x: hot, y: plot.maxY))
        mark.setLineDash([2, 2], count: 2, phase: 0); mark.lineWidth = 1
        Theme.heat(.peak).withAlphaComponent(0.6).setStroke(); mark.stroke()
        // Now.
        if let celsius, celsius.isFinite {
            let point = NSPoint(x: x(celsius), y: y(target ?? speed(celsius)))
            Theme.ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)).fill()
            Theme.iceMid.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
        }
        // Axis labels at the curve's own temperatures.
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.number(9, .medium), .foregroundColor: Theme.secondary]
        for c in [policy.restCelsius, policy.targetCelsius, policy.fullSpeedCelsius] {
            let label = NSAttributedString(string: SmartCoolingExplainer.degrees(c, fahrenheit), attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: min(plot.maxX - size.width, max(plot.minX, x(c) - size.width / 2)), y: 0))
        }
    }
}
