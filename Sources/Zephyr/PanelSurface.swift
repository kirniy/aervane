import AppKit

/// Owns the window silhouette separately from the material's internal layers.
/// The glass, heat aura and animated content must all stop at the same curve;
/// otherwise their transparent backing can leave square corners in the shadow.
final class PanelSurface: NSView {
    static let radius: CGFloat = 24
    let material: NSView
    private var shadowSize = NSSize.zero

    init(content: NSView) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.cornerRadius = Self.radius
            glass.style = .regular
            glass.contentView = content
            material = glass
        } else {
            let glass = NSVisualEffectView(frame: content.bounds)
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.addSubview(content)
            material = glass
        }
        super.init(frame: content.bounds)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(material)
        material.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        material.frame = bounds
        if shadowSize != bounds.size {
            shadowSize = bounds.size
            window?.invalidateShadow()
        }
    }
}
