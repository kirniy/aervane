import AppKit
import QuartzCore

/// The Dot Grid style: a tall lattice of glass dots set into a recessed
/// tray, with a slim sculpted glass handle. Cooling power reads as light and
/// frost on the lattice.
///
/// One energy curve (`SliderEnergy`) drives everything progressive: lit dots
/// swell and cool from mint through glacier cyan to ice white, a white-hot
/// head trails the handle, a halo gathers around it, and the dots under the
/// handle bulge like glass under a lens (stronger on hover and while held).
/// Above ~45% hoarfrost clings to the lit edges. At 100% the *whole* tray
/// freezes over (`IceCover`): a milky glaze, every dot a white faceted
/// crystal; while the panel shows it, the frozen lattice keeps moving
/// (`IceFlow`): soft waves of light roll from the handle toward the start
/// and crystals twinkle in two alternating sets. Reaching 100% crawls the
/// crystals in from the handle with a glint running out and back, and the
/// handle frosts over; lowering the value melts them back toward the handle.
///
/// The handle squashes when grabbed, leans and stretches with drag speed and
/// springs back on release; the head sloshes against fast moves; grabs,
/// releases and preset stops ripple through the dots. Transient reactions
/// are finite Core Animations; the full-cooling flow is the one repeating
/// motion (bounded compositor loops) and freezes in place whenever the
/// control stops it. No fan graphics: the Dot Grid is light on a lattice.
/// Artwork is cached per size, scale, appearance and floor.
@MainActor final class DotGridSkin: SliderSkin {
    private let tray = CALayer()
    private let dimDots = CALayer(), dimMask = CALayer(), litDots = CALayer(), litMask = CALayer()
    private let sparkDots = CALayer(), headMask = CAGradientLayer()
    /// Lens: larger, brighter dots seen through a soft disc under the handle.
    private let swell = CALayer(), swellMask = CAGradientLayer()
    /// The frozen lattice's flow: light waves and two twinkle sets.
    private let flowBox = CALayer(), shimmer = CALayer(), shimmerMask = CAGradientLayer(), twinkleA = CALayer(), twinkleB = CALayer()
    private let loops = LoopSet()
    private let frost = CALayer(), frostMask = CALayer()
    private let floorTick = CALayer(), measuredMark = CALayer(), halo = CAGradientLayer()
    private let crown = CALayer(), crownMask = CAGradientLayer()
    private let crownGlint = CALayer(), glintMask = CAGradientLayer()
    private let bloom = CALayer()
    // The handle: `thumb` carries position and the press shape, `tilt` the
    // speed reactions, so the two never fight over one transform.
    private let thumb = CALayer(), tilt = CALayer(), thumbBody = CALayer(), thumbFrost = CALayer()

    private enum Metric {
        static let dot = DotGridGeometry.dot, pitch = DotGridGeometry.pitch, rows = DotGridGeometry.rows
        static let inset = DotGridGeometry.inset  // handle, halo and crown room at both ends
        static let thumb = DotGridGeometry.thumb
        static let thumbPad: CGFloat = 5          // shadow and frost room around the handle
        static let grabSlop: CGFloat = 12         // pick the handle up without a jump
        static let glide: CFTimeInterval = 0.2
        static let tray: CGFloat = 5              // recessed tray margin around the lattice
        static let restDot: CGFloat = 2           // unlit dots sit smaller, recessed
        static let lens = CGSize(width: 64, height: 46)
        /// Light waves: one band every `wavePeriod`, one period per loop.
        static let wavePeriod: CGFloat = 84, waveLoop: CFTimeInterval = 2.6
        static let bloomReach = 6, bloomLift = 4  // in lattice cells
        static let frostFringe: CGFloat = 8       // grain room above and below the dots
        static let glintBand: CGFloat = 30
        static let head: CGFloat = 130
        static let slosh: CGFloat = 6
        /// Freezing front: crawls the whole lattice from the handle.
        static let form: CFTimeInterval = 1.0
        /// Front, then the glint's return to the handle, which frosts it.
        static let formation: CFTimeInterval = 1.6
        static let melt: CFTimeInterval = 0.6
        static let frostMelt: CFTimeInterval = 0.5
    }

    init(host: PercentSlider) {
        super.init(host: host, style: .dotGrid)
        // Unlit dots show only past the fill, so lit dots never sit on top
        // of dim ones.
        dimDots.mask = dimMask
        dimMask.backgroundColor = NSColor.black.cgColor; dimMask.anchorPoint = CGPoint(x: 1, y: 0.5)
        litDots.mask = litMask
        litMask.backgroundColor = NSColor.black.cgColor; litMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        // The head is a horizontal light falloff that peaks just behind the
        // handle; it lives inside the lit layer so it can never light dots
        // ahead of the value. The lens lives there too.
        sparkDots.mask = headMask
        litDots.addSublayer(sparkDots); litDots.addSublayer(swell)
        swell.mask = swellMask
        swellMask.type = .radial; swellMask.startPoint = CGPoint(x: 0.5, y: 0.5); swellMask.endPoint = CGPoint(x: 1, y: 1)
        swellMask.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        swellMask.locations = [0, 0.45, 1]
        headMask.startPoint = CGPoint(x: 0, y: 0.5); headMask.endPoint = CGPoint(x: 1, y: 0.5)
        headMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        headMask.locations = [0, 0.86, 1]; headMask.anchorPoint = CGPoint(x: 0.86, y: 0.5)
        frost.mask = frostMask
        frostMask.backgroundColor = NSColor.black.cgColor; frostMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        halo.type = .radial; halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        // The crystals reveal from the handle end leftward as they form.
        crown.mask = crownMask
        crownMask.startPoint = CGPoint(x: 1, y: 0.5); crownMask.endPoint = CGPoint(x: 0, y: 0.5)
        crownMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        crownMask.locations = [0, 1, 1]
        // The glint is the same crystals in white, seen through a narrow band.
        crownGlint.mask = glintMask
        glintMask.startPoint = CGPoint(x: 0, y: 0.5); glintMask.endPoint = CGPoint(x: 1, y: 0.5)
        glintMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        glintMask.locations = [0, 0.5, 1]
        // The flow lives inside the crystals, so the formation reveals it.
        crown.addSublayer(flowBox)
        flowBox.addSublayer(shimmer); flowBox.addSublayer(twinkleA); flowBox.addSublayer(twinkleB)
        shimmer.mask = shimmerMask; shimmerMask.anchorPoint = .zero
        shimmerMask.startPoint = CGPoint(x: 0, y: 0.5); shimmerMask.endPoint = CGPoint(x: 1, y: 0.5)
        twinkleA.opacity = 0.15; twinkleB.opacity = 0.15
        loops.scroll(shimmerMask, period: Metric.wavePeriod, duration: Metric.waveLoop)
        loops.breathe(twinkleA, amount: 0.85, duration: 2.1, phase: 0)
        loops.breathe(twinkleB, amount: 0.85, duration: 2.9, phase: 0.5)
        tilt.addSublayer(thumbBody); tilt.addSublayer(thumbFrost)
        thumb.addSublayer(tilt)
        dimDots.opacity = 0.82
        for layer in [sparkDots, swell, frost, halo, crown, crownGlint, measuredMark, bloom, thumbFrost] { layer.opacity = 0 }
        for layer in [tray, dimDots, litDots, sparkDots, swell, frost, crown, crownGlint, bloom, thumbBody, thumbFrost, shimmer, twinkleA, twinkleB] { layer.contentsGravity = .resize }
    }
    override var flow: LoopSet? { loops }

    override var layers: [CALayer] { [tray, dimDots, litDots, frost, halo, crown, crownGlint, floorTick, measuredMark, bloom, thumb] }
    override var allLayers: [CALayer] {
        [tray, dimDots, dimMask, litDots, litMask, sparkDots, headMask, swell, swellMask, frost, frostMask, halo,
         crown, crownMask, flowBox, crownGlint, glintMask, floorTick, measuredMark, bloom, thumb, tilt, thumbBody, thumbFrost]
    }
    override var thumbSize: CGSize { Metric.thumb }
    override var grabSlop: CGFloat { Metric.grabSlop }
    override func focusRing() -> NSBezierPath {
        let ring = trayRect.insetBy(dx: -3, dy: -3)
        return NSBezierPath(roundedRect: ring, xRadius: 10, yRadius: 10)
    }

    private var columns: Int { DotGridGeometry.columns(width: bounds.width) }
    private var gridRect: NSRect { DotGridGeometry.grid(width: bounds.width, height: bounds.height) }
    private var trayRect: NSRect { gridRect.insetBy(dx: -Metric.tray - 1, dy: -Metric.tray) }

    // MARK: Artwork (rendered once per geometry/appearance)

    @discardableResult override func render(scale: CGFloat) -> Bool {
        guard bounds.width > 4 * Metric.inset, bounds.height > 0 else { return false }
        renderedScale = scale
        let grid = gridRect, cols = columns, floorValue = minimumPercent, width = bounds.width
        let trayFrame = trayRect.insetBy(dx: -4, dy: -4)
        let reach = Metric.bloomReach, lift = Metric.bloomLift
        let bloomSize = CGSize(width: CGFloat(2 * reach) * Metric.pitch + Metric.dot, height: CGFloat(2 * lift) * Metric.pitch + Metric.dot)
        let frostSize = CGSize(width: grid.width, height: grid.height + 2 * Metric.frostFringe)
        let crownRect = trayRect.insetBy(dx: -2, dy: -2), crownSize = crownRect.size
        func columnPercent(_ c: Int) -> Double { Double(c) / Double(cols - 1) * 100 }
        func centre(_ c: Int, _ r: Int) -> CGPoint { CGPoint(x: CGFloat(c) * Metric.pitch + Metric.dot / 2, y: CGFloat(r) * Metric.pitch + Metric.dot / 2) }
        /// Every lattice dot, with its column and row.
        let lattice: [(Int, Int, CGPoint)] = (0..<cols).flatMap { c in (0..<Metric.rows).map { (c, $0, centre(c, $0)) } }
        // Full-cooling crystals cover the whole lattice, densest at the handle end.
        func crystal(_ x: CGFloat) -> CGFloat { CGFloat(IceCover.weight(at: Double(x / max(1, grid.width)))) }
        let crystalRamp: [(CGFloat, Double)] = stride(from: 0.0, through: 1.0, by: 0.05).map { (CGFloat($0) * grid.width, IceCover.weight(at: $0)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = Theme.dark
            let rest = Theme.ink.withAlphaComponent(dark ? 0.2 : 0.17).cgColor
            let held = Theme.iceLow.withAlphaComponent(dark ? 0.32 : 0.3).cgColor
            let low = Theme.iceLow.usingColorSpace(.sRGB) ?? Theme.iceLow
            let mid = Theme.iceMid.usingColorSpace(.sRGB) ?? Theme.iceMid
            let high = Theme.iceHigh.usingColorSpace(.sRGB) ?? Theme.iceHigh
            let rime = Theme.rime.usingColorSpace(.sRGB) ?? Theme.rime
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            /// Cooling ramp: mint → glacier cyan → ice white; alpha rises with it.
            func lit(_ v: Double) -> NSColor {
                let t = v / 100
                let tone = t < 0.6 ? (low.blended(withFraction: t / 0.6, of: mid) ?? mid)
                                   : (mid.blended(withFraction: (t - 0.6) / 0.4, of: high) ?? high)
                return tone.withAlphaComponent(0.42 + 0.58 * pow(t, 1.1))
            }
            func litSize(_ v: Double) -> CGFloat { CGFloat(SliderEnergy.dotSize(percent: v)) * 1.25 }

            // The tray: a shallow recess the lattice sits in, darker under
            // its upper lip and catching light along the lower one.
            self.tray.contents = Self.bitmap(trayFrame.size, scale: scale) { ctx in
                let r = CGRect(x: 4, y: 4, width: trayFrame.width - 8, height: trayFrame.height - 8)
                let path = CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil)
                ctx.addPath(path); ctx.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.24 : 0.045).cgColor); ctx.fillPath()
                ctx.saveGState(); ctx.addPath(path); ctx.clip()
                Self.vertical(ctx, NSColor.black.cgColor, from: (r.maxY, dark ? 0.4 : 0.11), to: (r.maxY - r.height * 0.45, 0))
                ctx.restoreGState()
                ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: trayFrame.width, height: r.midY))
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), cornerWidth: 9.5, cornerHeight: 9.5, transform: nil))
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(dark ? 0.1 : 0.75).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
                ctx.restoreGState()
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 8.75, cornerHeight: 8.75, transform: nil))
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.45 : 0.12).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
            }
            // Unlit dots: small dimples with a lit lower lip.
            self.dimDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                let s = Metric.restDot
                ctx.setFillColor(NSColor.white.withAlphaComponent(dark ? 0.07 : 0.5).cgColor)
                for (_, _, p) in lattice { Self.dot(ctx, at: CGPoint(x: p.x, y: p.y - 0.5), size: s) }
                // The dimple itself is translucent: clear the lip under it first.
                ctx.setBlendMode(.clear)
                for (_, _, p) in lattice { Self.dot(ctx, at: p, size: s) }
                ctx.setBlendMode(.normal); ctx.setFillColor(rest)
                for (_, _, p) in lattice { Self.dot(ctx, at: p, size: s) }
            }
            // Lit dots: glowing domes that swell with energy, each with a
            // small specular cap.
            self.litDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                for (c, _, p) in lattice {
                    let v = columnPercent(c), below = v < floorValue
                    let size = below ? Metric.restDot + 0.2 : litSize(v)
                    ctx.setFillColor(below ? held : lit(v).withAlphaComponent(lit(v).alphaComponent * (0.9 + 0.1 * Self.noise(c, Int(p.y)))).cgColor)
                    Self.dot(ctx, at: p, size: size)
                    guard !below else { continue }
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.2 + 0.4 * SliderEnergy.level(percent: v)).cgColor)
                    Self.dot(ctx, at: CGPoint(x: p.x - size * 0.16, y: p.y + size * 0.18), size: size * 0.4)
                }
            }
            self.sparkDots.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                ctx.setFillColor((dark ? NSColor.white : high).cgColor)
                for (c, _, p) in lattice { Self.dot(ctx, at: p, size: litSize(columnPercent(c)) + 0.3) }
            }
            // The lens: the same dots larger and brighter, with a full cap.
            self.swell.contents = Self.bitmap(grid.size, scale: scale) { ctx in
                for (c, _, p) in lattice {
                    let v = columnPercent(c), size = min(Metric.pitch - 0.4, litSize(v) + 0.9)
                    ctx.setFillColor(lit(max(v, 40)).withAlphaComponent(1).cgColor); Self.dot(ctx, at: p, size: size)
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
                    Self.dot(ctx, at: CGPoint(x: p.x - size * 0.16, y: p.y + size * 0.18), size: size * 0.45)
                }
            }
            // Hoarfrost: fine grains crowd the lit edges from the frost onset,
            // thicker and reaching further toward full cooling. Rendered
            // once; the mask reveals it.
            self.frost.contents = Self.bitmap(frostSize, scale: scale) { ctx in
                ctx.setFillColor(rime.cgColor); ctx.setStrokeColor(rime.cgColor); ctx.setLineCap(.round)
                let reach = Metric.frostFringe - 1
                for c in 0..<cols {
                    let v = columnPercent(c), w = CGFloat(Frost.amount(percent: v))
                    guard w > 0.02, v >= floorValue else { continue }
                    let x = centre(c, 0).x
                    for (side, up) in [(0, true), (1, false)] {
                        let edge = up ? Metric.frostFringe + grid.height + 0.3 : Metric.frostFringe - 0.3
                        for k in 0..<Frost.grains(amount: Double(w), noise: Double(Self.noise(c, 41 + side))) {
                            let seed = c * 7 + k
                            let d = pow(Self.noise(seed, 53 + side), 1.7) * (1.2 + (reach - 1.2) * w)
                            let size = (1.0 - 0.4 * d / reach) * (0.75 + 0.25 * Self.noise(seed, 61 + side))
                            let cx = x + (Self.noise(seed, 59 + side) - 0.5) * 2.4, cy = up ? edge + d : edge - d
                            ctx.setAlpha((0.22 + 0.6 * w) * (1 - 0.55 * d / reach))
                            ctx.fillEllipse(in: CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
                        }
                    }
                }
            }
            // Total frost: the whole tray freezes over (`IceCover`). A milky
            // glaze fills the recess, thickest against its lips, with soft
            // clouds of accumulated frost; every dot becomes a white faceted
            // crystal with an inked edge and a shaded facet, slightly varied in
            // size and clarity, so the lattice is visibly transformed and still
            // reads as dots. No cracks, ferns or needles: the life of the ice
            // is its flow (light waves and twinkles, below). Coverage scales
            // the glaze as opacity. The glint layer holds the crystals in white.
            let ox = grid.minX - crownRect.minX, oy = grid.minY - crownRect.minY
            let trayLocal = CGRect(x: trayRect.minX - crownRect.minX, y: trayRect.minY - crownRect.minY, width: trayRect.width, height: trayRect.height)
            let trayPath = CGPath(roundedRect: trayLocal, cornerWidth: 9, cornerHeight: 9, transform: nil)
            let edgeInk = dark ? CGColor(srgbRed: 0.05, green: 0.36, blue: 0.5, alpha: 1) : rime.cgColor
            let coverRamp = crystalRamp.map { ($0.0 + ox, $0.1) }
            func diamond(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> CGPath {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: cx, y: cy + s)); path.addLine(to: CGPoint(x: cx + s, y: cy))
                path.addLine(to: CGPoint(x: cx, y: cy - s)); path.addLine(to: CGPoint(x: cx - s, y: cy)); path.closeSubpath()
                return path
            }
            func crystalSize(_ c: Int, _ r: Int, _ w: CGFloat) -> CGFloat { (1.4 + 0.55 * w) * (0.82 + 0.18 * Self.noise(c, r + 83)) }
            @MainActor func crystals(_ ctx: CGContext, glint: Bool) {
                for (c, r, p) in lattice {
                    let w = crystal(p.x), cx = p.x + ox, cy = p.y + oy, s = crystalSize(c, r, w)
                    ctx.addPath(diamond(cx, cy, s))
                    ctx.setFillColor(NSColor.white.withAlphaComponent(glint ? w : (0.72 + 0.26 * w) * (0.7 + 0.3 * Self.noise(c, r + 89))).cgColor)
                    ctx.fillPath()
                    guard !glint else { continue }
                    let edge = (dark ? 0.5 : 0.42) * (0.6 + 0.4 * Self.noise(c, r + 91))
                    ctx.addPath(diamond(cx, cy, s)); ctx.setStrokeColor(edgeInk.copy(alpha: edge) ?? edgeInk); ctx.setLineWidth(0.35); ctx.strokePath()
                    // The lower-right facet in shade gives each crystal depth.
                    ctx.setFillColor(edgeInk.copy(alpha: dark ? 0.22 : 0.16) ?? edgeInk)
                    ctx.move(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx + s, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy - s)); ctx.closePath(); ctx.fillPath()
                }
                // The tray's rim, frosted.
                ctx.addPath(CGPath(roundedRect: trayLocal.insetBy(dx: 0.4, dy: 0.4), cornerWidth: 8.6, cornerHeight: 8.6, transform: nil))
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(glint ? 1 : 0.9).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
            }
            self.crown.contents = Self.bitmap(crownSize, scale: scale) { ctx in
                ctx.saveGState(); ctx.addPath(trayPath); ctx.clip()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                // Milky glaze, thickest against both lips.
                ctx.setFillColor(NSColor.white.withAlphaComponent(dark ? 0.26 : 0.4).cgColor); ctx.fill(trayLocal)
                Self.vertical(ctx, NSColor.white.cgColor, from: (trayLocal.maxY, dark ? 0.45 : 0.5), to: (trayLocal.midY, 0))
                Self.vertical(ctx, NSColor.white.cgColor, from: (trayLocal.minY, dark ? 0.35 : 0.4), to: (trayLocal.midY - 2, 0))
                for i in 0..<Int(trayLocal.width / 7) {
                    let walled = Self.noise(i, 401) < 0.65
                    let y = walled ? (Self.noise(i, 403) < 0.55 ? trayLocal.maxY - 2 : trayLocal.minY + 2) : trayLocal.minY + trayLocal.height * (0.3 + 0.4 * Self.noise(i, 411))
                    Self.radial(ctx, NSColor.white.withAlphaComponent(0.14 + 0.2 * Self.noise(i, 405)).cgColor,
                                at: CGPoint(x: trayLocal.minX + trayLocal.width * Self.noise(i, 413), y: y), radius: 4 + 7 * Self.noise(i, 407))
                }
                Self.vertical(ctx, edgeInk, from: (trayLocal.maxY, dark ? 0.16 : 0.08), to: (trayLocal.maxY - 4, 0))
                Self.fade(ctx, width: crownSize.width, stops: coverRamp)
                ctx.endTransparencyLayer()
                crystals(ctx, glint: false)
                ctx.restoreGState()
                ctx.addPath(CGPath(roundedRect: trayLocal.insetBy(dx: -0.3, dy: -0.3), cornerWidth: 9.3, cornerHeight: 9.3, transform: nil))
                ctx.setStrokeColor(edgeInk.copy(alpha: dark ? 0.5 : 0.35) ?? edgeInk); ctx.setLineWidth(0.5); ctx.strokePath()
                if floorValue > 0 {
                    // The floor stays readable through the ice.
                    let x = DotGridGeometry.x(percent: floorValue, width: width) - crownRect.minX - Metric.pitch / 2
                    ctx.setBlendMode(.destinationOut); ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
                    ctx.fill(CGRect(x: x - 1, y: 0, width: 2, height: crownSize.height)); ctx.setBlendMode(.normal)
                }
            }
            self.crownGlint.contents = Self.bitmap(crownSize, scale: scale) { ctx in
                ctx.saveGState(); ctx.addPath(trayPath); ctx.clip()
                crystals(ctx, glint: true)
                ctx.restoreGState()
            }
            // Flow artwork. The shimmer is every crystal lit from within
            // (seen only where a wave of light passes); the twinkles are two
            // sparse sets of crystal glints that breathe out of phase.
            let shine = dark ? NSColor.white : (mid.blended(withFraction: 0.15, of: .white) ?? mid)
            self.shimmer.contents = Self.bitmap(crownSize, scale: scale) { ctx in
                ctx.saveGState(); ctx.addPath(trayPath); ctx.clip()
                for (c, r, p) in lattice {
                    let w = crystal(p.x), cx = p.x + ox, cy = p.y + oy, s = crystalSize(c, r, w) + 0.5
                    Self.radial(ctx, shine.withAlphaComponent(dark ? 0.35 : 0.3).cgColor, at: CGPoint(x: cx, y: cy), radius: s * 1.6)
                    ctx.addPath(diamond(cx, cy, s)); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
                    if !dark { ctx.addPath(diamond(cx, cy, s)); ctx.setStrokeColor(mid.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.4); ctx.strokePath() }
                }
                ctx.restoreGState()
            }
            for (layer, salt) in [(self.twinkleA, 0), (self.twinkleB, 1)] {
                layer.contents = Self.bitmap(crownSize, scale: scale) { ctx in
                    ctx.setLineCap(.round)
                    for (c, r, p) in lattice where Self.noise(c * 2 + salt, r + 113) < 0.05 {
                        let cx = p.x + ox, cy = p.y + oy, arm = 2.2 + 1.2 * Self.noise(c, r + 117)
                        ctx.setStrokeColor((dark ? NSColor.white : mid).withAlphaComponent(dark ? 0.95 : 0.7).cgColor); ctx.setLineWidth(0.45)
                        ctx.move(to: CGPoint(x: cx - arm, y: cy)); ctx.addLine(to: CGPoint(x: cx + arm, y: cy))
                        ctx.move(to: CGPoint(x: cx, y: cy - arm)); ctx.addLine(to: CGPoint(x: cx, y: cy + arm)); ctx.strokePath()
                        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: CGRect(x: cx - 0.9, y: cy - 0.9, width: 1.8, height: 1.8))
                    }
                }
            }
            // A cluster of ice glints on the lattice: the ripple and the
            // full-cooling bloom. Vertically symmetric, so it is independent
            // of layer geometry flipping.
            self.bloom.contents = Self.bitmap(bloomSize, scale: scale) { ctx in
                ctx.setFillColor((dark ? NSColor.white : rime).cgColor)
                for dx in -reach...reach {
                    for dy in -lift...lift {
                        let d = (Double(dx * dx) / Double(reach * reach) + Double(dy * dy) / Double(lift * lift)).squareRoot()
                        guard d <= 1 else { continue }
                        let n = Double(Self.noise(abs(dx) + 17, abs(dy) + 31))
                        if d > 0.3 && n < d * 0.7 { continue }
                        ctx.setAlpha(CGFloat(pow(1 - d, 1.3) * (0.6 + 0.4 * n)))
                        Self.dot(ctx, at: CGPoint(x: CGFloat(dx + reach) * Metric.pitch + Metric.dot / 2, y: CGFloat(dy + lift) * Metric.pitch + Metric.dot / 2), size: Metric.dot)
                    }
                }
            }

            // The handle: a slim glass bar, white cooling toward the foot,
            // lit from the front with a specular streak, a cold glow at the
            // base and three grip ridges.
            let knob = Metric.thumb, pad = Metric.thumbPad
            let bar = CGRect(x: pad, y: pad, width: knob.width, height: knob.height)
            let body = CGSize(width: knob.width + 2 * pad, height: knob.height + 2 * pad)
            let barPath = CGPath(roundedRect: bar, cornerWidth: knob.width / 2, cornerHeight: knob.width / 2, transform: nil)
            self.thumbBody.contents = Self.bitmap(body, scale: scale) { ctx in
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 4 * scale, color: NSColor.black.withAlphaComponent(dark ? 0.6 : 0.3).cgColor)
                ctx.addPath(barPath); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState(); ctx.addPath(barPath); ctx.clip()
                let base = NSColor.white.blended(withFraction: dark ? 0.24 : 0.14, of: mid) ?? .white
                if let gradient = CGGradient(colorsSpace: space, colors: [NSColor.white.cgColor, base.cgColor] as CFArray, locations: [0.15, 1]) {
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bar.maxY), end: CGPoint(x: 0, y: bar.minY), options: [])
                }
                if let sides = CGGradient(colorsSpace: space, colors: [NSColor.black.withAlphaComponent(0.12).cgColor, NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.14).cgColor] as CFArray, locations: [0, 0.35, 0.65, 1]) {
                    ctx.drawLinearGradient(sides, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [])
                }
                Self.radial(ctx, mid.withAlphaComponent(dark ? 0.55 : 0.35).cgColor, at: CGPoint(x: bar.midX, y: bar.minY + 3), radius: 8)
                let streak = CGRect(x: bar.minX + 1.6, y: bar.midY - 2, width: 1.6, height: bar.height / 2 - 2)
                ctx.addPath(CGPath(roundedRect: streak, cornerWidth: 0.8, cornerHeight: 0.8, transform: nil)); ctx.clip()
                Self.vertical(ctx, NSColor.white.cgColor, from: (streak.maxY, 0.95), to: (streak.minY, 0))
                ctx.restoreGState()
                ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: 0.25, dy: 0.25), cornerWidth: knob.width / 2 - 0.25, cornerHeight: knob.width / 2 - 0.25, transform: nil))
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.45 : 0.22).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
                ctx.setLineCap(.round)
                for dy in [-3.0, 0, 3.0] as [CGFloat] {
                    let y = bar.midY + dy
                    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.8)
                    ctx.move(to: CGPoint(x: bar.midX - 1.6, y: y)); ctx.addLine(to: CGPoint(x: bar.midX + 1.6, y: y)); ctx.strokePath()
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(0.5)
                    ctx.move(to: CGPoint(x: bar.midX - 1.6, y: y - 0.7)); ctx.addLine(to: CGPoint(x: bar.midX + 1.6, y: y - 0.7)); ctx.strokePath()
                }
            }
            // Frozen handle: a glowing rime rim and a frosted cap.
            self.thumbFrost.contents = Self.bitmap(body, scale: scale) { ctx in
                ctx.saveGState(); ctx.addPath(barPath); ctx.clip()
                Self.vertical(ctx, (dark ? NSColor.white : rime).cgColor, from: (bar.maxY, dark ? 0.7 : 0.4), to: (bar.maxY - 11, 0))
                ctx.restoreGState()
                ctx.setShadow(offset: .zero, blur: 3.5 * scale, color: rime.withAlphaComponent(0.75).cgColor)
                ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), cornerWidth: knob.width / 2 - 0.5, cornerHeight: knob.width / 2 - 0.5, transform: nil))
                ctx.setStrokeColor(rime.cgColor); ctx.setLineWidth(1); ctx.strokePath()
            }
            self.halo.colors = [Theme.iceMid.withAlphaComponent(dark ? 0.5 : 0.3).cgColor, Theme.iceMid.withAlphaComponent(0).cgColor]
            self.measuredMark.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.6 : 0.5).cgColor
            self.floorTick.backgroundColor = Theme.ink.withAlphaComponent(dark ? 0.4 : 0.32).cgColor
        }
        for layer in [tray, dimDots, litDots, sparkDots, swell, frost, crown, crownGlint, bloom, thumbBody, thumbFrost, shimmer, twinkleA, twinkleB] { layer.contentsScale = scale }
        tray.frame = trayFrame
        dimDots.frame = grid; litDots.frame = grid
        dimMask.bounds = CGRect(x: 0, y: 0, width: grid.width, height: grid.height); dimMask.position = CGPoint(x: grid.width, y: grid.height / 2)
        litMask.bounds = CGRect(x: 0, y: 0, width: 0, height: grid.height); litMask.position = CGPoint(x: 0, y: grid.height / 2)
        sparkDots.frame = CGRect(origin: .zero, size: grid.size)
        headMask.bounds = CGRect(x: 0, y: 0, width: Metric.head, height: grid.height)
        swell.frame = CGRect(origin: .zero, size: grid.size)
        swellMask.bounds = CGRect(origin: .zero, size: Metric.lens)
        frost.frame = grid.insetBy(dx: 0, dy: -Metric.frostFringe)
        frostMask.bounds = CGRect(x: 0, y: 0, width: 0, height: frost.bounds.height); frostMask.position = CGPoint(x: 0, y: frost.bounds.height / 2)
        crown.frame = crownRect
        crownMask.frame = crown.bounds
        flowBox.frame = crown.bounds
        for layer in [shimmer, twinkleA, twinkleB] { layer.frame = crown.bounds }
        let flowing = loops.isRunning
        if flowing { loops.freeze() }
        let P = Metric.wavePeriod, span = crown.bounds.width + 2 * P
        shimmerMask.bounds = CGRect(x: 0, y: 0, width: span, height: crown.bounds.height); shimmerMask.position = .zero
        loops.setRest(shimmerMask, x: 0)
        // Soft bands of light, one per period, tileable for the scroll.
        var colors: [CGColor] = [], stops: [NSNumber] = []
        var band: CGFloat = P / 2
        while band < span {
            for (dx, a) in [(-P / 2, 0.0), (-16, 0.0), (-6, 0.55), (0, 1.0), (6, 0.55), (16, 0.0)] as [(CGFloat, CGFloat)] {
                let location = (band + dx) / span
                guard location >= 0, location <= 1, (stops.last?.doubleValue ?? -1) < Double(location) else { continue }
                colors.append(NSColor.black.withAlphaComponent(a).cgColor); stops.append(NSNumber(value: Double(location)))
            }
            band += P
        }
        shimmerMask.colors = colors; shimmerMask.locations = stops
        if flowing { loops.start(pace: IceFlow.pace(effects: effects)) }
        crownGlint.frame = crown.frame
        glintMask.bounds = CGRect(x: 0, y: 0, width: Metric.glintBand, height: crownGlint.bounds.height)
        glintMask.position = CGPoint(x: x(for: 100) - crownRect.minX, y: crownGlint.bounds.height / 2)
        halo.bounds = CGRect(x: 0, y: 0, width: 60, height: 46)
        measuredMark.bounds = CGRect(x: 0, y: 0, width: 2, height: grid.height + 6); measuredMark.cornerRadius = 1
        bloom.bounds = CGRect(origin: .zero, size: bloomSize); bloom.position = CGPoint(x: x(for: 100), y: grid.midY)
        floorTick.isHidden = floorValue <= 0
        floorTick.frame = CGRect(x: snap(x(for: floorValue) - Metric.pitch / 2), y: grid.minY - 5, width: 1, height: grid.height + 10)
        let knob = Metric.thumb, pad = Metric.thumbPad
        thumb.bounds = CGRect(origin: .zero, size: knob)
        tilt.bounds = thumb.bounds; tilt.position = CGPoint(x: knob.width / 2, y: knob.height / 2)
        thumbBody.bounds = CGRect(origin: .zero, size: CGSize(width: knob.width + 2 * pad, height: knob.height + 2 * pad)); thumbBody.position = tilt.position
        thumbFrost.bounds = thumbBody.bounds; thumbFrost.position = tilt.position
        CATransaction.commit()
        return true
    }

    // MARK: Placement and progressive decoration

    /// Moves handle, fill, frost reveal, head and halo together. Rime
    /// lowered by a drag melts back behind the handle instead of vanishing.
    override func place(animated: Bool, userAction: Bool) {
        let grid = gridRect, targetX = snap(x(for: value)), fill = max(0, targetX - grid.minX)
        let glide = animated && effects.animates && window != nil && abs((thumb.presentation() ?? thumb).position.x - targetX) > 0.5
        let frostShown = (frostMask.presentation() ?? frostMask).bounds.width
        let melting = !glide && dragging && effects.animates && effects.frost > 0 && window != nil && fill < frostShown - 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(thumb, "position", animated: glide) { thumb.position = CGPoint(x: targetX, y: grid.midY) }
        change(halo, "position", animated: glide) { halo.position = CGPoint(x: targetX, y: grid.midY) }
        change(litMask, "bounds", animated: glide) { litMask.bounds = CGRect(x: 0, y: 0, width: fill, height: grid.height) }
        change(dimMask, "bounds", animated: glide) { dimMask.bounds = CGRect(x: 0, y: 0, width: max(0, grid.width - fill), height: grid.height) }
        change(frostMask, "bounds", animated: glide || melting, duration: melting ? Metric.frostMelt : Metric.glide, timing: melting ? Theme.Ease.inOut : Theme.Ease.out) {
            frostMask.bounds = CGRect(x: 0, y: 0, width: fill, height: frost.bounds.height)
        }
        change(headMask, "position", animated: glide) { headMask.position = CGPoint(x: fill, y: grid.height / 2) }
        change(swellMask, "position", animated: glide) { swellMask.position = CGPoint(x: fill, y: grid.height / 2) }
        CATransaction.commit()
    }

    /// Intensities derived from the value: glow, head, lens, frost, the
    /// crystals and their flow. `userAction` distinguishes a person reaching full cooling
    /// from a model refresh (which never plays the formation).
    override func decorate(animated: Bool, userAction: Bool) {
        let energy = SliderEnergy.level(percent: value), amount = Frost.amount(percent: value)
        let interaction = dragging ? 1.0 : hovered ? 0.88 : 0.72
        let animate = animated && effects.animates && window != nil
        let crowned = Frost.crowned(percent: value) && effects.frost > 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change(halo, "opacity", animated: animate, duration: 0.25) { halo.opacity = Float(effects.glow * (0.12 + 0.88 * energy) * interaction) }
        change(halo, "transform", animated: animate, duration: 0.25) {
            let s = CGFloat(0.7 + 0.4 * energy + (dragging ? 0.1 : 0)); halo.transform = CATransform3DMakeScale(s, s, 1)
        }
        change(sparkDots, "opacity", animated: animate, duration: 0.25) { sparkDots.opacity = Float(effects.glow * (0.1 + 0.9 * energy) * interaction) }
        change(headMask, "transform", animated: animate, duration: 0.25) { headMask.transform = CATransform3DMakeScale(CGFloat(0.3 + energy), 1, 1) }
        // The lens: the dots under the handle bulge, more on hover and while
        // held. A drag shows it at once; a hover eases it in.
        let lens = Float(min(1, effects.glow * (0.25 + 0.35 * energy) * (dragging ? 1.6 : hovered ? 1.2 : 0.6)))
        if swell.opacity != lens { change(swell, "opacity", animated: animate, duration: 0.18) { swell.opacity = lens } }
        let strength = Float(IceFlow.strength(effects: effects))
        if flowBox.opacity != strength { change(flowBox, "opacity", animated: animate, duration: 0.3) { flowBox.opacity = strength } }
        let animateCrown = (animated || userAction && dragging) && effects.animates && window != nil
        // Loose hoarfrost consolidates into the crystals as they form.
        let consolidating = crowned != isIceFormed && animateCrown
        change(frost, "opacity", animated: animate || consolidating, duration: consolidating ? (crowned ? Metric.form : Metric.melt) : 0.3) {
            frost.opacity = Float(amount > 0 ? effects.frost * (0.3 + 0.7 * amount) * (crowned ? 0.55 : 1) : 0)
        }
        // A gliding handle (a click, preset or Smart) lands before the ice
        // forms around it; under a drag the handle is already there.
        if crowned != isIceFormed { setCrown(crowned, form: IceCover.forms(animated: animateCrown, allowed: effects.forms), animated: animateCrown, delay: animated ? glideDuration * 0.5 : 0) }
        else if crowned { crown.opacity = Float(effects.frost); thumbFrost.opacity = Float(effects.frost) }
        CATransaction.commit()
    }

    /// Forms (or melts) the crystals. The formed state is static artwork:
    /// model values hold it after any transition finishes.
    ///
    /// Formation (any crossing the person can see, `IceCover.forms`): a
    /// front of crystals crawls the whole lattice from the
    /// handle in growth spurts (`IceCover.crawl`) with a glint riding it; the
    /// glint then runs back to the handle, which frosts over. Melting starts
    /// from what is on screen: the front recedes toward the handle end while
    /// the crystals clear. Either direction can interrupt the other.
    private func setCrown(_ shown: Bool, form: Bool, animated: Bool, delay: CFTimeInterval = 0) {
        isIceFormed = shown
        let opacity = Float(shown ? effects.frost : 0)
        let thumbX = x(for: 100) - crown.frame.minX
        let shownCrown = crown.presentation() ?? crown
        let reach = shownCrown.opacity > 0.05 ? ((crownMask.presentation() ?? crownMask).locations?[1].doubleValue ?? 0) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        crownGlint.removeAllAnimations(); glintMask.removeAllAnimations(); crownGlint.opacity = 0
        if !shown { bloom.removeAllAnimations() }
        if shown { glintMask.position = CGPoint(x: thumbX, y: crownGlint.bounds.height / 2) }
        if shown && form {
            let from = shownCrown.opacity
            crown.opacity = opacity; crown.removeAllAnimations()
            thumbFrost.opacity = opacity; thumbFrost.removeAllAnimations()
            crownMask.removeAllAnimations(); crownMask.locations = [0, 1, 1]
            let crawl = IceCover.crawl(from: reach)
            let spread = CAKeyframeAnimation(keyPath: "locations")
            spread.values = crawl.map { [NSNumber(value: 0), NSNumber(value: $0.reach), NSNumber(value: min(1, $0.reach + 0.07))] as [NSNumber] }
            spread.keyTimes = crawl.map { NSNumber(value: $0.time) }
            spread.duration = Metric.form
            let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = from; appear.toValue = opacity; appear.duration = 0.14
            let out = Metric.form / Metric.formation
            let ride = CAKeyframeAnimation(keyPath: "position.x")
            ride.values = crawl.map { thumbX * CGFloat(1 - $0.reach) } + [0, thumbX]
            ride.keyTimes = (crawl.map { $0.time * out } + [out + 0.05, 1]).map { NSNumber(value: $0) }
            ride.duration = Metric.formation
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 0.9, 0.45, 0, 0, 1, 0].map { $0 * opacity }
            flash.keyTimes = [0, 0.06, out * 0.9, out, out + 0.06, 0.88, 1].map { NSNumber(value: $0) }
            flash.duration = Metric.formation
            let freeze = CABasicAnimation(keyPath: "opacity"); freeze.fromValue = 0; freeze.toValue = opacity
            freeze.duration = 0.24; freeze.timingFunction = Theme.Ease.out
            let start = CACurrentMediaTime() + delay
            for animation in [spread, appear, ride, flash] as [CAAnimation] { animation.beginTime = start; animation.fillMode = .backwards }
            freeze.beginTime = start + Metric.formation * 0.82; freeze.fillMode = .backwards
            crownMask.add(spread, forKey: "form"); crown.add(appear, forKey: "appear")
            glintMask.add(ride, forKey: "glint"); crownGlint.add(flash, forKey: "glint"); thumbFrost.add(freeze, forKey: "freeze")
        } else if shown {
            crownMask.removeAllAnimations(); crownMask.locations = [0, 1, 1]
            change(crown, "opacity", animated: animated, duration: 0.2) { crown.opacity = opacity }
            change(thumbFrost, "opacity", animated: animated, duration: 0.2) { thumbFrost.opacity = opacity }
        } else {
            let receded = [0, 0, 0.07].map { NSNumber(value: $0) }
            if animated && reach > 0 {
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
            change(thumbFrost, "opacity", animated: animated, duration: 0.3, timing: Theme.Ease.inOut) { thumbFrost.opacity = opacity }
            thumbFrost.removeAnimation(forKey: "freeze")
        }
        CATransaction.commit()
    }

    override func placeMeasured(visible: Bool, animated: Bool) {
        guard bounds.width > 4 * Metric.inset else { return }
        let grid = gridRect
        let animate = animated && effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Pixel-snapped, so sample-to-sample RPM jitter usually leaves the
        // mark where it is and adds no animation.
        if let measured = host.measuredPercent, measured.isFinite {
            let position = CGPoint(x: snap(x(for: measured)), y: grid.midY)
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

    // MARK: Handle and reactions

    /// Rest, hover and held shapes. A grab squashes the handle and flashes
    /// the head before it settles into its held shape; a release springs
    /// back with a little overshoot. Both start from what is on screen.
    override func shapeThumb(_ gesture: ThumbGesture) {
        let target = dragging ? CATransform3DMakeScale(1.3, 1.06, 1) : hovered && isEnabled ? CATransform3DMakeScale(1.14, 1.03, 1) : CATransform3DIdentity
        let restOpacity: Float = hovered || dragging ? 1 : 0.82
        let animate = effects.animates && window != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let from = (thumb.presentation() ?? thumb).transform
        switch gesture {
        case .grab where animate:
            thumb.transform = target
            let squash = CAKeyframeAnimation(keyPath: "transform")
            squash.values = [from, CATransform3DMakeScale(1.5, 0.9, 1), target].map { NSValue(caTransform3D: $0) }
            squash.keyTimes = [0, 0.35, 1]; squash.duration = 0.24; squash.timingFunction = Theme.Ease.out
            thumb.add(squash, forKey: "transform")
            if effects.glow > 0 { flare(sparkDots, by: 0.4, duration: 0.32) }
        case .release where animate:
            thumb.transform = target
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1; spring.stiffness = 420; spring.damping = 13
            spring.fromValue = NSValue(caTransform3D: from); spring.toValue = NSValue(caTransform3D: target)
            spring.duration = spring.settlingDuration
            thumb.add(spring, forKey: "transform")
        default:
            change(thumb, "transform", animated: animate, duration: 0.15) { thumb.transform = target }
        }
        change(dimDots, "opacity", animated: animate, duration: 0.15) { dimDots.opacity = restOpacity }
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
        let gain = effects.motion, intensity = SliderMotion.intensity(velocity: velocity), direction: CGFloat = velocity < 0 ? -1 : 1
        guard gain > 0, intensity > 0.01 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let swing = CASpringAnimation(keyPath: "transform.rotation.z")
        swing.isAdditive = true; swing.fromValue = SliderMotion.lean(velocity: velocity, gain: gain); swing.toValue = 0
        swing.mass = 1; swing.stiffness = 260; swing.damping = 11; swing.duration = swing.settlingDuration
        tilt.add(swing, forKey: "surge.lean")
        let stretch = SliderMotion.stretch(velocity: velocity, gain: gain)
        decay(tilt, "transform.scale.x", from: stretch, duration: 0.36, key: "surge.stretch")
        decay(tilt, "transform.scale.y", from: -0.25 * stretch, duration: 0.36, key: "surge.squash")
        decay(headMask, "transform.scale.x", from: SliderMotion.surge(velocity: velocity, gain: gain), duration: 0.5, key: "surge")
        decay(halo, "opacity", from: 0.3 * intensity * effects.glow, duration: 0.5, key: "surge")
        let slosh = CASpringAnimation(keyPath: "position.x")
        slosh.isAdditive = true; slosh.fromValue = -direction * Metric.slosh * CGFloat(intensity * gain); slosh.toValue = 0
        slosh.mass = 1; slosh.stiffness = 220; slosh.damping = 10; slosh.duration = slosh.settlingDuration
        sparkDots.add(slosh, forKey: "surge.slosh")
        CATransaction.commit()
    }

    private func decay(_ layer: CALayer, _ keyPath: String, from amount: Double, duration: CFTimeInterval, key: String) {
        guard amount.isFinite, abs(amount) > 0.002 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.isAdditive = true; animation.fromValue = amount; animation.toValue = 0
        animation.duration = duration; animation.timingFunction = Theme.Ease.out
        layer.add(animation, forKey: key)
    }

    /// A ring of glints spreading through the dots: grabs, releases and
    /// preset stops.
    override func ripple(at percent: Double, strength: Double, wide: Bool) {
        guard effects.wake, window != nil, renderedScale > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bloom.removeAllAnimations()
        bloom.position = CGPoint(x: snap(x(for: percent)), y: gridRect.midY)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.4; grow.toValue = wide ? 1.25 : 0.9
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, min(1, strength) * 0.8 * effects.glow, 0]; fade.keyTimes = [0, 0.15, 1]
        let group = CAAnimationGroup(); group.animations = [grow, fade]
        group.duration = wide ? 0.6 : 0.42; group.timingFunction = Theme.Ease.out
        bloom.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    override func interrupt() {
        headMask.removeAnimation(forKey: "sweep"); sparkDots.removeAnimation(forKey: "sweep")
        if value < 100 { bloom.removeAnimation(forKey: "bloom") }
    }

    /// Acknowledges a pointer release: a short pulse of light runs from the
    /// handle back along the lit dots toward the fan's floor.
    override func sweep() {
        guard effects.sweep, window != nil, value > minimumPercent + 1 else { return }
        let current = (sparkDots.presentation() ?? sparkDots).opacity
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = headMask.position.x; travel.toValue = -Metric.head * 0.2
        travel.duration = 0.55; travel.timingFunction = Theme.Ease.out
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [current, min(1, current + 0.55), current]; flash.keyTimes = [0, 0.22, 1]; flash.duration = 0.55
        headMask.add(travel, forKey: "sweep"); sparkDots.add(flash, forKey: "sweep")
    }

    /// A bloom of ice glints at the handle when a user action reaches 100%:
    /// on Expressive it closes the formation (when the returning glint
    /// frosts the handle), on Subtle it is the whole acknowledgement.
    /// Skipped for keyboard changes and with Reduce Motion.
    override func celebrate(animated: Bool, delay: CFTimeInterval) {
        guard animated, effects.bloom, window != nil else { return }
        let formed = effects.forms && isIceFormed
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bloom.removeAllAnimations()
        bloom.position = CGPoint(x: x(for: 100), y: gridRect.midY)
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0.0, 1.0, 0.0]; fade.keyTimes = [0, 0.18, 1]
        let spread = CAKeyframeAnimation(keyPath: "transform.scale"); spread.values = [0.55, 1.0, formed ? 1.3 : 1.15]; spread.keyTimes = [0, 0.35, 1]
        let group = CAAnimationGroup(); group.animations = [fade, spread]; group.duration = formed ? 0.62 : 0.48
        group.timingFunction = Theme.Ease.out
        if formed { group.beginTime = CACurrentMediaTime() + delay + Metric.formation * 0.82; group.fillMode = .backwards }
        bloom.add(group, forKey: "bloom")
        CATransaction.commit()
    }

    // MARK: Drawing helpers

    /// One rounded lattice dot centred on `point`.
    private static func dot(_ ctx: CGContext, at point: CGPoint, size: CGFloat) {
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.36, cornerHeight: size * 0.36, transform: nil)); ctx.fillPath()
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
    private static func fade(_ ctx: CGContext, width: CGFloat, stops: [(CGFloat, Double)]) {
        guard width > 0, stops.count > 1,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: stops.map { NSColor.black.withAlphaComponent(CGFloat(max(0, min(1, $0.1)))).cgColor } as CFArray,
                                        locations: stops.map { max(0, min(1, $0.0 / width)) }) else { return }
        ctx.saveGState(); ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}
