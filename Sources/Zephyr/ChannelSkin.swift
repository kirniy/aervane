import AppKit
import QuartzCore

/// The Cooling Channel (default style): a thick glass cryo tube on the
/// panel, filled with coolant light, with an etched scale and a sculpted
/// knob that stands proud of it.
///
/// One energy curve (`SliderEnergy`) drives everything progressive along the
/// tube: the coolant cools from mint through glacier cyan toward ice and
/// thickens; cold sparks multiply and brighten; a cold aura spreads around
/// the filled glass; a white-hot head gathers at the knob. A row of
/// miniature rotors rides in the coolant and turns in proportion to the fan's
/// *actual* RPM (`RotorMotion`), faint etched rotors waiting in the empty
/// glass. From ~45% rime grows on the glass and frost fog clouds the
/// coolant. At 100% the *whole* tube freezes (`IceCover`) into smooth milky
/// ice that keeps flowing (`IceFlow`): cold currents and fine streaks drift
/// from the knob toward the floor and crystal glints twinkle, while the
/// panel shows it. Reaching 100% crawls the ice in from the knob with a
/// glint running out and back, a soft frost halo grows on the glass, the
/// knob frosts over, a bloom of cold light and a breath of cold air rise.
/// Lowering the value melts it: the front recedes, the ice clears and a
/// little steam lifts.
///
/// The knob squashes when grabbed, leans and stretches with drag speed and
/// springs back on release; sparks slosh against fast moves; a moving knob
/// leaves a wake; grabs, releases and preset stops ripple. Transient
/// reactions are finite Core Animations; the rotors and the full-cooling
/// flow are the only repeating motion (bounded compositor loops) and freeze
/// in place whenever the control stops them. Artwork is cached per
/// size, scale, appearance and floor.
@MainActor final class ChannelSkin: SliderSkin {
    /// Resolved ice tones for the knob's core (set with the artwork).
    private var palette = Palette()
    /// Miniature rotors in the coolant, spinning with the measured fan speed.
    private let rotorField = RotorField()

    // Tube and coolant.
    private let aura = CALayer(), auraMask = CAGradientLayer()
    private let well = CALayer()
    private let coolant = CALayer(), fillMask = CALayer()
    private let sparks = CALayer(), head = CALayer(), headMask = CAGradientLayer()
    private let haze = CALayer(), hazeMask = CALayer()
    private let frost = CALayer(), frostMask = CALayer()
    private let glass = CALayer()
    // The full-cooling ice.
    private let crown = CALayer(), crownMask = CAGradientLayer(), sheet = CALayer(), fringe = CALayer()
    private let crownGlint = CALayer(), glintMask = CAGradientLayer()
    // The ice's continuous flow at full cooling: cold currents and streaks
    // drifting along the tube and two alternating sets of twinkles, clipped
    // to the tube and revealed with the ice.
    private let flowClip = CALayer(), flowShape = CAShapeLayer()
    private let streamWide = CALayer(), streamFine = CALayer(), twinkleA = CALayer(), twinkleB = CALayer()
    private let loops = LoopSet()
    // Marks and transient reactions.
    private let measuredMark = CALayer()
    private let wake = CAGradientLayer(), halo = CAGradientLayer(), rippleRing = CAShapeLayer(), vapor = CALayer(), burst = CALayer()
    // The knob: `thumb` carries position and the press shape, `tilt` the
    // speed reactions, so the two never fight over one transform.
    private let thumb = CALayer(), tilt = CALayer(), thumbBody = CALayer(), thumbCore = CALayer(), thumbGloss = CALayer(), thumbFrost = CALayer()

    private enum Metric {
        static let grabSlop: CGFloat = 16         // pick the knob up without a jump
        static let glide: CFTimeInterval = 0.2
        static let aura: CGFloat = 12             // cold glow room around the tube
        static let auraFade: CGFloat = 30         // the glow dies away past the knob over this length
        static let frostFringe: CGFloat = 8       // rime room above and below the tube
        static let crownFringe: CGFloat = 11      // rime crust room around the tube
        static let thumbPad: CGFloat = 6          // shadow and frost room around the knob
        static let slosh: CGFloat = 8             // coolant travel against a fast drag
        /// Flow tiles: each stream's artwork repeats every period, and one
        /// period passes per loop (cold drifts from the knob toward the floor).
        static let widePeriod: CGFloat = 104, wideLoop: CFTimeInterval = 4.0
        static let finePeriod: CGFloat = 60, fineLoop: CFTimeInterval = 1.25
        static let glintBand: CGFloat = 34
        static let head: CGFloat = 150
        static let burst = CGSize(width: 116, height: 76)
        static let vapor = CGSize(width: 150, height: 72)
        /// Freezing front: crawls the whole tube from the knob, in spurts.
        static let form: CFTimeInterval = 1.1
        /// Front, then the glint's return to the knob, which freezes it.
        static let formation: CFTimeInterval = 1.8
        /// The front recedes back to the knob end while the ice clears.
        static let melt: CFTimeInterval = 0.7
        static let frostMelt: CFTimeInterval = 0.55
        static let wakeFade: CFTimeInterval = 0.45
    }

    private struct Palette {
        var low: [CGFloat] = [0.56, 0.86, 0.76], mid: [CGFloat] = [0.42, 0.84, 0.96], top: [CGFloat] = [0.86, 0.98, 1]
        var dark = true
        func color(_ percent: Double, alpha: Double) -> CGColor {
            let w = SliderEnergy.tone(percent: percent)
            let c = (0..<3).map { low[$0] * CGFloat(w.low) + mid[$0] * CGFloat(w.mid) + top[$0] * CGFloat(w.high) }
            return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: CGFloat(alpha))
        }
        /// The knob's window stays saturated so it reads on the white glass.
        func core(_ percent: Double) -> CGColor { color(dark ? percent * 0.8 : percent, alpha: 1) }
    }

    init(host: PercentSlider) {
        super.init(host: host, style: .channel)
        // The glow has no edge of its own: a fixed-length fade that slides with
        // the knob (by position, so it never stretches), starting under it.
        aura.mask = auraMask
        auraMask.startPoint = CGPoint(x: 0, y: 0.5); auraMask.endPoint = CGPoint(x: 1, y: 0.5)
        auraMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        auraMask.anchorPoint = CGPoint(x: 1, y: 0.5)
        for mask in [fillMask, hazeMask, frostMask] { mask.backgroundColor = NSColor.black.cgColor; mask.anchorPoint = CGPoint(x: 0, y: 0.5) }
        coolant.mask = fillMask
        // The head is a horizontal light falloff that peaks just behind the
        // knob; it lives inside the coolant so it can never light the tube
        // ahead of the value.
        head.mask = headMask
        headMask.startPoint = CGPoint(x: 0, y: 0.5); headMask.endPoint = CGPoint(x: 1, y: 0.5)
        headMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        headMask.locations = [0, 0.86, 1]; headMask.anchorPoint = CGPoint(x: 0.86, y: 0.5)
        // Rotors ride in the coolant, so they show only where it has reached.
        coolant.addSublayer(sparks); coolant.addSublayer(rotorField.container); coolant.addSublayer(head)
        rotors = rotorField
        haze.mask = hazeMask
        frost.mask = frostMask
        // The ice reveals from the knob end leftward as it forms.
        crown.mask = crownMask
        crownMask.startPoint = CGPoint(x: 1, y: 0.5); crownMask.endPoint = CGPoint(x: 0, y: 0.5)
        crownMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        crownMask.locations = [0, 1, 1]
        crown.addSublayer(sheet); crown.addSublayer(flowClip); crown.addSublayer(fringe)
        flowClip.mask = flowShape; flowShape.fillColor = NSColor.black.cgColor
        for layer in [streamWide, streamFine, twinkleA, twinkleB] { flowClip.addSublayer(layer); layer.anchorPoint = .zero }
        twinkleA.opacity = 0.2; twinkleB.opacity = 0.2
        loops.scroll(streamWide, period: Metric.widePeriod, duration: Metric.wideLoop)
        loops.scroll(streamFine, period: Metric.finePeriod, duration: Metric.fineLoop)
        loops.breathe(twinkleA, amount: 0.8, duration: 2.3, phase: 0)
        loops.breathe(twinkleB, amount: 0.8, duration: 3.1, phase: 0.5)
        // The glint is the ice's edges in white, seen through a narrow band.
        crownGlint.mask = glintMask
        glintMask.startPoint = CGPoint(x: 0, y: 0.5); glintMask.endPoint = CGPoint(x: 1, y: 0.5)
        glintMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        glintMask.locations = [0, 0.5, 1]
        halo.type = .radial; halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        rippleRing.fillColor = nil; rippleRing.lineWidth = 1.5
        wake.masksToBounds = true
        tilt.addSublayer(thumbBody); tilt.addSublayer(thumbCore); tilt.addSublayer(thumbGloss); tilt.addSublayer(thumbFrost)
        thumb.addSublayer(tilt)
        for layer in [aura, sparks, head, haze, frost, crown, crownGlint, measuredMark, wake, halo, rippleRing, vapor, burst, thumbFrost] { layer.opacity = 0 }
        for layer in [aura, well, coolant, sparks, head, haze, frost, glass, sheet, fringe, crownGlint, vapor, burst, thumbBody, thumbGloss, thumbFrost,
                      streamWide, streamFine, twinkleA, twinkleB] { layer.contentsGravity = .resize }
    }
    override var flow: LoopSet? { loops }

    override var layers: [CALayer] { [aura, well, coolant, haze, frost, glass, crown, crownGlint, measuredMark, wake, halo, rippleRing, vapor, burst, thumb] }
    override var allLayers: [CALayer] {
        [aura, auraMask, well, coolant, fillMask, rotorField.container, sparks, head, headMask, haze, hazeMask, frost, frostMask, glass,
         crown, crownMask, sheet, flowClip, fringe, crownGlint, glintMask, measuredMark, wake, halo, rippleRing, vapor, burst,
         thumb, tilt, thumbBody, thumbCore, thumbGloss, thumbFrost]
    }
    override var thumbSize: CGSize { SliderGeometry.thumb }
    override var grabSlop: CGFloat { Metric.grabSlop }
    override func focusRing() -> NSBezierPath {
        let ring = channelRect.insetBy(dx: -4, dy: -6)
        return NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2)
    }
    private var channelRect: NSRect { SliderGeometry.channel(in: bounds) }
    /// The coolant's own rounded body, inside the glass wall (channel-local).
    private var innerHeight: CGFloat { SliderGeometry.channelHeight - 2 * SliderGeometry.wall }

    // MARK: Artwork (rendered once per geometry/appearance)

    @discardableResult override func render(scale: CGFloat) -> Bool {
        guard bounds.width > 4 * SliderGeometry.inset, bounds.height > 0 else { return false }
        renderedScale = scale
        let channel = channelRect, W = channel.width, H = channel.height, wall = SliderGeometry.wall, floorValue = minimumPercent
        let A = Metric.aura, F = Metric.frostFringe, C = Metric.crownFringe, pad = Metric.thumbPad
        let inner = CGRect(x: wall, y: wall, width: W - 2 * wall, height: H - 2 * wall)
        let knob = SliderGeometry.thumb
        let width = bounds.width
        /// Channel-local x of a value, and the value at a channel-local x.
        func px(_ p: Double) -> CGFloat { SliderGeometry.x(percent: p, width: width) - channel.minX }
        func pct(_ x: CGFloat) -> Double { SliderGeometry.percent(atX: x + channel.minX, width: width) }
        func energy(_ x: CGFloat) -> CGFloat { CGFloat(SliderEnergy.level(percent: pct(x))) }
        // Full-cooling ice covers the whole track (`IceCover`), thickest at the knob end.
        func crystal(_ x: CGFloat) -> CGFloat { CGFloat(IceCover.weight(at: Double(x / max(1, W)))) }
        let floorX = floorValue > 0 ? px(floorValue) : 0
        let energyRamp: [(CGFloat, Double)] = stride(from: 0.0, through: 100, by: 5).map { (px($0), SliderEnergy.level(percent: $0)) }
        let crystalRamp: [(CGFloat, Double)] = stride(from: 0.0, through: 1.0, by: 0.05).map { (CGFloat($0) * W, IceCover.weight(at: $0)) }
        let rotorCenters = SliderGeometry.rotorCenters(channelWidth: W), rotorDiameter = SliderGeometry.rotorDiameter
        var rotorArt: CGImage?
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
            // On dark glass the coolant stops short of white so ice, the knob
            // and white light still read on top of it.
            let top = dark ? (mid.blended(withFraction: 0.6, of: high) ?? high) : high
            self.palette = Palette(low: rgb(low), mid: rgb(mid), top: rgb(top), dark: dark)
            let palette = self.palette
            let rime = (Theme.rime.usingColorSpace(.sRGB) ?? Theme.rime).cgColor
            let white = NSColor.white.cgColor, black = NSColor.black.cgColor
            let crack = dark ? CGColor(srgbRed: 0.05, green: 0.36, blue: 0.5, alpha: 1) : CGColor(srgbRed: 0, green: 0.17, blue: 0.34, alpha: 1)
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            let ink = dark ? NSColor.white : NSColor.black

            // Miniature rotors: one cached image for the whole row in the
            // coolant, and a faint etched twin waiting in the empty glass.
            rotorArt = RotorField.rotorImage(diameter: rotorDiameter, scale: scale, blades: 5,
                                             blade: NSColor.white.withAlphaComponent(dark ? 0.46 : 0.6).cgColor,
                                             edge: crack.copy(alpha: dark ? 0.55 : 0.45) ?? crack,
                                             hub: NSColor.white.withAlphaComponent(0.92).cgColor)
            let etched = RotorField.rotorImage(diameter: rotorDiameter, scale: scale, blades: 5,
                                               blade: ink.withAlphaComponent(0.04).cgColor,
                                               edge: ink.withAlphaComponent(dark ? 0.16 : 0.13).cgColor,
                                               hub: ink.withAlphaComponent(0.08).cgColor)

            // Cold aura: a soft glow around the glass in the coolant's colour,
            // revealed with the fill and scaled by energy.
            self.aura.contents = Self.bitmap(CGSize(width: W + 2 * A, height: H + 2 * A), scale: scale) { ctx in
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                for k in stride(from: A, through: 0, by: -1) {
                    let t = 1 - k / A
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.05 + 0.1 * t * t).cgColor)
                    ctx.addPath(Self.capsule(CGRect(x: A - k, y: A - k, width: W + 2 * k, height: H + 2 * k))); ctx.fillPath()
                }
                let stops = stride(from: 0.0, through: 100, by: 5).map { (px($0) + A, palette.color($0, alpha: 1)) }
                if let gradient = CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 / (W + 2 * A) }) {
                    ctx.setBlendMode(.sourceIn)
                    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: W + 2 * A, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    ctx.setBlendMode(.normal)
                }
                Self.fade(ctx, width: W + 2 * A, height: H + 2 * A, stops: energyRamp.map { ($0.0 + A, 0.2 + 0.8 * $0.1) })
                ctx.endTransparencyLayer()
            }

            // The tube's interior: tinted glass, deeper under the upper wall,
            // catching light along the bottom, with a soft contact shadow.
            self.well.contents = Self.bitmap(CGSize(width: W + 8, height: H + 8), scale: scale) { ctx in
                let r = CGRect(x: 4, y: 4, width: W, height: H)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 4 * scale, color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.2).cgColor)
                ctx.addPath(Self.capsule(r)); ctx.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.42 : 0.1).cgColor); ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState(); ctx.addPath(Self.capsule(r)); ctx.clip()
                Self.vertical(ctx, black, from: (r.maxY, dark ? 0.55 : 0.2), to: (r.maxY - H * 0.5, 0))
                Self.vertical(ctx, white, from: (r.minY, dark ? 0.07 : 0.4), to: (r.minY + H * 0.3, 0))
                ctx.restoreGState()
                if let etched {
                    for c in rotorCenters {
                        ctx.draw(etched, in: CGRect(x: 4 + c.x - rotorDiameter / 2, y: 4 + c.y - rotorDiameter / 2, width: rotorDiameter, height: rotorDiameter))
                    }
                }
            }

            // Coolant: the held floor zone, then the cooling ramp, shaded like
            // liquid in a cylinder: a bright meniscus, a deep belly.
            self.coolant.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                ctx.addPath(Self.capsule(inner)); ctx.clip()
                if floorX > 0 {
                    ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: floorX, height: H))
                    ctx.setFillColor(palette.color(0, alpha: dark ? 0.38 : 0.3)); ctx.fill(CGRect(x: 0, y: 0, width: floorX, height: H))
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(dark ? 0.16 : 0.42).cgColor); ctx.setLineWidth(0.8)
                    var x = -H
                    while x < floorX { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x + H, y: H)); x += 4.5 }
                    ctx.strokePath(); ctx.restoreGState()
                }
                var stops = Array(stride(from: min(97.5, max(0, floorValue)), through: 100, by: 2.5))
                if stops.last != 100 { stops.append(100) }
                let colors = stops.map { palette.color($0, alpha: SliderEnergy.coolant(percent: $0)) }
                let locations = stops.map { min(1, max(0, px($0) / W)) }
                if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) {
                    ctx.saveGState(); ctx.clip(to: CGRect(x: floorX, y: 0, width: W - floorX, height: H))
                    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: W, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    ctx.restoreGState()
                }
                Self.vertical(ctx, white, from: (inner.maxY, 0.45), to: (inner.maxY - inner.height * 0.5, 0))
                Self.vertical(ctx, black, from: (inner.minY, dark ? 0.32 : 0.22), to: (inner.minY + inner.height * 0.4, 0))
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.8); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: inner.minX + inner.height / 2, y: inner.maxY - 2)); ctx.addLine(to: CGPoint(x: inner.maxX - inner.height / 2, y: inner.maxY - 2)); ctx.strokePath()
            }

            // Cold sparks: fine bright points, sparse at the floor, crowding
            // and catching four-point glints toward full cooling.
            self.sparks.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                ctx.addPath(Self.capsule(inner)); ctx.clip()
                for i in 0..<240 {
                    let x = max(floorX, inner.minX) + (inner.maxX - max(floorX, inner.minX)) * Self.noise(i, 321)
                    let e = energy(x)
                    guard Self.noise(i, 323) < 0.15 + 0.85 * pow(e, 0.7) else { continue }
                    let y = inner.minY + 1.5 + (inner.height - 3) * Self.noise(i, 327)
                    let size = 0.6 + 1.1 * Self.noise(i, 329) * (0.5 + 0.5 * e)
                    let alpha = (0.25 + 0.75 * e) * (0.4 + 0.6 * Self.noise(i, 331))
                    ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
                    if size > 1.25, e > 0.35 {
                        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha * 0.7).cgColor); ctx.setLineWidth(0.4)
                        let r = size * 1.8
                        ctx.move(to: CGPoint(x: x - r, y: y)); ctx.addLine(to: CGPoint(x: x + r, y: y))
                        ctx.move(to: CGPoint(x: x, y: y - r)); ctx.addLine(to: CGPoint(x: x, y: y + r)); ctx.strokePath()
                    }
                }
            }
            // The head: a white-hot core along the lanes, faded by energy.
            let lanes: [CGFloat] = [0.14, 0.27, 0.4, 0.53, 0.66, 0.79, 0.9]
            self.head.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                ctx.addPath(Self.capsule(inner)); ctx.clip()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setLineCap(.round); ctx.setLineWidth(0.9)
                for lane in lanes {
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                    let y = inner.minY + inner.height * lane
                    ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); ctx.strokePath()
                }
                Self.vertical(ctx, white, from: (H / 2, 0.55), to: (H * 0.85, 0))
                Self.vertical(ctx, white, from: (H / 2, 0.55), to: (H * 0.15, 0))
                Self.fade(ctx, width: W, height: H, stops: energyRamp.map { ($0.0, pow($0.1, 0.6)) })
                ctx.endTransparencyLayer()
            }

            // Frost fog: soft white cloud in the coolant toward the top of the
            // range, thickest under the upper wall.
            self.haze.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                ctx.addPath(Self.capsule(inner)); ctx.clip()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                for i in 0..<70 {
                    let x = px(Frost.onset) + (inner.maxX - px(Frost.onset)) * Self.noise(i, 341)
                    let edge = Self.noise(i, 343) < 0.65
                    let y = edge ? (Self.noise(i, 347) < 0.6 ? inner.maxY - 2 : inner.minY + 2) : inner.minY + inner.height * Self.noise(i, 349)
                    let radius = 3 + 6 * Self.noise(i, 353)
                    Self.radial(ctx, NSColor.white.withAlphaComponent(0.3 + 0.3 * Self.noise(i, 359)).cgColor, at: CGPoint(x: x, y: y), radius: radius)
                }
                Self.vertical(ctx, white, from: (inner.maxY, 0.35), to: (inner.maxY - inner.height * 0.45, 0))
                Self.fade(ctx, width: W, height: H, stops: stride(from: Frost.onset, through: 100, by: 2.5).map { (px($0), Frost.amount(percent: $0)) } + [(px(Frost.onset) - 1, 0)])
                ctx.endTransparencyLayer()
            }

            // Rime: from the frost onset, dendrites grow inward from both glass
            // walls and grains with small needles cling outside the tube.
            // Thicker and reaching further toward full cooling.
            self.frost.contents = Self.bitmap(CGSize(width: W, height: H + 2 * F), scale: scale) { ctx in
                ctx.setLineCap(.round)
                let innerPath = Self.capsule(inner.offsetBy(dx: 0, dy: F))
                for c in 0..<Int(W) {
                    let x = CGFloat(c) + 0.5, p = pct(x), w = CGFloat(Frost.amount(percent: p))
                    guard w > 0.02, p >= floorValue else { continue }
                    for side in 0..<2 {
                        let up = side == 0, inward: CGFloat = up ? -1 : 1
                        let edge = up ? F + inner.maxY : F + inner.minY
                        ctx.saveGState(); ctx.addPath(innerPath); ctx.clip()
                        let grains = Int((w * 2.4 * (0.4 + Self.noise(c, 151 + side))).rounded(.down))
                        for k in 0..<grains {
                            let seed = c * 7 + k
                            let d = pow(Self.noise(seed, 157 + side), 1.6) * (0.6 + inner.height * 0.4 * w)
                            let size = (1.1 - 0.4 * d / (inner.height / 2)) * (0.7 + 0.3 * Self.noise(seed, 163 + side))
                            let cx = x + (Self.noise(seed, 167 + side) - 0.5) * 1.6, cy = edge + inward * d
                            ctx.setFillColor(NSColor.white.withAlphaComponent((0.22 + 0.6 * w) * max(0.2, 1 - 0.6 * d / (inner.height / 2))).cgColor)
                            ctx.fillEllipse(in: CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
                        }
                        if c % 3 == 0, w > 0.15, Self.noise(c, 173 + side) < w * 0.65 {
                            let length = (1.5 + inner.height * 0.48 * w) * (0.5 + 0.5 * Self.noise(c, 179 + side))
                            let dir = Self.rotate(CGVector(dx: 0, dy: inward), (Self.noise(c, 181 + side) - 0.5) * 0.8)
                            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4 + 0.45 * w).cgColor); ctx.setLineWidth(0.6)
                            Self.dendrite(ctx, from: CGPoint(x: x, y: edge), dir: dir, length: length, flip: Self.noise(c, 183 + side) < 0.5)
                        }
                        ctx.restoreGState()
                        // Outside the glass, in rime.
                        guard c % 2 == 0 else { continue }
                        let outer = up ? F + H + 0.5 : F - 0.5, reach = F - 1
                        ctx.setFillColor(rime)
                        for k in 0..<Frost.grains(amount: Double(w), noise: Double(Self.noise(c, 41 + side))) {
                            let seed = c * 7 + k
                            let d = pow(Self.noise(seed, 53 + side), 1.7) * (1.2 + (reach - 1.2) * w)
                            let size = (1.0 - 0.4 * d / reach) * (0.75 + 0.25 * Self.noise(seed, 61 + side))
                            let cx = x + (Self.noise(seed, 59 + side) - 0.5) * 2.4, cy = outer - inward * d
                            ctx.setAlpha((0.25 + 0.6 * w) * (1 - 0.55 * d / reach))
                            ctx.fillEllipse(in: CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
                        }
                        ctx.setAlpha(1)
                    }
                }
            }

            // The glass shell, in front of the coolant: a crisp rim, a long
            // specular band and a hot spot, a refraction line along the bottom,
            // the etched scale and the hardware-floor mark.
            self.glass.contents = Self.bitmap(CGSize(width: W + 8, height: H + 8), scale: scale) { ctx in
                let r = CGRect(x: 4, y: 4, width: W, height: H)
                let hair = 1 / scale
                ctx.addPath(Self.capsule(r.insetBy(dx: 0.25, dy: 0.25))); ctx.setLineWidth(0.5)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.6 : 0.22).cgColor); ctx.strokePath()
                ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: r.midY, width: W + 8, height: H))
                ctx.addPath(Self.capsule(r.insetBy(dx: 0.9, dy: 0.9))); ctx.setLineWidth(0.8)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(dark ? 0.32 : 0.85).cgColor); ctx.strokePath()
                ctx.restoreGState()
                let band = CGRect(x: r.minX + H * 0.5, y: r.maxY - 3.5 - H * 0.24, width: W - H, height: H * 0.24)
                ctx.saveGState(); ctx.addPath(Self.capsule(band)); ctx.clip()
                Self.vertical(ctx, white, from: (band.maxY, dark ? 0.34 : 0.7), to: (band.minY, 0))
                ctx.restoreGState()
                Self.radial(ctx, NSColor.white.withAlphaComponent(dark ? 0.4 : 0.7).cgColor, at: CGPoint(x: r.minX + H * 0.75, y: r.maxY - 6), radius: 7)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(dark ? 0.18 : 0.45).cgColor); ctx.setLineWidth(0.6); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: r.minX + H / 2, y: r.minY + 2.2)); ctx.addLine(to: CGPoint(x: r.maxX - H / 2, y: r.minY + 2.2)); ctx.strokePath()
                // Scale, etched into the lower wall. Pixel-aligned so it stays
                // crisp at 1×.
                ctx.setLineCap(.butt); ctx.setLineWidth(max(hair, 0.75))
                for tick in SliderGeometry.ticks {
                    let x = ((4 + px(tick)) * scale).rounded() / scale + hair / 2
                    let length: CGFloat = tick == 50 ? 6 : 3.5
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(dark ? 0.32 : 0.6).cgColor)
                    ctx.move(to: CGPoint(x: x, y: r.minY + 3)); ctx.addLine(to: CGPoint(x: x, y: r.minY + 3 + length)); ctx.strokePath()
                    ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.35 : 0.18).cgColor)
                    ctx.move(to: CGPoint(x: x + hair, y: r.minY + 3)); ctx.addLine(to: CGPoint(x: x + hair, y: r.minY + 3 + length)); ctx.strokePath()
                }
                if floorValue > 0 {
                    let x = ((4 + floorX) * scale).rounded() / scale + hair / 2
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(dark ? 0.45 : 0.75).cgColor); ctx.setLineWidth(max(hair, 1))
                    ctx.move(to: CGPoint(x: x, y: r.minY + 2)); ctx.addLine(to: CGPoint(x: x, y: r.maxY - 2)); ctx.strokePath()
                }
            }

            // The ice: at full cooling the *whole* tube freezes (`IceCover`)
            // into smooth, milky frosted ice: a dense translucent body that is
            // thickest against both glass walls, soft clouds of accumulated
            // frost and a soft sheen, with the tube's rim redrawn crisp on top.
            // No cracks, mesh or needles: the life of the ice is its flow (the
            // layers below), not scratched texture. The centre stays a little
            // clearer, so the rotors still turn underneath. Coverage scales the
            // body as opacity; a clear seam keeps the floor mark readable.
            let current = dark ? NSColor.white : (mid.blended(withFraction: 0.25, of: .white) ?? mid)
            let haloTone = dark ? rime : ((Theme.rime.usingColorSpace(.sRGB) ?? Theme.rime).blended(withFraction: 0.4, of: .white) ?? Theme.rime).cgColor
            self.sheet.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                let tube = CGRect(x: 0, y: 0, width: W, height: H)
                ctx.addPath(Self.capsule(tube)); ctx.clip()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setFillColor(NSColor.white.withAlphaComponent(dark ? 0.32 : 0.4).cgColor); ctx.fill(tube)
                Self.vertical(ctx, white, from: (H, dark ? 0.55 : 0.6), to: (H * 0.48, 0))
                Self.vertical(ctx, white, from: (0, dark ? 0.4 : 0.48), to: (H * 0.44, 0))
                for i in 0..<Int(W / 6) {
                    let walled = Self.noise(i, 401) < 0.7
                    let y = walled ? (Self.noise(i, 403) < 0.55 ? H - wall - 1 : wall + 1) + (Self.noise(i, 409) - 0.5) * 4 : H * (0.3 + 0.4 * Self.noise(i, 411))
                    Self.radial(ctx, NSColor.white.withAlphaComponent(0.12 + 0.18 * Self.noise(i, 405)).cgColor,
                                at: CGPoint(x: W * Self.noise(i, 413), y: y), radius: 4 + 9 * Self.noise(i, 407))
                }
                // Thickness: a cold shade under the upper wall, a sheen above it.
                Self.vertical(ctx, crack, from: (H - wall, dark ? 0.16 : 0.1), to: (H - wall - 4, 0))
                let sheen = CGRect(x: H * 0.5, y: H - wall - H * 0.26, width: W - H, height: H * 0.18)
                ctx.saveGState(); ctx.addPath(Self.capsule(sheen)); ctx.clip()
                Self.vertical(ctx, white, from: (sheen.maxY, dark ? 0.35 : 0.5), to: (sheen.minY, 0))
                ctx.restoreGState()
                Self.fade(ctx, width: W, height: H, stops: crystalRamp)
                ctx.endTransparencyLayer()
                ctx.addPath(Self.capsule(tube.insetBy(dx: 0.25, dy: 0.25))); ctx.setLineWidth(0.5)
                ctx.setStrokeColor(crack.copy(alpha: dark ? 0.5 : 0.3) ?? crack); ctx.strokePath()
                ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: H / 2, width: W, height: H / 2))
                ctx.addPath(Self.capsule(tube.insetBy(dx: 0.9, dy: 0.9))); ctx.setLineWidth(0.7)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor); ctx.strokePath()
                ctx.restoreGState()
                if floorValue > 0 {
                    ctx.setBlendMode(.destinationOut); ctx.setFillColor(NSColor.black.withAlphaComponent(0.9).cgColor)
                    ctx.fill(CGRect(x: floorX - 1, y: 0, width: 2, height: H)); ctx.setBlendMode(.normal)
                }
            }
            // Cold currents: soft elongated mist drifting along the tube, with
            // one soft pulse of light per tile. Tileable every `widePeriod`.
            let lo = wall + 1.5, hi = H - wall - 1.5
            self.streamWide.contents = Self.bitmap(CGSize(width: W + 2 * Metric.widePeriod, height: H), scale: scale) { ctx in
                Self.tiled(width: W + 2 * Metric.widePeriod, period: Metric.widePeriod) { dx in
                    for i in 0..<5 {
                        let x = dx + Metric.widePeriod * Self.noise(i, 421), y = lo + (hi - lo) * Self.noise(i, 423)
                        Self.streak(ctx, current.withAlphaComponent((dark ? 0.16 : 0.14) + 0.16 * Self.noise(i, 425)).cgColor,
                                    at: CGPoint(x: x, y: y), length: 28 + 34 * Self.noise(i, 427), thickness: 3 + 4 * Self.noise(i, 429))
                    }
                    Self.streak(ctx, NSColor.white.withAlphaComponent(dark ? 0.32 : 0.45).cgColor,
                                at: CGPoint(x: dx + Metric.widePeriod * 0.5, y: H / 2), length: 18, thickness: H * 0.8)
                }
            }
            // Fine streaks: thin, quick glints of cold riding the current.
            self.streamFine.contents = Self.bitmap(CGSize(width: W + 2 * Metric.finePeriod, height: H), scale: scale) { ctx in
                Self.tiled(width: W + 2 * Metric.finePeriod, period: Metric.finePeriod) { dx in
                    for i in 0..<5 {
                        let x = dx + Metric.finePeriod * Self.noise(i, 431), y = lo + (hi - lo) * Self.noise(i, 433)
                        if !dark {
                            Self.streak(ctx, mid.withAlphaComponent(0.22).cgColor, at: CGPoint(x: x, y: y - 0.5), length: 10 + 14 * Self.noise(i, 435), thickness: 1.4)
                        }
                        Self.streak(ctx, NSColor.white.withAlphaComponent(0.55 + 0.35 * Self.noise(i, 437)).cgColor,
                                    at: CGPoint(x: x, y: y), length: 10 + 14 * Self.noise(i, 435), thickness: 1 + 0.6 * Self.noise(i, 439))
                    }
                }
            }
            // Twinkles: two sparse sets of crystal glints that breathe out of
            // phase, so the ice glitters rather than blinks.
            for (layer, salt) in [(self.twinkleA, 0), (self.twinkleB, 1)] {
                layer.contents = Self.bitmap(CGSize(width: W, height: H), scale: scale) { ctx in
                    ctx.addPath(Self.capsule(CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: wall, dy: wall))); ctx.clip()
                    ctx.setLineCap(.round)
                    for i in 0..<Int(W / 20) {
                        let seed = i * 2 + salt
                        let p = CGPoint(x: H / 2 + (W - H) * Self.noise(seed, 441), y: lo + (hi - lo) * Self.noise(seed, 443))
                        let size = 0.7 + 0.8 * Self.noise(seed, 445), arm = size * (1.2 + 0.8 * Self.noise(seed, 447))
                        ctx.setStrokeColor((dark ? NSColor.white : mid).withAlphaComponent(dark ? 0.75 : 0.4).cgColor); ctx.setLineWidth(0.4)
                        ctx.move(to: CGPoint(x: p.x - arm, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y))
                        ctx.move(to: CGPoint(x: p.x, y: p.y - arm)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm)); ctx.strokePath()
                        ctx.setFillColor(NSColor.white.cgColor)
                        ctx.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                    }
                }
            }
            // A soft frost halo hugging the outside of the glass (no needles).
            @MainActor func rims(_ ctx: CGContext, color: CGColor, alpha: CGFloat, glow: Bool) {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                if glow { ctx.setShadow(offset: .zero, blur: 5 * scale, color: color.copy(alpha: 0.7 * alpha) ?? color) }
                ctx.addPath(Self.capsule(CGRect(x: 0, y: C, width: W, height: H).insetBy(dx: -0.4, dy: -0.4)))
                ctx.setStrokeColor(color.copy(alpha: alpha) ?? color); ctx.setLineWidth(glow ? 1.2 : 0.8); ctx.strokePath()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                Self.fade(ctx, width: W, height: H + 2 * C, stops: crystalRamp)
                ctx.endTransparencyLayer()
            }
            self.fringe.contents = Self.bitmap(CGSize(width: W, height: H + 2 * C), scale: scale) { ctx in
                rims(ctx, color: haloTone, alpha: 0.55, glow: true)
            }
            // The glint: the ice's body as a bar of white light (formation).
            self.crownGlint.contents = Self.bitmap(CGSize(width: W, height: H + 2 * C), scale: scale) { ctx in
                ctx.saveGState(); ctx.addPath(Self.capsule(CGRect(x: 0, y: C, width: W, height: H))); ctx.clip()
                Self.vertical(ctx, white, from: (C + H, 0.95), to: (C, 0.35))
                ctx.restoreGState()
                rims(ctx, color: white, alpha: 1, glow: false)
            }

            // Burst: a soft bloom of cold light at the knob when a person
            // reaches full cooling.
            self.burst.contents = Self.bitmap(Metric.burst, scale: scale) { ctx in
                // A soft bloom of cold light and glints (no needles).
                let centre = CGPoint(x: Metric.burst.width / 2, y: Metric.burst.height / 2)
                Self.streak(ctx, NSColor.white.withAlphaComponent(dark ? 0.5 : 0.7).cgColor, at: centre, length: Metric.burst.width * 0.8, thickness: Metric.burst.height * 0.45)
                ctx.setLineCap(.round); ctx.setLineWidth(0.6)
                for i in 0..<16 {
                    let angle = Self.noise(i, 223) * 2 * .pi, reach: CGFloat = 12 + 22 * Self.noise(i, 227), size: CGFloat = 0.9 + 1.0 * Self.noise(i, 229)
                    let p = CGPoint(x: centre.x + cos(angle) * reach * 1.4, y: centre.y + sin(angle) * reach * 0.75)
                    let tone = (dark ? NSColor.white : mid).withAlphaComponent(0.45 + 0.5 * Self.noise(i, 231)).cgColor
                    ctx.setFillColor(tone); ctx.setStrokeColor(tone)
                    ctx.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                    if i % 4 == 0 {
                        let arm = size * 2.2
                        ctx.move(to: CGPoint(x: p.x - arm, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y))
                        ctx.move(to: CGPoint(x: p.x, y: p.y - arm)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm)); ctx.strokePath()
                    }
                }
            }
            // Vapor: a soft breath of cold air (or steam when ice melts).
            self.vapor.contents = Self.bitmap(Metric.vapor, scale: scale) { ctx in
                let tone = dark ? NSColor.white : (NSColor.white.blended(withFraction: 0.35, of: mid) ?? .white)
                for i in 0..<16 {
                    let x = Metric.vapor.width * (0.22 + 0.56 * Self.noise(i, 371)), y = Metric.vapor.height * (0.3 + 0.4 * Self.noise(i, 373))
                    Self.radial(ctx, tone.withAlphaComponent(0.22 + 0.2 * Self.noise(i, 379)).cgColor, at: CGPoint(x: x, y: y), radius: 10 + 16 * Self.noise(i, 383))
                }
            }

            // The knob: sculpted glass. White body cooling toward the foot, a
            // specular crest, a refracted glow at the base, a bevel, grip
            // ridges, and a recessed window onto the coolant.
            let puck = CGRect(x: pad, y: pad, width: knob.width, height: knob.height)
            let body = CGSize(width: knob.width + 2 * pad, height: knob.height + 2 * pad)
            let slot = CGRect(x: puck.midX - 4, y: puck.midY - 11, width: 8, height: 22)
            self.thumbBody.contents = Self.bitmap(body, scale: scale) { ctx in
                let path = Self.capsule(puck)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 5 * scale, color: NSColor.black.withAlphaComponent(dark ? 0.6 : 0.32).cgColor)
                ctx.addPath(path); ctx.setFillColor(white); ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState(); ctx.addPath(path); ctx.clip()
                let crest = NSColor.white.blended(withFraction: dark ? 0.05 : 0.03, of: mid) ?? .white
                let base = NSColor.white.blended(withFraction: dark ? 0.26 : 0.14, of: mid) ?? .white
                if let gradient = CGGradient(colorsSpace: space, colors: [crest.cgColor, base.cgColor] as CFArray, locations: [0.1, 1]) {
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: puck.maxY), end: CGPoint(x: 0, y: puck.minY), options: [])
                }
                // Side shading: a cylinder lit from the front.
                if let sides = CGGradient(colorsSpace: space, colors: [NSColor.black.withAlphaComponent(0.1).cgColor, NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.12).cgColor] as CFArray, locations: [0, 0.3, 0.7, 1]) {
                    ctx.drawLinearGradient(sides, start: CGPoint(x: puck.minX, y: 0), end: CGPoint(x: puck.maxX, y: 0), options: [])
                }
                Self.radial(ctx, mid.withAlphaComponent(dark ? 0.5 : 0.32).cgColor, at: CGPoint(x: puck.midX, y: puck.minY + 3), radius: 9)
                Self.radial(ctx, white, at: CGPoint(x: puck.midX - 2, y: puck.maxY - 5), radius: 7)
                ctx.restoreGState()
                ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: puck.midY, width: body.width, height: body.height))
                ctx.addPath(Self.capsule(puck.insetBy(dx: 1, dy: 1))); ctx.setStrokeColor(white); ctx.setLineWidth(0.8); ctx.strokePath()
                ctx.restoreGState()
                ctx.addPath(Self.capsule(puck.insetBy(dx: 0.25, dy: 0.25))); ctx.setLineWidth(0.5)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.45 : 0.22).cgColor); ctx.strokePath()
                // Grip ridges above and below the window.
                for y in [puck.maxY - 4.5, puck.minY + 4.5] {
                    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.8); ctx.setLineCap(.round)
                    ctx.move(to: CGPoint(x: puck.midX - 3, y: y)); ctx.addLine(to: CGPoint(x: puck.midX + 3, y: y)); ctx.strokePath()
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(0.6)
                    ctx.move(to: CGPoint(x: puck.midX - 3, y: y - 0.8)); ctx.addLine(to: CGPoint(x: puck.midX + 3, y: y - 0.8)); ctx.strokePath()
                }
                ctx.addPath(Self.capsule(slot)); ctx.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor); ctx.fillPath()
                ctx.saveGState(); ctx.addPath(Self.capsule(slot)); ctx.clip()
                Self.vertical(ctx, black, from: (slot.maxY, 0.25), to: (slot.maxY - 4, 0))
                ctx.restoreGState()
            }
            // The window's gloss: a vertical highlight on its left edge.
            self.thumbGloss.contents = Self.bitmap(CGSize(width: 6, height: 20), scale: scale) { ctx in
                ctx.addPath(Self.capsule(CGRect(x: 0, y: 0, width: 6, height: 20))); ctx.clip()
                if let gloss = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.7).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0.8, y: 0), end: CGPoint(x: 3.5, y: 0), options: [])
                }
            }
            // Frozen knob: a glowing rime rim and a frosted cap.
            self.thumbFrost.contents = Self.bitmap(body, scale: scale) { ctx in
                let path = Self.capsule(puck)
                ctx.saveGState(); ctx.addPath(path); ctx.clip()
                Self.vertical(ctx, dark ? white : rime, from: (puck.maxY, dark ? 0.7 : 0.35), to: (puck.maxY - 12, 0))
                Self.vertical(ctx, dark ? white : rime, from: (puck.minY, dark ? 0.35 : 0.2), to: (puck.minY + 8, 0))
                ctx.restoreGState()
                // A soft rime glow around the rim instead of spikes.
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 4 * scale, color: rime.copy(alpha: 0.75) ?? rime)
                ctx.addPath(Self.capsule(puck.insetBy(dx: 0.6, dy: 0.6))); ctx.setStrokeColor(rime); ctx.setLineWidth(1.2); ctx.strokePath()
                ctx.restoreGState()
            }

            self.halo.colors = [Theme.iceMid.withAlphaComponent(dark ? 0.55 : 0.3).cgColor, Theme.iceMid.withAlphaComponent(0).cgColor]
            self.wake.colors = [(dark ? high : NSColor.white).withAlphaComponent(0).cgColor, (dark ? high : NSColor.white).withAlphaComponent(0.95).cgColor]
            self.rippleRing.strokeColor = (dark ? high : mid).cgColor
            self.measuredMark.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.7 : 0.55).cgColor
        }
        for layer in [aura, well, coolant, sparks, head, haze, frost, glass, sheet, fringe, crownGlint, vapor, burst, thumbBody, thumbGloss, thumbFrost, rippleRing,
                      streamWide, streamFine, twinkleA, twinkleB] as [CALayer] { layer.contentsScale = scale }
        aura.frame = channel.insetBy(dx: -A, dy: -A)
        let auraSpan = aura.bounds.width + Metric.auraFade + 4
        auraMask.bounds = CGRect(x: 0, y: 0, width: auraSpan, height: aura.bounds.height)
        auraMask.locations = [0, NSNumber(value: Double((auraSpan - Metric.auraFade) / auraSpan)), 1]
        auraMask.position = CGPoint(x: 0, y: aura.bounds.height / 2)
        well.frame = channel.insetBy(dx: -4, dy: -4)
        glass.frame = well.frame
        coolant.frame = channel
        fillMask.cornerRadius = innerHeight / 2
        fillMask.bounds = CGRect(x: 0, y: 0, width: 0, height: innerHeight); fillMask.position = CGPoint(x: wall, y: H / 2)
        rotorField.container.frame = CGRect(x: 0, y: 0, width: W, height: H)
        rotorField.layout(image: rotorArt, diameter: rotorDiameter, centers: rotorCenters, scale: scale)
        sparks.frame = CGRect(x: 0, y: 0, width: W, height: H)
        head.frame = CGRect(x: 0, y: 0, width: W, height: H)
        headMask.bounds = CGRect(x: 0, y: 0, width: Metric.head, height: H)
        haze.frame = channel
        hazeMask.cornerRadius = innerHeight / 2
        hazeMask.bounds = CGRect(x: 0, y: 0, width: 0, height: innerHeight); hazeMask.position = CGPoint(x: wall, y: H / 2)
        frost.frame = channel.insetBy(dx: 0, dy: -F)
        frostMask.bounds = CGRect(x: 0, y: 0, width: 0, height: frost.bounds.height); frostMask.position = CGPoint(x: 0, y: frost.bounds.height / 2)
        crown.frame = channel.insetBy(dx: 0, dy: -C)
        crownMask.frame = crown.bounds
        sheet.frame = CGRect(x: 0, y: C, width: W, height: H)
        flowClip.frame = sheet.frame
        flowShape.frame = flowClip.bounds
        flowShape.path = Self.capsule(CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: wall - 0.5, dy: wall - 0.5))
        let flowing = loops.isRunning
        if flowing { loops.freeze() }
        for (layer, period) in [(streamWide, Metric.widePeriod), (streamFine, Metric.finePeriod)] {
            layer.bounds = CGRect(x: 0, y: 0, width: W + 2 * period, height: H); layer.position = .zero; loops.setRest(layer, x: 0)
        }
        for layer in [twinkleA, twinkleB] { layer.bounds = CGRect(x: 0, y: 0, width: W, height: H); layer.position = .zero }
        if flowing { loops.start(pace: IceFlow.pace(effects: effects)) }
        fringe.bounds = crown.bounds; fringe.position = CGPoint(x: crown.bounds.midX, y: crown.bounds.midY)
        crownGlint.frame = crown.frame
        glintMask.bounds = CGRect(x: 0, y: 0, width: Metric.glintBand, height: crownGlint.bounds.height)
        glintMask.position = CGPoint(x: x(for: 100) - channel.minX, y: crownGlint.bounds.height / 2)
        wake.cornerRadius = innerHeight / 2
        halo.bounds = CGRect(x: 0, y: 0, width: 96, height: 64)
        let ring = CGRect(origin: .zero, size: CGSize(width: knob.width + 6, height: knob.height + 6))
        rippleRing.bounds = ring; rippleRing.path = Self.capsule(ring.insetBy(dx: 0.75, dy: 0.75))
        burst.bounds = CGRect(origin: .zero, size: Metric.burst); burst.position = CGPoint(x: x(for: 100), y: channel.midY)
        vapor.bounds = CGRect(origin: .zero, size: Metric.vapor); vapor.position = CGPoint(x: x(for: 100), y: channel.midY)
        measuredMark.bounds = CGRect(x: 0, y: 0, width: 2, height: innerHeight - 4); measuredMark.cornerRadius = 1
        thumb.bounds = CGRect(origin: .zero, size: knob)
        tilt.bounds = thumb.bounds; tilt.position = CGPoint(x: knob.width / 2, y: knob.height / 2)
        thumbBody.bounds = CGRect(origin: .zero, size: CGSize(width: knob.width + 2 * pad, height: knob.height + 2 * pad)); thumbBody.position = tilt.position
        thumbFrost.bounds = thumbBody.bounds; thumbFrost.position = tilt.position
        thumbCore.bounds = CGRect(x: 0, y: 0, width: 6, height: 20); thumbCore.cornerRadius = 3; thumbCore.position = tilt.position
        thumbGloss.bounds = thumbCore.bounds; thumbGloss.position = tilt.position
        CATransaction.commit()
        return true
    }

    // MARK: Placement and progressive decoration

    /// Moves knob, coolant, aura, fog, rime, head and halo together. Rime
    /// lowered by a drag melts back behind the knob instead of vanishing.
    override func place(animated: Bool, userAction: Bool) {
        let channel = channelRect, targetX = snap(x(for: value)), fill = max(0, targetX - channel.minX)
        let wall = SliderGeometry.wall, inner = innerHeight
        let shownX = (thumb.presentation() ?? thumb).position.x
        let glide = animated && effects.animates && window != nil && abs(shownX - targetX) > 0.5
        let frostShown = (frostMask.presentation() ?? frostMask).bounds.width
        let melting = !glide && dragging && effects.animates && effects.frost > 0 && window != nil && fill < frostShown - 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(thumb, "position", animated: glide) { thumb.position = CGPoint(x: targetX, y: channel.midY) }
        change(halo, "position", animated: glide) { halo.position = CGPoint(x: targetX, y: channel.midY) }
        // The coolant's rounded end runs on under the knob.
        change(fillMask, "bounds", animated: glide) { fillMask.bounds = CGRect(x: 0, y: 0, width: max(0, fill - wall + 8), height: inner) }
        change(hazeMask, "bounds", animated: glide) { hazeMask.bounds = CGRect(x: 0, y: 0, width: max(0, fill - wall + 8), height: inner) }
        change(auraMask, "position", animated: glide) { auraMask.position = CGPoint(x: fill + Metric.aura + Metric.auraFade, y: aura.bounds.height / 2) }
        change(frostMask, "bounds", animated: glide || melting, duration: melting ? Metric.frostMelt : Metric.glide, timing: melting ? Theme.Ease.inOut : Theme.Ease.out) {
            frostMask.bounds = CGRect(x: 0, y: 0, width: fill, height: frost.bounds.height)
        }
        change(headMask, "position", animated: glide) { headMask.position = CGPoint(x: fill, y: channel.height / 2) }
        if glide && userAction && effects.wake { streak(from: shownX, to: targetX) }
        CATransaction.commit()
    }

    /// Intensities derived from the value: coolant light, rotors, sparks, aura,
    /// fog, head, halo, rime, the knob's window and the ice. `userAction`
    /// distinguishes a person reaching full cooling from a model refresh
    /// (which never plays the formation).
    override func decorate(animated: Bool, userAction: Bool) {
        let energy = SliderEnergy.level(percent: value), amount = Frost.amount(percent: value)
        let interaction = dragging ? 1.0 : hovered ? 0.88 : 0.75
        let animate = animated && effects.animates && window != nil
        let crowned = Frost.crowned(percent: value) && effects.frost > 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(halo, "opacity", animated: animate, duration: 0.25) { halo.opacity = Float(effects.glow * (0.15 + 0.85 * energy) * interaction) }
        change(halo, "transform", animated: animate, duration: 0.25) {
            let s = CGFloat(0.75 + 0.4 * energy + (dragging ? 0.12 : 0)); halo.transform = CATransform3DMakeScale(s, s, 1)
        }
        change(aura, "opacity", animated: animate, duration: 0.3) { aura.opacity = Float(effects.glow * (0.1 + 0.9 * energy) * (0.7 + 0.3 * interaction)) }
        // Rotors are part of the coolant's pattern: always there, brighter
        // with energy, quieter on Subtle, still on Off.
        change(rotorField.container, "opacity", animated: animate, duration: 0.3) {
            rotorField.container.opacity = Float((0.42 + 0.5 * energy) * (0.55 + 0.45 * max(effects.glow, effects.ambient)))
        }
        change(sparks, "opacity", animated: animate, duration: 0.25) { sparks.opacity = Float(effects.glow * (0.3 + 0.7 * energy)) }
        change(head, "opacity", animated: animate, duration: 0.25) { head.opacity = Float(effects.glow * (0.15 + 0.85 * energy) * interaction) }
        change(headMask, "transform", animated: animate, duration: 0.25) { headMask.transform = CATransform3DMakeScale(CGFloat(0.35 + 1.1 * energy), 1, 1) }
        change(haze, "opacity", animated: animate, duration: 0.35) { haze.opacity = Float(amount > 0 ? effects.frost * (0.25 + 0.75 * amount) * (crowned ? 1 : 0.8) : 0) }
        thumbCore.backgroundColor = palette.core(value)
        // A drag tracks instantly but may still form/melt the decorative ice.
        // Keyboard changes have neither a drag nor animated travel.
        let animateCrown = (animated || userAction && dragging) && effects.animates && window != nil
        // Loose rime consolidates into the ice as it forms (and loosens again
        // as it melts), so full cooling reads as ice, not more grain.
        let consolidating = crowned != isIceFormed && animateCrown
        change(frost, "opacity", animated: animate || consolidating, duration: consolidating ? (crowned ? Metric.form : Metric.melt) : 0.3) {
            frost.opacity = Float(amount > 0 ? effects.frost * (0.35 + 0.65 * amount) * (crowned ? 0.3 : 1) : 0)
        }
        // A gliding knob (a click, preset or Smart) lands before the ice forms
        // around it; under a drag the knob is already there.
        if crowned != isIceFormed { setCrown(crowned, form: IceCover.forms(animated: animateCrown, allowed: effects.forms), animated: animateCrown, delay: animated ? glideDuration * 0.5 : 0) }
        else if crowned { crown.opacity = Float(effects.frost); thumbFrost.opacity = Float(effects.frost) }
        // How present the flow is (Subtle fainter); its motion is IceFlow's.
        let strength = Float(IceFlow.strength(effects: effects))
        if flowClip.opacity != strength { change(flowClip, "opacity", animated: animate, duration: 0.3) { flowClip.opacity = strength } }
        CATransaction.commit()
    }

    /// Forms (or melts) the ice. The formed state is static artwork: model
    /// values hold it after any transition finishes.
    ///
    /// Formation (any crossing the person can see, `IceCover.forms`): a front
    /// of frosted ice crawls the whole tube from the knob in growth spurts
    /// (`IceCover.crawl`) while the rime crust grows on the glass and a glint
    /// rides the front; a breath of cold air rises; the glint then runs back
    /// to the knob, which frosts over. Melting starts from what is on screen:
    /// the front recedes toward the knob end while the ice clears, the crust
    /// draws back and a little steam lifts, so a drag that touches 100% and
    /// leaves never snaps. Either direction can interrupt the other mid-way.
    private func setCrown(_ shown: Bool, form: Bool, animated: Bool, delay: CFTimeInterval = 0) {
        isIceFormed = shown
        let opacity = Float(shown ? effects.frost : 0)
        let channel = channelRect, thumbX = x(for: 100) - channel.minX
        let rest = shown ? CATransform3DIdentity : CATransform3DMakeScale(1, 0.35, 1)
        // How far the front had reached on screen (0 none … 1 the whole tube).
        let shownCrown = crown.presentation() ?? crown
        let reach = shownCrown.opacity > 0.05 ? ((crownMask.presentation() ?? crownMask).locations?[1].doubleValue ?? 0) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        crownGlint.removeAllAnimations(); glintMask.removeAllAnimations(); crownGlint.opacity = 0
        if !shown { burst.removeAllAnimations() }
        vapor.removeAllAnimations()
        if shown { glintMask.position = CGPoint(x: thumbX, y: crownGlint.bounds.height / 2) }
        if shown && form {
            let from = shownCrown.opacity
            crown.opacity = opacity; crown.removeAllAnimations()
            fringe.transform = rest; fringe.removeAllAnimations()
            thumbFrost.opacity = opacity; thumbFrost.removeAllAnimations()
            crownMask.removeAllAnimations(); crownMask.locations = [0, 1, 1]
            // Growth in spurts, resumed from wherever a melt left the front.
            let crawl = IceCover.crawl(from: reach)
            let spread = CAKeyframeAnimation(keyPath: "locations")
            spread.values = crawl.map { [NSNumber(value: 0), NSNumber(value: $0.reach), NSNumber(value: min(1, $0.reach + 0.08))] as [NSNumber] }
            spread.keyTimes = crawl.map { NSNumber(value: $0.time) }
            spread.duration = Metric.form
            let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = from; appear.toValue = opacity; appear.duration = 0.16
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(1, 0.25, 1)); grow.toValue = NSValue(caTransform3D: rest)
            grow.duration = Metric.form * 1.1; grow.timingFunction = Theme.Ease.out
            // The glint rides the front out, rests, and runs back to the knob.
            let out = Metric.form / Metric.formation
            let ride = CAKeyframeAnimation(keyPath: "position.x")
            ride.values = crawl.map { thumbX * CGFloat(1 - $0.reach) } + [0, thumbX]
            ride.keyTimes = (crawl.map { $0.time * out } + [out + 0.05, 1]).map { NSNumber(value: $0) }
            ride.calculationMode = .linear
            ride.duration = Metric.formation
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 0.9, 0.45, 0, 0, 1, 0].map { $0 * opacity }
            flash.keyTimes = [0, 0.06, out * 0.9, out, out + 0.06, 0.88, 1].map { NSNumber(value: $0) }
            flash.duration = Metric.formation
            let freeze = CABasicAnimation(keyPath: "opacity"); freeze.fromValue = 0; freeze.toValue = opacity
            freeze.duration = 0.24; freeze.timingFunction = Theme.Ease.out
            let start = CACurrentMediaTime() + delay
            for animation in [spread, appear, grow, ride, flash] as [CAAnimation] { animation.beginTime = start; animation.fillMode = .backwards }
            freeze.beginTime = start + Metric.formation * 0.82; freeze.fillMode = .backwards
            crownMask.add(spread, forKey: "form"); crown.add(appear, forKey: "appear"); fringe.add(grow, forKey: "grow")
            glintMask.add(ride, forKey: "glint"); crownGlint.add(flash, forKey: "glint"); thumbFrost.add(freeze, forKey: "freeze")
            puff(strength: 0.85 * Double(opacity), rise: 10, at: start + 0.1)
        } else if shown {
            crownMask.removeAllAnimations(); crownMask.locations = [0, 1, 1]
            change(crown, "opacity", animated: animated, duration: 0.2) { crown.opacity = opacity }
            change(fringe, "transform", animated: animated, duration: 0.2) { fringe.transform = rest }
            change(thumbFrost, "opacity", animated: animated, duration: 0.2) { thumbFrost.opacity = opacity }
        } else {
            let receded = [0, 0, 0.08].map { NSNumber(value: $0) }
            if animated && reach > 0 {
                // The front recedes from where it is; the ice clears late, so
                // the retreat is what reads.
                let current = (crownMask.presentation() ?? crownMask).locations ?? [0, 1, 1]
                crownMask.removeAllAnimations(); crownMask.locations = receded
                let recede = CABasicAnimation(keyPath: "locations")
                recede.fromValue = current; recede.toValue = receded
                recede.duration = Metric.melt; recede.timingFunction = Theme.Ease.inOut
                crownMask.add(recede, forKey: "melt")
                let clear = CAKeyframeAnimation(keyPath: "opacity")
                clear.values = [shownCrown.opacity, shownCrown.opacity * 0.8, 0]; clear.keyTimes = [0, 0.55, 1]
                clear.duration = Metric.melt
                crown.opacity = 0; crown.removeAllAnimations(); crown.add(clear, forKey: "opacity")
            } else {
                crownMask.removeAllAnimations(); crownMask.locations = receded
                crown.removeAllAnimations(); crown.opacity = 0
            }
            change(fringe, "transform", animated: animated, duration: Metric.melt, timing: Theme.Ease.inOut) { fringe.transform = rest }
            change(thumbFrost, "opacity", animated: animated, duration: 0.35, timing: Theme.Ease.inOut) { thumbFrost.opacity = opacity }
            fringe.removeAnimation(forKey: "grow"); thumbFrost.removeAnimation(forKey: "freeze")
            // Melting lets off a little steam (Expressive, moving).
            if animated && effects.forms { puff(strength: 0.45 * effects.frost, rise: 14, at: CACurrentMediaTime()) }
        }
        CATransaction.commit()
    }

    /// One finite breath of vapor rising from the end of the tube.
    private func puff(strength: Double, rise: CGFloat, at start: CFTimeInterval) {
        guard effects.forms, window != nil, strength > 0 else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, strength, 0]; fade.keyTimes = [0, 0.25, 1]
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.6; grow.toValue = 1.35
        // Up the screen in the control's flipped coordinates.
        let lift = CABasicAnimation(keyPath: "position.y"); lift.fromValue = vapor.position.y; lift.toValue = vapor.position.y - rise
        let group = CAAnimationGroup(); group.animations = [fade, grow, lift]; group.duration = 1.0
        group.timingFunction = Theme.Ease.out; group.beginTime = start; group.fillMode = .backwards
        vapor.add(group, forKey: "puff")
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

    // MARK: Knob and reactions

    /// Rest, hover and held shapes. A grab squashes the knob and flashes the
    /// coolant before it settles into its held shape; a release springs back
    /// with a little overshoot. Both start from what is on screen.
    override func shapeThumb(_ gesture: ThumbGesture) {
        let target = dragging ? CATransform3DMakeScale(1.1, 1.05, 1) : hovered && isEnabled ? CATransform3DMakeScale(1.07, 1.03, 1) : CATransform3DIdentity
        let animate = effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let from = (thumb.presentation() ?? thumb).transform
        switch gesture {
        case .grab where animate:
            thumb.transform = target
            let squash = CAKeyframeAnimation(keyPath: "transform")
            squash.values = [from, CATransform3DMakeScale(1.24, 0.9, 1), target].map { NSValue(caTransform3D: $0) }
            squash.keyTimes = [0, 0.35, 1]; squash.duration = 0.26; squash.timingFunction = Theme.Ease.out
            thumb.add(squash, forKey: "transform")
            if effects.glow > 0 { flare(sparks, by: 0.45, duration: 0.35) }
        case .release where animate:
            thumb.transform = target
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1; spring.stiffness = 380; spring.damping = 12
            spring.fromValue = NSValue(caTransform3D: from); spring.toValue = NSValue(caTransform3D: target)
            spring.duration = spring.settlingDuration
            thumb.add(spring, forKey: "transform")
        default:
            change(thumb, "transform", animated: animate, duration: 0.15) { thumb.transform = target }
        }
        CATransaction.commit()
    }

    /// A short additive brightening of a layer (grab, release twinkle).
    private func flare(_ layer: CALayer, by amount: Double, duration: CFTimeInterval) {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, amount, 0]; pulse.keyTimes = [0, 0.25, 1]; pulse.isAdditive = true
        pulse.duration = duration; pulse.timingFunction = Theme.Ease.out
        layer.add(pulse, forKey: "flare")
    }

    /// Answers drag speed. Every reaction is additive and decays on its own,
    /// so the control settles when the pointer stops without any timer.
    override func react() {
        guard window != nil, effects.animates else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let gain = effects.motion, intensity = SliderMotion.intensity(velocity: velocity), direction: CGFloat = velocity < 0 ? -1 : 1
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
            decay(aura, "opacity", from: 0.25 * intensity * effects.glow, duration: 0.6, key: "surge")
            let slosh = CASpringAnimation(keyPath: "position.x")
            slosh.isAdditive = true; slosh.fromValue = -direction * Metric.slosh * CGFloat(intensity * gain); slosh.toValue = 0
            slosh.mass = 1; slosh.stiffness = 200; slosh.damping = 10; slosh.duration = slosh.settlingDuration
            sparks.add(slosh, forKey: "surge.slosh")
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

    /// The cold wake behind a moving knob: brightest at the knob, it retracts
    /// into it and fades once the pointer slows.
    private func trail() {
        let (length, peak) = SliderMotion.wake(velocity: velocity, energy: SliderEnergy.level(percent: value))
        guard peak > 0, effects.glow > 0 else { return }
        let channel = channelRect, thumbX = thumb.position.x, forward = velocity > 0
        let room = forward ? thumbX - channel.minX - SliderGeometry.wall : channel.maxX - SliderGeometry.wall - thumbX
        let shown = min(CGFloat(length) * 1.3, max(0, room))
        guard shown > 3 else { return }
        shapeWake(at: thumbX, length: shown, forward: forward)
        playWake(peak: Float(peak * effects.glow), duration: Metric.wakeFade, keep: 0.25)
    }
    /// A user glide (preset or track click) shoots light to the target; the
    /// tail then gathers into the arriving knob.
    private func streak(from: CGFloat, to: CGFloat) {
        let distance = abs(to - from)
        guard distance > 24, effects.glow > 0 else { return }
        shapeWake(at: to, length: distance, forward: to > from)
        playWake(peak: Float((0.55 + 0.45 * SliderEnergy.level(percent: value)) * effects.glow), duration: Metric.glide + 0.3, keep: 0.06)
    }
    private func shapeWake(at x: CGFloat, length: CGFloat, forward: Bool) {
        wake.anchorPoint = CGPoint(x: forward ? 1 : 0, y: 0.5)
        wake.bounds = CGRect(x: 0, y: 0, width: length, height: innerHeight)
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

    /// A ring that spreads along the tube: grabs, releases and detents.
    override func ripple(at percent: Double, strength: Double, wide: Bool) {
        guard effects.wake, window != nil, renderedScale > 0 else { return }
        let x = snap(self.x(for: percent))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rippleRing.position = CGPoint(x: x, y: channelRect.midY)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.9, 0.9, 1))
        grow.toValue = NSValue(caTransform3D: CATransform3DMakeScale(wide ? 3.4 : 2.1, wide ? 1.35 : 1.2, 1))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, min(1, strength) * effects.glow, 0]; fade.keyTimes = [0, 0.12, 1]
        let group = CAAnimationGroup(); group.animations = [grow, fade]
        group.duration = wide ? 0.66 : 0.46; group.timingFunction = Theme.Ease.out
        rippleRing.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    override func interrupt() { headMask.removeAnimation(forKey: "sweep"); head.removeAnimation(forKey: "sweep") }

    /// Acknowledges a pointer release: a pulse of light runs from the knob
    /// back along the coolant toward the fan's floor, and the sparks twinkle.
    override func sweep() {
        guard effects.sweep, window != nil, value > minimumPercent + 1 else { return }
        let current = (head.presentation() ?? head).opacity
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = headMask.position.x; travel.toValue = -Metric.head * 0.2
        travel.duration = 0.6; travel.timingFunction = Theme.Ease.out
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [current, min(1, current + 0.55), current]; flash.keyTimes = [0, 0.22, 1]; flash.duration = 0.6
        headMask.add(travel, forKey: "sweep"); head.add(flash, forKey: "sweep")
        flare(sparks, by: 0.5, duration: 0.6)
    }

    /// A bloom of cold light at the knob when a user action reaches 100%: on
    /// Expressive it closes the formation (when the returning glint freezes
    /// the knob), on Subtle it is the whole acknowledgement. Skipped for
    /// keyboard changes and with Reduce Motion.
    override func celebrate(animated: Bool, delay: CFTimeInterval) {
        guard animated, effects.bloom, window != nil else { return }
        let formed = effects.forms && isIceFormed
        let strength = Float(formed ? 1 : 0.65)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        burst.position = CGPoint(x: x(for: 100), y: channelRect.midY)
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, strength, 0]; fade.keyTimes = [0, 0.18, 1]
        let spread = CAKeyframeAnimation(keyPath: "transform.scale"); spread.values = [0.5, 1.0, formed ? 1.25 : 1.1]; spread.keyTimes = [0, 0.35, 1]
        let group = CAAnimationGroup(); group.animations = [fade, spread]; group.duration = formed ? 0.7 : 0.5
        group.timingFunction = Theme.Ease.out
        if formed { group.beginTime = CACurrentMediaTime() + delay + Metric.formation * 0.82; group.fillMode = .backwards }
        burst.add(group, forKey: "burst")
        CATransaction.commit()
    }

    // MARK: Drawing helpers

    /// Draws a tile at every `period` across `width` (plus one before), so
    /// the artwork repeats seamlessly for a scrolling loop.
    private static func tiled(width: CGFloat, period: CGFloat, draw: (CGFloat) -> Void) {
        var dx = -period
        while dx < width + period { draw(dx); dx += period }
    }
    /// A soft horizontal streak: a radial falloff stretched along x.
    private static func streak(_ ctx: CGContext, _ color: CGColor, at centre: CGPoint, length: CGFloat, thickness: CGFloat) {
        guard thickness > 0, length > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: centre.x, y: centre.y); ctx.scaleBy(x: length / thickness, y: 1)
        radial(ctx, color, at: .zero, radius: thickness / 2)
        ctx.restoreGState()
    }
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
    /// A small fern of rime: a stem with two side branches (stroked).
    private static func dendrite(_ ctx: CGContext, from point: CGPoint, dir: CGVector, length: CGFloat, flip: Bool) {
        func along(_ t: CGFloat) -> CGPoint { CGPoint(x: point.x + dir.dx * length * t, y: point.y + dir.dy * length * t) }
        ctx.move(to: point); ctx.addLine(to: along(1))
        for (t, reach, side) in [(0.4 as CGFloat, 0.4 as CGFloat, flip ? 1.0 : -1.0), (0.68, 0.28, flip ? -1.0 : 1.0)] {
            let branch = rotate(dir, CGFloat(side) * 0.85), start = along(t)
            ctx.move(to: start); ctx.addLine(to: CGPoint(x: start.x + branch.dx * length * reach, y: start.y + branch.dy * length * reach))
        }
        ctx.strokePath()
    }
}
