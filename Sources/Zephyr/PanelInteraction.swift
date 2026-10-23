import Foundation
import ZephyrCore

// Interaction rules for the panel that do not need AppKit: keyboard quick
// actions, the preset editor's draft, and trend inspection. Foundation-only
// so the behaviour is testable without a window server.

/// Plain-key shortcuts while the fan controls are showing. Text fields never
/// see these: a field editor consumes its own keys before the panel does.
enum QuickAction: Equatable {
    case preset(Int), automatic, smart, manual, settings
    /// Smart's target, in display steps: [ and ] by one, { and } by five.
    case smartTarget(Int)

    /// Physical top-row and keypad keys 1–6, so layouts that need Shift for
    /// digits (AZERTY) still reach presets by position.
    private static let digitKeyCodes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5,
                                                      83: 0, 84: 1, 85: 2, 86: 3, 87: 4, 88: 5]

    static func resolve(characters: String?, keyCode: UInt16, command: Bool, option: Bool, control: Bool, presetCount: Int) -> QuickAction? {
        guard !option, !control else { return nil }
        let key = (characters ?? "").lowercased()
        if command { return key == "," ? .settings : nil }
        if let digit = key.first?.wholeNumberValue, key.count == 1, (1...6).contains(digit) {
            return digit <= presetCount ? .preset(digit - 1) : nil
        }
        if let index = digitKeyCodes[keyCode] { return index < presetCount ? .preset(index) : nil }
        switch key {
        case "[": return .smartTarget(-1)
        case "]": return .smartTarget(1)
        case "{": return .smartTarget(-5)
        case "}": return .smartTarget(5)
        case "a": return .automatic
        case "s": return .smart
        case "m": return .manual
        default: return nil
        }
    }
}

/// Presets being edited. Nothing reaches the model until `resolved` is
/// saved, so Cancel (or Escape) is always a true undo of the session.
struct PresetDraft: Equatable {
    static let capacity = 6
    static let nameLimit = 20
    static let fallbackName = "Custom"

    struct Item: Equatable {
        let id: UUID
        var name: String
        /// Last valid speed typed for this row (0...100, whole percent).
        var percent: Double
    }

    private(set) var items: [Item]
    private let original: [FanPreset]

    init(_ presets: [FanPreset]) {
        original = presets
        items = presets.prefix(Self.capacity).map { Item(id: $0.id, name: $0.name, percent: $0.percent) }
    }

    var isFull: Bool { items.count >= Self.capacity }
    var isEmpty: Bool { items.isEmpty }
    /// True when saving would change what is stored.
    func hasChanges(minimum: Double) -> Bool { resolved(minimum: minimum) != original }

    /// Appends a row at the given speed. Returns its index, or nil when full.
    @discardableResult mutating func add(percent: Double, name: String = fallbackName) -> Int? {
        guard !isFull else { return nil }
        items.append(Item(id: UUID(), name: Self.sanitize(name), percent: Self.whole(percent) ?? 50))
        return items.count - 1
    }
    mutating func remove(at index: Int) { if items.indices.contains(index) { items.remove(at: index) } }

    /// Stores a name as typed (blank is allowed while editing) and returns the
    /// text the field should show: single line, at most `nameLimit` characters.
    @discardableResult mutating func rename(_ index: Int, to text: String) -> String {
        let clean = Self.sanitize(text)
        if items.indices.contains(index) { items[index].name = clean }
        return clean
    }
    /// Accepts typed speed text. Invalid text leaves the last valid value.
    @discardableResult mutating func setPercent(_ index: Int, text: String) -> Double? {
        guard items.indices.contains(index), let value = Self.parsePercent(text) else { return nil }
        items[index].percent = value
        return value
    }
    /// Steps a row's speed (arrow keys), staying within the hardware range.
    @discardableResult mutating func step(_ index: Int, by delta: Double, minimum: Double) -> Double? {
        guard items.indices.contains(index) else { return nil }
        let value = Self.effective(items[index].percent + delta, minimum: minimum)
        items[index].percent = value
        return value
    }

    /// What Save stores: trimmed names (blank becomes "Custom"), speeds raised
    /// to the hardware floor, identities preserved.
    func resolved(minimum: Double) -> [FanPreset] {
        items.map { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return FanPreset(id: item.id, name: name.isEmpty ? Self.fallbackName : name, percent: Self.effective(item.percent, minimum: minimum))
        }
    }

    static func effective(_ percent: Double, minimum: Double) -> Double {
        let floor = minimum.isFinite ? max(0, min(100, minimum)) : 0
        return max(floor, min(100, (percent.isFinite ? percent : floor).rounded()))
    }
    /// "64", "64%", " 64 % " → 64. Clamped to 0...100; nil when not a number.
    static func parsePercent(_ text: String) -> Double? {
        let trimmed = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        return whole(value)
    }
    /// True when typed text names a speed the hardware cannot run.
    static func isBelowFloor(_ text: String, minimum: Double) -> Bool {
        guard let value = parsePercent(text) else { return false }
        return value < minimum.rounded(.up)
    }
    private static func whole(_ value: Double) -> Double? { value.isFinite ? max(0, min(100, value.rounded())) : nil }
    private static func sanitize(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(nameLimit))
    }
}

/// Reading the recent-temperature trend under the pointer.
enum TrendInspection {
    /// Nearest sample to a horizontal position in a plot spanning
    /// `minX...minX + width`. Positions outside the plot clamp to its ends.
    static func index(x: Double, minX: Double, width: Double, count: Int) -> Int? {
        guard count > 0, x.isFinite else { return nil }
        guard count > 1, width > 0 else { return count - 1 }
        let t = max(0, min(1, (x - minX) / width))
        return Int((t * Double(count - 1)).rounded())
    }
    /// One decimal, in the user's unit: the exact sample, not the rounded headline.
    static func readout(celsius: Double, fahrenheit: Bool) -> String {
        let value = fahrenheit ? celsius * 1.8 + 32 : celsius
        return String(format: "%.1f°", value)
    }
    /// Spoken range of the visible trend, e.g. "64 to 78 °C, now 73".
    static func summary(_ samples: [Double], fahrenheit: Bool) -> String? {
        let values = samples.filter(\.isFinite).map { fahrenheit ? $0 * 1.8 + 32 : $0 }
        guard let low = values.min(), let high = values.max(), let now = values.last else { return nil }
        let unit = fahrenheit ? "°F" : "°C"
        return "\(Int(low.rounded())) to \(Int(high.rounded())) \(unit), now \(Int(now.rounded()))"
    }
}

/// What Smart measured in one evaluated sample, and when (for freshness).
struct SmartSample: Equatable {
    let celsius: Double?
    let source: SmartTemperatureSource?
    let at: Date
}

/// The panel's big temperature: its value, compact tag, spoken detail and
/// the history that belongs with it. While Smart runs, the panel shows the
/// very measurement Smart regulates (its source and any held GPU value), so
/// the figure, the heat colour, the chart and Smart's status agree. In Auto
/// and Manual it shows the user's selected sensor. The menu bar always keeps
/// the selected sensor. Missing or stale Smart data is shown as unavailable,
/// never replaced by an average.
struct TemperatureReadout: Equatable {
    enum Series: Equatable { case selected, smart }
    let celsius: Double?
    let tag: String
    let detail: String
    let series: Series

    /// A Smart sample older than this is not shown (matches the model's
    /// staleness limit for fan and sensor samples).
    static let smartFreshness: TimeInterval = 12

    static func panel(smartEnabled: Bool, smart: SmartSample?, selectedSensor: String, selectedCelsius: Double?, stale: Bool, now: Date) -> TemperatureReadout {
        if smartEnabled {
            let fresh = smart.flatMap { sample -> Double? in
                guard !stale, let celsius = sample.celsius, celsius.isFinite,
                      (-1...smartFreshness).contains(now.timeIntervalSince(sample.at)) else { return nil }
                return celsius
            }
            let source = fresh == nil ? nil : smart?.source
            return TemperatureReadout(celsius: fresh, tag: (source ?? .cpuPeak).tag,
                                      detail: source?.detail ?? "Smart's temperature is unavailable", series: .smart)
        }
        let (tag, detail): (String, String)
        switch selectedSensor {
        case "GPU": (tag, detail) = ("GPU AVG", "GPU average")
        case "Warmer": (tag, detail) = ("WARMER", "Warmer of the CPU and GPU averages")
        default: (tag, detail) = ("CPU AVG", "CPU average")
        }
        return TemperatureReadout(celsius: stale ? nil : selectedCelsius, tag: tag, detail: detail, series: .selected)
    }

    /// The figure as shown: whole degrees in the user's unit, or "—".
    func text(fahrenheit: Bool) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        return String(SmartStatusText.displayed(celsius, fahrenheit: fahrenheit))
    }
}

/// How the panel's large temperature figure changes to a new reading.
///
/// Calm and honest: a reading replaces the previous one at once (no
/// interpolation through temperatures that were never measured); when both
/// are real readings of the same source in the same unit and the panel is on
/// screen with motion allowed, the figure crossfades briefly. Anything else
/// (first reading, stale ↔ valid, a different source or unit, hidden, Effects
/// Off, Reduce Motion) changes without motion, so nothing implies a change
/// that did not happen.
enum TemperatureMotion: Equatable {
    case none, fade
    /// Short enough to finish well before the next 1 s sample.
    static let duration = 0.2

    static func between(_ old: String, _ new: String, sameSeries: Bool, sameUnit: Bool, visible: Bool, allowed: Bool) -> TemperatureMotion {
        guard old != new, allowed, visible, sameSeries, sameUnit, Int(old) != nil, Int(new) != nil else { return .none }
        return .fade
    }
}

/// Smart's status words, consistent with the figure the panel shows.
enum SmartStatusText {
    /// Whole degrees as displayed in the user's unit.
    static func displayed(_ celsius: Double, fahrenheit: Bool) -> Int {
        Int((fahrenheit ? celsius * 1.8 + 32 : celsius).rounded())
    }
    /// "Above 73° · max cooling", only when Smart's full speed is confirmed
    /// (`atMaximum`, gated on the applied target) *and* the shown temperature
    /// is visibly above the shown target: 73° beside a 73° target never says
    /// "Above".
    static func chip(atMaximum: Bool, celsius: Double?, target: Double, fahrenheit: Bool) -> String? {
        guard atMaximum, let celsius, celsius.isFinite else { return nil }
        let shownTarget = SmartTarget.display(target, fahrenheit: fahrenheit)
        guard displayed(celsius, fahrenheit: fahrenheit) > shownTarget else { return nil }
        return "Above \(shownTarget)° · max cooling"
    }
    /// The Smart button's tooltip: key, target, what it measures and asks
    /// for, and why when it asks for full speed below the target.
    static func summary(enabled: Bool, celsius: Double?, source: SmartTemperatureSource?, request: Double?, target: Double, fahrenheit: Bool) -> String {
        let unit = fahrenheit ? "°F" : "°C"
        let goal = "\(SmartTarget.display(target, fahrenheit: fahrenheit))\(unit)"
        guard enabled else { return "Smart (S): regulates around \(goal)" }
        guard let celsius, celsius.isFinite, let request else { return "Smart (S), target \(goal): waiting for a reading" }
        let now = "\(displayed(celsius, fahrenheit: fahrenheit))\(unit) \((source ?? .cpuPeak).tag.lowercased())"
        var text = "Smart (S), target \(goal): \(now), requesting \(Int(request.rounded()))%"
        if request >= 100, displayed(celsius, fahrenheit: fahrenheit) <= SmartTarget.display(target, fahrenheit: fahrenheit) {
            text += " in response to recent heat"
        }
        return text
    }
}

/// The trend's vertical scale: the recent samples with a little air, and
/// Smart's target when it is shown, so the target line is always on the
/// plot. Without a target this is exactly the original scale.
enum TrendScale {
    static func range(samples: [Double], target: Double?) -> (low: Double, high: Double) {
        let finite = samples.filter(\.isFinite)
        var lowest = finite.min() ?? 30, highest = finite.max() ?? 60
        if let target, target.isFinite { lowest = min(lowest, target); highest = max(highest, target) }
        let low = max(10, lowest - 3)
        return (low, max(low + 6, highest + 3))
    }
    /// A temperature's height in a plot spanning `minY…minY + height`
    /// (y up), clamped to the plot.
    static func y(_ celsius: Double, range: (low: Double, high: Double), minY: Double, height: Double) -> Double {
        guard range.high > range.low, celsius.isFinite else { return minY }
        let t = max(0, min(1, (celsius - range.low) / (range.high - range.low)))
        return minY + t * height
    }
}

/// Dragging Smart's target on the trend. The mapping is fixed for the whole
/// gesture: every `pointsPerStep` of vertical travel is one whole degree in
/// the user's unit, clamped to Smart's range, and the chart keeps the scale
/// it had at the grab, so nothing rescales under the pointer. Nothing is
/// stored until the gesture ends.
struct SmartTargetScrub: Equatable {
    static let pointsPerStep = 4.0
    /// The target at the grab, in whole display degrees.
    let start: Int
    let fahrenheit: Bool

    init(celsius: Double, fahrenheit: Bool) {
        self.start = SmartTarget.display(celsius, fahrenheit: fahrenheit); self.fahrenheit = fahrenheit
    }
    /// Display degrees after `travel` points of upward pointer movement
    /// (negative is downward).
    func display(travel: Double) -> Int {
        guard travel.isFinite else { return start }
        let range = SmartTarget.displayRange(fahrenheit: fahrenheit)
        return min(range.upperBound, max(range.lowerBound, start + Int((travel / Self.pointsPerStep).rounded())))
    }
    func celsius(travel: Double) -> Double { SmartTarget.celsius(fromDisplay: Double(display(travel: travel)), fahrenheit: fahrenheit) }
    /// One keyboard or VoiceOver step (whole display degrees), clamped.
    static func stepped(_ celsius: Double, by steps: Int, fahrenheit: Bool) -> Double {
        let range = SmartTarget.displayRange(fahrenheit: fahrenheit)
        let shown = min(range.upperBound, max(range.lowerBound, SmartTarget.display(celsius, fahrenheit: fahrenheit) + steps))
        return SmartTarget.celsius(fromDisplay: Double(shown), fahrenheit: fahrenheit)
    }
}
