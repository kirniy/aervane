import Foundation
import ZephyrCore

// Interaction rules for the panel that do not need AppKit: keyboard quick
// actions, the preset editor's draft, and trend inspection. Foundation-only
// so the behaviour is testable without a window server.

/// Plain-key shortcuts while the fan controls are showing. Text fields never
/// see these: a field editor consumes its own keys before the panel does.
enum QuickAction: Equatable {
    case preset(Int), automatic, manual, settings

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
        case "a": return .automatic
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
