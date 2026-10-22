import AppKit
import ZephyrCore

/// One compact glass panel. Frames come from a single `arrange` pass on a
/// 4/8 pt grid, so the window height can never disagree with the layout.
///
/// Minimal copy: state is carried by layout and controls (the mode switch,
/// the measured-speed mark on the slider, heat colour), and text appears
/// only for exceptions that need words (not applied, no reading, errors).
final class PanelView: FlippedView, NSTextFieldDelegate {
    static let width: CGFloat = 344
    let model: AppModel
    var resize: ((CGFloat) -> Void)?
    var quit: (() -> Void)?
    /// Called when the temperature band changes (the window tints its glass).
    var thermalChanged: ((ThermalState) -> Void)?
    var preferredFirstResponder: NSView { slider }
    private(set) var thermal = ThermalState.unknown
    private var needsSetup: Bool { !model.helperReady || model.competingApp != nil }
    private let margin: CGFloat = 16

    // Header and temperature (always visible).
    private let aura = AuraView()
    private let mark = NSImageView()
    private let titleLabel = label("Aervane", size: 13, weight: .semibold)
    private let temperature = label("—", size: 52, weight: .light)
    private let unit = label("°C", size: 17, color: .secondaryLabelColor)
    private let sensorTag = label("CPU", size: 10, weight: .semibold, color: .secondaryLabelColor)
    private let chart = TemperatureHistory()
    private lazy var settingsButton = SoftButton("", glyph: .settings) { [weak self] in self?.toggleSettings() }

    // Fan section.
    private let fanSection = FlippedView()
    private let percent = label("—%", size: 30, weight: .medium)
    private let stateChip = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let slider = PercentSlider(frame: .zero)
    private let floorLabel = label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var autoButton = SoftButton("Auto") { [weak self] in self?.model.restore() }
    private lazy var manualButton = SoftButton("Manual") { [weak self] in guard let self else { return }; self.request(self.model.shownPercent, animated: false) }
    private lazy var modeSwitch = ModeSwitch(auto: autoButton, manual: manualButton)
    private lazy var enableButton = SoftButton("Set up fan control", glyph: .airflow) { [weak self] in self?.model.enableControl() }
    private var presetButtons: [SoftButton] = []
    private var editorViews: [NSView] = []
    private var editing = false

    // Settings page (replaces the fan section while open).
    private lazy var settingsPage = SettingsView(model: model)
    private var settingsOpen = false
    private var layoutKey = ""
    /// A value the user asked for that the model has not confirmed yet. Keeps
    /// the thumb from snapping back while the helper write is in flight.
    private var hold: (value: Double, until: Date)?

    init(model: AppModel) {
        self.model = model; super.init(frame: .init(x: 0, y: 0, width: Self.width, height: 300))
        wantsLayer = true
        [aura, mark, titleLabel, temperature, unit, sensorTag, chart, settingsButton, fanSection, settingsPage].forEach(addSubview)
        [percent, stateChip, modeSwitch, slider, floorLabel, enableButton, message].forEach(fanSection.addSubview)
        fanSection.wantsLayer = true; settingsPage.wantsLayer = true; settingsPage.isHidden = true
        temperature.font = Theme.rounded(52, .light); temperature.wantsLayer = true
        unit.font = Theme.rounded(17)
        percent.font = Theme.number(30, .medium)
        message.font = Theme.font(11); message.textColor = Theme.caution; message.maximumNumberOfLines = 2
        message.lineBreakMode = .byTruncatingTail
        mark.image = Glyphs.image(.airflow, size: 16, color: Theme.accent); mark.imageScaling = .scaleNone
        mark.setAccessibilityElement(false)
        settingsButton.quiet = true; enableButton.prominent = true
        settingsButton.setAccessibilityLabel("Settings"); settingsButton.toolTip = "Settings"
        autoButton.setAccessibilityLabel("Restore automatic fan control"); manualButton.setAccessibilityLabel("Manual fan control")
        percent.setAccessibilityLabel("Requested fan speed")
        floorLabel.toolTip = "Hardware minimum"; floorLabel.alignment = .center
        slider.preview = { [weak self] value in self?.showReadout(value) }
        slider.commit = { [weak self] value in self?.request(value, animated: false) }
        settingsPage.editPresets = { [weak self] in self?.openEditorFromSettings() }
        settingsPage.quit = { [weak self] in self?.quit?() }
        settingsPage.changed = { [weak self] in self?.update() }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat { arrange(apply: false) }
    func prepareForHiding() {
        endTextEditing()
        slider.prepareForHiding()
        for button in allButtons { button.resetHover() }
        settleAnimations(in: layer)
    }
    private func settleAnimations(in layer: CALayer?) {
        layer?.removeAllAnimations()
        layer?.sublayers?.forEach { settleAnimations(in: $0) }
        if let mask = layer?.mask { settleAnimations(in: mask) }
    }
    private var allButtons: [SoftButton] {
        [settingsButton, autoButton, manualButton, enableButton] + presetButtons + editorViews.compactMap { $0 as? SoftButton } + settingsPage.buttons
    }
    override func layout() { super.layout(); arrange(apply: true) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    /// Content settles into the glass as the panel appears.
    func playEntrance() {
        guard Theme.effects.animates, let layer, window != nil else { return }
        let drop = CASpringAnimation(keyPath: "transform")
        drop.mass = 1; drop.stiffness = 340; drop.damping = 26
        drop.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 6, 0)); drop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        drop.duration = drop.settlingDuration
        layer.add(drop, forKey: "entrance")
    }
    /// Re-reads presentation preferences and system accessibility settings.
    func applyPresentation() {
        let effects = Theme.effects
        slider.effects = effects
        chart.heatColor = PresentationPreferences.shared.heatColor
        aura.apply(state: thermal, effects: effects, heatColor: PresentationPreferences.shared.heatColor, animated: false)
        settingsPage.sync()
        update()
        if Theme.reduceMotion { settleAnimations(in: layer) }
    }

    // MARK: Layout

    @discardableResult private func arrange(apply: Bool) -> CGFloat {
        let m = margin, w = bounds.width - 2 * m
        func put(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            if apply { view.frame = NSRect(x: x, y: y, width: max(0, width), height: height) }
        }
        var y: CGFloat = 14
        // Header: mark (drawn), name, settings.
        put(mark, m, y + 5, 16, 16)
        put(titleLabel, m + 23, y + 4, 140, 18)
        put(settingsButton, m + w - 26, y, 26, 26)
        y += 26 + 4
        // Temperature leads. Unit and sensor stack beside the figure, cap-aligned.
        let numberWidth = ceil(temperature.attributedStringValue.size().width) + 4
        put(temperature, m - 3, y, numberWidth, 62)
        let numberFont = temperature.font ?? Theme.rounded(52, .light), unitFont = unit.font ?? Theme.rounded(17)
        let unitY = (y + (numberFont.ascender - numberFont.capHeight) - (unitFont.ascender - unitFont.capHeight)).rounded()
        put(unit, m - 3 + numberWidth, unitY, 40, 22)
        put(sensorTag, m - 1 + numberWidth, unitY + 21, 44, 13)
        put(chart, m + w - 124, y + 14, 124, 40)
        // The aura is centred on the figure; its gradient fills the view, so
        // layer geometry flipping cannot move it.
        put(aura, m + numberWidth / 2 - 150, y + 31 - 95, 300, 190)
        y += 62 + 10

        if settingsOpen {
            let height = settingsPage.height(width: bounds.width, margin: m)
            put(settingsPage, 0, y, bounds.width, height)
            return y + height + 14
        }
        let top = y; y = 0
        // Section-local coordinates from here.
        // Readout row: requested percent, exceptional state, mode switch.
        let percentWidth = ceil(percent.attributedStringValue.size().width) + 4
        put(percent, m - 1, y - 2, percentWidth, 36)
        put(stateChip, m + percentWidth + 4, y + 14, max(0, w - percentWidth - 140), 15)
        put(modeSwitch, m + w - 128, y + 3, 128, 28)
        y += 34 + 4
        // Slider (hit area spills into the margins) and its floor mark.
        put(slider, m - 16, y, w + 32, 34)
        y += 34
        let floorX = (m - 16) + PercentSlider.trackX(percent: model.minimumPercent, width: w + 32)
        put(floorLabel, max(m - 6, floorX - 22), y - 3, 44, 13)
        y += 10 + 10
        // Presets wrap into rows of at most three: 1–3 → one row, 4 → 2×2,
        // 5 → 3+2, 6 → 3×2. Short last rows stretch to the full width.
        let gap: CGFloat = 8
        if editing {
            let rows = max(0, (editorViews.count - 2) / 4)
            if apply { layoutEditor(at: y, margin: m, width: w) }
            y += CGFloat(rows) * 34 + 30 + 12
        } else if !presetButtons.isEmpty {
            let count = presetButtons.count
            let perRow = count <= 3 ? count : count == 4 ? 2 : 3
            let rows = (count + perRow - 1) / perRow
            for row in 0..<rows {
                let first = row * perRow, items = min(perRow, count - first)
                let width = (w - CGFloat(items - 1) * gap) / CGFloat(items)
                for i in 0..<items { put(presetButtons[first + i], (m + CGFloat(i) * (width + gap)).rounded(), y + CGFloat(row) * (40 + gap), width.rounded(.down), 40) }
            }
            y += CGFloat(rows) * 40 + CGFloat(rows - 1) * gap + 12
        }
        if needsSetup { put(enableButton, m, y, w, 32); y += 32 + 10 }
        if model.error != nil {
            let height = min(32, max(15, ceil(message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 200)).height ?? 15)))
            put(message, m, y, w, height); y += height + 8
        }
        y += 2
        put(fanSection, 0, top, bounds.width, y)
        return top + y
    }

    // MARK: State

    func update() {
        let prefs = PresentationPreferences.shared, effects = Theme.effects
        slider.effects = effects
        chart.heatColor = prefs.heatColor
        // Temperature: number, unit, sensor tag and heat band.
        let state = model.stale ? ThermalState.unknown : ThermalState.classify(model.displayTemperature, previous: thermal)
        let colored = prefs.heatColor && state >= .warm
        let text = model.temperatureText, previousText = temperature.stringValue
        if text != previousText {
            if effects.rolls, window?.isVisible == true, let old = Double(previousText), let new = Double(text) {
                let roll = CATransition(); roll.type = .push; roll.subtype = new > old ? .fromBottom : .fromTop
                roll.duration = 0.3; roll.timingFunction = Theme.Ease.out
                temperature.layer?.add(roll, forKey: "roll")
            }
            temperature.stringValue = text
        }
        temperature.textColor = colored ? Theme.heat(state) : Theme.ink
        unit.stringValue = model.temperatureUnit
        sensorTag.stringValue = model.selectedSensor == "Warmer" ? "MAX" : model.selectedSensor
        sensorTag.toolTip = model.selectedSensor == "Warmer" ? "Warmer of CPU and GPU averages" : "\(model.selectedSensor) average"
        temperature.setAccessibilityLabel("\(model.selectedSensor == "Warmer" ? "Warmer of CPU and GPU averages" : model.selectedSensor) temperature, \(state.accessibilityName)")
        if state != thermal {
            aura.apply(state: state, effects: effects, heatColor: prefs.heatColor, animated: window?.isVisible == true, rising: state > thermal && thermal != .unknown)
            thermal = state; thermalChanged?(state)
        }
        chart.samples = model.history

        // Fan.
        slider.minimumPercent = model.minimumPercent
        slider.isUnavailable = model.stale
        slider.detents = model.presets.map { max(model.minimumPercent, $0.percent) }
        slider.measuredPercent = model.sample == nil || model.stale ? nil : model.actualPercent
        if let held = hold, !model.busy, abs(model.shownPercent - held.value) < 1.5 || model.error != nil || held.until < Date() { hold = nil }
        // A sample refresh never moves the thumb under the user's pointer/keys.
        if !slider.isInteracting {
            // Stays draggable while a command is in flight: the model queues
            // the newest value instead of dropping input.
            slider.isEnabled = !model.stale
            let value = (hold?.value ?? model.shownPercent).rounded()
            if abs(slider.percent - value) >= 0.5 { slider.setPercent(value, animated: window?.isVisible == true) }
            showReadout(slider.percent)
        }
        floorLabel.isHidden = model.sample == nil || model.minimumPercent <= 0
        floorLabel.stringValue = "\(Int(model.minimumPercent))%"
        floorLabel.setAccessibilityLabel("Hardware minimum \(Int(model.minimumPercent)) percent")

        let previewing = model.requestedPercent != nil
        modeSwitch.mode = model.ownsControl || previewing ? .manual : model.sample?.automatic == true ? .automatic : .none
        modeSwitch.pending = model.pendingPercent != nil
        manualButton.isEnabled = !model.stale
        if let deadline = model.controlDeadline, model.ownsControl {
            manualButton.toolTip = "Returns to Auto in \(DurationText.short(minutes: max(1, deadline.timeIntervalSinceNow / 60)))"
        } else { manualButton.toolTip = nil }
        syncPresets()
        settingsButton.selected = settingsOpen

        enableButton.isHidden = !needsSetup; enableButton.isEnabled = !model.busy
        enableButton.title = model.busy && !model.helperReady ? "Connecting…" : model.helperApprovalRequired ? "Approve in System Settings" : model.pendingPercent.map { "Set up & apply \(Int($0.rounded()))%" } ?? "Set up fan control"
        enableButton.setAccessibilityLabel(enableButton.title)
        enableButton.toolTip = model.setupMessage
        message.stringValue = model.error ?? ""; message.isHidden = model.error == nil
        message.toolTip = model.error
        settingsPage.updateStatus()

        let key = "\(needsSetup)|\(editing)|\(settingsOpen)|\(editorViews.count)|\(presetButtons.count)|\(message.stringValue)|\(temperature.stringValue)\(unit.stringValue)|\(percent.stringValue.count)|\(model.minimumPercent)|\(settingsPage.layoutKey)"
        if key != layoutKey { layoutKey = key; needsLayout = true }
        resize?(desiredHeight)
    }

    /// Big number and, only when it needs words, the state.
    private func showReadout(_ value: Double) {
        let shown = Int(value.rounded())
        let text = model.sample == nil ? "—%" : "\(shown)%"
        if percent.stringValue != text { percent.stringValue = text; needsLayout = true }
        percent.setAccessibilityValue(model.sample == nil ? "unavailable" : "\(shown) percent")
        let chip = exceptionState(interacting: slider.isInteracting)
        stateChip.stringValue = chip?.0 ?? ""; stateChip.textColor = chip?.1 ?? Theme.secondary
        stateChip.isHidden = chip == nil
        for (i, button) in presetButtons.enumerated() where model.presets.indices.contains(i) {
            button.selected = (model.ownsControl || model.requestedPercent != nil || slider.isInteracting) && abs(value - effectivePercent(model.presets[i])) < 0.5
        }
    }
    private func exceptionState(interacting: Bool) -> (String, NSColor)? {
        guard model.sample != nil else { return nil }
        if model.stale { return ("No reading", Theme.caution) }
        if interacting { return model.helperReady ? (slider.dragging ? nil : ("Applying…", Theme.secondary)) : ("Not applied", Theme.caution) }
        if model.busy && model.helperReady { return ("Applying…", Theme.secondary) }
        if model.pendingPercent != nil { return ("Not applied", Theme.caution) }
        if !model.ownsControl && model.sample?.automatic == false { return ("External control", Theme.secondary) }
        return nil
    }
    private func effectivePercent(_ preset: FanPreset) -> Double { max(model.minimumPercent, min(100, preset.percent)).rounded() }

    /// Single path for every user-requested speed (slider release, keys,
    /// presets, Manual). Before setup the model stores it as a preview.
    private func request(_ value: Double, animated: Bool) {
        let target = max(model.minimumPercent, min(100, value.rounded()))
        if !model.stale {
            hold = (target, Date().addingTimeInterval(3))
            if animated { slider.setPercent(target, animated: true, celebrate: true) }
        }
        model.setPercent(target)
    }

    // MARK: Presets

    private func syncPresets() {
        if presetButtons.count != model.presets.count {
            presetButtons.forEach { $0.removeFromSuperview() }
            presetButtons = model.presets.indices.map { i in
                let button = SoftButton("") { [weak self] in self?.applyPreset(at: i) }
                fanSection.addSubview(button); return button
            }
        }
        for (i, button) in presetButtons.enumerated() {
            let preset = model.presets[i], figure = "\(Int(effectivePercent(preset)))%"
            if button.title != preset.name { button.title = preset.name }
            button.detail = figure; button.toolTip = nil
            button.setAccessibilityLabel("\(preset.name) preset, \(figure)")
            button.isEnabled = !model.stale
            button.isHidden = editing
        }
        showReadout(slider.percent)
    }
    private func applyPreset(at i: Int) {
        guard model.presets.indices.contains(i) else { return }
        request(model.presets[i].percent, animated: true)
    }
    /// Ends any in-progress text edit so its value is saved before the editor
    /// or settings are rebuilt.
    private func endTextEditing() {
        guard let window, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }
    private func openEditorFromSettings() {
        endTextEditing()
        settingsOpen = false; editing = true
        rebuildEditor(); showSection(fanSection, from: -1); update()
    }
    private func finishEditing() {
        endTextEditing()
        editing = false; rebuildEditor(); update()
    }
    private func rebuildEditor() {
        editorViews.forEach { $0.removeFromSuperview() }; editorViews.removeAll()
        guard editing else { return }
        for (i, preset) in model.presets.enumerated() {
            let name = NSTextField(string: preset.name); name.font = Theme.font(12); name.bezelStyle = .roundedBezel; name.placeholderString = "Name"; name.tag = i * 10; name.delegate = self; name.setAccessibilityLabel("Preset \(i + 1) name")
            let value = NSTextField(string: "\(Int(preset.percent))"); value.font = Theme.number(12); value.alignment = .right; value.bezelStyle = .roundedBezel; value.tag = i * 10 + 1; value.delegate = self; value.setAccessibilityLabel("Preset \(i + 1) percentage")
            let suffix = label("%", size: 12, color: .secondaryLabelColor)
            let remove = SoftButton("", glyph: .close) { [weak self] in self?.removePreset(at: i) }
            remove.quiet = true; remove.setAccessibilityLabel("Delete \(preset.name) preset"); remove.toolTip = "Delete"
            [name, value, suffix, remove].forEach { editorViews.append($0); fanSection.addSubview($0) }
        }
        let full = model.presets.count >= 6
        let add = SoftButton("Add current speed", glyph: .plus) { [weak self] in self?.addPreset() }
        add.quiet = true; add.isEnabled = !full; add.toolTip = full ? "Up to six presets" : nil
        let done = SoftButton("Done") { [weak self] in self?.finishEditing() }
        done.selected = true; done.setAccessibilityLabel("Finish editing presets")
        [add, done].forEach { editorViews.append($0); fanSection.addSubview($0) }
    }
    private func layoutEditor(at y: CGFloat, margin m: CGFloat, width w: CGFloat) {
        let rows = max(0, (editorViews.count - 2) / 4)
        let removeX = m + w - 28, suffixX = removeX - 8 - 14, valueX = suffixX - 2 - 52
        for i in 0..<rows {
            let row = y + CGFloat(i) * 34
            editorViews[i * 4].frame = .init(x: m, y: row + 2, width: valueX - 8 - m, height: 24)
            editorViews[i * 4 + 1].frame = .init(x: valueX, y: row + 2, width: 52, height: 24)
            editorViews[i * 4 + 2].frame = .init(x: suffixX, y: row + 6, width: 14, height: 16)
            editorViews[i * 4 + 3].frame = .init(x: removeX, y: row, width: 28, height: 28)
        }
        let actions = y + CGFloat(rows) * 34 + 2
        editorViews[editorViews.count - 2].frame = .init(x: m - 4, y: actions, width: 158, height: 28)
        editorViews[editorViews.count - 1].frame = .init(x: m + w - 64, y: actions, width: 64, height: 28)
    }
    private func removePreset(at i: Int) {
        endTextEditing()
        guard model.presets.indices.contains(i) else { return }
        model.presets.remove(at: i); model.savePresets(); rebuildEditor(); update()
    }
    private func addPreset() {
        endTextEditing()
        guard model.presets.count < 6 else { return }
        model.presets.append(FanPreset(name: "Custom", percent: max(model.minimumPercent, slider.percent.rounded())))
        model.savePresets(); rebuildEditor(); update()
        if let field = editorViews.dropLast(2).dropLast(3).last as? NSTextField { window?.makeFirstResponder(field); field.currentEditor()?.selectAll(nil) }
    }
    /// Saves as you type so closing the editor, opening Settings or hiding
    /// the panel never loses an edit. Buttons update live.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, model.presets.indices.contains(field.tag / 10) else { return }
        let i = field.tag / 10
        if field.tag % 10 == 0 {
            let name = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
            guard !name.isEmpty else { return }
            model.presets[i].name = name
        } else {
            guard let n = Double(field.stringValue.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)), n.isFinite else { return }
            model.presets[i].percent = max(0, min(100, n.rounded()))
        }
        model.savePresets()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, model.presets.indices.contains(field.tag / 10) else { return }; let i = field.tag / 10
        if field.tag % 10 == 0 {
            let value = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
            model.presets[i].name = value.isEmpty ? "Custom" : value; field.stringValue = model.presets[i].name
        } else {
            if let n = Double(field.stringValue.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)), n.isFinite { model.presets[i].percent = max(model.minimumPercent, min(100, n.rounded())) }
            field.stringValue = "\(Int(model.presets[i].percent))"
        }
        model.savePresets(); update()
    }

    // MARK: Settings

    private func toggleSettings() {
        endTextEditing()
        settingsOpen.toggle()
        if settingsOpen {
            editing = false; rebuildEditor()
            settingsPage.sync()
            showSection(settingsPage, from: 1)
        } else {
            showSection(fanSection, from: -1)
        }
        update()
    }
    /// Swaps the lower section in place: the incoming one slides a few
    /// points in from the side it lives on and fades up; the outgoing one
    /// leaves at once (exits are faster than entrances).
    private func showSection(_ incoming: NSView, from direction: CGFloat) {
        let outgoing: NSView = incoming === settingsPage ? fanSection : settingsPage
        outgoing.isHidden = true; incoming.isHidden = false
        guard Theme.effects.animates, window?.isVisible == true, let layer = incoming.layer else { incoming.alphaValue = 1; return }
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(12 * direction, 0, 0)); slide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        slide.duration = 0.26; slide.timingFunction = Theme.Ease.out
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.2
        layer.add(slide, forKey: "slide"); layer.add(fade, forKey: "fade")
    }
}

/// Soft radial light behind the temperature, coloured by the heat band.
/// Changes only when the band changes; never animates on its own.
final class AuraView: NSView {
    private let glow = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.type = .radial; glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1); glow.opacity = 0
        layer?.addSublayer(glow)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
    private var state = ThermalState.unknown, effects = Theme.effects, heatColor = true

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply(state: state, effects: effects, heatColor: heatColor, animated: false) }

    private static func strength(_ state: ThermalState) -> Double {
        switch state {
        case .unknown, .steady: return 0
        case .cool: return 0.35
        case .warm: return 0.55
        case .hot: return 0.8
        case .peak: return 1
        }
    }
    func apply(state: ThermalState, effects: EffectsProfile, heatColor: Bool, animated: Bool, rising: Bool = false) {
        self.state = state; self.effects = effects; self.heatColor = heatColor
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = Theme.cg(Theme.heat(state).withAlphaComponent(dark ? 0.30 : 0.20), effectiveAppearance)
        let clear = Theme.cg(Theme.heat(state).withAlphaComponent(0), effectiveAppearance)
        let opacity = Float(heatColor ? effects.aura * Self.strength(state) : 0)
        let fromColors = (glow.presentation() ?? glow).colors, fromOpacity = (glow.presentation() ?? glow).opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.colors = [color, clear]; glow.opacity = opacity
        if animated && effects.animates {
            let tone = CABasicAnimation(keyPath: "colors"); tone.fromValue = fromColors; tone.toValue = glow.colors
            tone.duration = 0.7; tone.timingFunction = Theme.Ease.inOut
            glow.add(tone, forKey: "tone")
            let light = CAKeyframeAnimation(keyPath: "opacity")
            // A rising band breathes in once, then settles. Never repeats.
            light.values = rising && effects.rolls ? [fromOpacity, min(1, opacity * 1.5 + 0.1), opacity] : [fromOpacity, opacity]
            light.keyTimes = rising && effects.rolls ? [0, 0.35, 1] : [0, 1]
            light.duration = rising ? 0.9 : 0.6; light.timingFunction = Theme.Ease.inOut
            glow.add(light, forKey: "light")
        } else {
            glow.removeAnimation(forKey: "tone"); glow.removeAnimation(forKey: "light")
        }
        CATransaction.commit()
    }
    func settle() { glow.removeAllAnimations() }
}

/// Inline settings: short row labels on the left, native controls on the
/// right. Every change applies and persists immediately.
final class SettingsView: FlippedView {
    let model: AppModel
    var editPresets: (() -> Void)?
    var quit: (() -> Void)?
    var changed: (() -> Void)?
    private let prefs = PresentationPreferences.shared
    private let sensorValues = ["CPU", "GPU", "Warmer"]

    private let sensor = NSSegmentedControl(labels: ["CPU", "GPU", "Max"], trackingMode: .selectOne, target: nil, action: nil)
    private let units = NSSegmentedControl(labels: ["°C", "°F"], trackingMode: .selectOne, target: nil, action: nil)
    private let menuBar = NSSegmentedControl(labels: MenuBarContent.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let spacing = NSSegmentedControl(labels: MenuBarSpacing.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let effects = NSSegmentedControl(labels: EffectsLevel.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let heat = NSSwitch(), autoReturn = NSSwitch(), login = NSSwitch(), lowPower = NSSwitch()
    private let returnSlider = NSSlider(value: 30, minValue: 5, maxValue: 120, target: nil, action: nil)
    private let returnValue = label("30 min", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let errorMessage = NSTextField(wrappingLabelWithString: "")
    private lazy var source = SoftButton("Source code", glyph: .github) { NSWorkspace.shared.open(URL(string: "https://github.com/kirniy/aervane")!) }
    private lazy var editButton = SoftButton("Edit Presets") { [weak self] in self?.editPresets?() }
    private lazy var quitButton = SoftButton("Quit", glyph: .power) { [weak self] in self?.quit?() }
    var buttons: [SoftButton] { [source, editButton, quitButton] }
    private var rows: [(label: NSTextField, control: NSView)] = []

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        let entries: [(String, NSView, String?)] = [
            ("Sensor", sensor, nil), ("Units", units, nil), ("Menu bar", menuBar, nil), ("Spacing", spacing, "Menu bar item spacing"),
            ("Effects", effects, "Light, frost and motion. Reduce Motion and Reduce Transparency always apply."),
            ("Heat color", heat, "Tint the temperature by how hot it is"),
            ("Return to Auto", autoReturn, "Hand the fan back to macOS after a set time"),
            ("", returnSlider, nil),
            ("Open at login", login, nil), ("Low power", lowPower, "Read sensors less often while the panel is closed"),
        ]
        for (title, control, tip) in entries {
            let name = label(title, size: 12, color: .labelColor)
            name.toolTip = tip; control.toolTip = tip
            if !title.isEmpty { control.setAccessibilityLabel(title) }
            if let control = control as? NSControl { control.target = self; control.action = #selector(changedControl(_:)) }
            rows.append((name, control)); addSubview(name); addSubview(control)
        }
        for control in [sensor, units, menuBar, spacing, effects] { control.controlSize = .small; control.segmentDistribution = .fillEqually; control.font = Theme.font(11, .medium) }
        for toggle in [heat, autoReturn, login, lowPower] { toggle.controlSize = .small }
        returnSlider.controlSize = .small; returnSlider.isContinuous = true
        returnSlider.setAccessibilityLabel("Return to Auto after")
        returnValue.alignment = .right
        addSubview(returnValue)
        errorMessage.font = Theme.font(11); errorMessage.textColor = Theme.caution
        errorMessage.maximumNumberOfLines = 2; errorMessage.lineBreakMode = .byTruncatingTail
        addSubview(errorMessage)
        source.quiet = true; source.setAccessibilityLabel("Source code on GitHub")
        editButton.quiet = true; quitButton.quiet = true
        buttons.forEach(addSubview)
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Changes when the row set changes (the time slider shows only when
    /// Return to Auto is on).
    var layoutKey: String { "\(model.autoReturnEnabled)|\(model.error ?? "")" }

    func updateStatus() {
        let text = model.error ?? ""
        if errorMessage.stringValue != text { errorMessage.stringValue = text; needsLayout = true }
        errorMessage.isHidden = text.isEmpty
        errorMessage.toolTip = model.error
    }

    func sync() {
        sensor.selectedSegment = sensorValues.firstIndex(of: model.selectedSensor) ?? 0
        units.selectedSegment = model.fahrenheit ? 1 : 0
        menuBar.selectedSegment = MenuBarContent.allCases.firstIndex(of: prefs.menuBarContent) ?? 0
        spacing.selectedSegment = MenuBarSpacing.allCases.firstIndex(of: prefs.menuBarSpacing) ?? 0
        effects.selectedSegment = EffectsLevel.allCases.firstIndex(of: prefs.effects) ?? 0
        heat.state = prefs.heatColor ? .on : .off
        autoReturn.state = model.autoReturnEnabled ? .on : .off
        login.state = model.loginEnabled ? .on : .off
        lowPower.state = model.lowPower ? .on : .off
        returnSlider.doubleValue = model.autoReturnMinutes
        returnSlider.isHidden = !model.autoReturnEnabled; returnValue.isHidden = !model.autoReturnEnabled
        returnValue.stringValue = DurationText.short(minutes: model.autoReturnMinutes)
        returnSlider.setAccessibilityValueDescription(DurationText.spoken(minutes: model.autoReturnMinutes))
        updateStatus()
        needsLayout = true
    }

    private var visibleRows: [(label: NSTextField, control: NSView)] { rows.filter { !($0.control === returnSlider && !model.autoReturnEnabled) } }

    func height(width: CGFloat, margin: CGFloat) -> CGFloat { CGFloat(visibleRows.count) * 30 + 8 + 30 + 2 + (model.error == nil ? 0 : 40) }

    override func layout() {
        super.layout()
        let m: CGFloat = 16, w = bounds.width - 2 * m
        var y: CGFloat = 0
        for row in rows { row.label.isHidden = true; if row.control !== returnSlider { row.control.isHidden = false } }
        for row in visibleRows {
            row.label.isHidden = false
            row.label.frame = NSRect(x: m, y: y + 5, width: 120, height: 16)
            if let toggle = row.control as? NSSwitch {
                let size = toggle.fittingSize
                toggle.frame = NSRect(x: m + w - size.width, y: y + (26 - size.height) / 2, width: size.width, height: size.height)
            } else if row.control === returnSlider {
                returnSlider.frame = NSRect(x: m, y: y + 3, width: w - 84, height: 20)
                returnValue.frame = NSRect(x: m + w - 76, y: y + 5, width: 76, height: 16)
            } else {
                let controlWidth: CGFloat = row.control === sensor || row.control === units ? 150 : 206
                row.control.frame = NSRect(x: m + w - controlWidth, y: y + 2, width: controlWidth, height: 22)
            }
            y += 30
        }
        y += 8
        if model.error != nil {
            errorMessage.frame = NSRect(x: m, y: y, width: w, height: 32)
            y += 40
        }
        source.frame = NSRect(x: m - 6, y: y, width: 124, height: 28)
        editButton.frame = NSRect(x: m + 122, y: y, width: 96, height: 28)
        quitButton.frame = NSRect(x: m + w - 68, y: y, width: 74, height: 28)
    }

    @objc private func changedControl(_ sender: NSControl) {
        if sender === sensor {
            model.selectedSensor = sensorValues[max(0, sensor.selectedSegment)]; model.history.removeAll()
        } else if sender === units {
            model.fahrenheit = units.selectedSegment == 1
        } else if sender === menuBar {
            prefs.menuBarContent = MenuBarContent.allCases[max(0, menuBar.selectedSegment)]
        } else if sender === spacing {
            prefs.menuBarSpacing = MenuBarSpacing.allCases[max(0, spacing.selectedSegment)]
        } else if sender === effects {
            prefs.effects = EffectsLevel.allCases[max(0, effects.selectedSegment)]
        } else if sender === heat {
            prefs.heatColor = heat.state == .on
        } else if sender === autoReturn {
            model.autoReturnEnabled = autoReturn.state == .on
        } else if sender === returnSlider {
            // Whole five-minute steps; the model clamps and persists.
            let minutes = (returnSlider.doubleValue / 5).rounded() * 5
            returnSlider.doubleValue = minutes
            if model.autoReturnMinutes != minutes { model.autoReturnMinutes = minutes }
            // Dragging updates the value label without re-laying out rows.
            returnValue.stringValue = DurationText.short(minutes: minutes)
            returnSlider.setAccessibilityValueDescription(DurationText.spoken(minutes: minutes))
            return
        } else if sender === login {
            model.toggleLogin()
        } else if sender === lowPower {
            model.lowPower = lowPower.state == .on
        }
        sync()
        changed?()
    }
}
