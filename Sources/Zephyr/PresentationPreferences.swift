import Foundation

// Presentation-only state: how Aervane looks, never what it does to the fan.
// Foundation-only so the logic is testable without AppKit.

enum MenuBarContent: String, CaseIterable {
    case iconAndTemperature, temperature, icon
    var showsIcon: Bool { self != .temperature }
    var showsTemperature: Bool { self != .icon }
    var title: String {
        switch self {
        case .iconAndTemperature: return "Both"
        case .temperature: return "Temperature"
        case .icon: return "Icon"
        }
    }
}

enum MenuBarSpacing: String, CaseIterable {
    case compact, comfortable
    /// Horizontal padding on each side of the status item content, in points.
    var padding: Double { self == .compact ? 4 : 8 }
    var title: String { self == .compact ? "Compact" : "Comfortable" }
}

enum EffectsLevel: String, CaseIterable {
    case off, subtle, expressive
    var title: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .expressive: return "Expressive"
        }
    }
}

/// How the cooling slider is drawn. Presentation only: both styles are the
/// same control with the same values, hardware floor, measured mark, input
/// and commits. Choosing one never sends anything to the fan.
enum SliderStyle: String, CaseIterable {
    /// A coolant channel with a glass thumb.
    case channel
    /// The original lattice of dots with a slim white handle.
    case dotGrid
    var title: String { self == .channel ? "Channel" : "Dot Grid" }
    /// Thumb centre for a value in a slider of the given width.
    func x(percent: Double, width: CGFloat) -> CGFloat {
        self == .channel ? SliderGeometry.x(percent: percent, width: width) : DotGridGeometry.x(percent: percent, width: width)
    }
    /// Value under a point (unclamped; the control applies its floor).
    func percent(atX x: CGFloat, width: CGFloat) -> Double {
        self == .channel ? SliderGeometry.percent(atX: x, width: width) : DotGridGeometry.percent(atX: x, width: width)
    }
    /// Height the panel gives the control. The Dot Grid keeps its original
    /// 34 pt; the Channel's thick tube, knob and rime need more.
    var frameHeight: CGFloat { self == .channel ? SliderGeometry.frameHeight : DotGridGeometry.frameHeight }
}

/// What the interface may draw and animate right now. The user's level sets
/// the ceiling; Reduce Motion and Reduce Transparency always lower it.
struct EffectsProfile: Equatable {
    /// Static light intensity (slider glow, spark head), 0...1.
    let glow: Double
    /// Temperature aura intensity behind the reading, 0...1.
    let aura: Double
    /// Continuity transitions: glide, mode pill, inline settings, press.
    let animates: Bool
    /// Number roll on temperature changes.
    let rolls: Bool
    /// Light sweep that acknowledges a pointer release.
    let sweep: Bool
    /// One-shot crystal burst when a user action reaches 100%.
    let bloom: Bool
    /// Static frost artwork intensity on the cooling slider, 0...1.
    let frost: Double
    /// The authored ice-formation reveal at maximum cooling. Without it the
    /// ice simply appears (Subtle) or is absent (Off).
    let forms: Bool
    /// How strongly the slider answers drag speed (thumb lean and stretch,
    /// energy surge), 0...1. Zero with Reduce Motion.
    let motion: Double
    /// Speed wake behind a moving thumb and ripples on grab, release and
    /// preset detents. Expressive only.
    let wake: Bool
    /// Continuous ambient motion, 0...1: whether the Channel's rotors turn
    /// and the full-cooling ice flows, and how present that flow is (Subtle
    /// is calmer and fainter). Rotor *speed* never depends on it: it always
    /// follows the real fan. Zero with Effects Off or Reduce Motion.
    let ambient: Double

    init(level: EffectsLevel, reduceMotion: Bool, reduceTransparency: Bool) {
        let light: Double = reduceTransparency ? 0.5 : 1
        switch level {
        case .off: glow = 0; aura = 0; frost = 0; motion = 0; ambient = 0
        case .subtle: glow = 0.55 * light; aura = 0.6 * light; frost = 0.6 * light; motion = reduceMotion ? 0 : 0.45; ambient = reduceMotion ? 0 : 0.55
        case .expressive: glow = 1 * light; aura = 1 * light; frost = 1 * light; motion = reduceMotion ? 0 : 1; ambient = reduceMotion ? 0 : 1
        }
        animates = !reduceMotion
        rolls = !reduceMotion && level != .off
        sweep = !reduceMotion && level == .expressive
        bloom = !reduceMotion && level != .off
        forms = !reduceMotion && level == .expressive
        wake = !reduceMotion && level == .expressive
    }
}

/// Coarse temperature bands for presentation. They describe the reading;
/// they never gate control.
enum ThermalState: Int, CaseIterable, Comparable {
    case unknown, cool, steady, warm, hot, peak

    /// Lower bound in °C of each band above `cool`.
    static let lowerBounds: [ThermalState: Double] = [.steady: 55, .warm: 70, .hot: 82, .peak: 92]

    static func < (a: ThermalState, b: ThermalState) -> Bool { a.rawValue < b.rawValue }

    /// Classifies a Celsius reading. A falling reading keeps the previous
    /// band until it is `hysteresis` below that band's bound, so a value
    /// hovering at a boundary does not flicker between states.
    static func classify(_ celsius: Double?, previous: ThermalState = .unknown, hysteresis: Double = 1.5) -> ThermalState {
        guard let celsius, celsius.isFinite else { return .unknown }
        let raw = ([ThermalState.peak, .hot, .warm, .steady].first { celsius >= lowerBounds[$0]! }) ?? .cool
        guard previous != .unknown, previous != .cool, raw < previous, let bound = lowerBounds[previous] else { return raw }
        return celsius > bound - hysteresis ? previous : raw
    }

    var accessibilityName: String {
        switch self {
        case .unknown: return "no reading"
        case .cool: return "cool"
        case .steady: return "normal"
        case .warm: return "warm"
        case .hot: return "hot"
        case .peak: return "very hot"
        }
    }
}

/// Persisted presentation choices. Every key lives here; components read
/// typed values and observe `didChange`.
final class PresentationPreferences {
    static let didChange = Notification.Name("dev.kirniy.aervane.presentationPreferencesDidChange")
    static let shared = PresentationPreferences()

    enum Key {
        static let menuBarContent = "presentation.menuBarContent"
        static let menuBarSpacing = "presentation.menuBarSpacing"
        static let effects = "presentation.effects"
        static let heatColor = "presentation.heatColor"
        static let sliderStyle = "presentation.sliderStyle"
    }

    private let defaults: UserDefaults
    private let center: NotificationCenter

    var menuBarContent: MenuBarContent { didSet { store(menuBarContent.rawValue, Key.menuBarContent, changed: menuBarContent != oldValue) } }
    var menuBarSpacing: MenuBarSpacing { didSet { store(menuBarSpacing.rawValue, Key.menuBarSpacing, changed: menuBarSpacing != oldValue) } }
    var effects: EffectsLevel { didSet { store(effects.rawValue, Key.effects, changed: effects != oldValue) } }
    /// Colours the temperature (panel and menu bar) by thermal band.
    var heatColor: Bool { didSet { store(heatColor, Key.heatColor, changed: heatColor != oldValue) } }
    /// How the cooling slider is drawn.
    var sliderStyle: SliderStyle { didSet { store(sliderStyle.rawValue, Key.sliderStyle, changed: sliderStyle != oldValue) } }

    init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults; self.center = center
        menuBarContent = defaults.string(forKey: Key.menuBarContent).flatMap(MenuBarContent.init(rawValue:)) ?? .iconAndTemperature
        menuBarSpacing = defaults.string(forKey: Key.menuBarSpacing).flatMap(MenuBarSpacing.init(rawValue:)) ?? .compact
        effects = defaults.string(forKey: Key.effects).flatMap(EffectsLevel.init(rawValue:)) ?? .expressive
        heatColor = defaults.object(forKey: Key.heatColor) as? Bool ?? true
        sliderStyle = defaults.string(forKey: Key.sliderStyle).flatMap(SliderStyle.init(rawValue:)) ?? .dotGrid
    }

    private func store(_ value: Any, _ key: String, changed: Bool) {
        defaults.set(value, forKey: key)
        if changed { center.post(name: Self.didChange, object: self) }
    }
}

/// Status item sizing from measured content, so the item hugs its content
/// with a small native margin instead of a fixed width.
enum StatusItemLayout {
    /// Reading shown in the menu bar: digits and a degree sign, no padding
    /// characters. "—" when there is no fresh reading.
    static func title(temperatureText: String) -> String { "\(temperatureText)°" }

    /// Width reserved for the title so two-digit readings never shift the
    /// menu bar; wider readings (e.g. 104°F) grow it.
    static let reservedTitle = "88°"

    static func length(content: MenuBarContent, spacing: MenuBarSpacing, iconWidth: Double, titleWidth: Double, gap: Double = 3) -> Double {
        var width = 0.0
        if content.showsIcon { width += iconWidth }
        if content.showsTemperature { width += titleWidth }
        if content.showsIcon && content.showsTemperature { width += gap }
        return (width + 2 * spacing.padding).rounded(.up)
    }
}

/// How much "energy" the slider shows at a value: coolant brightness,
/// streamline density, head length and glow all scale from this one curve,
/// so effects intensify progressively and consistently with speed.
enum SliderEnergy {
    static func level(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return pow(max(0, min(1, percent / 100)), 1.6)
    }
    /// Lit dot diameter for a column at `percent` (Dot Grid; resting dots are 2 pt).
    static func dotSize(percent: Double) -> Double { 1.7 + 0.7 * level(percent: percent) }
    /// Coolant colour at a value as weights of the three ice tones (mint,
    /// glacier cyan, ice white). The weights sum to 1; the ramp reaches cyan
    /// at 60% and ice at 100%.
    static func tone(percent: Double) -> (low: Double, mid: Double, high: Double) {
        let t = percent.isFinite ? max(0, min(1, percent / 100)) : 0
        if t < 0.6 { let f = t / 0.6; return (1 - f, f, 0) }
        let f = (t - 0.6) / 0.4
        return (0, 1 - f, f)
    }
    /// Coolant opacity: thin at the firmware floor, dense at full cooling.
    static func coolant(percent: Double) -> Double { 0.5 + 0.46 * pow(percent.isFinite ? max(0, min(1, percent / 100)) : 0, 0.9) }
}

/// Where things sit on the cooling slider. Pure geometry, so the owner can
/// align the floor mark before layout and the mapping is testable.
enum SliderGeometry {
    /// Room at both ends for the halo, ripples and rim crystals.
    static let inset: CGFloat = 16
    /// The glass tube the coolant runs in.
    static let channelHeight: CGFloat = 28
    /// The knob stands 5 pt proud of the tube above and below.
    static let thumb = CGSize(width: 20, height: 38)
    /// Control height in the panel: the tube plus room for rime and crystals.
    static let frameHeight: CGFloat = 52
    /// Coolant sits inside the glass wall, inset this much from the tube.
    static let wall: CGFloat = 3
    /// Etched scale marks, in percent; the middle one is longer.
    static let ticks: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90]

    static func channel(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + inset, y: bounds.minY + ((bounds.height - channelHeight) / 2).rounded(.down),
               width: max(0, bounds.width - 2 * inset), height: channelHeight)
    }
    /// Thumb centre for a value. The thumb stays inside the channel at both
    /// ends, so 0% and 100% are where its edges meet the channel caps.
    static func x(percent: Double, width: CGFloat) -> CGFloat {
        let t = percent.isFinite ? max(0, min(1, percent / 100)) : 0
        return inset + thumb.width / 2 + CGFloat(t) * travel(width: width)
    }
    /// Value under a point (unclamped; the control applies its floor).
    static func percent(atX x: CGFloat, width: CGFloat) -> Double {
        Double((x - inset - thumb.width / 2) / travel(width: width)) * 100
    }
    static func travel(width: CGFloat) -> CGFloat { max(1, width - 2 * inset - thumb.width) }

    /// Miniature rotors inside the coolant: diameter and evenly spaced
    /// centres along the channel (channel-local x, centred vertically).
    static let rotorDiameter: CGFloat = 16
    static let rotorPitch: CGFloat = 34
    static func rotorCenters(channelWidth width: CGFloat) -> [CGPoint] {
        let usable = width - channelHeight
        guard usable > rotorPitch else { return [] }
        let count = Int((usable / rotorPitch).rounded(.down)) + 1
        let step = usable / CGFloat(max(1, count - 1))
        return (0..<count).map { CGPoint(x: channelHeight / 2 + CGFloat($0) * step, y: channelHeight / 2) }
    }
}

/// The Dot Grid's geometry: seven rows of 2.6 pt dots on a 4 pt pitch,
/// centred in a 50 pt frame with 16 pt of room at both ends. The thumb centre
/// sits on a column centre at 0% and 100%.
enum DotGridGeometry {
    static let dot: CGFloat = 2.6, pitch: CGFloat = 4, rows = 7
    static let inset: CGFloat = 16
    static let thumb = CGSize(width: 9, height: 38)
    static let frameHeight: CGFloat = 50

    static func columns(width: CGFloat) -> Int { max(2, Int(((width - 2 * inset - dot) / pitch).rounded(.down)) + 1) }
    /// The lattice inside bounds at the origin (as the control lays it out).
    static func grid(width: CGFloat, height: CGFloat) -> CGRect {
        let w = CGFloat(columns(width: width) - 1) * pitch + dot
        let h = CGFloat(rows - 1) * pitch + dot
        return CGRect(x: ((width - w) / 2).rounded(.down), y: ((height - h) / 2).rounded(.down), width: w, height: h)
    }
    static func x(percent: Double, width: CGFloat) -> CGFloat {
        let grid = grid(width: width, height: 1), t = percent.isFinite ? max(0, min(100, percent)) / 100 : 0
        return grid.minX + dot / 2 + CGFloat(t) * (grid.width - dot)
    }
    static func percent(atX x: CGFloat, width: CGFloat) -> Double {
        let grid = grid(width: width, height: 1)
        return Double((x - grid.minX - dot / 2) / max(1, grid.width - dot)) * 100
    }
}

/// The Channel's miniature rotors turn in proportion to the fan's *actual*
/// speed: the measured RPM from the hardware, never the slider, the target
/// or Smart's request, so they spin up and down with the real rotor.
///
/// Scale: one visual revolution per second for every `rpmPerTurn` RPM, so
/// the rotors turn at 1/33 of the real fan (`RPM / 2000` rev/s: 1200 RPM →
/// 0.6 rev/s, 4900 RPM → 2.45 rev/s). A literal 1000–4900 RPM (17–82 rev/s)
/// would alias on a 60/120 Hz display; at this scale a five-blade rotor
/// turns at most 24° per 60 Hz frame (under the 36° aliasing limit of its
/// 72° symmetry) up to the `fastest` guard. Zero RPM stands still. The same
/// scale applies at every effects level; intensity changes appearance only.
enum RotorMotion {
    static let rpmPerTurn = 2000.0
    /// Ceiling in rev/s (8000 RPM, beyond any Mac fan): guards against
    /// implausible telemetry and aliasing.
    static let fastest = 4.0

    static func revolutionsPerSecond(rpm: Double?) -> Double {
        guard let rpm, rpm.isFinite, rpm > 0 else { return 0 }
        return min(fastest, rpm / rpmPerTurn)
    }
    /// Spinning needs a visible panel, an enabled control with fresh
    /// telemetry, a turning fan and motion allowed by Effects and Reduce
    /// Motion.
    static func spins(visible: Bool, enabled: Bool, available: Bool, rpm: Double?, effects: EffectsProfile) -> Bool {
        visible && enabled && available && effects.ambient > 0 && revolutionsPerSecond(rpm: rpm) > 0
    }
}

/// The continuous full-cooling motion: at 100% the ice keeps flowing (cold
/// currents and glints in the Channel, light rolling through the crystal
/// lattice in the Dot Grid). Bounded compositor loops that run only while
/// the panel is visible, the control is enabled with fresh data, the ice is
/// formed, and Effects allow motion; otherwise they freeze in place.
enum IceFlow {
    static func runs(visible: Bool, enabled: Bool, available: Bool, frozen: Bool, effects: EffectsProfile) -> Bool {
        visible && enabled && available && frozen && effects.ambient > 0 && effects.frost > 0
    }
    /// Time scale for every loop: 1 on Expressive, longer (calmer) on Subtle.
    static func pace(effects: EffectsProfile) -> Double { 1 / max(0.3, min(1, effects.ambient)) }
    /// How present the flow is (opacity), 0...1.
    static func strength(effects: EffectsProfile) -> Double { max(0, min(1, effects.ambient)) * (0.5 + 0.5 * max(0, min(1, effects.frost))) }
}

/// The Dot Grid's life at every speed: a soft wave of light travelling
/// through the lit dots from the floor toward the handle, paced by the fan's
/// *actual* speed (measured RPM over the firmware maximum, never the request
/// or Smart's target). A fan spinning up visibly quickens the wave; a stopped
/// fan, or no fresh telemetry, stands it still. Frost stays reserved for
/// 100%.
///
/// Scale (M4 mini, 1000–4900 RPM): `velocity = 6 + 104 × fraction` points per
/// second, so the firmware idle (≈20%) drifts at ≈27 pt/s, 60% at ≈68 pt/s
/// and full speed at 110 pt/s. Amplitude grows with speed (more expressive
/// when the fan works hard). Subtle keeps the same pace, at half the
/// amplitude: effects change presence, never the truth about speed.
enum DotVitality {
    /// Light band spacing (points); one band passes per `period / velocity`.
    static let period: CGFloat = 96
    static let slowest = 6.0, span = 104.0
    /// Relative velocity change below which the wave is not re-timed (RPM
    /// jitter between samples is not news).
    static let retimeTolerance = 0.04

    /// Measured RPM as a fraction of the maximum, 0 when unknown or invalid.
    static func fraction(rpm: Double?, maximumRPM: Double?) -> Double {
        guard let rpm, let maximumRPM, rpm.isFinite, maximumRPM.isFinite, rpm > 0, maximumRPM > 0 else { return 0 }
        return min(1, rpm / maximumRPM)
    }
    /// Points per second along the track, 0 for a stopped fan.
    static func velocity(fraction: Double) -> Double {
        guard fraction.isFinite, fraction > 0 else { return 0 }
        return slowest + span * min(1, fraction)
    }
    /// Opacity of the wave, 0...1: brighter as the fan works harder; half on
    /// Subtle; nothing with Effects Off or Reduce Motion.
    static func amplitude(fraction: Double, effects: EffectsProfile) -> Double {
        guard fraction.isFinite, fraction > 0, effects.ambient > 0 else { return 0 }
        let presence = effects.ambient >= 1 ? 1.0 : 0.5
        return (0.38 + 0.62 * min(1, fraction)) * presence
    }
    /// Runs only while shown, enabled, fresh, turning and allowed to move.
    static func runs(visible: Bool, enabled: Bool, available: Bool, rpm: Double?, maximumRPM: Double?, effects: EffectsProfile) -> Bool {
        visible && enabled && available && effects.ambient > 0 && velocity(fraction: fraction(rpm: rpm, maximumRPM: maximumRPM)) > 0
    }
    /// Whether a new velocity is different enough to re-time the wave.
    static func needsRetime(current: Double, target: Double) -> Bool {
        guard current > 0 else { return target > 0 }
        return abs(target - current) / current > retimeTolerance
    }
}

/// How much of the track the full-cooling ice covers, by position (0 at
/// the start of the track, 1 at its end). At 100% the whole track freezes:
/// the ice is thickest at the thumb end and never thinner than `edge`, so
/// it reads as one sheet, not crystals huddled near the thumb.
enum IceCover {
    static let edge = 0.85
    static func weight(at fraction: Double) -> Double {
        guard fraction.isFinite else { return edge }
        let t = max(0, min(1, fraction))
        return edge + (1 - edge) * t * t * (3 - 2 * t)
    }
    /// Whether crossing into full cooling plays the formation. It plays for
    /// every crossing the person can see happen: a drag, a click or preset,
    /// and an external value (Smart) gliding to 100% while the panel is
    /// open. Keyboard and VoiceOver steps, refreshes while hidden or at
    /// startup (all unanimated) show the ice at once, and a value that stays
    /// at 100% never crosses, so polling never replays it. Expressive only
    /// (`EffectsProfile.forms`, off with Reduce Motion).
    static func forms(animated: Bool, allowed: Bool) -> Bool { animated && allowed }
    /// The freezing front's growth spurts as (fraction of the formation
    /// time, fraction of the track reached): fast, a pause, fast again,
    /// settling. Both styles crawl to this.
    static let crawl: [(time: Double, reach: Double)] = [(0, 0), (0.16, 0.22), (0.28, 0.25), (0.5, 0.58), (0.6, 0.61), (0.82, 0.9), (1, 1)]
    /// The crawl resumed from a front already at `reach` (a formation that
    /// interrupts a melt continues from what is on screen).
    static func crawl(from reach: Double) -> [(time: Double, reach: Double)] {
        let start = reach.isFinite ? max(0, min(1, reach)) : 0
        return crawl.map { ($0.time, start + (1 - start) * $0.reach) }
    }
}

/// How the slider answers the speed of a drag, in points per second of
/// thumb travel. Every curve is bounded and has a dead zone, so a fast
/// sweep reads as momentum while a slow, precise adjustment stays still.
enum SliderMotion {
    /// Exponential smoothing of raw per-event velocity. Event spacing varies
    /// (60–120 Hz, coalesced), so the weight follows the elapsed time.
    static func smoothed(previous: Double, sample: Double, interval: Double, timeConstant: Double = 0.05) -> Double {
        let previous = previous.isFinite ? previous : 0
        guard sample.isFinite else { return previous }
        let dt = interval.isFinite && interval > 0 ? min(interval, 0.25) : 1.0 / 60
        return previous + (sample - previous) * (1 - exp(-dt / timeConstant))
    }
    /// Perceived speed, 0...1: nothing below 40 pt/s, saturating near 1500.
    static func intensity(velocity: Double) -> Double {
        guard velocity.isFinite else { return 0 }
        return 1 - exp(-max(0, abs(velocity) - 40) / 520)
    }
    /// Thumb lean in radians; the top leads the travel. At most 8°.
    static let maxLean = 0.14
    static func lean(velocity: Double, gain: Double) -> Double {
        guard velocity.isFinite, gain.isFinite else { return 0 }
        return (velocity < 0 ? -1 : 1) * maxLean * intensity(velocity: velocity) * max(0, min(1, gain))
    }
    /// Extra horizontal scale of the thumb at speed, 0...0.35.
    static func stretch(velocity: Double, gain: Double) -> Double {
        guard gain.isFinite else { return 0 }
        return 0.35 * intensity(velocity: velocity) * max(0, min(1, gain))
    }
    /// Extra length of the energy head at speed (added to its scale), 0...0.9.
    static func surge(velocity: Double, gain: Double) -> Double {
        guard gain.isFinite else { return 0 }
        return 0.9 * intensity(velocity: velocity) * max(0, min(1, gain))
    }
    /// The cold wake left behind a moving thumb: trail length in points and
    /// peak opacity. Hotter coolant leaves a brighter wake.
    static func wake(velocity: Double, energy: Double) -> (length: Double, opacity: Double) {
        let i = intensity(velocity: velocity)
        guard i > 0.03 else { return (0, 0) }
        let e = energy.isFinite ? max(0, min(1, energy)) : 0
        return (12 + 76 * i, min(1, 1.2 * i * (0.45 + 0.55 * e)))
    }
}

/// Frost grows with cooling power. It starts at a moderate speed, thickens
/// toward the top, and becomes a formed sheet of ice only at full cooling.
enum Frost {
    static let onset = 45.0
    /// Visible frost amount for a slider value, 0...1 (smoothstep).
    static func amount(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        let t = max(0, min(1, (percent - onset) / (100 - onset)))
        return t * t * (3 - 2 * t)
    }
    /// The sheet is a state, not a gradient: it exists only at maximum.
    static func crowned(percent: Double) -> Bool { percent >= 99.5 }
    /// Where the sheet freezes the channel: the top of the range only,
    /// strongest at the thumb (0 below `crystalOnset`, 1 at 100%).
    static let crystalOnset = 70.0
    static func crystal(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        let t = max(0, min(1, (percent - crystalOnset) / (100 - crystalOnset)))
        return t * t * (3 - 2 * t)
    }
    /// Rime grains clinging outside one lip at a point. Restrained: never
    /// more than four, so the track stays legible as an instrument.
    static func grains(amount: Double, noise: Double) -> Int {
        guard amount.isFinite, amount > 0.02 else { return 0 }
        return min(4, Int((amount * 3.4 * (0.45 + max(0, min(1, noise)))).rounded(.down)))
    }
}

/// Cold air rising from the panel's lower edge. It follows the measured fan
/// speed (what the hardware is doing), never the request, so it can lag a
/// change in the same way the fan does.
enum Airflow {
    static func chill(measuredPercent: Double?) -> Double {
        guard let measured = measuredPercent, measured.isFinite else { return 0 }
        return pow(max(0, min(1, measured / 100)), 1.4)
    }
}

/// Compact duration text for the Return to Auto setting.
enum DurationText {
    static func short(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let hours = total / 60, rest = total % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }
    static func spoken(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let hours = total / 60, rest = total % 60
        let h = hours == 1 ? "1 hour" : "\(hours) hours", m = rest == 1 ? "1 minute" : "\(rest) minutes"
        return hours == 0 ? m : rest == 0 ? h : "\(h) \(m)"
    }
}

// MARK: Vector artwork

/// Minimal SVG path-data reader for small bundled marks (M L H V C S Q Z A,
/// absolute and relative). Produces device-independent segments that the
/// AppKit layer turns into a bezier path; no runtime asset loading.
enum VectorPath {
    enum Segment: Equatable { case move(CGPoint), line(CGPoint), curve(CGPoint, CGPoint, CGPoint), close }

    static func parse(_ data: String) -> [Segment] {
        var tokens: [String] = [], number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        var previous: Character = " "
        for ch in data {
            if ch.isLetter && ch != "e" && ch != "E" { flush(); tokens.append(String(ch)) }
            else if ch == "-" && previous != "e" && previous != "E" { flush(); number = "-" }
            else if ch == "." && number.contains(".") { flush(); number = "." }
            else if ch == "," || ch == " " || ch == "\n" || ch == "\t" { flush() }
            else { number.append(ch) }
            previous = ch
        }
        flush()

        var out: [Segment] = [], i = 0, command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        func isCommand(_ token: String) -> Bool { token.count == 1 && token.first!.isLetter }
        func num() -> CGFloat { defer { i += 1 }; return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0 }
        func flag() -> Bool {
            // Arc flags may be packed ("0016" = 0, 0, 16): consume one digit.
            guard i < tokens.count else { return false }
            var token = tokens[i]
            let first = token.removeFirst()
            if token.isEmpty { i += 1 } else { tokens[i] = token }
            return first == "1"
        }
        while i < tokens.count {
            if isCommand(tokens[i]) { command = tokens[i].first!; i += 1 }
            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y) }
            switch command.uppercased().first! {
            case "M":
                current = point(num(), num()); start = current; out.append(.move(current))
                command = relative ? "l" : "L"; lastControl = nil
            case "L": current = point(num(), num()); out.append(.line(current)); lastControl = nil
            case "H": let x = num(); current = CGPoint(x: relative ? current.x + x : x, y: current.y); out.append(.line(current)); lastControl = nil
            case "V": let y = num(); current = CGPoint(x: current.x, y: relative ? current.y + y : y); out.append(.line(current)); lastControl = nil
            case "C":
                let c1 = point(num(), num()), c2 = point(num(), num()), end = point(num(), num())
                out.append(.curve(c1, c2, end)); current = end; lastControl = c2
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(num(), num()), end = point(num(), num())
                out.append(.curve(c1, c2, end)); current = end; lastControl = c2
            case "Q":
                let q = point(num(), num()), end = point(num(), num())
                out.append(.curve(CGPoint(x: current.x + 2 / 3 * (q.x - current.x), y: current.y + 2 / 3 * (q.y - current.y)),
                                  CGPoint(x: end.x + 2 / 3 * (q.x - end.x), y: end.y + 2 / 3 * (q.y - end.y)), end))
                current = end; lastControl = nil
            case "A":
                let rx = num(), ry = num(), rotation = num(), large = flag(), sweep = flag(), end = point(num(), num())
                out += arc(from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end; lastControl = nil
            case "Z":
                out.append(.close); current = start; lastControl = nil
            default:
                i += 1
            }
        }
        return out
    }

    /// SVG endpoint arc to cubic segments of at most 90°.
    private static func arc(from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) -> [Segment] {
        var rx = abs(Double(rx)), ry = abs(Double(ry))
        guard rx > 0, ry > 0, p0 != p1 else { return [.line(p1)] }
        let phi = Double(rotation) * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = Double(p0.x - p1.x) / 2, dy = Double(p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator == 0 ? 0 : (max(0, numerator) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + Double(p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + Double(p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let pieces = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(pieces), k = 4.0 / 3.0 * tan(step / 4)
        func onEllipse(_ t: Double) -> (Double, Double) {
            let x = rx * cos(t), y = ry * sin(t)
            return (cosP * x - sinP * y + cx, sinP * x + cosP * y + cy)
        }
        func derivative(_ t: Double) -> (Double, Double) {
            let x = -rx * sin(t), y = ry * cos(t)
            return (cosP * x - sinP * y, sinP * x + cosP * y)
        }
        var segments: [Segment] = [], t = theta1
        for piece in 0..<pieces {
            let t2 = t + step
            let a = onEllipse(t), b = piece == pieces - 1 ? (Double(p1.x), Double(p1.y)) : onEllipse(t2)
            let da = derivative(t), db = derivative(t2)
            segments.append(.curve(CGPoint(x: a.0 + k * da.0, y: a.1 + k * da.1),
                                   CGPoint(x: b.0 - k * db.0, y: b.1 - k * db.1),
                                   CGPoint(x: b.0, y: b.1)))
            t = t2
        }
        return segments
    }

    /// GitHub mark ("mark-github", 16×16, y down) from Primer Octicons,
    /// MIT License, © GitHub, Inc. Used only to label the source link.
    static let githubMark = "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.06-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"
}
