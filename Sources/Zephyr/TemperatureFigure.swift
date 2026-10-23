import AppKit
import CoreText

/// The panel's large temperature figure: the rounded light face with
/// tabular (fixed-width) digits, so the figure, the unit and the sensor tag
/// never shift as digits change, and a short, calm crossfade when a reading
/// changes (`TemperatureMotion`). Unchanged digits draw identically in both
/// states, so only the digits that changed visibly fade. One animation key:
/// a newer reading replaces a running fade instead of stacking, and the
/// latest text is always set at once.
@MainActor enum TemperatureFigure {
    // Core Animation stores CATransition under its reserved transition key.
    static let fadeKey = kCATransition

    static func font(size: CGFloat = 52) -> NSFont {
        let rounded = Theme.rounded(size, .light)
        let tabular: [NSFontDescriptor.FeatureKey: Int] = [.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]
        return NSFont(descriptor: rounded.fontDescriptor.addingAttributes([.featureSettings: [tabular]]), size: size) ?? rounded
    }

    static func show(_ text: String, in field: NSTextField, motion: TemperatureMotion) {
        if motion == .none { field.layer?.removeAnimation(forKey: fadeKey) }
        guard field.stringValue != text else { return }
        if motion == .fade, let layer = field.layer {
            let fade = CATransition()
            fade.type = .fade; fade.duration = TemperatureMotion.duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: fadeKey)
        } else {
            field.layer?.removeAnimation(forKey: fadeKey)
        }
        field.stringValue = text
    }
}
