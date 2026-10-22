import AppKit
import QuartzCore

/// The coolant channel (default style). A recessed glass channel filled with
/// coolant light. One energy curve (`SliderEnergy`) drives everything
/// progressive: the coolant cools from mint through glacier cyan toward ice
/// and thickens, streamlines inside it multiply and brighten, and a
/// white-hot head and halo gather at the thumb. From ~45% rime grows inward
/// from the channel's lips and grains cling outside them. At 100% the top of
/// the channel freezes into a faceted sheet with crystals on its rim: a
/// freezing front runs back from the thumb, a glint returns along it, and
/// the thumb frosts over with a burst of needles. Lowering the value melts
/// it: plates fade, crystals retract.
///
/// The thumb is a sculpted glass puck with a coolant core. It squashes when
/// grabbed, leans and stretches with drag speed (springing upright when the
/// pointer stops) and springs back on release. Coolant sloshes against the
/// motion, a moving thumb leaves a short cold wake, and grabs, releases and
/// preset detents send a ripple along the channel.
final class ChannelSkin: SliderSkin {
    /// Resolved ice tones for the thumb core (set with the artwork).
    private var palette = Palette()

    // Channel and coolant.
    private let well = CALayer()
    private let coolant = CALayer(), fillMask = CALayer()
    private let streams = CALayer(), head = CALayer(), headMask = CAGradientLayer()
    // Frost and the full-cooling sheet.
    private let frost = CALayer(), frostMask = CALayer()
    private let crown = CALayer(), crownMask = CAGradientLayer(), sheet = CALayer(), fringe = CALayer()
    private let crownGlint = CALayer(), glintMask = CAGradientLayer()
    // Marks and transient reactions.
    private let floorTick = CALayer(), measuredMark = CALayer()
    private let wake = CAGradientLayer(), halo = CAGradientLayer(), rippleRing = CAShapeLayer(), burst = CALayer()
    // The thumb: `thumb` carries position and the press shape, `tilt` the
    // speed reactions, so the two never fight over one transform.
    private let thumb = CALayer(), tilt = CALayer(), thumbBody = CALayer(), thumbCore = CALayer(), thumbFrost = CALayer()

    private enum Metric {
        static let grabSlop: CGFloat = 12         // pick the thumb up without a jump
        static let glide: CFTimeInterval = 0.2
        static let frostFringe: CGFloat = 7       // rime room above and below the channel
        static let crownFringe: CGFloat = 5       // rim crystals overhang the channel
        static let thumbPad: CGFloat = 5          // shadow and frost room around the thumb
        static let slosh: CGFloat = 6             // streamline travel at full drag speed
        static let glintBand: CGFloat = 26
        static let head: CGFloat = 120
        static let burst = CGSize(width: 76, height: 50)
        /// Freezing front: one stroke from the thumb to the crystal onset.
        static let form: CFTimeInterval = 0.62
        /// Front, then the glint's return to the thumb, which freezes it.
        static let formation: CFTimeInterval = 1.25
        static let melt: CFTimeInterval = 0.42
        static let frostMelt: CFTimeInterval = 0.5
        static let wakeFade: CFTimeInterval = 0.42
    }

    private struct Palette {
        var low: [CGFloat] = [0.56, 0.86, 0.76], mid: [CGFloat] = [0.42, 0.84, 0.96], top: [CGFloat] = [0.86, 0.98, 1]
        var dark = true
        func color(_ percent: Double, alpha: Double) -> CGColor {
            let w = SliderEnergy.tone(percent: percent)
            let c = (0..<3).map { low[$0] * CGFloat(w.low) + mid[$0] * CGFloat(w.mid) + top[$0] * CGFloat(w.high) }
            return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: CGFloat(alpha))
        }
        /// The thumb's core stays saturated so it reads on the white puck.
        func core(_ percent: Double) -> CGColor { color(dark ? percent * 0.8 : percent, alpha: 1) }
    }

    init(host: PercentSlider) {
        super.init(host: host, style: .channel)
        coolant.mask = fillMask
        fillMask.backgroundColor = NSColor.black.cgColor; fillMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        // The head is a horizontal light falloff that peaks just behind the
        // thumb; it lives inside the coolant so it can never light the
        // channel ahead of the value.
        head.mask = headMask
        headMask.startPoint = CGPoint(x: 0, y: 0.5); headMask.endPoint = CGPoint(x: 1, y: 0.5)
        headMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        headMask.locations = [0, 0.86, 1]; headMask.anchorPoint = CGPoint(x: 0.86, y: 0.5)
        coolant.addSublayer(streams); coolant.addSublayer(head)
        frost.mask = frostMask
        frostMask.backgroundColor = NSColor.black.cgColor; frostMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        // The sheet reveals from the thumb end leftward as it forms.
        crown.mask = crownMask
        crownMask.startPoint = CGPoint(x: 1, y: 0.5); crownMask.endPoint = CGPoint(x: 0, y: 0.5)
        crownMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        crownMask.locations = [0, 1, 1]
        crown.addSublayer(sheet); crown.addSublayer(fringe)
        // The glint is the sheet's edges in white, seen through a narrow band.
        crownGlint.mask = glintMask
        glintMask.startPoint = CGPoint(x: 0, y: 0.5); glintMask.endPoint = CGPoint(x: 1, y: 0.5)
        glintMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        glintMask.locations = [0, 0.5, 1]
        halo.type = .radial; halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        rippleRing.fillColor = nil; rippleRing.lineWidth = 1
        wake.masksToBounds = true
        tilt.addSublayer(thumbBody); tilt.addSublayer(thumbCore); tilt.addSublayer(thumbFrost)
        thumb.addSublayer(tilt)
        for layer in [streams, head, frost, crown, crownGlint, measuredMark, wake, halo, rippleRing, burst, thumbFrost] { layer.opacity = 0 }
        for layer in [well, coolant, streams, head, frost, sheet, fringe, crownGlint, burst, thumbBody, thumbFrost] { layer.contentsGravity = .resize }
    }

    override var layers: [CALayer] { [well, floorTick, coolant, frost, crown, crownGlint, measuredMark, wake, halo, rippleRing, burst, thumb] }
    override var allLayers: [CALayer] {
        [well, coolant, fillMask, streams, head, headMask, frost, frostMask, crown, crownMask, sheet, fringe, crownGlint, glintMask,
         floorTick, measuredMark, wake, halo, rippleRing, burst, thumb, tilt, thumbBody, thumbCore, thumbFrost]
    }
    override var thumbSize: CGSize { SliderGeometry.thumb }
    override var grabSlop: CGFloat { Metric.grabSlop }
    override func focusRing() -> NSBezierPath {
        let ring = channelRect.insetBy(dx: -5, dy: -6)
        return NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2)
    }
    private var channelRect: NSRect { SliderGeometry.channel(in: bounds) }

    // MARK: Artwork (rendered once per geometry/appearance)

    @discardableResult override func render(scale: CGFloat) -> Bool {
        guard bounds.width > 4 * SliderGeometry.inset, bounds.height > 0 else { return false }
        renderedScale = scale
        let channel = channelRect, W = channel.width, H = channel.height, floorValue = minimumPercent
        let F = Metric.frostFringe, C = Metric.crownFringe, pad = Metric.thumbPad, S = Metric.slosh
        let thumbSize = SliderGeometry.thumb
        let width = bounds.width
        /// Channel-local x of a value, and the value at a channel-local x.
        func px(_ p: Double) -> CGFloat { SliderGeometry.x(percent: p, width: width) - channel.minX }
        func pct(_ x: CGFloat) -> Double { SliderGeometry.percent(atX: x + channel.minX, width: width) }
        func crystal(_ x: CGFloat) -> CGFloat { CGFloat(Frost.crystal(percent: pct(x))) }
        let floorX = floorValue > 0 ? px(floorValue) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = Theme.dark
            func rgb(_ color: NSColor) -> [CGFloat] {
                let c = color.usingColorSpace(.sRGB) ?? color
                return [c.redComponent, c.greenComponent, c.blueComponent]
            }
            let low = Theme.iceLow.usingColorSpace(.sRGB) ?? Theme.iceLow
            let mid = Theme.iceMid.usingColorSpace(.sRGB) ?? Theme.iceMid
            let high = Theme.iceHigh.usingColorSpace(.sRGB) ?? Theme.iceHigh
            // On dark glass the coolant stops short of white so the ice
            // sheet, the thumb and white light still read on top of it.
            let top = dark ? (mid.blended(withFraction: 0.6, of: high) ?? high) : high
            self.palette = Palette(low: rgb(low), mid: rgb(mid), top: rgb(top), dark: dark)
            let palette = self.palette
            let rime = (Theme.rime.usingColorSpace(.sRGB) ?? Theme.rime).cgColor
            let white = NSColor.white.cgColor
            let crack = dark ? CGColor(srgbRed: 0.05, green: 0.36, blue: 0.5, alpha: 1) : CGColor(srgbRed: 0, green: 0.17, blue: 0.34, alpha: 1)
            let shade = NSColor.black.cgColor

            // The channel: a capsule cut into the glass, shadowed under its
            // upper lip and catching light along its lower one.
            self.well.contents = Self.bitmap(CGSize(width: W + 4, height: H + 4), scale: scale) { ctx in
                let r = CGRect(x: 2, y: 2, width: W, height: H)
                ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: W + 4, height: 2 + H / 2))
                ctx.addPath(Self.capsule(r.offsetBy(dx: 0, dy: -1))); ctx.setFillColor(NSColor.white.withAlphaComponent(dark ? 0.08 : 0.6).cgColor); ctx.fillPath()
                ctx.restoreGState()
                ctx.addPath(Self.capsule(r)); ctx.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.26 : 0.075).cgColor); ctx.fillPath()
                ctx.saveGState(); ctx.addPath(Self.capsule(r)); ctx.clip()
                Self.vertical(ctx, shade, from: (r.maxY, dark ? 0.5 : 0.17), to: (r.maxY - H * 0.55, 0))
                ctx.restoreGState()
                ctx.addPath(Self.capsule(r.insetBy(dx: 0.25, dy: 0.25))); ctx.setLineWidth(0.5)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.3 : 0.07).cgColor); ctx.strokePath()
            }

            // Coolant: the held floor zone, then the cooling ramp, shaded
            // like light inside a glass tube.
            self.coolant.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                ctx.addPath(Self.capsule(CGRect(x: 0, y: 0, width: W, height: H))); ctx.clip()
                if floorX > 0 {
                    ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: floorX, height: H))
                    ctx.setFillColor(palette.color(0, alpha: dark ? 0.34 : 0.28)); ctx.fill(CGRect(x: 0, y: 0, width: floorX, height: H))
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(dark ? 0.16 : 0.42).cgColor); ctx.setLineWidth(0.6)
                    var x = -H
                    while x < floorX { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x + H, y: H)); x += 3.5 }
                    ctx.strokePath(); ctx.restoreGState()
                }
                var stops = Array(stride(from: min(97.5, max(0, floorValue)), through: 100, by: 2.5))
                if stops.last != 100 { stops.append(100) }
                let colors = stops.map { palette.color($0, alpha: SliderEnergy.coolant(percent: $0)) }
                let locations = stops.map { min(1, max(0, px($0) / W)) }
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations) {
                    ctx.saveGState(); ctx.clip(to: CGRect(x: floorX, y: 0, width: W - floorX, height: H))
                    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: W, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    ctx.restoreGState()
                }
                Self.vertical(ctx, white, from: (H, 0.34), to: (H * 0.45, 0))
                Self.vertical(ctx, shade, from: (0, dark ? 0.2 : 0.14), to: (H * 0.4, 0))
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.6); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: H / 2, y: H - 1.6)); ctx.addLine(to: CGPoint(x: W - H / 2, y: H - 1.6)); ctx.strokePath()
            }

            // Streamlines: cold air inside the coolant. Longer, denser and
            // brighter toward full cooling. Wider than the channel so the
            // coolant can slosh against a fast drag.
            let lanes: [CGFloat] = [0.24, 0.42, 0.6, 0.78]
            self.streams.contents = Self.bitmap(CGSize(width: W + 2 * S, height: H), scale: scale) { ctx in
                ctx.setLineCap(.round)
                for (l, lane) in lanes.enumerated() {
                    var x = max(floorX, px(0) - 4), k = 0
                    while x < W + S {
                        let seed = l * 977 + k
                        let e = CGFloat(SliderEnergy.level(percent: pct(x)))
                        let length = 3 + 9 * Self.noise(seed, 191) + 22 * e
                        let alpha = (0.14 + 0.6 * e) * (0.55 + 0.45 * Self.noise(seed, 197))
                        let y = H * lane + (Self.noise(seed, 199) - 0.5) * 0.9
                        // Tapered streak: faint tail, bright leading tip.
                        for (i, part) in [0.35, 0.7, 1.0].enumerated() {
                            let a = x + length * CGFloat(i) / 3, b = x + length * CGFloat(i + 1) / 3
                            ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha * CGFloat(part)).cgColor)
                            ctx.setLineWidth(0.45 + 0.12 * CGFloat(i) + 0.3 * e)
                            ctx.move(to: CGPoint(x: S + a, y: y)); ctx.addLine(to: CGPoint(x: S + b, y: y)); ctx.strokePath()
                        }
                        x += length + 2 + 9 * (1 - e) * Self.noise(seed, 193) + 2; k += 1
                    }
                }
            }
            // The head: a white-hot core of the same lanes, faded by energy.
            self.head.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setLineCap(.round); ctx.setLineWidth(0.75)
                for lane in lanes {
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                    ctx.move(to: CGPoint(x: 0, y: H * lane)); ctx.addLine(to: CGPoint(x: W, y: H * lane)); ctx.strokePath()
                }
                Self.vertical(ctx, white, from: (H / 2, 0.5), to: (H * 0.85, 0))
                Self.vertical(ctx, white, from: (H / 2, 0.5), to: (H * 0.15, 0))
                Self.fade(ctx, width: W, height: H, stops: stride(from: 0.0, through: 100, by: 5).map { (px($0), pow(SliderEnergy.level(percent: $0), 0.6)) })
                ctx.endTransparencyLayer()
            }

            // Rime: from the frost onset, grains and small dendrites grow from
            // both lips into the coolant, and grains cling outside. Thicker
            // and reaching further toward full cooling.
            self.frost.contents = Self.bitmap(CGSize(width: W, height: H + 2 * F), scale: scale) { ctx in
                ctx.setLineCap(.round)
                let inner = Self.capsule(CGRect(x: 0, y: F, width: W, height: H))
                for c in 0..<Int(W) {
                    let x = CGFloat(c) + 0.5, p = pct(x), w = CGFloat(Frost.amount(percent: p))
                    guard w > 0.02, p >= floorValue else { continue }
                    for side in 0..<2 {
                        let up = side == 0, inward: CGFloat = up ? -1 : 1
                        let edge = up ? F + H : F
                        ctx.saveGState(); ctx.addPath(inner); ctx.clip()
                        let grains = Int((w * 2.2 * (0.4 + Self.noise(c, 151 + side))).rounded(.down))
                        for k in 0..<grains {
                            let seed = c * 7 + k
                            let d = pow(Self.noise(seed, 157 + side), 1.6) * (0.5 + H * 0.42 * w)
                            let size = (0.95 - 0.35 * d / (H / 2)) * (0.7 + 0.3 * Self.noise(seed, 163 + side))
                            let cx = x + (Self.noise(seed, 167 + side) - 0.5) * 1.6, cy = edge + inward * d
                            ctx.setFillColor(NSColor.white.withAlphaComponent((0.2 + 0.6 * w) * max(0.2, 1 - 0.6 * d / (H / 2))).cgColor)
                            ctx.fillEllipse(in: CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
                        }
                        if c % 3 == 0, w > 0.2, Self.noise(c, 173 + side) < w * 0.6 {
                            let length = (1.2 + H * 0.5 * w) * (0.55 + 0.45 * Self.noise(c, 179 + side))
                            let dir = Self.rotate(CGVector(dx: 0, dy: inward), (Self.noise(c, 181 + side) - 0.5) * 0.8)
                            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35 + 0.45 * w).cgColor); ctx.setLineWidth(0.5)
                            Self.dendrite(ctx, from: CGPoint(x: x, y: edge), dir: dir, length: length, flip: Self.noise(c, 183 + side) < 0.5)
                        }
                        ctx.restoreGState()
                        // Outside the lip, in rime (every other point, so it
                        // reads as grain rather than fur).
                        guard c % 2 == 0 else { continue }
                        let outer = up ? edge + 0.4 : edge - 0.4, reach = F - 1
                        ctx.setFillColor(rime)
                        for k in 0..<Frost.grains(amount: Double(w), noise: Double(Self.noise(c, 41 + side))) {
                            let seed = c * 7 + k
                            let d = pow(Self.noise(seed, 53 + side), 1.7) * (1.2 + (reach - 1.2) * w)
                            let size = (0.95 - 0.4 * d / reach) * (0.75 + 0.25 * Self.noise(seed, 61 + side))
                            let cx = x + (Self.noise(seed, 59 + side) - 0.5) * 2.4, cy = outer - inward * d
                            ctx.setAlpha((0.22 + 0.6 * w) * (1 - 0.55 * d / reach))
                            ctx.fillEllipse(in: CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
                        }
                        ctx.setAlpha(1)
                    }
                }
            }

            // The sheet: at full cooling the top of the channel freezes into
            // plates of varied clarity with bevelled fractures, a few long
            // cracks, trapped bubbles and a specular band, strongest at the
            // thumb (`Frost.crystal`). Geometry is built once and shared by
            // the sheet and its glint.
            let ice = IceGeometry(start: max(0, px(Frost.crystalOnset) - 6), width: W, height: H, weight: crystal)
            self.sheet.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                ctx.addPath(Self.capsule(CGRect(x: 0, y: 0, width: W, height: H))); ctx.clip()
                for (i, plate) in ice.plates.enumerated() where plate.weight > 0.01 {
                    ctx.setFillColor(NSColor.white.withAlphaComponent(plate.weight * (0.08 + 0.4 * Self.noise(i, 113))).cgColor)
                    ctx.addLines(between: plate.points); ctx.closePath(); ctx.fillPath()
                }
                ctx.setLineJoin(.round); ctx.setLineCap(.round)
                for edge in ice.edges {
                    ctx.setStrokeColor(crack.copy(alpha: 0.75 * edge.weight) ?? crack); ctx.setLineWidth(0.65)
                    ctx.move(to: edge.a.applying(.init(translationX: 0, y: -0.35))); ctx.addLine(to: edge.b.applying(.init(translationX: 0, y: -0.35))); ctx.strokePath()
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7 * edge.weight).cgColor); ctx.setLineWidth(0.5)
                    ctx.move(to: edge.a.applying(.init(translationX: 0, y: 0.35))); ctx.addLine(to: edge.b.applying(.init(translationX: 0, y: 0.35))); ctx.strokePath()
                }
                for fracture in ice.fractures {
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75 * fracture.weight).cgColor); ctx.setLineWidth(0.5)
                    ctx.addLines(between: fracture.points); ctx.strokePath()
                }
                for bubble in ice.bubbles {
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.5 * bubble.weight).cgColor)
                    ctx.fillEllipse(in: CGRect(x: bubble.center.x - bubble.size / 2, y: bubble.center.y - bubble.size / 2, width: bubble.size, height: bubble.size))
                }
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                Self.vertical(ctx, white, from: (H, 0.6), to: (H * 0.55, 0))
                Self.fade(ctx, width: W, height: H, stops: stride(from: Frost.crystalOnset, through: 100, by: 2.5).map { (px($0), Frost.crystal(percent: $0)) })
                ctx.endTransparencyLayer()
            }
            // Rim crystals: tapered needles (some branched) and grains growing
            // out of both lips, with a hairline of rime along each edge.
            @MainActor func needles(_ ctx: CGContext, color: CGColor, solid: Bool) {
                for c in stride(from: 0, to: Int(W - H / 2), by: 2) {
                    let x = CGFloat(c) + 0.5, w = crystal(x)
                    guard w > 0.04 else { continue }
                    for side in 0..<2 {
                        let up = side == 0, edge = up ? C + H : C, out: CGFloat = up ? 1 : -1
                        guard Self.noise(c, 131 + side) < 0.12 + 0.36 * w else { continue }
                        let length = (0.8 + 4.2 * w) * (0.3 + 0.7 * pow(Self.noise(c, 137 + side), 2))
                        let dir = Self.rotate(CGVector(dx: 0, dy: out), (Self.noise(c, 139 + side) - 0.5) * 0.9)
                        ctx.setFillColor(color.copy(alpha: solid ? w : 0.4 + 0.55 * w) ?? color)
                        Self.needle(ctx, from: CGPoint(x: x, y: edge), dir: dir, length: length, base: 0.5 + 0.5 * w)
                        if Self.noise(c, 141 + side) < 0.3 * w {
                            let fork = CGPoint(x: x + dir.dx * length * 0.55, y: edge + dir.dy * length * 0.55)
                            Self.needle(ctx, from: fork, dir: Self.rotate(dir, Self.noise(c, 143 + side) < 0.5 ? 0.8 : -0.8), length: length * 0.4, base: 0.45)
                        }
                    }
                }
            }
            @MainActor func rims(_ ctx: CGContext, color: CGColor, alpha: CGFloat) {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setStrokeColor(color.copy(alpha: alpha) ?? color); ctx.setLineWidth(0.6)
                for y in [C + H + 0.3, C - 0.3] { ctx.move(to: CGPoint(x: H / 2, y: y)); ctx.addLine(to: CGPoint(x: W - H / 2, y: y)) }
                ctx.strokePath()
                Self.fade(ctx, width: W, height: H + 2 * C, stops: stride(from: Frost.crystalOnset, through: 100, by: 2.5).map { (px($0), Frost.crystal(percent: $0)) })
                ctx.endTransparencyLayer()
            }
            self.fringe.contents = Self.bitmap(CGSize(width: W, height: H + 2 * C), scale: scale) { ctx in
                rims(ctx, color: rime, alpha: 0.8)
                needles(ctx, color: rime, solid: false)
            }
            self.crownGlint.contents = Self.bitmap(CGSize(width: W, height: H + 2 * C), scale: scale) { ctx in
                ctx.saveGState(); ctx.translateBy(x: 0, y: C)
                ctx.addPath(Self.capsule(CGRect(x: 0, y: 0, width: W, height: H))); ctx.clip()
                ctx.setLineCap(.round); ctx.setLineWidth(0.8)
                for edge in ice.edges {
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(edge.weight).cgColor)
                    ctx.move(to: edge.a); ctx.addLine(to: edge.b); ctx.strokePath()
                }
                for fracture in ice.fractures {
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(fracture.weight).cgColor)
                    ctx.addLines(between: fracture.points); ctx.strokePath()
                }
                ctx.restoreGState()
                rims(ctx, color: white, alpha: 1)
                needles(ctx, color: white, solid: true)
            }

            // Crystallisation burst: irregular needles thrown out along the
            // channel from the thumb. Not a flake: uneven lengths and angles.
            self.burst.contents = Self.bitmap(Metric.burst, scale: scale) { ctx in
                let centre = CGPoint(x: Metric.burst.width / 2, y: Metric.burst.height / 2)
                ctx.setFillColor(dark ? white : rime)
                for i in 0..<17 {
                    let angle = CGFloat(i) / 17 * 2 * .pi + (Self.noise(i, 211) - 0.5) * 0.32
                    let reach = 8.5 + 2.5 * Self.noise(i, 217)
                    let start = CGPoint(x: centre.x + cos(angle) * reach * 1.35, y: centre.y + sin(angle) * reach * 0.85)
                    let length: CGFloat = (i % 3 == 0 ? 6 : 10) + 12 * Self.noise(i, 213)
                    ctx.setAlpha(0.5 + 0.5 * Self.noise(i, 219))
                    Self.needle(ctx, from: start, dir: CGVector(dx: cos(angle), dy: sin(angle) * 0.7), length: length, base: 1.1)
                }
                for i in 0..<12 {
                    let angle = Self.noise(i, 223) * 2 * .pi, reach = 12 + 14 * Self.noise(i, 227), size = 0.7 + 0.7 * Self.noise(i, 229)
                    ctx.setAlpha(0.35 + 0.5 * Self.noise(i, 231))
                    ctx.fillEllipse(in: CGRect(x: centre.x + cos(angle) * reach * 1.3 - size / 2, y: centre.y + sin(angle) * reach * 0.75 - size / 2, width: size, height: size))
                }
            }

            // The thumb: a sculpted glass puck. White body cooling toward the
            // base, a specular crest, a refracted glow at the foot, a bevel
            // and a recessed slot that holds the coolant core.
            let puck = CGRect(x: pad, y: pad, width: thumbSize.width, height: thumbSize.height)
            let body = CGSize(width: thumbSize.width + 2 * pad, height: thumbSize.height + 2 * pad)
            self.thumbBody.contents = Self.bitmap(body, scale: scale) { ctx in
                let path = Self.capsule(puck)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.3).cgColor)
                ctx.addPath(path); ctx.setFillColor(white); ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState(); ctx.addPath(path); ctx.clip()
                // Faintly cool glass, so the white specular crest reads on it.
                let crest = NSColor.white.blended(withFraction: dark ? 0.06 : 0.035, of: mid) ?? .white
                let base = NSColor.white.blended(withFraction: dark ? 0.24 : 0.13, of: mid) ?? .white
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [crest.cgColor, base.cgColor] as CFArray, locations: [0.15, 1]) {
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: puck.maxY), end: CGPoint(x: 0, y: puck.minY), options: [])
                }
                Self.radial(ctx, mid.withAlphaComponent(dark ? 0.45 : 0.3).cgColor, at: CGPoint(x: puck.midX, y: puck.minY + 2.5), radius: 6)
                Self.radial(ctx, white, at: CGPoint(x: puck.midX - 1, y: puck.maxY - 4), radius: 5.5)
                ctx.restoreGState()
                ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: puck.midY, width: body.width, height: body.height))
                ctx.addPath(Self.capsule(puck.insetBy(dx: 0.9, dy: 0.9))); ctx.setStrokeColor(white); ctx.setLineWidth(0.6); ctx.strokePath()
                ctx.restoreGState()
                ctx.addPath(Self.capsule(puck.insetBy(dx: 0.25, dy: 0.25))); ctx.setLineWidth(0.5)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.42 : 0.2).cgColor); ctx.strokePath()
                ctx.addPath(Self.capsule(CGRect(x: puck.midX - 2.5, y: puck.midY - 7.5, width: 5, height: 15)))
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.16).cgColor); ctx.fillPath()
            }
            // Frozen thumb: a rime rim with needles and a frosted cap.
            self.thumbFrost.contents = Self.bitmap(body, scale: scale) { ctx in
                let path = Self.capsule(puck)
                ctx.saveGState(); ctx.addPath(path); ctx.clip()
                Self.vertical(ctx, dark ? white : rime, from: (puck.maxY, dark ? 0.6 : 0.3), to: (puck.maxY - 8, 0))
                ctx.restoreGState()
                ctx.addPath(Self.capsule(puck.insetBy(dx: 0.5, dy: 0.5))); ctx.setStrokeColor(rime); ctx.setLineWidth(1); ctx.strokePath()
                ctx.setFillColor(rime)
                let radius = puck.width / 2
                for (i, (point, normal)) in Self.capsuleOutline(puck, radius: radius).enumerated() where Self.noise(i, 233) < 0.72 {
                    let dir = Self.rotate(normal, (Self.noise(i, 237) - 0.5) * 0.8)
                    ctx.setAlpha(0.6 + 0.4 * Self.noise(i, 239))
                    Self.needle(ctx, from: point, dir: dir, length: 0.9 + 2.2 * Self.noise(i, 241), base: 0.8)
                }
            }

            self.halo.colors = [Theme.iceMid.withAlphaComponent(dark ? 0.55 : 0.3).cgColor, Theme.iceMid.withAlphaComponent(0).cgColor]
            self.wake.colors = [(dark ? high : NSColor.white).withAlphaComponent(0).cgColor, (dark ? high : NSColor.white).withAlphaComponent(0.95).cgColor]
            self.rippleRing.strokeColor = (dark ? high : mid).cgColor
            self.measuredMark.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.55 : 0.45).cgColor
            self.floorTick.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.34 : 0.28).cgColor
        }
        for layer in [well, coolant, streams, head, frost, sheet, fringe, crownGlint, burst, thumbBody, thumbFrost, rippleRing] as [CALayer] { layer.contentsScale = scale }
        well.frame = channel.insetBy(dx: -2, dy: -2)
        coolant.frame = channel
        fillMask.bounds = CGRect(x: 0, y: 0, width: 0, height: H); fillMask.position = CGPoint(x: 0, y: H / 2)
        streams.bounds = CGRect(x: 0, y: 0, width: W + 2 * S, height: H); streams.position = CGPoint(x: W / 2, y: H / 2)
        head.frame = CGRect(x: 0, y: 0, width: W, height: H)
        headMask.bounds = CGRect(x: 0, y: 0, width: Metric.head, height: H)
        frost.frame = channel.insetBy(dx: 0, dy: -F)
        frostMask.bounds = CGRect(x: 0, y: 0, width: 0, height: frost.bounds.height); frostMask.position = CGPoint(x: 0, y: frost.bounds.height / 2)
        crown.frame = channel.insetBy(dx: 0, dy: -C)
        crownMask.frame = crown.bounds
        sheet.frame = CGRect(x: 0, y: C, width: W, height: H)
        fringe.bounds = crown.bounds; fringe.position = CGPoint(x: crown.bounds.midX, y: crown.bounds.midY)
        crownGlint.frame = crown.frame
        glintMask.bounds = CGRect(x: 0, y: 0, width: Metric.glintBand, height: crownGlint.bounds.height)
        glintMask.position = CGPoint(x: x(for: 100) - channel.minX, y: crownGlint.bounds.height / 2)
        wake.cornerRadius = H / 2
        halo.bounds = CGRect(x: 0, y: 0, width: 60, height: 40)
        let ring = CGRect(origin: .zero, size: CGSize(width: thumbSize.width + 4, height: thumbSize.height + 4))
        rippleRing.bounds = ring; rippleRing.path = Self.capsule(ring.insetBy(dx: 0.5, dy: 0.5))
        burst.bounds = CGRect(origin: .zero, size: Metric.burst); burst.position = CGPoint(x: x(for: 100), y: channel.midY)
        measuredMark.bounds = CGRect(x: 0, y: 0, width: 2, height: H + 8); measuredMark.cornerRadius = 1
        floorTick.isHidden = floorValue <= 0
        floorTick.frame = CGRect(x: snap(x(for: floorValue) - 0.5), y: channel.minY - 4, width: 1, height: H + 8)
        thumb.bounds = CGRect(origin: .zero, size: thumbSize)
        tilt.bounds = thumb.bounds; tilt.position = CGPoint(x: thumbSize.width / 2, y: thumbSize.height / 2)
        thumbBody.bounds = CGRect(origin: .zero, size: CGSize(width: thumbSize.width + 2 * pad, height: thumbSize.height + 2 * pad)); thumbBody.position = tilt.position
        thumbFrost.bounds = thumbBody.bounds; thumbFrost.position = tilt.position
        thumbCore.bounds = CGRect(x: 0, y: 0, width: 4, height: 14); thumbCore.cornerRadius = 2; thumbCore.position = tilt.position
        CATransaction.commit()
        return true
    }

    // MARK: Placement and progressive decoration

    /// Moves thumb, coolant, frost reveal, head and halo together. Frost
    /// lowered by a drag melts back behind the thumb instead of vanishing.
    override func place(animated: Bool, userAction: Bool) {
        let channel = channelRect, targetX = snap(x(for: value)), fill = max(0, targetX - channel.minX)
        let shownX = (thumb.presentation() ?? thumb).position.x
        let glide = animated && effects.animates && window != nil && abs(shownX - targetX) > 0.5
        let frostShown = (frostMask.presentation() ?? frostMask).bounds.width
        let melting = !glide && dragging && effects.animates && effects.frost > 0 && window != nil && fill < frostShown - 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(thumb, "position", animated: glide) { thumb.position = CGPoint(x: targetX, y: channel.midY) }
        change(halo, "position", animated: glide) { halo.position = CGPoint(x: targetX, y: channel.midY) }
        change(fillMask, "bounds", animated: glide) { fillMask.bounds = CGRect(x: 0, y: 0, width: fill, height: channel.height) }
        change(frostMask, "bounds", animated: glide || melting, duration: melting ? Metric.frostMelt : Metric.glide, timing: melting ? Theme.Ease.inOut : Theme.Ease.out) {
            frostMask.bounds = CGRect(x: 0, y: 0, width: fill, height: frost.bounds.height)
        }
        change(headMask, "position", animated: glide) { headMask.position = CGPoint(x: fill, y: channel.height / 2) }
        if glide && userAction && effects.wake { streak(from: shownX, to: targetX) }
        CATransaction.commit()
    }

    /// Intensities derived from the value: coolant light, head, halo, frost,
    /// the thumb's core and the sheet. `userAction` distinguishes a person
    /// reaching full cooling from a model refresh (which never plays the
    /// formation).
    override func decorate(animated: Bool, userAction: Bool) {
        let energy = SliderEnergy.level(percent: value), amount = Frost.amount(percent: value)
        let interaction = dragging ? 1.0 : hovered ? 0.85 : 0.7
        let animate = animated && effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(halo, "opacity", animated: animate, duration: 0.25) { halo.opacity = Float(effects.glow * (0.15 + 0.85 * energy) * interaction) }
        change(halo, "transform", animated: animate, duration: 0.25) {
            let s = CGFloat(0.75 + 0.4 * energy + (dragging ? 0.12 : 0)); halo.transform = CATransform3DMakeScale(s, s, 1)
        }
        change(streams, "opacity", animated: animate, duration: 0.25) { streams.opacity = Float(effects.glow * (0.35 + 0.65 * energy)) }
        change(head, "opacity", animated: animate, duration: 0.25) { head.opacity = Float(effects.glow * (0.15 + 0.85 * energy) * interaction) }
        change(headMask, "transform", animated: animate, duration: 0.25) { headMask.transform = CATransform3DMakeScale(CGFloat(0.35 + 1.1 * energy), 1, 1) }
        thumbCore.backgroundColor = palette.core(value)
        let crowned = Frost.crowned(percent: value) && effects.frost > 0
        // A drag tracks instantly but may still form/melt the decorative
        // sheet. Keyboard changes have neither a drag nor animated travel.
        let animateCrown = (animated || userAction && dragging) && effects.animates && window != nil
        // Loose rime consolidates into the sheet as it forms (and loosens
        // again as it melts), so full cooling reads as ice, not more grain.
        let consolidating = crowned != isIceFormed && animateCrown
        change(frost, "opacity", animated: animate || consolidating, duration: consolidating ? (crowned ? Metric.form : Metric.melt) : 0.3) {
            frost.opacity = Float(amount > 0 ? effects.frost * (0.35 + 0.65 * amount) * (crowned ? 0.45 : 1) : 0)
        }
        // A gliding thumb lands before the ice forms around it; under a drag
        // the thumb is already there.
        if crowned != isIceFormed { setCrown(crowned, form: userAction && animateCrown && effects.forms, animated: animateCrown, delay: animated ? Metric.glide * 0.5 : 0) }
        else if crowned { crown.opacity = Float(effects.frost); thumbFrost.opacity = Float(effects.frost) }
        CATransaction.commit()
    }

    /// Forms (or melts) the ice sheet. The formed state is static artwork:
    /// model values hold it after any transition finishes.
    ///
    /// Formation: a front of plates runs back from the thumb to the crystal
    /// onset while rim crystals grow out of the lips and a glint rides the
    /// front; the glint then returns to the thumb, which frosts over.
    /// Melting freezes the front wherever it is, fades the plates and draws
    /// the crystals back into the lips, so a drag that touches 100% and
    /// leaves never snaps to a full sheet.
    private func setCrown(_ shown: Bool, form: Bool, animated: Bool, delay: CFTimeInterval = 0) {
        isIceFormed = shown
        let opacity = Float(shown ? effects.frost : 0)
        let channel = channelRect, thumbX = x(for: 100) - channel.minX
        let onsetX = x(for: Frost.crystalOnset) - channel.minX
        let rest = shown ? CATransform3DIdentity : CATransform3DMakeScale(1, 0.4, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        crownGlint.removeAllAnimations(); glintMask.removeAllAnimations(); crownGlint.opacity = 0
        if !shown { burst.removeAllAnimations() }
        if shown {
            crownMask.removeAllAnimations(); crownMask.locations = [0, 1, 1]
            glintMask.position = CGPoint(x: thumbX, y: crownGlint.bounds.height / 2)
        }
        if shown && form {
            crown.opacity = opacity; crown.removeAnimation(forKey: "opacity")
            fringe.transform = rest; fringe.removeAnimation(forKey: "transform")
            thumbFrost.opacity = opacity; thumbFrost.removeAnimation(forKey: "opacity")
            // The plates occupy the top of the range; the front crosses
            // exactly that span, so its speed is what the eye follows.
            let span = Double(max(0.05, min(1, (thumbX - onsetX) / max(1, channel.width))))
            let spread = CABasicAnimation(keyPath: "locations")
            spread.fromValue = [0, 0, 0.05]; spread.toValue = [0, span, span + 0.06]
            spread.duration = Metric.form; spread.timingFunction = Theme.Ease.out
            let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = 0; appear.toValue = opacity; appear.duration = 0.12
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(1, 0.3, 1)); grow.toValue = NSValue(caTransform3D: rest)
            grow.duration = Metric.form; grow.timingFunction = Theme.Ease.out
            let back = CGFloat(span) * channel.width
            let ride = CAKeyframeAnimation(keyPath: "position.x")
            ride.values = [thumbX, thumbX - back, thumbX - back, thumbX]; ride.keyTimes = [0, 0.5, 0.58, 1]
            ride.timingFunctions = [Theme.Ease.out, CAMediaTimingFunction(name: .linear), Theme.Ease.inOut]
            ride.duration = Metric.formation
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 0.9, 0.35, 0, 0, 1, 0].map { $0 * opacity }; flash.keyTimes = [0, 0.08, 0.45, 0.52, 0.6, 0.86, 1]
            flash.duration = Metric.formation
            let freeze = CABasicAnimation(keyPath: "opacity"); freeze.fromValue = 0; freeze.toValue = opacity
            freeze.duration = 0.22; freeze.timingFunction = Theme.Ease.out
            let start = CACurrentMediaTime() + delay
            for animation in [spread, appear, grow, ride, flash] as [CAAnimation] { animation.beginTime = start; animation.fillMode = .backwards }
            freeze.beginTime = start + Metric.formation * 0.82; freeze.fillMode = .backwards
            crownMask.add(spread, forKey: "form"); crown.add(appear, forKey: "appear"); fringe.add(grow, forKey: "grow")
            glintMask.add(ride, forKey: "glint"); crownGlint.add(flash, forKey: "glint"); thumbFrost.add(freeze, forKey: "freeze")
        } else {
            if !shown, let current = (crownMask.presentation() ?? crownMask).locations {
                crownMask.removeAllAnimations(); crownMask.locations = current
            }
            let duration = shown ? 0.2 : Metric.melt, timing = shown ? Theme.Ease.out : Theme.Ease.inOut
            change(crown, "opacity", animated: animated, duration: duration, timing: timing) { crown.opacity = opacity }
            change(fringe, "transform", animated: animated, duration: duration, timing: timing) { fringe.transform = rest }
            change(thumbFrost, "opacity", animated: animated, duration: shown ? 0.2 : 0.3, timing: timing) { thumbFrost.opacity = opacity }
            crown.removeAnimation(forKey: "appear"); fringe.removeAnimation(forKey: "grow"); thumbFrost.removeAnimation(forKey: "freeze")
        }
        CATransaction.commit()
    }

    override func placeMeasured(visible: Bool, animated: Bool) {
        guard bounds.width > 4 * SliderGeometry.inset else { return }
        let channel = channelRect
        let animate = animated && effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Pixel-snapped, so sample-to-sample RPM jitter usually leaves the
        // mark where it is and adds no animation.
        if let measured = host.measuredPercent, measured.isFinite {
            let position = CGPoint(x: snap(x(for: measured)), y: channel.midY)
            if position != measuredMark.position {
                change(measuredMark, "position", animated: animate && measuredMark.opacity > 0, duration: 0.45, timing: Theme.Ease.inOut) {
                    measuredMark.position = position
                }
            }
        }
        if measuredMark.opacity != (visible ? 1 : 0) {
            change(measuredMark, "opacity", animated: animate, duration: 0.2) { measuredMark.opacity = visible ? 1 : 0 }
        }
        CATransaction.commit()
    }

    // MARK: Thumb and reactions

    /// Rest, hover and held shapes. A grab squashes the puck before it
    /// settles into its held shape; a release springs back with a little
    /// overshoot. Both start from what is on screen.
    override func shapeThumb(_ gesture: ThumbGesture) {
        let target = dragging ? CATransform3DMakeScale(1.12, 1.06, 1) : hovered && isEnabled ? CATransform3DMakeScale(1.08, 1.04, 1) : CATransform3DIdentity
        let animate = effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let from = (thumb.presentation() ?? thumb).transform
        switch gesture {
        case .grab where animate:
            thumb.transform = target
            let squash = CAKeyframeAnimation(keyPath: "transform")
            squash.values = [from, CATransform3DMakeScale(1.26, 0.88, 1), target].map { NSValue(caTransform3D: $0) }
            squash.keyTimes = [0, 0.35, 1]; squash.duration = 0.26; squash.timingFunction = Theme.Ease.out
            thumb.add(squash, forKey: "transform")
        case .release where animate:
            thumb.transform = target
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1; spring.stiffness = 380; spring.damping = 13
            spring.fromValue = NSValue(caTransform3D: from); spring.toValue = NSValue(caTransform3D: target)
            spring.duration = spring.settlingDuration
            thumb.add(spring, forKey: "transform")
        default:
            change(thumb, "transform", animated: animate, duration: 0.15) { thumb.transform = target }
        }
        CATransaction.commit()
    }

    /// Answers drag speed. Every reaction is additive and decays on its own,
    /// so the slider settles when the pointer stops without any timer.
    override func react() {
        guard window != nil, effects.animates else { return }
        let gain = effects.motion, intensity = SliderMotion.intensity(velocity: velocity), direction: CGFloat = velocity < 0 ? -1 : 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if gain > 0 && intensity > 0.01 {
            let swing = CASpringAnimation(keyPath: "transform.rotation.z")
            swing.isAdditive = true; swing.fromValue = SliderMotion.lean(velocity: velocity, gain: gain); swing.toValue = 0
            swing.mass = 1; swing.stiffness = 240; swing.damping = 11; swing.duration = swing.settlingDuration
            tilt.add(swing, forKey: "surge.lean")
            let stretch = SliderMotion.stretch(velocity: velocity, gain: gain)
            decay(tilt, "transform.scale.x", from: stretch, duration: 0.38, key: "surge.stretch")
            decay(tilt, "transform.scale.y", from: -0.3 * stretch, duration: 0.38, key: "surge.squash")
            decay(headMask, "transform.scale.x", from: SliderMotion.surge(velocity: velocity, gain: gain), duration: 0.5, key: "surge")
            decay(halo, "opacity", from: 0.35 * intensity * effects.glow, duration: 0.5, key: "surge")
            let slosh = CASpringAnimation(keyPath: "position.x")
            slosh.isAdditive = true; slosh.fromValue = -direction * Metric.slosh * CGFloat(intensity * gain); slosh.toValue = 0
            slosh.mass = 1; slosh.stiffness = 200; slosh.damping = 10; slosh.duration = slosh.settlingDuration
            streams.add(slosh, forKey: "surge.slosh")
        }
        if effects.wake { trail() }
        CATransaction.commit()
    }

    private func decay(_ layer: CALayer, _ keyPath: String, from amount: Double, duration: CFTimeInterval, key: String) {
        guard amount.isFinite, abs(amount) > 0.002 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.isAdditive = true; animation.fromValue = amount; animation.toValue = 0
        animation.duration = duration; animation.timingFunction = Theme.Ease.out
        layer.add(animation, forKey: key)
    }

    /// The cold wake behind a moving thumb: brightest at the thumb, it
    /// retracts into it and fades once the pointer slows.
    private func trail() {
        let (length, peak) = SliderMotion.wake(velocity: velocity, energy: SliderEnergy.level(percent: value))
        guard peak > 0, effects.glow > 0 else { return }
        let channel = channelRect, thumbX = thumb.position.x, forward = velocity > 0
        let room = forward ? thumbX - channel.minX : channel.maxX - thumbX
        let shown = min(CGFloat(length), max(0, room))
        guard shown > 3 else { return }
        shapeWake(at: thumbX, length: shown, forward: forward)
        playWake(peak: Float(peak * effects.glow), duration: Metric.wakeFade, keep: 0.25)
    }
    /// A user glide (preset or track click) shoots light to the target; the
    /// tail then gathers into the arriving thumb.
    private func streak(from: CGFloat, to: CGFloat) {
        let distance = abs(to - from)
        guard distance > 24, effects.glow > 0 else { return }
        shapeWake(at: to, length: distance, forward: to > from)
        playWake(peak: Float((0.55 + 0.45 * SliderEnergy.level(percent: value)) * effects.glow), duration: Metric.glide + 0.3, keep: 0.06)
    }
    private func shapeWake(at x: CGFloat, length: CGFloat, forward: Bool) {
        wake.anchorPoint = CGPoint(x: forward ? 1 : 0, y: 0.5)
        wake.bounds = CGRect(x: 0, y: 0, width: length, height: SliderGeometry.channelHeight)
        wake.position = CGPoint(x: x, y: channelRect.midY)
        wake.startPoint = CGPoint(x: forward ? 0 : 1, y: 0.5); wake.endPoint = CGPoint(x: forward ? 1 : 0, y: 0.5)
        wake.opacity = 0; wake.transform = CATransform3DIdentity
    }
    private func playWake(peak: Float, duration: CFTimeInterval, keep: CGFloat) {
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = peak; fade.toValue = 0
        let gather = CABasicAnimation(keyPath: "transform.scale.x"); gather.fromValue = 1; gather.toValue = keep
        let group = CAAnimationGroup(); group.animations = [fade, gather]; group.duration = duration; group.timingFunction = Theme.Ease.out
        wake.add(group, forKey: "wake")
    }

    /// A ring that spreads along the channel: grabs, releases and detents.
    override func ripple(at percent: Double, strength: Double, wide: Bool) {
        guard effects.wake, window != nil, renderedScale > 0 else { return }
        let x = snap(self.x(for: percent))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rippleRing.position = CGPoint(x: x, y: channelRect.midY)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.9, 0.9, 1))
        grow.toValue = NSValue(caTransform3D: CATransform3DMakeScale(wide ? 3.6 : 2.3, wide ? 1.5 : 1.3, 1))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, min(1, strength) * effects.glow, 0]; fade.keyTimes = [0, 0.12, 1]
        let group = CAAnimationGroup(); group.animations = [grow, fade]
        group.duration = wide ? 0.62 : 0.44; group.timingFunction = Theme.Ease.out
        rippleRing.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    override func interrupt() { headMask.removeAnimation(forKey: "sweep"); head.removeAnimation(forKey: "sweep") }

    /// Acknowledges a pointer release: a pulse of light runs from the thumb
    /// back along the coolant toward the fan's floor.
    override func sweep() {
        guard effects.sweep, window != nil, value > minimumPercent + 1 else { return }
        let current = (head.presentation() ?? head).opacity
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = headMask.position.x; travel.toValue = -Metric.head * 0.2
        travel.duration = 0.55; travel.timingFunction = Theme.Ease.out
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [current, min(1, current + 0.55), current]; flash.keyTimes = [0, 0.22, 1]; flash.duration = 0.55
        headMask.add(travel, forKey: "sweep"); head.add(flash, forKey: "sweep")
    }

    /// A burst of needles at the thumb when a user action reaches 100%: on
    /// Expressive it closes the formation (when the returning glint freezes
    /// the thumb), on Subtle it is the whole acknowledgement. Skipped for
    /// keyboard changes and with Reduce Motion.
    override func celebrate(animated: Bool, delay: CFTimeInterval) {
        guard animated, effects.bloom, window != nil else { return }
        let formed = effects.forms && isIceFormed
        let strength = Float(formed ? 1 : 0.65)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        burst.position = CGPoint(x: x(for: 100), y: channelRect.midY)
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, strength, 0]; fade.keyTimes = [0, 0.18, 1]
        let spread = CAKeyframeAnimation(keyPath: "transform.scale"); spread.values = [0.55, 1.0, formed ? 1.22 : 1.1]; spread.keyTimes = [0, 0.35, 1]
        let group = CAAnimationGroup(); group.animations = [fade, spread]; group.duration = formed ? 0.6 : 0.48
        group.timingFunction = Theme.Ease.out
        if formed { group.beginTime = CACurrentMediaTime() + delay + Metric.formation * 0.82; group.fillMode = .backwards }
        burst.add(group, forKey: "burst")
        CATransaction.commit()
    }

    // MARK: Drawing helpers

    private static func capsule(_ rect: CGRect) -> CGPath {
        let radius = min(rect.width, rect.height) / 2
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    /// A vertical gradient of one colour between two (y, alpha) stops.
    private static func vertical(_ ctx: CGContext, _ color: CGColor, from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat)) {
        guard let start = color.copy(alpha: a.1), let end = color.copy(alpha: b.1),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [start, end] as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: a.0), end: CGPoint(x: 0, y: b.0), options: [])
    }
    private static func radial(_ ctx: CGContext, _ color: CGColor, at centre: CGPoint, radius: CGFloat) {
        guard let clear = color.copy(alpha: 0),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color, clear] as CFArray, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }
    /// Inside a transparency layer: keeps what is drawn only as strongly as
    /// a horizontal ramp of (x, alpha) stops allows.
    private static func fade(_ ctx: CGContext, width: CGFloat, height: CGFloat, stops: [(CGFloat, Double)]) {
        let ordered = stops.filter { $0.0.isFinite }.sorted { $0.0 < $1.0 }
        guard width > 0, ordered.count > 1,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: ordered.map { NSColor.black.withAlphaComponent(CGFloat(max(0, min(1, $0.1)))).cgColor } as CFArray,
                                        locations: ordered.map { max(0, min(1, $0.0 / width)) }) else { return }
        ctx.saveGState(); ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    /// A tapered crystal needle (filled with the current fill colour).
    private static func needle(_ ctx: CGContext, from point: CGPoint, dir: CGVector, length: CGFloat, base: CGFloat) {
        let n = CGVector(dx: -dir.dy * base / 2, dy: dir.dx * base / 2)
        ctx.move(to: CGPoint(x: point.x + n.dx, y: point.y + n.dy))
        ctx.addLine(to: CGPoint(x: point.x + dir.dx * length, y: point.y + dir.dy * length))
        ctx.addLine(to: CGPoint(x: point.x - n.dx, y: point.y - n.dy))
        ctx.closePath(); ctx.fillPath()
    }
    /// A small fern of rime: a stem with two side branches (stroked).
    private static func dendrite(_ ctx: CGContext, from point: CGPoint, dir: CGVector, length: CGFloat, flip: Bool) {
        func along(_ t: CGFloat) -> CGPoint { CGPoint(x: point.x + dir.dx * length * t, y: point.y + dir.dy * length * t) }
        ctx.move(to: point); ctx.addLine(to: along(1))
        for (t, reach, side) in [(0.45 as CGFloat, 0.4 as CGFloat, flip ? 1.0 : -1.0), (0.72, 0.28, flip ? -1.0 : 1.0)] {
            let branch = rotate(dir, CGFloat(side) * 0.85), start = along(t)
            ctx.move(to: start); ctx.addLine(to: CGPoint(x: start.x + branch.dx * length * reach, y: start.y + branch.dy * length * reach))
        }
        ctx.strokePath()
    }
    /// Points around a vertical capsule with their outward normals.
    private static func capsuleOutline(_ rect: CGRect, radius: CGFloat) -> [(CGPoint, CGVector)] {
        var out: [(CGPoint, CGVector)] = []
        for (centreY, start) in [(rect.maxY - radius, 0.0), (rect.minY + radius, Double.pi)] {
            for i in 0...7 {
                let a = CGFloat(start + Double(i) / 7 * .pi)
                out.append((CGPoint(x: rect.midX + cos(a) * radius, y: centreY + sin(a) * radius), CGVector(dx: cos(a), dy: sin(a))))
            }
        }
        var y = rect.minY + radius + 2.4
        while y < rect.maxY - radius - 1 {
            out.append((CGPoint(x: rect.minX, y: y), CGVector(dx: -1, dy: 0))); out.append((CGPoint(x: rect.maxX, y: y), CGVector(dx: 1, dy: 0)))
            y += 2.4
        }
        return out
    }
}

/// The frozen sheet's geometry in channel-local points (y up): a strip of
/// jittered triangular plates between the channel's lips, the fracture
/// edges worth drawing, a few long cracks and trapped bubbles. Every element
/// carries the crystal weight at its position, so the sheet is strongest at
/// the thumb and thins out toward `Frost.crystalOnset`.
private struct IceGeometry {
    struct Plate { var points: [CGPoint]; var weight: CGFloat }
    struct Edge { var a: CGPoint; var b: CGPoint; var weight: CGFloat }
    struct Line { var points: [CGPoint]; var weight: CGFloat }
    struct Bubble { var center: CGPoint; var size: CGFloat; var weight: CGFloat }
    var plates: [Plate] = [], edges: [Edge] = [], fractures: [Line] = [], bubbles: [Bubble] = []

    init(start: CGFloat, width: CGFloat, height: CGFloat, weight weightAt: (CGFloat) -> CGFloat) {
        let noise = SliderSkin.noise
        var columns: [[CGPoint]] = []
        var x = start, k = 0
        while x < width + 5 {
            let jitter = (noise(k, 101) - 0.5) * 2.2
            columns.append([CGPoint(x: x + jitter, y: height + 0.6),
                            CGPoint(x: x + (noise(k, 103) - 0.5) * 3.2, y: height * (0.3 + 0.4 * noise(k, 107))),
                            CGPoint(x: x - jitter * 0.6, y: -0.6)])
            x += 4 + 1.6 * noise(k, 109); k += 1
        }
        func w(_ points: [CGPoint]) -> CGFloat { weightAt(points.map(\.x).reduce(0, +) / CGFloat(points.count)) }
        for i in 0..<max(0, columns.count - 1) {
            let a = columns[i], b = columns[i + 1]
            for triangle in [[a[0], a[1], b[0]], [a[1], b[1], b[0]], [a[1], a[2], b[1]], [a[2], b[2], b[1]]] {
                plates.append(Plate(points: triangle, weight: w(triangle)))
            }
            // Not every seam is a fracture, or the sheet reads as a mesh.
            for (j, pair) in [(a[0], a[1]), (a[1], a[2]), (a[1], b[0]), (a[1], b[1]), (a[2], b[1])].enumerated() where noise(i * 5 + j, 115) < 0.62 {
                let weight = w([pair.0, pair.1])
                if weight > 0.02 { edges.append(Edge(a: pair.0, b: pair.1, weight: weight)) }
            }
        }
        for i in 0..<4 {
            var px = start + (width - start) * (0.3 + 0.17 * CGFloat(i)) + (noise(i, 251) - 0.5) * 6
            var points = [CGPoint(x: px, y: height + 1)]
            for (j, y) in [height * 0.62, height * 0.3, -1].enumerated() {
                px += (noise(i * 3 + j, 253) - 0.5) * 6; points.append(CGPoint(x: px, y: y))
            }
            let weight = w(points)
            if weight > 0.05 { fractures.append(Line(points: points, weight: weight)) }
        }
        for i in 0..<16 {
            let p = CGPoint(x: start + (width - start) * noise(i, 257), y: 1.5 + (height - 3) * noise(i, 259))
            let weight = weightAt(p.x)
            if weight > 0.05 { bubbles.append(Bubble(center: p, size: 0.45 + 0.4 * noise(i, 263), weight: weight)) }
        }
    }
}
