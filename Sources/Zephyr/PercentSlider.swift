import AppKit

/// A native keyboard- and VoiceOver-accessible control. Values always mean a
/// percentage of maximum physical speed; the dim segment is the firmware floor.
final class PercentSlider: NSControl {
    var percent: Double = 50 { didSet { needsDisplay = true; setAccessibilityValue(Int(percent)) } }
    var minimumPercent: Double = 0 { didSet { needsDisplay = true } }
    var preview: ((Double) -> Void)?
    var commit: ((Double) -> Void)?
    private(set) var dragging = false
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Fan speed"); setAccessibilityMinValue(0); setAccessibilityMaxValue(100); setAccessibilityValueDescription("Percent of maximum fan speed"); focusRingType = .exterior }
    required init?(coder: NSCoder) { fatalError() }
    private var track: NSRect { bounds.insetBy(dx: 10, dy: 10) }
    override func draw(_ dirtyRect: NSRect) {
        let r = track, alpha: CGFloat = isEnabled ? 1 : 0.40
        Theme.ink.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: .init(x: r.minX - 7, y: bounds.midY - 17, width: r.width + 14, height: 34), xRadius: 10, yRadius: 10).fill()
        for column in 0...59 {
            let value = Double(column) / 59 * 100
            for row in 0..<5 {
                let lit = value <= percent && value >= minimumPercent
                let intensity = lit ? 0.20 + 0.70 * Double(column) / 59 : 0.08
                let color = lit ? Theme.accent : Theme.ink
                color.withAlphaComponent(intensity * alpha).setFill()
                let x = r.minX + CGFloat(column) / 59 * r.width
                NSBezierPath(roundedRect: .init(x: x - 1.6, y: bounds.midY - 11.5 + CGFloat(row) * 5, width: 3.2, height: 3.2), xRadius: 0.8, yRadius: 0.8).fill()
            }
        }
        let x = r.minX + CGFloat(percent / 100) * r.width
        let knob = NSBezierPath(roundedRect: .init(x: x - 6, y: bounds.midY - 16, width: 12, height: 32), xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState(); let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.20); shadow.shadowBlurRadius = 5; shadow.shadowOffset = .init(width: 0, height: -2); shadow.set()
        (Theme.dark ? NSColor.white : Theme.accent).withAlphaComponent(alpha).setFill(); knob.fill(); NSGraphicsContext.restoreGraphicsState()
    }
    private func update(at point: NSPoint) {
        let raw = Double((point.x - track.minX) / track.width) * 100
        let next = max(minimumPercent, min(100, raw.rounded()))
        if [minimumPercent, 30, 60, 100].contains(where: { abs(next - $0) < 0.5 && abs(percent - $0) >= 0.5 }) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        percent = next; preview?(percent)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }; window.makeFirstResponder(self); dragging = true; update(at: convert(event.locationInWindow, from: nil))
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            update(at: convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        dragging = false; commit?(percent)
    }
    override func keyDown(with event: NSEvent) {
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode { case 123, 125: change(-step); case 124, 126: change(step); case 115: percent = minimumPercent; preview?(percent); commit?(percent); case 119: percent = 100; preview?(percent); commit?(percent); default: super.keyDown(with: event) }
    }
    private func change(_ amount: Double) { guard isEnabled else { return }; percent = max(minimumPercent, min(100, percent + amount)); preview?(percent); commit?(percent) }
    override func accessibilityPerformIncrement() -> Bool { change(1); return isEnabled }
    override func accessibilityPerformDecrement() -> Bool { change(-1); return isEnabled }
}

final class TemperatureHistory: NSView {
    var samples: [Double] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard samples.count > 1 else { return }
        let r = bounds.insetBy(dx: 2, dy: 5), low = max(10, (samples.min() ?? 30) - 4), high = (samples.max() ?? 60) + 4
        let path = NSBezierPath(); path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round
        for (i, value) in samples.enumerated() {
            let point = NSPoint(x: r.minX + CGFloat(i) / CGFloat(max(1, samples.count - 1)) * r.width, y: r.minY + CGFloat((value - low) / (high - low)) * r.height)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        Theme.accent.withAlphaComponent(0.75).setStroke(); path.stroke()
    }
}
