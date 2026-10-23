import AppKit

/// Owns the window silhouette separately from the material's internal layers:
/// a continuous rounded body with a pointer rising from its top edge to the
/// status item (`PanelSilhouette`). Material, heat tint and rim all take the
/// same one-piece outline, so the pointer is the body's own material with no
/// seam, and nothing (glass backing, aura, content) can square the corners in
/// the window shadow.
///
/// Public API only. AppKit's Liquid Glass view has no public custom shape, so
/// the material is one `NSVisualEffectView` shaped by `maskImage`, the
/// documented way to shape behind-window material. Content is clipped to the
/// rounded body by a plain layer of its own; no mask sits over the material.
final class PanelSurface: NSView {
    static let radius: CGFloat = PanelMetrics.standard.cornerRadius
    let metrics = PanelMetrics.standard
    /// Pointer centre in surface coordinates, from the window's placement.
    var pointerX: CGFloat? {
        didSet { if pointerX != oldValue { needsLayout = true } }
    }
    /// Faint heat colour across the whole silhouette, pointer included.
    var tint: NSColor? {
        didSet { if tint != oldValue { updateColors() } }
    }

    private let material = NSVisualEffectView()
    private let content: NSView
    /// Clips content to the body (everything below the pointer).
    private let body = NSView()
    private let wash = PassiveLayerView()
    private let rim = PassiveLayerView()
    private let washShape = CAShapeLayer()
    private let rimLight = CAGradientLayer()
    private let rimLine = CAShapeLayer()
    private let rimClip = CAShapeLayer()
    private struct ShapeKey: Equatable { let size: NSSize; let pointerX: CGFloat; let scale: CGFloat }
    private var shapeKey: ShapeKey?
    private var outline: CGPath?

    init(content: NSView) {
        self.content = content
        let frame = NSRect(origin: .zero, size: NSSize(width: content.bounds.width, height: content.bounds.height + PanelMetrics.standard.pointerHeight))
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        material.frame = bounds
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)

        // Tint under the content, rim over it; both are layers masked to the
        // outline (no backdrop inside them, so masking is safe).
        wash.wantsLayer = true
        wash.layer?.mask = washShape
        body.wantsLayer = true
        body.layer?.cornerRadius = Self.radius
        body.layer?.cornerCurve = .continuous
        body.layer?.masksToBounds = true
        body.addSubview(content)
        rim.wantsLayer = true
        rim.layer?.addSublayer(rimLight)
        rimLine.fillColor = nil
        rimLine.strokeColor = NSColor.black.cgColor
        rimLight.mask = rimLine
        rim.layer?.mask = rimClip
        [wash, body, rim].forEach(material.addSubview)
        // The light falls from above: brighter along the top and pointer.
        rimLight.startPoint = CGPoint(x: 0.5, y: 1)
        rimLight.endPoint = CGPoint(x: 0.5, y: 0)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    /// The body: everything below the pointer. Its height is the content's.
    var bodyRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - metrics.pointerHeight))
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        wash.frame = bounds; rim.frame = bounds
        body.frame = bodyRect
        content.frame = body.bounds
        let scale = window?.backingScaleFactor ?? 2
        let key = ShapeKey(size: bounds.size, pointerX: pointerX ?? bounds.width / 2, scale: scale)
        guard key != shapeKey else { return }
        shapeKey = key
        let path = CGPath.make(PanelSilhouette.elements(bodySize: bodyRect.size, pointerX: key.pointerX, metrics: metrics))
        outline = path
        material.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path); context.setFillColor(NSColor.black.cgColor); context.fillPath()
            return true
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        washShape.frame = bounds; washShape.path = path
        rimLight.frame = bounds; rimLine.frame = bounds; rimClip.frame = bounds
        // A two-pixel stroke clipped to the outline leaves one device pixel inside.
        rimLine.path = path; rimLine.lineWidth = 2 / scale
        rimClip.path = path
        CATransaction.commit()
        window?.invalidateShadow()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }

    /// Rim and tint for the current appearance. The rim is a faint highlight
    /// on the material's own edge (stronger with Increase Contrast).
    func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if contrast {
                let edge = NSColor.labelColor.withAlphaComponent(0.45).cgColor
                self.rimLight.colors = [edge, edge]
            } else {
                self.rimLight.colors = dark ? [NSColor.white.withAlphaComponent(0.24).cgColor, NSColor.white.withAlphaComponent(0.08).cgColor]
                                       : [NSColor.white.withAlphaComponent(0.70).cgColor, NSColor.white.withAlphaComponent(0.30).cgColor]
            }
            self.wash.layer?.backgroundColor = self.tint?.cgColor ?? NSColor.clear.cgColor
        }
        CATransaction.commit()
    }

    /// Transparent corners and the air beside the pointer are not the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, let outline else { return super.hitTest(point) }
        return outline.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
}

/// Hosts decorative layers; never takes clicks or accessibility focus.
private final class PassiveLayerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

private extension CGPath {
    static func make(_ elements: [PathElement]) -> CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .curve(let p, let c1, let c2): path.addCurve(to: p, control1: c1, control2: c2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}
