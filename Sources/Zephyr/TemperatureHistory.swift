import AppKit
import QuartzCore

/// Recent temperature as a line whose colour follows the heat bands at each
/// point, with a soft fill beneath. Redrawn only when samples change.
///
/// Pointing at the plot inspects it: a device-pixel hairline and a probe snap
/// to the nearest sample, and that sample's exact value appears in the band
/// above the plot. Inspection moves three layers and never redraws the line;
/// it tracks the pointer without animation and fades only on entry and exit.
final class TemperatureHistory: NSView {
    /// Room above the plot for the inspected value.
    static let readoutBand: CGFloat = 14

    var samples: [Double] = [] {
        didSet { guard samples != oldValue else { return }; needsDisplay = true; refreshInspection(fade: false) }
    }
    var heatColor = true { didSet { if heatColor != oldValue { needsDisplay = true; refreshInspection(fade: false) } } }
    var fahrenheit = false { didSet { if fahrenheit != oldValue { refreshInspection(fade: false) } } }
    /// Whether the pointer is reading a sample (lifecycle tests).
    var isInspecting: Bool { inspectedIndex != nil }
    private(set) var inspectedIndex: Int?

    private var pointerX: CGFloat?
    private var tracking: NSTrackingArea?
    private let inspector = CALayer(), crosshair = CALayer(), probe = CALayer(), readout = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        inspector.opacity = 0
        readout.alignmentMode = .center
        probe.bounds = CGRect(x: 0, y: 0, width: 7, height: 7); probe.cornerRadius = 3.5; probe.borderWidth = 1.5
        [crosshair, probe, readout].forEach(inspector.addSublayer)
        layer?.addSublayer(inspector)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var plot: NSRect { NSRect(x: 3, y: 4, width: max(0, bounds.width - 6), height: max(0, bounds.height - 8 - Self.readoutBand)) }
    private var range: (low: Double, high: Double) {
        let low = max(10, (samples.min() ?? 30) - 3)
        return (low, max(low + 6, (samples.max() ?? 60) + 3))
    }
    private func point(_ index: Int) -> CGPoint {
        let r = plot, (low, high) = range
        return CGPoint(x: r.minX + CGFloat(index) / CGFloat(max(1, samples.count - 1)) * r.width,
                       y: r.minY + CGFloat((samples[index] - low) / (high - low)) * r.height)
    }
    private func tone(_ celsius: Double) -> NSColor { heatColor ? Theme.heat(ThermalState.classify(celsius)) : Theme.accent }

    override func draw(_ dirtyRect: NSRect) {
        guard samples.count > 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = plot, (low, high) = range
        func y(_ t: Double) -> CGFloat { r.minY + CGFloat((t - low) / (high - low)) * r.height }
        let path = CGMutablePath()
        let points = samples.indices.map(point)
        for (i, p) in points.enumerated() { if i == 0 { path.move(to: p) } else { path.addLine(to: p) } }
        // Vertical heat gradient pinned to absolute temperatures, so a colour
        // on the line always means the same reading.
        let stops: [(Double, ThermalState)] = [(50, .cool), (62, .steady), (74, .warm), (86, .hot), (95, .peak)]
        let colors = stops.map { (heatColor ? Theme.heat($0.1) : Theme.accent).cgColor } as CFArray
        let locations = stops.map { CGFloat(max(0, min(1, ($0.0 - low) / (high - low)))) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
        let start = CGPoint(x: 0, y: y(low)), end = CGPoint(x: 0, y: y(high))
        if let last = points.last, let first = points.first {
            let area = path.mutableCopy() ?? CGMutablePath()
            area.addLine(to: CGPoint(x: last.x, y: r.minY)); area.addLine(to: CGPoint(x: first.x, y: r.minY)); area.closeSubpath()
            ctx.saveGState(); ctx.addPath(area); ctx.clip(); ctx.setAlpha(0.13)
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.setLineWidth(1.4); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        if let last = points.last, let value = samples.last {
            tone(value).setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2.25, y: last.y - 2.25, width: 4.5, height: 4.5)).fill()
        }
    }

    // MARK: Inspection

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { pointerX = nil; refreshInspection(fade: true) }
    private func track(_ event: NSEvent) {
        pointerX = convert(event.locationInWindow, from: nil).x
        refreshInspection(fade: true)
    }
    /// Pointer-free inspection for tests and agents: reads the sample nearest
    /// a horizontal position in the view, or clears with nil.
    func inspect(atX x: CGFloat?) { pointerX = x; refreshInspection(fade: false) }
    /// Ends inspection at once (panel hiding).
    func endInspection() {
        pointerX = nil; inspectedIndex = nil
        inspector.removeAllAnimations(); inspector.opacity = 0
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; refreshInspection(fade: false) }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshInspection(fade: false) }

    private func refreshInspection(fade: Bool) {
        let r = plot
        let index = pointerX.flatMap { samples.count > 1 ? TrendInspection.index(x: Double($0), minX: Double(r.minX), width: Double(r.width), count: samples.count) : nil }
        let wasShowing = inspectedIndex != nil
        inspectedIndex = index
        let animate = fade && window != nil && Theme.effects.animates
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let target: Float = index == nil ? 0 : 1
        if (index != nil) != wasShowing || inspector.opacity != target {
            let from = (inspector.presentation() ?? inspector).opacity
            inspector.opacity = target
            if animate {
                let opacity = CABasicAnimation(keyPath: "opacity"); opacity.fromValue = from; opacity.toValue = target
                opacity.duration = target > 0 ? 0.12 : 0.18; opacity.timingFunction = Theme.Ease.out
                inspector.add(opacity, forKey: "opacity")
            } else { inspector.removeAnimation(forKey: "opacity") }
        }
        guard let index else { return }
        let scale = window?.backingScaleFactor ?? 2, p = point(index), value = samples[index]
        let hairline = 1 / scale, snappedX = (p.x * scale).rounded() / scale
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = Theme.dark
            self.inspector.frame = self.bounds
            self.crosshair.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.32 : 0.26).cgColor
            self.crosshair.frame = CGRect(x: snappedX - hairline / 2, y: r.minY - 2, width: hairline, height: r.height + 4)
            self.probe.backgroundColor = self.tone(value).cgColor
            self.probe.borderColor = (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.9)).cgColor
            self.probe.position = CGPoint(x: snappedX, y: p.y)
            let text = TrendInspection.readout(celsius: value, fahrenheit: self.fahrenheit), font = Theme.number(11, .semibold)
            self.readout.string = text; self.readout.font = font; self.readout.fontSize = 11; self.readout.contentsScale = scale
            self.readout.foregroundColor = (self.heatColor && ThermalState.classify(value) >= .warm ? self.tone(value) : Theme.ink).cgColor
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
            self.readout.frame = CGRect(x: max(0, min(self.bounds.width - width, snappedX - width / 2)).rounded(), y: self.bounds.height - Self.readoutBand, width: width, height: Self.readoutBand)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        TrendInspection.summary(samples, fahrenheit: fahrenheit).map { "Recent temperature, \($0)" } ?? "Recent temperature trend"
    }
}
