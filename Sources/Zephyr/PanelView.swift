import AppKit
import ZephyrCore

final class PanelView: FlippedView, NSTextFieldDelegate {
    let model: AppModel
    var resize: ((CGFloat) -> Void)?
    var quit: (() -> Void)?
    private let titleLabel = label("Aervane", size: 16, weight: .semibold)
    private let temperature = label("—", size: 64, weight: .light)
    private let unit = label("°C", size: 25, weight: .regular, color: .secondaryLabelColor)
    private let temperatureCaption = label("CPU average", size: 12, color: .secondaryLabelColor)
    private let health = label("Reading sensors…", size: 12, color: .secondaryLabelColor)
    private let chart = TemperatureHistory()
    private let speedLabel = label("Cooling", size: 14, weight: .medium)
    private let percent = label("—%", size: 30, weight: .medium)
    private let actual = label("", size: 11, color: .secondaryLabelColor)
    private let slider = PercentSlider(frame: .zero)
    private let quietLabel = label("Quieter", size: 11, color: .secondaryLabelColor)
    private let coolLabel = label("Cooler", size: 11, color: .secondaryLabelColor)
    private let note = label("", size: 11, color: .secondaryLabelColor)
    private let footer = label("", size: 11, color: .secondaryLabelColor)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var presetButtons: [SoftButton] = []
    private var editing = false
    private var settingsOpen = false
    private var editorViews: [NSView] = []
    private var settingsViews: [NSView] = []
    private lazy var settingsButton = SoftButton("", glyph: .settings) { [weak self] in self?.toggleSettings() }
    private lazy var autoButton = SoftButton("Auto") { [weak self] in self?.model.restore() }
    private lazy var manualButton = SoftButton("Manual") { [weak self] in guard let self else { return }; if self.model.helperReady { self.model.setPercent(self.model.shownPercent) } else { self.model.enableControl() } }
    private lazy var editButton = SoftButton("Edit") { [weak self] in self?.toggleEditor() }
    private lazy var enableButton = SoftButton("Enable fan control", glyph: .airflow) { [weak self] in self?.model.enableControl() }

    init(model: AppModel) {
        self.model = model; super.init(frame: .init(x: 0, y: 0, width: 380, height: 458))
        wantsLayer = true
        [titleLabel, temperature, unit, temperatureCaption, health, chart, speedLabel, percent, actual, slider, quietLabel, coolLabel, note, footer, message, settingsButton, autoButton, manualButton, editButton, enableButton].forEach(addSubview)
        temperature.font = Theme.rounded(64, .light); percent.font = Theme.number(30, .medium)
        message.font = Theme.font(11); message.textColor = .systemOrange; message.maximumNumberOfLines = 3
        settingsButton.setAccessibilityLabel("Settings"); autoButton.setAccessibilityLabel("Restore automatic fan control"); manualButton.setAccessibilityLabel("Manual fan control")
        coolLabel.alignment = .right; percent.alignment = .right; actual.alignment = .right
        slider.preview = { [weak self] value in self?.percent.stringValue = "\(Int(value))%"; self?.note.stringValue = value == 100 ? "Maximum cooling" : "Release to apply" }
        slider.commit = { [weak self] value in self?.model.setPercent(value) }
        makePresets(); update()
    }
    required init?(coder: NSCoder) { fatalError() }
    var desiredHeight: CGFloat { 458 + (model.helperReady ? 0 : 48) + (editing ? CGFloat(model.presets.count * 44 + 54) : 0) + (settingsOpen ? 212 : 0) + (model.error == nil ? 0 : 54) }
    override func layout() {
        super.layout()
        titleLabel.frame = .init(x: 50, y: 24, width: 210, height: 22)
        settingsButton.frame = .init(x: 326, y: 18, width: 32, height: 32)
        temperature.frame = .init(x: 24, y: 72, width: 144, height: 80)
        unit.frame = .init(x: 165, y: 88, width: 48, height: 36)
        temperatureCaption.frame = .init(x: 28, y: 153, width: 200, height: 18)
        health.frame = .init(x: 238, y: 94, width: 116, height: 20)
        chart.frame = .init(x: 238, y: 119, width: 112, height: 42)
        speedLabel.frame = .init(x: 26, y: 206, width: 100, height: 20)
        autoButton.frame = .init(x: 225, y: 198, width: 57, height: 30)
        manualButton.frame = .init(x: 286, y: 198, width: 68, height: 30)
        percent.frame = .init(x: 248, y: 242, width: 108, height: 40)
        actual.frame = .init(x: 230, y: 284, width: 124, height: 16)
        quietLabel.frame = .init(x: 26, y: 257, width: 100, height: 18)
        slider.frame = .init(x: 21, y: 300, width: 338, height: 48)
        note.frame = .init(x: 26, y: 353, width: 245, height: 18)
        coolLabel.frame = .init(x: 294, y: 353, width: 60, height: 18)
        let width = model.presets.isEmpty ? 0 : (278.0 - CGFloat(max(0, model.presets.count - 1)) * 6) / CGFloat(model.presets.count)
        for (i, button) in presetButtons.enumerated() { button.frame = .init(x: 26 + CGFloat(i) * (width + 6), y: 385, width: width, height: 33) }
        editButton.frame = .init(x: 310, y: 385, width: 44, height: 33)
        var y: CGFloat = 432
        if !model.helperReady { enableButton.frame = .init(x: 26, y: y, width: 328, height: 33); y += 48 }
        if editing { layoutEditor(at: y); y += CGFloat(model.presets.count * 44 + 54) }
        if settingsOpen { layoutSettings(at: y); y += 212 }
        if model.error != nil { message.frame = .init(x: 26, y: y, width: 328, height: 48); y += 54 }
        footer.frame = .init(x: 26, y: y, width: 328, height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Glyphs.image(.airflow, size: 18, color: Theme.accent).draw(in: .init(x: 26, y: 25, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        Theme.ink.withAlphaComponent(0.09).setFill(); NSRect(x: 26, y: 187, width: 328, height: 0.5).fill()
    }
    func update() {
        temperature.stringValue = model.temperatureText; unit.stringValue = model.temperatureUnit
        temperatureCaption.stringValue = model.selectedSensor == "CPU" ? "CPU average" : model.selectedSensor == "GPU" ? "GPU temperature" : "Warmer of CPU & GPU"
        let temp = model.displayTemperature
        health.stringValue = model.stale ? "No live reading" : (temp ?? 0) >= 90 ? "Running hot" : (temp ?? 0) >= 75 ? "Working hard" : "Comfortable"
        health.textColor = (temp ?? 0) >= 90 ? .systemOrange : Theme.secondary
        chart.samples = model.history
        if !slider.dragging { percent.stringValue = "\(Int(model.shownPercent.rounded()))%"; slider.percent = model.shownPercent }
        slider.minimumPercent = model.minimumPercent
        slider.isEnabled = !model.stale && !model.busy
        actual.stringValue = "Actual \(Int(model.actualPercent.rounded()))%"
        quietLabel.stringValue = model.pendingPercent != nil ? "Preview · not applied" : model.sample?.automatic == true ? "Managed by macOS" : model.ownsControl ? "Your fan speed" : "Current fan speed"
        note.stringValue = model.pendingPercent != nil ? "Enable control to apply this speed" : model.minimumPercent > 0 ? "\(Int(model.minimumPercent))% hardware minimum" : "Fan stop supported"
        autoButton.selected = model.sample?.automatic == true && model.pendingPercent == nil; autoButton.isEnabled = model.ownsControl || model.pendingPercent != nil
        manualButton.selected = model.ownsControl; manualButton.isEnabled = !model.busy
        for (i, button) in presetButtons.enumerated() {
            button.isHidden = false; button.isEnabled = slider.isEnabled
            button.selected = model.ownsControl && abs(model.shownPercent - max(model.minimumPercent, model.presets[i].percent)) < 1.5
        }
        enableButton.isHidden = model.helperReady; enableButton.isEnabled = !model.busy
        enableButton.title = model.busy ? "Connecting…" : model.pendingPercent.map { "Enable & apply \(Int($0))%" } ?? "Enable fan control"
        editButton.title = editing ? "Done" : "Edit"; settingsButton.selected = settingsOpen
        message.stringValue = model.error ?? ""; message.isHidden = model.error == nil
        if let deadline = model.controlDeadline, model.ownsControl { footer.stringValue = "Returns to Auto in \(max(1, Int(deadline.timeIntervalSinceNow / 60))) min · protected by macOS" }
        else { footer.stringValue = model.helperReady ? "Live readings · automatic on quit" : "Live readings · no background network activity" }
        needsLayout = true; needsDisplay = true; resize?(desiredHeight)
    }
    private func makePresets() {
        presetButtons.forEach { $0.removeFromSuperview() }
        presetButtons = model.presets.enumerated().map { i, preset in
            let button = SoftButton(preset.name, glyph: model.presets.count <= 3 ? ([Glyph.quiet, .balance, .boost][min(i, 2)]) : nil) { [weak self] in self?.model.setPercent(preset.percent) }
            button.toolTip = "\(preset.name) · \(Int(preset.percent))%"; addSubview(button); return button
        }
    }
    private func toggleEditor() {
        editing.toggle(); settingsOpen = false; settingsViews.forEach { $0.removeFromSuperview() }; settingsViews.removeAll()
        rebuildEditor(); update()
    }
    private func rebuildEditor() {
        editorViews.forEach { $0.removeFromSuperview() }; editorViews.removeAll()
        guard editing else { return }
        for (i, preset) in model.presets.enumerated() {
            let name = NSTextField(string: preset.name); name.font = Theme.font(12); name.bezelStyle = .roundedBezel; name.tag = i * 10; name.delegate = self; name.setAccessibilityLabel("Preset \(i + 1) name")
            let value = NSTextField(string: "\(Int(preset.percent))"); value.font = Theme.number(12); value.alignment = .right; value.bezelStyle = .roundedBezel; value.tag = i * 10 + 1; value.delegate = self; value.setAccessibilityLabel("Preset \(i + 1) percentage")
            let suffix = label("%", size: 12, color: .secondaryLabelColor)
            let remove = SoftButton("", glyph: .close) { [weak self] in guard let self else { return }; self.model.presets.remove(at: i); self.model.savePresets(); self.makePresets(); self.rebuildEditor(); self.update() }; remove.setAccessibilityLabel("Delete \(preset.name) preset")
            [name, value, suffix, remove].forEach { editorViews.append($0); addSubview($0) }
        }
        let add = SoftButton("Add preset", glyph: .plus) { [weak self] in guard let self, self.model.presets.count < 6 else { return }; self.model.presets.append(FanPreset(name: "Custom", percent: 50)); self.model.savePresets(); self.makePresets(); self.rebuildEditor(); self.update() }; add.isEnabled = model.presets.count < 6
        editorViews.append(add); addSubview(add)
    }
    private func layoutEditor(at y: CGFloat) {
        for i in model.presets.indices {
            let row = y + CGFloat(i) * 44
            editorViews[i * 4].frame = .init(x: 26, y: row, width: 180, height: 28)
            editorViews[i * 4 + 1].frame = .init(x: 216, y: row, width: 65, height: 28)
            editorViews[i * 4 + 2].frame = .init(x: 285, y: row + 5, width: 18, height: 20)
            editorViews[i * 4 + 3].frame = .init(x: 322, y: row, width: 32, height: 28)
        }
        editorViews.last?.frame = .init(x: 26, y: y + CGFloat(model.presets.count) * 44, width: 130, height: 30)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, model.presets.indices.contains(field.tag / 10) else { return }; let i = field.tag / 10
        if field.tag % 10 == 0 { let value = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)); model.presets[i].name = value.isEmpty ? "Custom" : value }
        else { if let n = Double(field.stringValue), n.isFinite { model.presets[i].percent = max(0, min(100, n.rounded())) }; field.stringValue = "\(Int(model.presets[i].percent))" }
        model.savePresets(); makePresets(); update()
    }
    private func toggleSettings() {
        settingsOpen.toggle(); editing = false; rebuildEditor(); settingsViews.forEach { $0.removeFromSuperview() }; settingsViews.removeAll()
        if settingsOpen {
            let sensorTitle = label("Menu bar temperature", size: 12, weight: .medium)
            let sensors = NSSegmentedControl(labels: ["CPU", "GPU", "Warmer"], trackingMode: .selectOne, target: self, action: #selector(sensorChanged)); sensors.selectedSegment = ["CPU", "GPU", "Warmer"].firstIndex(of: model.selectedSensor) ?? 0; sensors.controlSize = .small
            let units = NSButton(checkboxWithTitle: "Use Fahrenheit", target: self, action: #selector(unitsChanged)); units.state = model.fahrenheit ? .on : .off
            let login = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(loginChanged)); login.state = model.loginEnabled ? .on : .off
            let eco = NSButton(checkboxWithTitle: "Low-power polling when closed", target: self, action: #selector(ecoChanged)); eco.state = model.lowPower ? .on : .off
            let repo = SoftButton("Source code") { NSWorkspace.shared.open(URL(string: "https://github.com/kirniy/aervane")!) }
            let quitButton = SoftButton("Quit Aervane", glyph: .power) { [weak self] in self?.quit?() }
            settingsViews = [sensorTitle, sensors, units, login, eco, repo, quitButton]; settingsViews.forEach(addSubview)
        }; update()
    }
    private func layoutSettings(at y: CGFloat) {
        guard settingsViews.count == 7 else { return }
        settingsViews[0].frame = .init(x: 26, y: y, width: 230, height: 20)
        settingsViews[1].frame = .init(x: 26, y: y + 26, width: 328, height: 28)
        for i in 2...4 { settingsViews[i].frame = .init(x: 26, y: y + 62 + CGFloat(i - 2) * 30, width: 328, height: 24) }
        settingsViews[5].frame = .init(x: 26, y: y + 162, width: 130, height: 30)
        settingsViews[6].frame = .init(x: 204, y: y + 162, width: 150, height: 30)
    }
    @objc private func sensorChanged(_ sender: NSSegmentedControl) { model.selectedSensor = ["CPU", "GPU", "Warmer"][sender.selectedSegment]; model.history.removeAll() }
    @objc private func unitsChanged(_ sender: NSButton) { model.fahrenheit = sender.state == .on }
    @objc private func loginChanged(_ sender: NSButton) { model.toggleLogin(); sender.state = model.loginEnabled ? .on : .off }
    @objc private func ecoChanged(_ sender: NSButton) { model.lowPower = sender.state == .on }
}
