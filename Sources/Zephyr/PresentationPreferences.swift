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
    /// One-shot bloom when a user action reaches 100%.
    let bloom: Bool
    /// Static frost artwork intensity on the cooling slider, 0...1.
    let frost: Double
    /// The authored ice-formation reveal at maximum cooling. Without it the
    /// ice simply appears (Subtle) or is absent (Off).
    let forms: Bool

    init(level: EffectsLevel, reduceMotion: Bool, reduceTransparency: Bool) {
        let light: Double = reduceTransparency ? 0.5 : 1
        switch level {
        case .off: glow = 0; aura = 0; frost = 0
        case .subtle: glow = 0.55 * light; aura = 0.6 * light; frost = 0.6 * light
        case .expressive: glow = 1 * light; aura = 1 * light; frost = 1 * light
        }
        animates = !reduceMotion
        rolls = !reduceMotion && level != .off
        sweep = !reduceMotion && level == .expressive
        bloom = !reduceMotion && level != .off
        forms = !reduceMotion && level == .expressive
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
    }

    private let defaults: UserDefaults
    private let center: NotificationCenter

    var menuBarContent: MenuBarContent { didSet { store(menuBarContent.rawValue, Key.menuBarContent, changed: menuBarContent != oldValue) } }
    var menuBarSpacing: MenuBarSpacing { didSet { store(menuBarSpacing.rawValue, Key.menuBarSpacing, changed: menuBarSpacing != oldValue) } }
    var effects: EffectsLevel { didSet { store(effects.rawValue, Key.effects, changed: effects != oldValue) } }
    /// Colours the temperature (panel and menu bar) by thermal band.
    var heatColor: Bool { didSet { store(heatColor, Key.heatColor, changed: heatColor != oldValue) } }

    init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults; self.center = center
        menuBarContent = defaults.string(forKey: Key.menuBarContent).flatMap(MenuBarContent.init(rawValue:)) ?? .iconAndTemperature
        menuBarSpacing = defaults.string(forKey: Key.menuBarSpacing).flatMap(MenuBarSpacing.init(rawValue:)) ?? .compact
        effects = defaults.string(forKey: Key.effects).flatMap(EffectsLevel.init(rawValue:)) ?? .expressive
        heatColor = defaults.object(forKey: Key.heatColor) as? Bool ?? true
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

/// How much "energy" the slider shows at a value: light, dot density, glow
/// and head length all scale from this one curve, so effects intensify
/// progressively and consistently with speed.
enum SliderEnergy {
    static func level(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return pow(max(0, min(1, percent / 100)), 1.6)
    }
    /// Lit dot diameter for a column at `percent` (resting dots are 2 pt).
    static func dotSize(percent: Double) -> Double { 1.7 + 0.7 * level(percent: percent) }
}

/// Frost grows with cooling power. It starts at a moderate speed, thickens
/// toward the top, and becomes a formed ice crown only at full cooling.
enum Frost {
    static let onset = 45.0
    /// Visible frost amount for a slider value, 0...1 (smoothstep).
    static func amount(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        let t = max(0, min(1, (percent - onset) / (100 - onset)))
        return t * t * (3 - 2 * t)
    }
    /// The crown is a state, not a gradient: it exists only at maximum.
    static func crowned(percent: Double) -> Bool { percent >= 99.5 }
    /// Where the crown crystallises the lattice: the top of the range only,
    /// strongest at the thumb (0 below `crystalOnset`, 1 at 100%).
    static let crystalOnset = 70.0
    static func crystal(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        let t = max(0, min(1, (percent - crystalOnset) / (100 - crystalOnset)))
        return t * t * (3 - 2 * t)
    }
    /// Hoarfrost grains clinging to one edge of a column. Restrained: never
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
