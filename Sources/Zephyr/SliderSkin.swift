import AppKit
import QuartzCore

enum ThumbGesture { case settle, grab, release }

/// Draws a `PercentSlider`. The control owns everything that means
/// something (the value, hardware floor, input, commits, haptics,
/// accessibility and focus); a skin owns only layers and the reactions they
/// play. Both styles therefore share one input path, and swapping skins is
/// presentation-only: it never previews, commits or touches the fan.
///
/// Skins read the control's state through the forwarding properties below
/// and keep the event-driven rules: artwork is cached per geometry, every
/// transient animation is finite, and `settle()` removes all of them. The
/// deliberate exceptions are the Channel's miniature rotors (`rotors`),
/// which turn with the real fan, and the full-cooling flow (`flow`): both
/// repeat only while the panel is visible, and freeze in place whenever the
/// control asks (hidden, Settings open, Effects Off, Reduce Motion,
/// disabled or stale).
@MainActor class SliderSkin {
    unowned let host: PercentSlider
    let style: SliderStyle
    /// The full-cooling ice is present (static once formed).
    var isIceFormed = false
    /// Scale of the cached artwork (0 until first rendered).
    var renderedScale: CGFloat = 0
    /// Travel time for value placement. The control lengthens it while it
    /// places a value set from outside (Smart), so every style — including
    /// skins written before this existed — glides perceptibly.
    var glideDuration: CFTimeInterval = SliderSkin.glide
    /// The style's miniature rotors, if it has any (set by the subclass).
    var rotors: RotorField?

    init(host: PercentSlider, style: SliderStyle) { self.host = host; self.style = style }

    /// Root sublayers, bottom to top; the thumb is last.
    var layers: [CALayer] { [] }
    /// Every layer (including masks and sublayers) that may carry animations.
    var allLayers: [CALayer] { layers }
    var thumbSize: CGSize { .zero }
    /// Pointer distance from the thumb centre that picks it up without a jump.
    var grabSlop: CGFloat { 10 }
    func focusRing() -> NSBezierPath { NSBezierPath(rect: bounds) }

    /// Renders cached artwork for the current size, scale, appearance and
    /// floor. Returns false while there is no usable geometry.
    @discardableResult func render(scale: CGFloat) -> Bool { false }
    func place(animated: Bool, userAction: Bool) {}
    func decorate(animated: Bool, userAction: Bool) {}
    func placeMeasured(visible: Bool, animated: Bool) {}
    func shapeThumb(_ gesture: ThumbGesture) {}
    /// The value moved or a pointer went down: drop reactions tied to the
    /// old value (the release sweep).
    func interrupt() {}
    /// Drag speed changed (`host.velocity`).
    func react() {}
    func ripple(at percent: Double, strength: Double, wide: Bool) {}
    func sweep() {}
    /// A user action reached 100% (the control already played the haptic).
    func celebrate(animated: Bool, delay: CFTimeInterval) {}

    func settle() { rotors?.freeze(); setFlow(false); allLayers.forEach { $0.removeAllAnimations() } }
    func uninstall() { settle(); layers.forEach { $0.removeFromSuperlayer() } }
    /// Spins the rotors at `rps` revolutions per second, or freezes them
    /// in place (0). Called by the control whenever visibility, effects,
    /// enablement, freshness or the measured fan speed change.
    func spinRotors(at rps: Double) { if rps > 0 { rotors?.spin(at: rps) } else { rotors?.freeze() } }
    /// The style's continuous full-cooling motion, if it has any.
    var flow: LoopSet? { nil }
    /// Runs (or freezes in place) the full-cooling flow. The control decides
    /// when (`IceFlow.runs`); the skin only plays it at the effects' pace.
    func setFlow(_ running: Bool) {
        guard let flow else { return }
        if running { flow.start(pace: IceFlow.pace(effects: effects)) } else { flow.freeze() }
    }

    // MARK: Control state (read-only)

    var value: Double { host.percent }
    var minimumPercent: Double { host.minimumPercent }
    var effects: EffectsProfile { host.effects }
    var dragging: Bool { host.dragging }
    var hovered: Bool { host.hovered }
    var isEnabled: Bool { host.isEnabled }
    var velocity: Double { host.velocity }
    var window: NSWindow? { host.window }
    var bounds: NSRect { host.bounds }
    var effectiveAppearance: NSAppearance { host.effectiveAppearance }
    func x(for percent: Double) -> CGFloat { style.x(percent: percent, width: bounds.width) }
    /// Rounds to the device pixel grid so the thumb and marks stay crisp at 1×.
    func snap(_ v: CGFloat) -> CGFloat { let s = renderedScale > 0 ? renderedScale : 2; return (v * s).rounded() / s }

    // MARK: Shared animation and drawing helpers

    nonisolated static let glide: CFTimeInterval = 0.2

    /// Sets a layer property and, when animated, eases from what is on
    /// screen now, so a new target interrupts an old one cleanly. Key paths
    /// are whole properties (position, bounds, opacity, transform), which
    /// are always KVC-readable on CALayer. A layer carrying only an additive
    /// speed reaction starts from its model value, so the reaction is not
    /// counted twice.
    func change(_ layer: CALayer, _ keyPath: String, animated: Bool, duration: CFTimeInterval = SliderSkin.glide,
                timing: CAMediaTimingFunction = Theme.Ease.out, _ apply: () -> Void) {
        let surging = layer.animation(forKey: "surge") != nil && layer.animation(forKey: keyPath) == nil
        let from = (surging ? layer : layer.presentation() ?? layer).value(forKeyPath: keyPath)
        apply()
        guard animated, let from else { layer.removeAnimation(forKey: keyPath); return }
        // A placement glide takes the control's current glide time; a longer
        // (external) glide eases in and out so the travel reads as motion.
        let placement = duration == SliderSkin.glide && glideDuration != SliderSkin.glide
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from; animation.toValue = layer.value(forKeyPath: keyPath)
        animation.duration = placement ? glideDuration : duration
        animation.timingFunction = placement ? Theme.Ease.inOut : timing
        layer.add(animation, forKey: keyPath)
    }

    static func bitmap(_ size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded(.up))), height = max(1, Int((size.height * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        return ctx.makeImage()
    }
    static func rotate(_ v: CGVector, _ angle: CGFloat) -> CGVector {
        CGVector(dx: v.dx * cos(angle) - v.dy * sin(angle), dy: v.dx * sin(angle) + v.dy * cos(angle))
    }
    /// Deterministic per-element variation: texture without motion.
    nonisolated static func noise(_ a: Int, _ b: Int) -> CGFloat {
        var h = UInt32(truncatingIfNeeded: (a &* 73_856_093) ^ (b &* 19_349_663))
        h ^= h >> 13; h = h &* 1_274_126_177; h ^= h >> 16
        return CGFloat(h & 0xffff) / 65_535
    }
}
