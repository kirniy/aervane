import AppKit
import QuartzCore

/// A text field that reports focus, so its row can show where typing goes
/// without a heavy bezel or a focus ring that spills onto the glass.
final class EditorField: NSTextField {
    var focusChanged: ((Bool) -> Void)?
    /// Select the whole value on focus, so typing replaces it (speed fields).
    var selectsAllOnFocus = false

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focusChanged?(true)
        // A click places the caret after this returns; select afterwards.
        if selectsAllOnFocus { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
        return true
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focusChanged?(false)
    }
}

/// One preset in the inline editor: the same soft tile as a preset button,
/// now editable in place. Name on the left, speed on the right, delete last.
/// The tile's own edge shows focus.
final class PresetEditorRow: FlippedView {
    static let height: CGFloat = 32
    let name = EditorField(string: "")
    let value = EditorField(string: "")
    private let suffix = label("%", size: 12, weight: .medium, color: .secondaryLabelColor)
    let remove: SoftButton
    private var focused = false

    init(index: Int, onRemove: @escaping () -> Void) {
        remove = SoftButton("", glyph: .close, action: onRemove)
        super.init(frame: .zero)
        wantsLayer = true
        for field in [name, value] {
            field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
            field.isEditable = true; field.isSelectable = true
            field.lineBreakMode = .byTruncatingTail; field.cell?.isScrollable = true; field.cell?.wraps = false
            field.focusChanged = { [weak self] in self?.setFocused($0) }
        }
        name.font = Theme.font(12, .medium); name.placeholderString = PresetDraft.fallbackName
        name.tag = index * 10
        value.font = Theme.number(12, .medium); value.alignment = .right; value.selectsAllOnFocus = true
        value.tag = index * 10 + 1
        remove.quiet = true
        [name, value, suffix, remove].forEach(addSubview)
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name text: String, percent: Double, position: Int) {
        name.stringValue = text; value.stringValue = "\(Int(percent))"
        name.setAccessibilityLabel("Preset \(position) name"); value.setAccessibilityLabel("Preset \(position) speed")
        remove.setAccessibilityLabel(text.isEmpty ? "Delete preset \(position)" : "Delete \(text)"); remove.toolTip = "Delete"
    }
    /// Speeds below the hardware floor are shown in the attention colour
    /// while typing; leaving the field raises them to the floor.
    func showFloorWarning(_ below: Bool, minimum: Double) {
        value.textColor = below ? Theme.caution : Theme.ink
        value.toolTip = below ? "Hardware minimum \(Int(minimum))%" : nil
    }

    override func layout() {
        super.layout()
        let h = bounds.height, deleteX = bounds.width - 30
        let fieldHeight = ceil(name.intrinsicContentSize.height), fieldY = ((h - fieldHeight) / 2).rounded()
        remove.frame = NSRect(x: deleteX, y: ((h - 28) / 2).rounded(), width: 28, height: 28)
        suffix.frame = NSRect(x: deleteX - 4 - 12, y: fieldY, width: 12, height: fieldHeight)
        value.frame = NSRect(x: deleteX - 4 - 12 - 36, y: fieldY, width: 36, height: fieldHeight)
        name.frame = NSRect(x: 11, y: fieldY, width: max(0, value.frame.minX - 8 - 11), height: fieldHeight)
        layer?.cornerRadius = min(9, h / 2)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh(animated: false) }

    private func setFocused(_ on: Bool) {
        guard on != focused else { return }
        focused = on; refresh(animated: true)
    }
    private func refresh(animated: Bool) {
        guard let layer else { return }
        let appearance = effectiveAppearance
        let fill = Theme.cg(Theme.ink.withAlphaComponent(focused ? 0.085 : 0.05), appearance)
        let edge = Theme.cg(focused ? Theme.accent.withAlphaComponent(0.6) : Theme.accent.withAlphaComponent(0), appearance)
        let from = layer.presentation() ?? layer
        let fromFill = from.backgroundColor, fromEdge = from.borderColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.backgroundColor = fill; layer.borderColor = edge; layer.borderWidth = 1
        if animated, window != nil, Theme.effects.animates {
            for (key, old, new) in [("backgroundColor", fromFill, fill), ("borderColor", fromEdge, edge)] {
                let fade = CABasicAnimation(keyPath: key); fade.fromValue = old; fade.toValue = new
                fade.duration = 0.15; fade.timingFunction = Theme.Ease.out
                layer.add(fade, forKey: key)
            }
        }
        CATransaction.commit()
    }

    /// A newly added row settles into place (the only editor entrance).
    func playEntrance() {
        guard let layer, window != nil, Theme.effects.animates else { return }
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -4, 0)); rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        for animation in [rise, fade] { animation.duration = 0.2; animation.timingFunction = Theme.Ease.out }
        layer.add(rise, forKey: "entrance"); layer.add(fade, forKey: "entranceFade")
    }
}

/// A menu item that runs a closure; the item retains its action.
final class MenuAction: NSObject {
    private let block: () -> Void
    private init(_ block: @escaping () -> Void) { self.block = block }
    @objc private func run() { block() }
    static func item(_ title: String, enabled: Bool = true, _ block: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(block)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action; item.representedObject = action; item.isEnabled = enabled
        return item
    }
}
