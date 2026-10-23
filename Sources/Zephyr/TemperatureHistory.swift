import AppKit
import QuartzCore
import ZephyrCore

/// Recent temperature as a line whose colour follows the heat bands at each
/// point, with a soft fill beneath. Redrawn only when samples change.
///
/// Pointing at the plot inspects it: a device-pixel hairline and a probe snap
/// to the nearest sample, and that sample's exact value appears in the band
/// above the plot. Inspection moves three layers and never redraws the line;
/// it tracks the pointer without animation and fades only on entry and exit.
///
/// While Smart runs, its target sits on the trend as a dashed line with a
/// small degree handle, so regulation is visible around it. Dragging the
/// handle (or the line) scrubs the target in whole degrees of the user's
/// unit with a fixed mapping (`SmartTargetScrub`): the scale is frozen for
/// the gesture, and nothing is stored until release (`targetCommitted`).
/// VoiceOver sees an adjustable "Smart target" element.
final class TemperatureHistory: NSView {
    /// Room above the plot for the inspected value.
    static let readoutBand: CGFloat = 14

    var samples: [Double] = [] {
        didSet { guard samples != oldValue else { return }; needsDisplay = true; refreshInspection(fade: false); layoutTarget() }
    }
    var heatColor = true { didSet { if heatColor != oldValue { needsDisplay = true; refreshInspection(fade: false) } } }
    var fahrenheit = false { didSet { if fahrenheit != oldValue { endInspection(); refreshInspection(fade: false); layoutTarget() } } }
    /// Smart's target (°C) while Smart runs, else nil (no line). Ignored
    /// while the user is dragging it.
    var smartTarget: Double? {
        didSet { guard smartTarget != oldValue else { return }; if smartTarget == nil { endInspection() }; needsDisplay = true; refreshInspection(fade: false); layoutTarget() }
    }
    /// The user finished choosing a new target (°C): drag release, keys or
    /// VoiceOver. The owner stores it; the chart never writes on its own.
    var targetCommitted: ((Double) -> Void)?
    /// The target being dragged (°C), nil when not dragging (tests).
    private(set) var draggedTarget: Double?
    private var scrub: SmartTargetScrub?, grabY: CGFloat = 0, frozenRange: (low: Double, high: Double)?
    private let targetLine = CAShapeLayer(), targetHandle = CALayer(), targetText = CATextLayer()
    private lazy var targetElement = SmartTargetElement(chart: self)
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
        targetLine.fillColor = nil; targetLine.lineWidth = 1; targetLine.lineDashPattern = [3, 3]
        targetHandle.cornerRadius = 7.5; targetHandle.borderWidth = 0.5
        targetText.alignmentMode = .center
        targetHandle.addSublayer(targetText)
        for layer in [targetLine, targetHandle] { layer.isHidden = true; self.layer?.addSublayer(layer) }
        layer?.addSublayer(inspector)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var plot: NSRect { NSRect(x: 3, y: 4, width: max(0, bounds.width - 6), height: max(0, bounds.height - 8 - Self.readoutBand)) }
    /// The scale: frozen while the target is dragged, else the samples and
    /// the target (`TrendScale`).
    private var range: (low: Double, high: Double) { frozenRange ?? TrendScale.range(samples: samples, target: smartTarget) }
    private func point(_ index: Int) -> CGPoint {
        let r = plot, (low, high) = range
        return CGPoint(x: r.minX + CGFloat(index) / CGFloat(max(1, samples.count - 1)) * r.width,
                       y: CGFloat(TrendScale.y(samples[index], range: (low, high), minY: Double(r.minY), height: Double(r.height))))
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
        guard scrub == nil else { return }
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
        // Hiding mid-drag abandons the gesture: nothing was stored.
        if scrub != nil { scrub = nil; draggedTarget = nil; frozenRange = nil; needsDisplay = true; layoutTarget() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; refreshInspection(fade: false); layoutTarget() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshInspection(fade: false); layoutTarget() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutTarget() }

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
    /// A plain image, or a group holding the adjustable target while Smart runs.
    override func accessibilityRole() -> NSAccessibility.Role? { smartTarget == nil ? .image : .group }
    override func accessibilityChildren() -> [Any]? { smartTarget == nil ? nil : [targetElement] }
    override func accessibilityLabel() -> String? {
        TrendInspection.summary(samples, fahrenheit: fahrenheit).map { "Recent temperature, \($0)" } ?? "Recent temperature trend"
    }

    // MARK: Smart target

    /// The target as shown now (°C): the dragged value during a gesture.
    var shownTarget: Double? { draggedTarget ?? smartTarget }
    /// The handle's frame (view coordinates), for hit testing and tests.
    private(set) var handleFrame: NSRect = .zero
    private var targetY: CGFloat? {
        guard let value = shownTarget else { return nil }
        let r = plot
        return CGFloat(TrendScale.y(value, range: range, minY: Double(r.minY), height: Double(r.height)))
    }
    /// Whether a point (view coordinates) picks up the target: the handle,
    /// or within a few points of the line.
    func grabsTarget(at point: NSPoint) -> Bool {
        guard smartTarget != nil, let y = targetY else { return false }
        return handleFrame.insetBy(dx: -4, dy: -5).contains(point) || (abs(point.y - y) <= 4 && point.x >= plot.minX && point.x <= plot.maxX)
    }
    private func layoutTarget() {
        let shown = shownTarget != nil && bounds.width > 40
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit(); window?.invalidateCursorRects(for: self) }
        targetLine.isHidden = !shown; targetHandle.isHidden = !shown
        guard shown, let value = shownTarget, let y = targetY else { handleFrame = .zero; return }
        let scale = window?.backingScaleFactor ?? 2, r = plot
        let display = SmartTarget.display(value, fahrenheit: fahrenheit)
        let text = "\(display)°", font = Theme.number(10, .semibold)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12, height: CGFloat = 15
        let snappedY = (y * scale).rounded() / scale + 0.5 / scale
        handleFrame = NSRect(x: bounds.width - width, y: (y - height / 2).rounded(), width: width, height: height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: snappedY)); path.addLine(to: CGPoint(x: handleFrame.minX - 2, y: snappedY))
        targetLine.frame = bounds; targetLine.path = path
        targetHandle.frame = handleFrame
        targetText.frame = CGRect(x: 0, y: (height - 13) / 2 - 0.5, width: width, height: 13)
        targetText.string = text; targetText.font = font; targetText.fontSize = 10; targetText.contentsScale = scale
        let dragging = scrub != nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = Theme.dark
            self.targetLine.strokeColor = Theme.ink.withAlphaComponent(dark ? 0.5 : 0.42).cgColor
            self.targetHandle.backgroundColor = (dragging ? Theme.accent.withAlphaComponent(dark ? 0.32 : 0.18) : Theme.ink.withAlphaComponent(dark ? 0.12 : 0.07)).cgColor
            self.targetHandle.borderColor = (dragging ? Theme.accent : Theme.ink.withAlphaComponent(0.18)).cgColor
            self.targetText.foregroundColor = (dragging ? Theme.accent : Theme.ink).cgColor
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard smartTarget != nil, let y = targetY else { return }
        addCursorRect(handleFrame.insetBy(dx: -4, dy: -5), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: plot.minX, y: y - 4, width: max(0, handleFrame.minX - plot.minX), height: 8), cursor: .resizeUpDown)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = smartTarget, grabsTarget(at: point) else { super.mouseDown(with: event); return }
        beginScrub(at: point.y, target: target)
    }
    override func mouseDragged(with event: NSEvent) {
        guard scrub != nil else { super.mouseDragged(with: event); return }
        moveScrub(to: convert(event.locationInWindow, from: nil).y)
    }
    override func mouseUp(with event: NSEvent) {
        guard scrub != nil else { super.mouseUp(with: event); return }
        endScrub()
    }
    /// Pointer-free gesture for tests and agents (view coordinates, y up in
    /// the plot, matching `isFlipped == false`).
    func beginScrub(at y: CGFloat, target: Double) {
        scrub = SmartTargetScrub(celsius: target, fahrenheit: fahrenheit); grabY = y
        frozenRange = range; draggedTarget = target
        pointerX = nil; refreshInspection(fade: true)
        layoutTarget()
    }
    func moveScrub(to y: CGFloat) {
        guard let scrub else { return }
        let next = scrub.celsius(travel: Double(y - grabY))
        guard next != draggedTarget else { return }
        draggedTarget = next
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        layoutTarget()
        NSAccessibility.post(element: targetElement, notification: .valueChanged)
    }
    func endScrub() {
        guard scrub != nil else { return }
        let chosen = draggedTarget, original = smartTarget
        scrub = nil; frozenRange = nil
        if let chosen, chosen != original { targetCommitted?(chosen) }
        draggedTarget = nil
        needsDisplay = true; layoutTarget()
    }
    /// Keyboard and VoiceOver: one whole display step, committed at once.
    func stepTarget(by steps: Int) {
        guard let target = smartTarget, scrub == nil else { return }
        let next = SmartTargetScrub.stepped(target, by: steps, fahrenheit: fahrenheit)
        if next != target { targetCommitted?(next) }
    }
    fileprivate var targetDescription: String {
        guard let value = shownTarget else { return "" }
        return "\(SmartTarget.display(value, fahrenheit: fahrenheit)) degrees \(fahrenheit ? "Fahrenheit" : "Celsius")"
    }
}

/// VoiceOver's view of Smart's target on the trend: an adjustable slider
/// whose increments commit one whole degree at a time.
final class SmartTargetElement: NSAccessibilityElement {
    private weak var chart: TemperatureHistory?
    init(chart: TemperatureHistory) { self.chart = chart; super.init() }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func isAccessibilityEnabled() -> Bool { chart?.smartTarget != nil && chart?.draggedTarget == nil }
    override func accessibilityLabel() -> String? { "Smart target" }
    override func accessibilityValue() -> Any? {
        guard let chart, let value = chart.shownTarget else { return nil }
        return NSNumber(value: SmartTarget.display(value, fahrenheit: chart.fahrenheit))
    }
    override func accessibilityValueDescription() -> String? { chart?.targetDescription }
    override func accessibilityMinValue() -> Any? { SmartTarget.displayRange(fahrenheit: chart?.fahrenheit ?? false).lowerBound }
    override func accessibilityMaxValue() -> Any? { SmartTarget.displayRange(fahrenheit: chart?.fahrenheit ?? false).upperBound }
    override func setAccessibilityValue(_ value: Any?) {
        guard let chart, chart.smartTarget != nil, chart.draggedTarget == nil,
              let number = value as? NSNumber, number.doubleValue.isFinite else { return }
        chart.targetCommitted?(SmartTarget.celsius(fromDisplay: number.doubleValue.rounded(), fahrenheit: chart.fahrenheit))
    }
    override func accessibilityParent() -> Any? { chart }
    override func accessibilityFrame() -> NSRect {
        guard let chart, let window = chart.window else { return .zero }
        return window.convertToScreen(chart.convert(chart.handleFrame, to: nil))
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformIncrement() -> Bool { chart?.stepTarget(by: 1); return chart != nil }
    override func accessibilityPerformDecrement() -> Bool { chart?.stepTarget(by: -1); return chart != nil }
}
