import AppKit
import QuartzCore

/// The Channel's small, fixed row of miniature fan rotors, turning in
/// proportion to the real fan's measured RPM (`RotorMotion`).
///
/// Cost model: one cached rotor bitmap shared by every rotor layer, at most
/// a dozen layers, and one repeating Core Animation rotation per rotor that
/// the render server runs on its own. The rate lives on a shared `clock`
/// layer's `speed`; changing it re-bases the clock's time so the phase
/// carries on without a jump. No display link, no timer, no per-frame Swift.
///
/// `freeze()` stops the motion where it is: each rotor's on-screen angle
/// becomes its model angle and the animation is removed, so stopping and
/// resuming never flashes or snaps.
@MainActor final class RotorField {
    /// Add this to the skin's layer tree; the skin positions it.
    let container = CALayer()
    private let clock = CALayer()
    private(set) var rotors: [CALayer] = []
    /// Revolutions per second while spinning, else 0.
    private(set) var rate: Double = 0
    var isSpinning: Bool { rotors.first?.animation(forKey: Self.spinKey) != nil }
    private static let spinKey = "spin"

    init() {
        container.addSublayer(clock)
        clock.anchorPoint = .zero
    }

    /// Places rotors of `diameter` at `centers` (container coordinates),
    /// drawing all of them with one shared `image`. Reuses existing layers;
    /// new ones start at staggered angles so the row never looks in lockstep.
    func layout(image: CGImage?, diameter: CGFloat, centers: [CGPoint], scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clock.frame = container.bounds
        while rotors.count > centers.count { rotors.removeLast().removeFromSuperlayer() }
        while rotors.count < centers.count {
            let rotor = CALayer()
            rotor.contentsGravity = .resize
            rotor.transform = CATransform3DMakeRotation(Self.phase(rotors.count), 0, 0, 1)
            clock.addSublayer(rotor); rotors.append(rotor)
        }
        for (rotor, centre) in zip(rotors, centers) {
            rotor.contents = image; rotor.contentsScale = scale
            rotor.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            rotor.position = centre
            // A rotor added to a running row joins it.
            if rate > 0, rotor.animation(forKey: Self.spinKey) == nil { rotor.add(Self.turn(), forKey: Self.spinKey) }
        }
        CATransaction.commit()
    }

    /// Spins at `rps` revolutions per second (0 freezes). Retargeting a
    /// running row keeps every rotor's phase.
    func spin(at rps: Double) {
        guard rps.isFinite, rps > 0, !rotors.isEmpty else { freeze(); return }
        // Sample-to-sample jitter in the measurement changes nothing.
        if isSpinning && abs(rps - rate) < 0.01 { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !isSpinning {
            clock.speed = 1; clock.timeOffset = 0; clock.beginTime = 0
            for rotor in rotors { rotor.add(Self.turn(), forKey: Self.spinKey) }
        }
        let now = CACurrentMediaTime()
        let local = clock.convertTime(now, from: nil)
        clock.beginTime = now; clock.timeOffset = local; clock.speed = Float(rps)
        rate = rps
        CATransaction.commit()
    }

    /// Stops where the rotors are now, without a snap.
    func freeze() {
        guard isSpinning else { rate = 0; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for rotor in rotors {
            let angle = (rotor.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue
                ?? (rotor.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
            rotor.transform = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
            rotor.removeAnimation(forKey: Self.spinKey)
        }
        clock.speed = 1; clock.timeOffset = 0; clock.beginTime = 0
        rate = 0
        CATransaction.commit()
    }

    /// Repeating animations currently attached (lifecycle tests).
    var animationCount: Int { rotors.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) } }
    /// Read-only probe: the first rotor's angle as rendered right now (its
    /// presentation layer, radians in (−π, π]), or nil before the layer has
    /// been committed. Tests sample it over time to prove actual motion.
    var shownAngle: Double? {
        guard let shown = rotors.first?.presentation() else { return nil }
        let t = shown.transform
        return atan2(Double(t.m12), Double(t.m11))
    }

    private static func phase(_ index: Int) -> CGFloat { CGFloat(index) * 1.9 }
    /// One turn per clock second, additive on top of the model angle (the
    /// stagger, or where a previous run froze).
    private static func turn() -> CABasicAnimation {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = 2 * Double.pi; turn.isAdditive = true
        turn.duration = 1; turn.repeatCount = .greatestFiniteMagnitude
        return turn
    }

    // MARK: Artwork

    /// A miniature fan rotor: hub, ring and `blades` swept blades, drawn once
    /// per size, scale and appearance and shared by every rotor in a row.
    static func rotorImage(diameter: CGFloat, scale: CGFloat, blades: Int, blade: CGColor, edge: CGColor, hub: CGColor) -> CGImage? {
        SliderSkin.bitmap(CGSize(width: diameter, height: diameter), scale: scale) { ctx in
            let c = CGPoint(x: diameter / 2, y: diameter / 2), r = diameter / 2 - 0.6
            ctx.setLineJoin(.round)
            for i in 0..<blades {
                let a = CGFloat(i) / CGFloat(blades) * 2 * .pi
                let path = CGMutablePath()
                // A swept blade: leading edge curves forward, trailing edge back.
                func p(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a + angle) * radius, y: c.y + sin(a + angle) * radius) }
                path.move(to: p(r * 0.28, -0.32))
                path.addQuadCurve(to: p(r * 0.98, 0.18), control: p(r * 0.72, -0.42))
                path.addQuadCurve(to: p(r * 0.86, 0.62), control: p(r * 1.02, 0.44))
                path.addQuadCurve(to: p(r * 0.28, 0.42), control: p(r * 0.58, 0.58))
                path.closeSubpath()
                ctx.addPath(path); ctx.setFillColor(blade); ctx.fillPath()
                ctx.addPath(path); ctx.setStrokeColor(edge); ctx.setLineWidth(0.5); ctx.strokePath()
            }
            ctx.setFillColor(hub)
            ctx.fillEllipse(in: CGRect(x: c.x - r * 0.3, y: c.y - r * 0.3, width: r * 0.6, height: r * 0.6))
            ctx.setStrokeColor(edge); ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.3, y: c.y - r * 0.3, width: r * 0.6, height: r * 0.6))
        }
    }
}

/// A fixed set of repeating Core Animation loops (the full-cooling flow)
/// that start together and freeze in place together.
///
/// Every loop is additive on its layer's model value and repeats forever on
/// the render server; there is no timer or per-frame code. `freeze()` copies
/// what is on screen into the model and removes the loops, so stopping never
/// jumps. A scrolling loop declares its tile `period`, and the frozen offset
/// is wrapped into one period (its artwork repeats every period), so the
/// offset never accumulates however often it stops and resumes.
@MainActor final class LoopSet {
    private struct Loop { let layer: CALayer; let keyPath: String; let period: CGFloat?; let duration: CFTimeInterval; var direction: CGFloat = -1; let make: (Double) -> CAAnimation }
    private var loops: [Loop] = []
    private var rests: [ObjectIdentifier: CGFloat] = [:]
    private var pace: Double = 1
    private static let key = "loop"

    /// A scrolling loop: moves `layer` by one `period` along x every
    /// `duration` seconds (scaled by the pace given to `start`), toward the
    /// start of the track by default (`direction` −1) or the handle (+1).
    func scroll(_ layer: CALayer, period: CGFloat, duration: CFTimeInterval, direction: CGFloat = -1) {
        loops.append(Loop(layer: layer, keyPath: "position.x", period: period, duration: duration, direction: direction < 0 ? -1 : 1) { pace in
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = 0; move.toValue = (direction < 0 ? -1 : 1) * period; move.isAdditive = true
            move.duration = duration * pace; move.repeatCount = .greatestFiniteMagnitude
            return move
        })
    }
    /// A breathing loop on opacity: up by `amount` and back every `duration`
    /// seconds, starting `phase` (0…1) of the way through its cycle.
    func breathe(_ layer: CALayer, amount: Double, duration: CFTimeInterval, phase: Double) {
        loops.append(Loop(layer: layer, keyPath: "opacity", period: nil, duration: duration) { pace in
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0, amount, 0]; pulse.keyTimes = [0, 0.5, 1]; pulse.isAdditive = true
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            pulse.duration = duration * pace; pulse.repeatCount = .greatestFiniteMagnitude
            pulse.timeOffset = phase * duration * pace
            return pulse
        })
    }
    /// The rest position of scrolling layers (set when the skin lays out).
    func setRest(_ layer: CALayer, x: CGFloat) { rests[ObjectIdentifier(layer)] = x }

    var isRunning: Bool { loops.first.map { $0.layer.animation(forKey: Self.key) != nil } ?? false }

    /// Read-only probe of one loop as rendered right now: its key path, its
    /// presentation value (nil before the layer has been committed), its tile
    /// period (scrolls) and the velocity it should move at with the current
    /// pace (scrolls, points per second; nil for breathing loops). Tests
    /// sample these over time to prove actual motion, not mere attachment.
    struct Probe { let keyPath: String; let shown: Double?; let period: CGFloat?; let velocity: CGFloat? }
    var probes: [Probe] {
        loops.map { loop in
            let shown = (loop.layer.presentation()?.value(forKeyPath: loop.keyPath) as? NSNumber)?.doubleValue
            let velocity = loop.period.flatMap { period in loop.duration > 0 ? loop.direction * period / CGFloat(loop.duration * pace) : nil }
            return Probe(keyPath: loop.keyPath, shown: shown, period: loop.period, velocity: velocity)
        }
    }
    var animationCount: Int { loops.reduce(0) { $0 + ($1.layer.animation(forKey: Self.key) == nil ? 0 : 1) } }
    /// The pace the loops run at (or last ran at).
    var currentPace: Double { pace }

    /// Starts every loop (idempotent). `pace` scales every duration; a new
    /// pace (Expressive ↔ Subtle) re-times the loops from where they are.
    func start(pace: Double) {
        guard !loops.isEmpty else { return }
        if isRunning { guard pace != self.pace else { return }; freeze() }
        self.pace = pace
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for loop in loops { loop.layer.add(loop.make(pace), forKey: Self.key) }
        CATransaction.commit()
    }
    /// Stops where it is now, without a jump.
    func freeze() {
        guard isRunning else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for loop in loops {
            let shown = (loop.layer.presentation() ?? loop.layer).value(forKeyPath: loop.keyPath) as? NSNumber
            loop.layer.removeAnimation(forKey: Self.key)
            guard let value = shown.map({ CGFloat($0.doubleValue) }) else { continue }
            if let period = loop.period, period > 0 {
                let rest = rests[ObjectIdentifier(loop.layer)] ?? loop.layer.position.x
                var offset = (value - rest).truncatingRemainder(dividingBy: period)
                if offset > 0 { offset -= period }
                loop.layer.position.x = rest + offset
            } else if loop.keyPath == "opacity" {
                // The breathing layer keeps its resting opacity; a sparse
                // twinkle settling by a fraction is not a visible jump.
                continue
            } else {
                loop.layer.setValue(value, forKeyPath: loop.keyPath)
            }
        }
        CATransaction.commit()
    }
}
