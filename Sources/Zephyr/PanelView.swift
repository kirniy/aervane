import AppKit
import ZephyrCore

/// One compact glass panel. Frames come from a single `arrange` pass on a
/// 4/8 pt grid, so the window height can never disagree with the layout.
final class PanelView: FlippedView, NSTextFieldDelegate {
    let model: AppModel
    var resize: ((CGFloat) -> Void)?
    var quit: (() -> Void)?
    var preferredFirstResponder: NSView { slider }
    private var needsSetup: Bool { !model.helperReady || model.competingApp != nil }
    private let titleLabel = label("Aervane", size: 13, weight: .semibold)
    private let temperature = label("—", size: 44, weight: .light)
    private let unit = label("°C", size: 17, color: .secondaryLabelColor)
    private let temperatureCaption = label("CPU average", size: 11, color: .secondaryLabelColor)
    private let health = label("Reading sensors…", size: 11, color: .secondaryLabelColor)
    private let chart = TemperatureHistory()
    private let speedLabel = label("Fan", size: 13, weight: .semibold)
    private let percent = label("—%", size: 28, weight: .medium)
    private let stateLabel = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let actual = label("", size: 11, color: .secondaryLabelColor)
    private let slider = PercentSlider(frame: .zero)
    private let floorLabel = label("", size: 11, color: .secondaryLabelColor)
    private let maxLabel = label("100%", size: 11, color: .secondaryLabelColor)
    private let presetsTitle = label("Presets", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private let footer = label("", size: 11, color: .secondaryLabelColor)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var presetButtons: [SoftButton] = []
    private var editing = false
    private var settingsOpen = false
    private var editorViews: [NSView] = []
    private var settingsViews: [NSView] = []
    private var dividers: [CGFloat] = []
    private var layoutKey = ""
    /// A value the user asked for that the model has not confirmed yet. Keeps
    /// the thumb from snapping back while the helper write is in flight.
    private var hold: (value: Double, until: Date)?
    private lazy var settingsButton = SoftButton("", glyph: .settings) { [weak self] in self?.toggleSettings() }
    private lazy var autoButton = SoftButton("Auto") { [weak self] in self?.model.restore() }
    private lazy var manualButton = SoftButton("Manual") { [weak self] in guard let self else { return }; self.request(self.model.shownPercent, animated: false) }
    private lazy var editButton = SoftButton("Edit") { [weak self] in self?.toggleEditor() }
    private lazy var enableButton = SoftButton("Set up fan control", glyph: .airflow) { [weak self] in self?.model.enableControl() }

    init(model: AppModel) {
        self.model = model; super.init(frame: .init(x: 0, y: 0, width: 380, height: 420))
        wantsLayer = true
        [titleLabel, temperature, unit, temperatureCaption, health, chart, speedLabel, percent, stateLabel, actual, slider, floorLabel, maxLabel, presetsTitle, footer, message, settingsButton, autoButton, manualButton, editButton, enableButton].forEach(addSubview)
        temperature.font = Theme.rounded(44, .light); unit.font = Theme.rounded(17); percent.font = Theme.number(28, .medium)
        message.font = Theme.font(11); message.textColor = Theme.caution; message.maximumNumberOfLines = 3
        [stateLabel, actual, maxLabel, health].forEach { $0.alignment = .right }
        settingsButton.quiet = true; editButton.quiet = true; enableButton.prominent = true
        settingsButton.setAccessibilityLabel("Settings"); settingsButton.toolTip = "Settings"
        autoButton.setAccessibilityLabel("Restore automatic fan control"); manualButton.setAccessibilityLabel("Manual fan control")
        slider.preview = { [weak self] value in self?.showReadout(value) }
        slider.commit = { [weak self] value in self?.request(value, animated: false) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat { arrange(apply: false) }
    func prepareForHiding() {
        endTextEditing()
        slider.prepareForHiding()
        for button in subviews.compactMap({ $0 as? SoftButton }) { button.resetHover() }
    }
    override func layout() { super.layout(); arrange(apply: true) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    // MARK: Layout

    @discardableResult private func arrange(apply: Bool) -> CGFloat {
        let m: CGFloat = 20, w = bounds.width - 2 * m, gap: CGFloat = 8
        var marks: [CGFloat] = []
        func put(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            if apply { view.frame = NSRect(x: x, y: y, width: max(0, width), height: height) }
        }
        var y: CGFloat = 16
        // Header: mark, name, settings.
        put(titleLabel, m + 24, y + 5, 200, 18)
        put(settingsButton, m + w - 28, y, 28, 28)
        y += 28 + 12
        // Temperature: the number leads; trend and plain-language health trail.
        let numberWidth = ceil(temperature.attributedStringValue.size().width) + 4
        put(temperature, m - 2, y, numberWidth, 52)
        // Cap-top align the unit with the number, from the actual font metrics.
        let numberFont = temperature.font ?? Theme.rounded(44, .light), unitFont = unit.font ?? Theme.rounded(17)
        let unitY = (y + (numberFont.ascender - numberFont.capHeight) - (unitFont.ascender - unitFont.capHeight)).rounded()
        put(unit, m - 2 + numberWidth, unitY, 40, 22)
        put(temperatureCaption, m, y + 52, 180, 16)
        put(chart, m + w - 128, y + 8, 128, 36)
        put(health, m + w - 160, y + 52, 160, 16)
        y += 68 + 16
        marks.append(y); y += 16
        // Fan: mode, readout, slider, scale.
        put(speedLabel, m, y + 4, 80, 18)
        put(manualButton, m + w - 68, y, 68, 26)
        put(autoButton, m + w - 68 - 4 - 56, y, 56, 26)
        y += 26 + 12
        put(percent, m - 1, y, 120, 34)
        put(stateLabel, m + 120, y + 2, w - 120, 16)
        put(actual, m + 120, y + 18, w - 120, 16)
        y += 34 + 4
        put(slider, m - 16, y, w + 32, 32)          // hit area spills into the margins
        y += 32
        put(floorLabel, m, y, w / 2, 14); put(maxLabel, m + w / 2, y, w / 2, 14)
        y += 14 + 16
        // Presets wrap into rows of at most three: 1–3 → one row, 4 → 2×2,
        // 5 → 3+2, 6 → 3×2. Short last rows stretch to the full width.
        put(presetsTitle, m, y + 4, 120, 16); put(editButton, m + w - 56, y, 56, 24)
        y += 24 + gap
        let count = presetButtons.count
        if count > 0 {
            let perRow = count <= 3 ? count : count == 4 ? 2 : 3
            let rows = (count + perRow - 1) / perRow
            for row in 0..<rows {
                let first = row * perRow, items = min(perRow, count - first)
                let width = (w - CGFloat(items - 1) * gap) / CGFloat(items)
                for i in 0..<items { put(presetButtons[first + i], (m + CGFloat(i) * (width + gap)).rounded(), y + CGFloat(row) * (32 + gap), width.rounded(.down), 32) }
            }
            y += CGFloat(rows) * 32 + CGFloat(rows - 1) * gap + 16
        }
        if editing {
            let rows = max(0, (editorViews.count - 1) / 4)
            if apply { layoutEditor(at: y, margin: m, width: w) }
            y += CGFloat(rows) * 36 + 28 + 16
        }
        if needsSetup { put(enableButton, m, y, w, 32); y += 32 + 16 }
        if settingsOpen {
            marks.append(y - 8)
            if apply { layoutSettings(at: y + 8, margin: m, width: w) }
            y += 8 + 166 + 16
        }
        if model.error != nil {
            let height = min(48, max(16, ceil(message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 200)).height ?? 32)))
            put(message, m, y, w, height); y += height + 12
        }
        put(footer, m, y, w, 14); y += 14 + 16
        if apply && marks != dividers { dividers = marks; needsDisplay = true }
        return y
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Glyphs.image(.airflow, size: 16, color: Theme.accent).draw(in: .init(x: 20, y: 22, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let hairline = 1 / max(1, window?.backingScaleFactor ?? 2)
        Theme.hairline.setFill(); for y in dividers { NSRect(x: 20, y: y, width: bounds.width - 40, height: hairline).fill() }
    }

    // MARK: State

    func update() {
        temperature.stringValue = model.temperatureText; unit.stringValue = model.temperatureUnit
        temperatureCaption.stringValue = model.selectedSensor == "CPU" ? "CPU average" : model.selectedSensor == "GPU" ? "GPU temperature" : "Warmer of CPU & GPU"
        let temp = model.displayTemperature
        health.stringValue = model.stale ? "No live reading" : temp.map { $0 >= 90 ? "Running hot" : $0 >= 75 ? "Working hard" : "Comfortable" } ?? "Reading sensors…"
        health.textColor = !model.stale && (temp ?? 0) >= 90 ? Theme.caution : Theme.secondary
        chart.samples = model.history

        slider.minimumPercent = model.minimumPercent
        slider.isUnavailable = model.stale
        slider.detents = model.presets.map { max(model.minimumPercent, $0.percent) }
        if let held = hold, !model.busy, abs(model.shownPercent - held.value) < 1.5 || model.error != nil || held.until < Date() { hold = nil }
        // A sample refresh never moves the thumb under the user's pointer/keys.
        if !slider.isInteracting {
            slider.isEnabled = !model.stale && !model.busy
            let value = (hold?.value ?? model.shownPercent).rounded()
            if abs(slider.percent - value) >= 0.5 { slider.setPercent(value, animated: window?.isVisible == true) }
            showReadout(slider.percent)
        }
        floorLabel.stringValue = model.sample == nil ? "" : model.minimumPercent > 0 ? "\(Int(model.minimumPercent))% hardware minimum" : "0% · fan can stop"

        let previewing = model.pendingPercent != nil
        autoButton.selected = model.sample?.automatic == true && !model.ownsControl && !previewing
        autoButton.isEnabled = !model.busy
        manualButton.selected = model.ownsControl || previewing
        manualButton.isEnabled = !model.stale && !model.busy
        syncPresets()
        editButton.title = editing ? "Done" : "Edit"; editButton.setAccessibilityLabel(editing ? "Finish editing presets" : "Edit presets")
        settingsButton.selected = settingsOpen

        enableButton.isHidden = !needsSetup; enableButton.isEnabled = !model.busy
        enableButton.title = model.busy && !model.helperReady ? "Connecting…" : model.pendingPercent.map { "Set up & apply \(Int($0.rounded()))%" } ?? "Set up fan control"
        enableButton.setAccessibilityLabel(enableButton.title)
        message.stringValue = model.error ?? ""; message.isHidden = model.error == nil
        if let deadline = model.controlDeadline, model.ownsControl { footer.stringValue = "Returns to Auto in \(max(1, Int(deadline.timeIntervalSinceNow / 60))) min" }
        else { footer.stringValue = model.helperReady ? "Live readings · Auto restored on quit" : "Live readings · nothing applied until setup" }

        let key = "\(needsSetup)|\(editing)|\(settingsOpen)|\(editorViews.count)|\(presetButtons.count)|\(model.error ?? "")|\(temperature.stringValue)\(unit.stringValue)"
        if key != layoutKey { layoutKey = key; needsLayout = true }
        resize?(desiredHeight)
    }

    /// Big number, status and (only when it differs) the measured speed.
    private func showReadout(_ value: Double) {
        let shown = Int(value.rounded())
        percent.stringValue = model.sample == nil ? "—%" : "\(shown)%"
        let (text, color) = statusLine()
        stateLabel.stringValue = text; stateLabel.textColor = color
        let measured = Int(model.actualPercent.rounded())
        let informative = model.sample != nil && !model.stale && abs(measured - shown) >= 3
        actual.stringValue = !informative ? "" : model.ownsControl && model.pendingPercent == nil && !slider.isInteracting ? "Actual \(measured)% · settling" : "Fan now \(measured)%"
        for (i, button) in presetButtons.enumerated() where model.presets.indices.contains(i) {
            button.selected = (model.ownsControl || model.pendingPercent != nil || slider.isInteracting) && abs(value - effectivePercent(model.presets[i])) < 0.5
        }
    }
    private func statusLine() -> (String, NSColor) {
        if model.sample == nil { return ("Reading sensors…", Theme.secondary) }
        if model.stale { return ("Waiting for a fresh reading", Theme.caution) }
        if slider.isInteracting {
            if !model.helperReady { return ("Preview · not applied", Theme.caution) }
            return (slider.dragging ? "Release to apply" : "Applying…", Theme.accent)
        }
        if model.busy { return (model.helperReady ? "Applying…" : "Connecting…", Theme.secondary) }
        if model.pendingPercent != nil { return ("Preview · not applied", Theme.caution) }
        if model.ownsControl { return ("Manual · applied", Theme.accent) }
        if model.sample?.automatic == true { return ("Automatic", Theme.secondary) }
        return ("Set by another controller", Theme.secondary)
    }
    private func effectivePercent(_ preset: FanPreset) -> Double { max(model.minimumPercent, min(100, preset.percent)).rounded() }

    /// Single path for every user-requested speed (slider release, keys,
    /// presets, Manual). Before setup the model stores it as a preview.
    private func request(_ value: Double, animated: Bool) {
        guard !model.busy else { return }
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
                addSubview(button); return button
            }
        }
        for (i, button) in presetButtons.enumerated() {
            let preset = model.presets[i], figure = "\(Int(effectivePercent(preset)))%"
            if button.title != preset.name { button.title = preset.name }
            button.detail = figure; button.toolTip = "\(preset.name) · \(figure)"
            button.setAccessibilityLabel("\(preset.name) preset, \(figure)")
            button.isEnabled = !model.stale && !model.busy
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
    private func toggleEditor() {
        endTextEditing()
        editing.toggle(); if editing { settingsOpen = false; rebuildSettings() }
        rebuildEditor(); update()
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
            [name, value, suffix, remove].forEach { editorViews.append($0); addSubview($0) }
        }
        let full = model.presets.count >= 6
        let add = SoftButton("Add current speed", glyph: .plus) { [weak self] in self?.addPreset() }
        add.quiet = true; add.isEnabled = !full; add.toolTip = full ? "Up to six presets" : nil
        editorViews.append(add); addSubview(add)
    }
    private func layoutEditor(at y: CGFloat, margin m: CGFloat, width w: CGFloat) {
        let rows = max(0, (editorViews.count - 1) / 4)
        let removeX = m + w - 28, suffixX = removeX - 8 - 14, valueX = suffixX - 2 - 52
        for i in 0..<rows {
            let row = y + CGFloat(i) * 36
            editorViews[i * 4].frame = .init(x: m, y: row + 2, width: valueX - 8 - m, height: 24)
            editorViews[i * 4 + 1].frame = .init(x: valueX, y: row + 2, width: 52, height: 24)
            editorViews[i * 4 + 2].frame = .init(x: suffixX, y: row + 6, width: 14, height: 16)
            editorViews[i * 4 + 3].frame = .init(x: removeX, y: row, width: 28, height: 28)
        }
        editorViews.last?.frame = .init(x: m - 4, y: y + CGFloat(rows) * 36, width: 150, height: 28)
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
        if let field = editorViews.dropLast().dropLast(3).last as? NSTextField { window?.makeFirstResponder(field); field.currentEditor()?.selectAll(nil) }
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
        settingsOpen.toggle(); if settingsOpen { editing = false; rebuildEditor() }
        rebuildSettings(); update()
    }
    private func rebuildSettings() {
        settingsViews.forEach { $0.removeFromSuperview() }; settingsViews.removeAll()
        guard settingsOpen else { return }
        let sensorTitle = label("Menu bar temperature", size: 11, weight: .semibold, color: .secondaryLabelColor)
        let sensors = NSSegmentedControl(labels: ["CPU", "GPU", "Warmer"], trackingMode: .selectOne, target: self, action: #selector(sensorChanged)); sensors.selectedSegment = ["CPU", "GPU", "Warmer"].firstIndex(of: model.selectedSensor) ?? 0; sensors.controlSize = .small; sensors.segmentDistribution = .fillEqually
        let units = NSButton(checkboxWithTitle: "Use Fahrenheit", target: self, action: #selector(unitsChanged)); units.state = model.fahrenheit ? .on : .off
        let login = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(loginChanged)); login.state = model.loginEnabled ? .on : .off
        let eco = NSButton(checkboxWithTitle: "Low-power polling when closed", target: self, action: #selector(ecoChanged)); eco.state = model.lowPower ? .on : .off
        [units, login, eco].forEach { $0.font = Theme.font(12) }
        let repo = SoftButton("Source code") { NSWorkspace.shared.open(URL(string: "https://github.com/kirniy/aervane")!) }; repo.quiet = true
        let quitButton = SoftButton("Quit Aervane", glyph: .power) { [weak self] in self?.quit?() }
        settingsViews = [sensorTitle, sensors, units, login, eco, repo, quitButton]; settingsViews.forEach(addSubview)
    }
    private func layoutSettings(at y: CGFloat, margin m: CGFloat, width w: CGFloat) {
        guard settingsViews.count == 7 else { return }
        settingsViews[0].frame = .init(x: m, y: y, width: w, height: 16)
        settingsViews[1].frame = .init(x: m, y: y + 22, width: w, height: 24)
        for i in 2...4 { settingsViews[i].frame = .init(x: m, y: y + 58 + CGFloat(i - 2) * 24, width: w, height: 20) }
        settingsViews[5].frame = .init(x: m - 4, y: y + 138, width: 110, height: 28)
        settingsViews[6].frame = .init(x: m + w - 132, y: y + 138, width: 132, height: 28)
    }
    @objc private func sensorChanged(_ sender: NSSegmentedControl) { model.selectedSensor = ["CPU", "GPU", "Warmer"][sender.selectedSegment]; model.history.removeAll() }
    @objc private func unitsChanged(_ sender: NSButton) { model.fahrenheit = sender.state == .on }
    @objc private func loginChanged(_ sender: NSButton) { model.toggleLogin(); sender.state = model.loginEnabled ? .on : .off }
    @objc private func ecoChanged(_ sender: NSButton) { model.lowPower = sender.state == .on }
}
