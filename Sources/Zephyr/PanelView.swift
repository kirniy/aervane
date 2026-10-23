import AppKit
import ServiceManagement
import ZephyrCore

/// One compact glass panel. Frames come from a single `arrange` pass on a
/// 4/8 pt grid, so the window height can never disagree with the layout.
///
/// Minimal copy: state is carried by layout and controls (the mode switch,
/// the measured-speed mark on the slider, heat colour), and text appears
/// only for exceptions that need words (not applied, no reading, errors).
///
/// Visual point of view: warm light behind the glass, frost on it. Heat
/// glows from behind the reading at the top; the fan's measured speed sends
/// cold air up from the lower edge; the cooling command frosts the slider.
///
/// Keyboard: arrows adjust the slider, 1–6 apply presets, A restores Auto,
/// S selects Smart, M takes manual control, [ and ] move Smart's target (⇧
/// by five), and ⌘, toggles Settings. Holding ⌘ shows these keys on the
/// controls. In the preset editor Return saves and Escape cancels. Text
/// fields keep their keys.
///
/// First launch shows a short introduction in place of the fan section
/// (`Onboarding`): the fan as it is, then a choice between controlling it and
/// only reading the temperature. Without a fan there is nothing to choose.
final class PanelView: FlippedView, NSTextFieldDelegate, NSMenuDelegate {
    static let width: CGFloat = 344
    let model: AppModel
    var resize: ((CGFloat) -> Void)?
    var quit: (() -> Void)?
    /// Called when the temperature band changes (the window tints its glass).
    var thermalChanged: ((ThermalState) -> Void)?
    var preferredFirstResponder: NSView {
        if settingsOpen || section == .temperatureOnly { return self }
        return section == .welcome ? welcomeCard.controlButton : slider
    }
    private(set) var thermal = ThermalState.unknown
    /// Which history the hero and chart show, to restart the heat band's
    /// hysteresis when the source changes.
    private var shownSeries = TemperatureReadout.Series.selected
    /// The introduction and the remembered fan choice (temperature only, or
    /// full control).
    let onboarding: OnboardingFlow
    private var section: Onboarding.Section { onboarding.state.section(fanAvailable: model.offersFanControls) }
    private var setupStage: Onboarding.Card { onboarding.state.card(helperReady: model.helperReady, fanAvailable: model.fanAvailable) }
    /// The Set Up button: only in the fan section, never while the setup card
    /// already says what to do.
    private var needsSetup: Bool { model.fanAvailable && section == .fan && setupStage == .none && (!model.helperReady || model.competingApp != nil) }
    /// A policy suggestion is not evidence that the helper applied it.
    private var smartAtMaximum: Bool {
        model.smartEnabled && model.smartSaturated && model.helperReady && model.ownsControl
            && !model.busy && (model.sample?.targetPercent ?? 0) >= 99.5
    }
    /// "Above 73° · max cooling": confirmed full speed and the figure shown
    /// visibly above the target shown (see `SmartStatusText.chip`).
    private var smartLimitWords: String? {
        SmartStatusText.chip(atMaximum: smartAtMaximum, celsius: model.panelReadout.celsius,
                             target: model.smartTarget, fahrenheit: model.fahrenheit)
    }
    private let margin: CGFloat = 16

    // Header and temperature (always visible).
    private let aura = AuraView()
    private let mark = NSImageView()
    private let titleLabel = label("Aervane", size: 13, weight: .semibold)
    private let temperature = label("—", size: 52, weight: .light)
    private let unit = label("°C", size: 17, color: .secondaryLabelColor)
    private let sensorTag = label("CPU", size: 10, weight: .semibold, color: .secondaryLabelColor)
    private let chart = TemperatureHistory()
    private let chill = ChillView()
    private lazy var settingsButton = SoftButton("", glyph: .settings) { [weak self] in self?.toggleSettings() }

    // Fan section.
    private let fanSection = FlippedView()
    private let percent = label("—%", size: 30, weight: .medium)
    private let stateChip = label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let slider = PercentSlider(frame: .zero)
    private let floorLabel = label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var autoButton = SoftButton("Auto") { [weak self] in self?.model.chooseAutomatic() }
    private lazy var smartButton = SoftButton("Smart") { [weak self] in self?.model.chooseSmart() }
    private lazy var manualButton = SoftButton("Manual") { [weak self] in guard let self else { return }; self.request(self.model.shownPercent, motion: .none) }
    private lazy var modeSwitch = ModeSwitch(auto: autoButton, smart: smartButton, manual: manualButton)
    private lazy var enableButton = SoftButton("Set up fan control", glyph: .airflow) { [weak self] in self?.startSetup() }
    private lazy var welcomeCard = WelcomeCard(control: { [weak self] in self?.chooseControl() },
                                               temperatureOnly: { [weak self] in self?.chooseTemperatureOnly() })
    private let setupCard = SetupCard()
    private let keyHints = KeyHintsView()
    private var presetButtons: [SoftButton] = []

    // Preset editor: works on a draft; Save stores it, Cancel drops it.
    private var draft: PresetDraft?
    private var editing: Bool { draft != nil }
    private var editorRows: [PresetEditorRow] = []
    private lazy var addButton = SoftButton("", glyph: .plus) { [weak self] in self?.addPreset() }
    private lazy var cancelButton = SoftButton("Cancel") { [weak self] in self?.cancelEditing() }
    private lazy var saveButton = SoftButton("Save") { [weak self] in self?.saveEditing() }

    // Settings page (replaces the fan section while open).
    private lazy var settingsPage = SettingsView(model: model)
    /// Settings scroll when the screen cannot show them whole, so the panel
    /// never grows into the menu bar.
    private lazy var settingsScroll: NSScrollView = {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder; scroll.verticalScrollElasticity = .allowed
        scroll.documentView = settingsPage
        return scroll
    }()
    private var settingsOpen = false
    private var layoutKey = ""
    private var displayedSection: Onboarding.Section?
    /// A value the user asked for that the model has not confirmed yet. Keeps
    /// the thumb from snapping back while the helper write is in flight.
    private var hold: (value: Double, until: Date)?

    init(model: AppModel, onboarding: OnboardingFlow? = nil) {
        self.model = model
        let status = HelperInstaller().status
        self.onboarding = onboarding ?? OnboardingFlow(store: OnboardingStore(), helperRegistered: status == .enabled || status == .requiresApproval)
        super.init(frame: .init(x: 0, y: 0, width: Self.width, height: 300))
        wantsLayer = true
        [aura, mark, titleLabel, temperature, unit, sensorTag, chart, settingsButton, fanSection, welcomeCard, settingsScroll, keyHints].forEach(addSubview)
        [chill, percent, stateChip, modeSwitch, slider, floorLabel, enableButton, setupCard, message, addButton, cancelButton, saveButton].forEach(fanSection.addSubview)
        percent.wantsLayer = true
        fanSection.wantsLayer = true; settingsScroll.wantsLayer = true; settingsScroll.isHidden = true
        temperature.font = TemperatureFigure.font(); temperature.wantsLayer = true
        unit.font = Theme.rounded(17)
        percent.font = Theme.number(30, .medium)
        message.font = Theme.font(11); message.textColor = Theme.caution; message.maximumNumberOfLines = 2
        message.lineBreakMode = .byTruncatingTail
        mark.image = Glyphs.image(.airflow, size: 16, color: Theme.accent); mark.imageScaling = .scaleNone
        mark.setAccessibilityElement(false)
        settingsButton.quiet = true; enableButton.prominent = true
        settingsButton.setAccessibilityLabel("Settings"); settingsButton.toolTip = "Settings (⌘,)"
        autoButton.setAccessibilityLabel("Restore automatic fan control"); manualButton.setAccessibilityLabel("Manual fan control")
        autoButton.toolTip = "Auto (A)"
        smartButton.setAccessibilityLabel("Smart cooling")
        addButton.quiet = true; cancelButton.quiet = true; saveButton.selected = true
        saveButton.setAccessibilityLabel("Save presets"); cancelButton.setAccessibilityLabel("Discard preset changes")
        saveButton.toolTip = "Save (Return)"; cancelButton.toolTip = "Cancel (Esc)"
        [addButton, cancelButton, saveButton].forEach { $0.isHidden = true }
        percent.setAccessibilityLabel("Requested fan speed")
        floorLabel.toolTip = "Hardware minimum"; floorLabel.alignment = .center
        stateChip.alignment = .right
        slider.preview = { [weak self] value in self?.showReadout(value) }
        slider.commit = { [weak self] value in self?.request(value, motion: .none) }
        // Taking hold of the slider is a manual choice: Smart ends at once
        // (with no command) so it never moves the fan under the user's hand.
        slider.began = { [weak self] in self?.model.beginManualAdjustment() }
        settingsPage.editPresets = { [weak self] in self?.openEditor() }
        settingsPage.quit = { [weak self] in self?.quit?() }
        settingsPage.changed = { [weak self] in self?.update() }
        settingsPage.fanControls = { [weak self] in self?.onboarding.state.choice != .temperatureOnly }
        settingsPage.setFanControls = { [weak self] shown in
            guard let self else { return }
            if shown { self.onboarding.handle(.fanControls(true)); self.update() }
            else { self.chooseTemperatureOnly() }
        }
        settingsPage.replayIntroduction = { [weak self] in self?.replayIntroduction() }
        // Smart's target on the trend: stored only when the gesture ends (or
        // on a key or VoiceOver step); it never turns Smart on.
        chart.targetCommitted = { [weak self] celsius in
            guard let self else { return }
            self.model.setSmartTarget(celsius); self.settingsPage.syncTarget()
        }
        setupCard.open = { SMAppService.openSystemSettingsLoginItems() }
        setupCard.done = { [weak self] in self?.onboarding.handle(.finish); self?.update(); self?.focusControls() }
        welcomeCard.isHidden = true
        self.onboarding.changed = { [weak self] in self?.needsLayout = true }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat { arrange(apply: false) }
    func prepareForHiding() {
        // Closing the panel keeps edits, like other macOS popovers; only
        // Cancel or Escape discards them.
        if editing { saveEditing(focus: false) }
        endTextEditing()
        slider.prepareForHiding(); chart.endInspection(); keyHints.show([])
        for button in allButtons { button.resetHover() }
        settleAnimations(in: layer)
        // Closing ends the introduction (it never insists) and a finished
        // setup's card; waiting for approval survives.
        onboarding.handle(.panelClosed)
    }
    private func settleAnimations(in layer: CALayer?) {
        layer?.removeAllAnimations()
        layer?.sublayers?.forEach { settleAnimations(in: $0) }
        if let mask = layer?.mask { settleAnimations(in: mask) }
    }
    private var allButtons: [SoftButton] {
        [settingsButton, autoButton, smartButton, manualButton, enableButton, addButton, cancelButton, saveButton,
         welcomeCard.controlButton, welcomeCard.temperatureButton, setupCard.actionButton] + presetButtons + editorRows.map(\.remove) + settingsPage.buttons
    }
    override func layout() { super.layout(); arrange(apply: true); keyHints.frame = bounds }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    /// Content settles into the glass as the panel appears.
    func playEntrance() {
        guard Theme.effects.animates, let layer, window != nil else { return }
        let drop = CASpringAnimation(keyPath: "transform")
        drop.mass = 1; drop.stiffness = 340; drop.damping = 26
        drop.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 6, 0)); drop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        drop.duration = drop.settlingDuration
        layer.add(drop, forKey: "entrance")
        if section == .welcome && !settingsOpen { welcomeCard.playEntrance() }
    }
    /// Re-reads presentation preferences and system accessibility settings.
    func applyPresentation() {
        let effects = Theme.effects
        slider.effects = effects
        chart.heatColor = PresentationPreferences.shared.heatColor
        aura.apply(state: thermal, effects: effects, heatColor: PresentationPreferences.shared.heatColor, animated: false)
        chill.apply(level: chillLevel, effects: effects, animated: false)
        settingsPage.sync()
        update()
        if Theme.reduceMotion { settleAnimations(in: layer) }
    }

    // MARK: Layout

    /// Tallest body the anchored panel can have on its screen: the visible
    /// height less the pointer, its gap and the bottom margin (PanelMetrics).
    private var availableBodyHeight: CGFloat {
        guard let screen = window?.screen ?? NSScreen.main else { return .greatestFiniteMagnitude }
        let metrics = PanelMetrics.standard
        return screen.visibleFrame.height - metrics.bodyGap - metrics.minimumScreenMargin - 4
    }
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
        put(sensorTag, m - 1 + numberWidth, unitY + 21, 64, 13)
        // The trend, roomier than the original 124×40 so Smart's target can be
        // grabbed: 144 wide, its plot as tall as the figure's digits.
        put(chart, m + w - 144, y + 4, 144, 46 + TemperatureHistory.readoutBand)
        // The aura is centred on the figure; its gradient fills the view, so
        // layer geometry flipping cannot move it.
        put(aura, m + numberWidth / 2 - 150, y + 31 - 95, 300, 190)
        y += 62 + 10

        if settingsOpen {
            let height = settingsPage.height(width: bounds.width, margin: m)
            // As tall as the screen allows below the status item; beyond
            // that the page scrolls inside the panel.
            let shown = min(height, max(200, availableBodyHeight - y - 14))
            put(settingsScroll, 0, y, bounds.width, shown)
            if apply { settingsPage.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height) }
            return y + shown + 14
        }
        switch section {
        case .welcome:
            put(welcomeCard, m, y + 2, w, WelcomeCard.height)
            return y + 2 + WelcomeCard.height + 16
        case .temperatureOnly:
            return y + 4
        case .fan: break
        }
        let top = y; y = 0
        // Section-local coordinates from here.
        // Readout row: requested percent and the Auto · Smart · Manual
        // selector, centred on the figure's optical middle. Room for 100%.
        let percentWidth = ceil(percent.attributedStringValue.size().width) + 4
        put(percent, m - 1, y - 2, percentWidth, 36)
        put(modeSwitch, m + w - Self.selectorWidth, y + 3, Self.selectorWidth, 28)
        y += 34 + 4
        // Slider (hit area spills into the margins) and its floor mark.
        let sliderTop = y
        // Each style sets its own frame: the Channel's thick tube and the
        // Dot Grid's tall lattice and tray.
        let sliderHeight = slider.style.frameHeight
        put(slider, m - 16, y, w + 32, sliderHeight)
        y += sliderHeight
        let floorX = (m - 16) + PercentSlider.trackX(percent: model.minimumPercent, width: w + 32, style: slider.style)
        let floorLift: CGFloat = 5
        put(floorLabel, max(m - 6, floorX - 22), y - floorLift, 44, 13)
        // Exceptional states share the floor label's line, right-aligned, so
        // the readout row stays clean and nothing floats off its baseline.
        put(stateChip, m + w - 200, y - floorLift, 200, 13)
        y += 20 - floorLift + 3
        // Presets wrap into rows of at most three: 1–3 → one row, 4 → 2×2,
        // 5 → 3+2, 6 → 3×2. Short last rows stretch to the full width.
        let gap: CGFloat = 8
        if editing {
            if apply { layoutEditor(at: y, margin: m, width: w) }
            y += CGFloat(editorRows.count) * (PresetEditorRow.height + 6) + 28 + 12
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
        if setupStage != .none { put(setupCard, m, y, w, SetupCard.height); y += SetupCard.height + 10 }
        if model.error != nil || model.smartNotice != nil {
            let height = min(32, max(15, ceil(message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 200)).height ?? 15)))
            put(message, m, y, w, height); y += height + 8
        }
        y += 2
        // Cold air rises from the lower edge: the ellipse is centred on the
        // panel's bottom, so only its upper half shows through the glass.
        let chillTop = sliderTop - 8
        put(chill, -12, chillTop, bounds.width + 24, max(0, 2 * (y - chillTop)))
        put(fanSection, 0, top, bounds.width, y)
        return top + y
    }

    // MARK: State

    func update() {
        let prefs = PresentationPreferences.shared, effects = Theme.effects
        slider.effects = effects
        slider.style = prefs.sliderStyle
        chart.heatColor = prefs.heatColor
        // Temperature: number, unit, source tag and heat band. While Smart
        // runs this is the measurement Smart regulates; otherwise the
        // selected sensor. The menu bar uses the same readout.
        let readout = model.panelReadout
        let sameSeries = readout.series == shownSeries
        if !sameSeries { shownSeries = readout.series; thermal = .unknown }
        let state = readout.celsius == nil ? ThermalState.unknown : ThermalState.classify(readout.celsius, previous: thermal)
        let colored = prefs.heatColor && state >= .warm
        // The newest reading shows at once; a real change of the same source
        // and unit crossfades briefly (`TemperatureMotion`), never rolls.
        let text = readout.text(fahrenheit: model.fahrenheit)
        let motion = TemperatureMotion.between(temperature.stringValue, text, sameSeries: sameSeries, sameUnit: unit.stringValue == model.temperatureUnit,
                                               visible: window?.isVisible == true, allowed: effects.rolls)
        TemperatureFigure.show(text, in: temperature, motion: motion)
        temperature.textColor = colored ? Theme.heat(state) : Theme.ink
        unit.stringValue = model.temperatureUnit
        sensorTag.stringValue = readout.tag
        sensorTag.toolTip = readout.detail
        temperature.setAccessibilityLabel("\(readout.detail), \(state.accessibilityName)")
        if state != thermal {
            aura.apply(state: state, effects: effects, heatColor: prefs.heatColor, animated: window?.isVisible == true, rising: state > thermal && thermal != .unknown)
            thermal = state; thermalChanged?(state)
        }
        chart.fahrenheit = model.fahrenheit
        // Each source keeps its own history; switching never mixes them.
        chart.samples = readout.series == .smart ? model.smartHistory : model.history
        // Smart's target lives on the trend while Smart runs.
        chart.smartTarget = model.smartEnabled ? model.smartTarget : nil
        chill.apply(level: chillLevel, effects: effects, animated: window?.isVisible == true)

        // Fan.
        slider.minimumPercent = model.minimumPercent
        slider.isUnavailable = model.stale
        slider.detents = model.presets.map { max(model.minimumPercent, $0.percent) }
        slider.measuredPercent = model.sample == nil || model.stale ? nil : model.actualPercent
        // The Channel's rotors turn with the real fan: hardware RPM, never the
        // request; unknown or stale telemetry stands them still.
        slider.measuredRPM = model.stale ? nil : model.sample?.currentRPM
        slider.maximumRPM = model.sample?.maximumRPM
        // Settings replaces the fan section; hidden artwork must stop too.
        slider.ambientActive = model.panelVisible && !settingsOpen && section == .fan
        if let held = hold, !model.busy, abs(model.shownPercent - held.value) < 1.5 || model.error != nil || held.until < Date() { hold = nil }
        // A sample refresh never moves the thumb under the user's pointer/keys.
        if !slider.isInteracting {
            // Stays draggable while a command is in flight: the model queues
            // the newest value instead of dropping input.
            slider.isEnabled = !model.stale && section == .fan && !settingsOpen
            let value = (hold?.value ?? model.shownPercent).rounded()
            if abs(slider.percent - value) >= 0.5 {
                // Smart moving the fan: a visible, eased glide of the thumb,
                // coolant and effects, retargeted by each newer value, and
                // the figure rolls. It is the requested speed; the ghost mark
                // shows the measured rotor speed catching up.
                let external = model.smartEnabled && hold == nil
                slider.setPercent(value, animated: window?.isVisible == true, glide: external ? PercentSlider.externalGlide : nil)
                showReadout(slider.percent, roll: external)
            } else { showReadout(slider.percent) }
        }
        floorLabel.isHidden = model.sample == nil || model.minimumPercent <= 0
        floorLabel.stringValue = "\(Int(model.minimumPercent))%"
        floorLabel.setAccessibilityLabel("Hardware minimum \(Int(model.minimumPercent)) percent")

        let previewing = model.requestedPercent != nil
        modeSwitch.mode = model.smartEnabled ? .smart
            : model.ownsControl || previewing || slider.isInteracting ? .manual
            : model.sample?.automatic == true ? .automatic : .none
        modeSwitch.pending = model.pendingPercent != nil
        // The pill's attention tone, the words and the figure agree.
        modeSwitch.saturated = smartLimitWords != nil
        manualButton.isEnabled = !model.stale
        smartButton.toolTip = smartSummary
        stateChip.toolTip = smartLimitWords != nil
            ? "The helper confirmed the full-speed target; the controlled temperature is still above the goal. The fan may still be accelerating." : nil
        if let deadline = model.controlDeadline, model.ownsControl {
            manualButton.toolTip = "Returns to Auto in \(DurationText.short(minutes: max(1, deadline.timeIntervalSinceNow / 60)))"
        } else { manualButton.toolTip = "Manual (M)" }
        syncPresets()
        settingsButton.selected = settingsOpen

        enableButton.isHidden = !needsSetup; enableButton.isEnabled = !model.busy
        // Setting up quits a running Macs Fan Control first; the button says
        // so rather than doing it silently.
        enableButton.title = model.busy && !model.helperReady ? "Connecting…"
            : model.competingApp != nil ? "Quit Macs Fan Control & Set Up"
            : model.helperApprovalRequired ? "Approve in System Settings"
            : model.pendingPercent.map { "Set up & apply \(Int($0.rounded()))%" } ?? "Set up fan control"
        enableButton.setAccessibilityLabel(enableButton.title)
        enableButton.toolTip = model.competingApp != nil ? "Only one app can control the fan." : model.setupMessage
        updateIntroduction()
        // A command error first; otherwise why Smart stopped, kept until the
        // next mode choice so an unexpected change is explained.
        let note = model.error ?? model.smartNotice ?? (model.hasDetectedFan && !model.fanAvailable ? "Fan reading unavailable" : model.fanControlUnavailable)
        message.stringValue = note ?? ""; message.isHidden = note == nil
        message.toolTip = note
        settingsPage.updateStatus()

        let key = "\(section)|\(setupStage)|\(needsSetup)|\(editing)|\(settingsOpen)|\(editorRows.count)|\(presetButtons.count)|\(message.stringValue)|\(temperature.stringValue)\(unit.stringValue)|\(percent.stringValue.count)|\(model.minimumPercent)|\(slider.style.rawValue)|\(settingsPage.layoutKey)"
        if key != layoutKey { layoutKey = key; needsLayout = true }
        resize?(desiredHeight)
        if displayedSection != section {
            displayedSection = section
            focusControls()
        }
    }

    /// Big number and, only when it needs words, the state. `roll` turns the
    /// figure over like a counter (preset clicks); drags and keys never roll.
    private func showReadout(_ value: Double, roll: Bool = false) {
        let shown = Int(value.rounded())
        let text = model.sample == nil ? "—%" : "\(shown)%"
        if percent.stringValue != text {
            if roll, Theme.effects.rolls, window?.isVisible == true, let old = Int(percent.stringValue.dropLast()) {
                let turn = CATransition(); turn.type = .push; turn.subtype = shown > old ? .fromBottom : .fromTop
                turn.duration = 0.22; turn.timingFunction = Theme.Ease.out
                percent.layer?.add(turn, forKey: "roll")
            }
            percent.stringValue = text; needsLayout = true
        }
        percent.setAccessibilityValue(model.sample == nil ? "unavailable" : "\(shown) percent")
        let chip = exceptionState(interacting: slider.isInteracting)
        stateChip.stringValue = chip?.0 ?? ""; stateChip.textColor = chip?.1 ?? Theme.secondary
        stateChip.isHidden = chip == nil
        if editing { syncAddButton() }
        for (i, button) in presetButtons.enumerated() where model.presets.indices.contains(i) {
            button.selected = (model.ownsControl || model.requestedPercent != nil || slider.isInteracting) && !(model.smartEnabled && !slider.isInteracting) && abs(value - effectivePercent(model.presets[i])) < 0.5
        }
    }
    private func exceptionState(interacting: Bool) -> (String, NSColor)? {
        guard model.sample != nil else { return nil }
        if model.stale { return ("No reading", Theme.caution) }
        if interacting { return model.helperReady ? (slider.dragging ? nil : ("Applying…", Theme.secondary)) : ("Not applied", Theme.caution) }
        if model.smartEnabled {
            if needsSetup { return ("Not applied", Theme.caution) }
            if model.busy { return ("Applying…", Theme.secondary) }
            // Only a real limit is worth words: confirmed full speed, and the
            // figure shown is visibly above the target shown.
            return smartLimitWords.map { ($0, Theme.caution) }
        }
        if model.busy && model.helperReady { return ("Applying…", Theme.secondary) }
        if model.pendingPercent != nil { return ("Not applied", Theme.caution) }
        if !model.ownsControl && model.sample?.automatic == false { return ("External control", Theme.secondary) }
        return nil
    }
    /// The Smart button's tooltip: its key, target and what it is doing.
    private var smartSummary: String {
        let readout = model.panelReadout
        return SmartStatusText.summary(enabled: model.smartEnabled, celsius: readout.series == .smart ? readout.celsius : nil,
                                       source: model.smartSample?.source, request: model.smartStep?.target,
                                       target: model.smartTarget, fahrenheit: model.fahrenheit)
    }
    static let selectorWidth: CGFloat = 186
    private func effectivePercent(_ preset: FanPreset) -> Double { max(model.minimumPercent, min(100, preset.percent)).rounded() }

    /// How a requested speed reaches the thumb: pointer actions glide,
    /// keyboard actions jump, and slider commits are already in place.
    private enum Motion { case glide, instant, none }

    /// Single path for every user-requested speed (slider release, keys,
    /// presets, Manual). Before setup the model stores it as a preview.
    private func request(_ value: Double, motion: Motion) {
        let target = max(model.minimumPercent, min(100, value.rounded()))
        if !model.stale {
            hold = (target, Date().addingTimeInterval(3))
            switch motion {
            case .glide: slider.setPercent(target, animated: true, celebrate: true); showReadout(target, roll: true)
            case .instant: slider.setPercent(target, animated: false, celebrate: true); showReadout(target)
            case .none: break
            }
        }
        model.setPercent(target)
    }
    /// Cold-air strength: the measured fan speed, absent without a fresh reading.
    private var chillLevel: Double { Airflow.chill(measuredPercent: model.sample == nil || model.stale ? nil : model.actualPercent) }

    // MARK: Introduction and setup

    /// Which lower view shows (none for temperature only), the welcome's
    /// live glance, and the setup card. While macOS waits for approval and
    /// the panel is open, the approval is noticed within a sample (instead of
    /// the model's bounded approval checks), and nothing is sent to the fan.
    private func updateIntroduction() {
        if !settingsOpen {
            fanSection.isHidden = section != .fan
            welcomeCard.isHidden = section != .welcome
        }
        if section == .welcome && !settingsOpen {
            welcomeCard.glance.show(measuredPercent: model.sample == nil || model.stale ? nil : model.actualPercent, animated: window?.isVisible == true)
        }
        let stage = onboarding.state.stage
        if stage == .approval && !model.busy && !model.helperReady && !model.helperApprovalRequired {
            onboarding.handle(.setupFailed)
        }
        if model.helperReady && (stage == .approval || stage == .preview) { onboarding.handle(.helperConnected) }
        switch setupStage {
        case .approval:
            setupCard.show(.approval(connecting: model.busy))
        case .connected:
            setupCard.show(.connected(measuredPercent: model.sample == nil || model.stale ? nil : model.actualPercent))
        case .none: break
        }
        setupCard.isHidden = setupStage == .none
    }
    /// "Control the fan": the fan section appears as a preview (nothing is
    /// set up or sent until the Set Up button).
    private func chooseControl() {
        onboarding.handle(.chooseControl)
        update(); layoutSubtreeIfNeeded()
        reveal(fanSection)
        focusControls()
    }
    private func chooseTemperatureOnly() {
        // Monitoring alone means firmware owns the fan. Do not hide the
        // controls until restoration succeeds, or conceal a failed restore.
        model.chooseAutomatic { [weak self] in
            guard let self else { return }
            if !self.model.ownsControl && !self.model.smartEnabled && !self.model.busy && self.model.requestedPercent == nil && self.model.sample?.automatic == true && !self.model.stale {
                self.onboarding.handle(.chooseTemperatureOnly)
            } else {
                self.onboarding.handle(.fanControls(true))
                if self.model.error == nil { self.model.error = "Automatic control is not confirmed. Try again after a fresh reading." }
            }
            self.settingsPage.sync()
            self.update(); self.focusControls()
        }
    }
    /// The explicit setup click: approval in Login Items, then connection.
    private func startSetup() {
        onboarding.handle(.setupRequested)
        model.enableControl()
        update(); focusControls()
    }
    private func replayIntroduction() {
        onboarding.handle(.replay)
        if settingsOpen { settingsOpen = false; settingsScroll.isHidden = true }
        update(); layoutSubtreeIfNeeded()
        welcomeCard.playEntrance()
        focusControls()
    }
    /// A section arriving below the temperature rises a few points as it
    /// fades up (finite, skipped with Reduce Motion).
    private func reveal(_ view: NSView) {
        guard Theme.effects.animates, window?.isVisible == true, let layer = view.layer else { return }
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 8, 0)); rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        rise.duration = 0.3; rise.timingFunction = Theme.Ease.out
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.22
        layer.add(rise, forKey: "rise"); layer.add(fade, forKey: "fade")
    }

    // MARK: Presets

    private func syncPresets() {
        if presetButtons.count != model.presets.count {
            presetButtons.forEach { $0.removeFromSuperview() }
            presetButtons = model.presets.indices.map { i in
                let button = SoftButton("") { [weak self] in self?.applyPreset(at: i) }
                button.contextMenu = { [weak self] in self?.presetMenu(at: i) }
                fanSection.addSubview(button); return button
            }
        }
        for (i, button) in presetButtons.enumerated() {
            let preset = model.presets[i], figure = "\(Int(effectivePercent(preset)))%"
            if button.title != preset.name { button.title = preset.name }
            // The full name lives in the tooltip; long names truncate on the tile.
            button.detail = figure; button.toolTip = "\(preset.name) (\(i + 1))"
            button.setAccessibilityLabel("\(preset.name) preset, \(figure)")
            button.isEnabled = !model.stale
            button.isHidden = editing
        }
        showReadout(slider.percent)
    }
    private func applyPreset(at i: Int, keyboard: Bool = false) {
        guard model.presets.indices.contains(i) else { return }
        request(model.presets[i].percent, motion: keyboard ? .instant : .glide)
        if keyboard, presetButtons.indices.contains(i) { presetButtons[i].acknowledge() }
    }
    /// Right-click on a preset: store the current speed in it, or edit all.
    private func presetMenu(at i: Int) -> NSMenu? {
        guard model.presets.indices.contains(i), !editing else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        if model.sample != nil {
            let current = max(model.minimumPercent, min(100, slider.percent.rounded()))
            menu.addItem(MenuAction.item("Set to \(Int(current))%", enabled: effectivePercent(model.presets[i]) != current) { [weak self] in
                guard let self, self.model.presets.indices.contains(i) else { return }
                self.model.presets[i].percent = current; self.model.savePresets()
            })
            menu.addItem(.separator())
        }
        menu.addItem(MenuAction.item("Edit Presets…") { [weak self] in self?.openEditor() })
        return menu
    }
    /// True while a preset's context menu is open; a click on the menu is
    /// not a click outside the panel.
    private(set) var isTrackingMenu = false
    func menuWillOpen(_ menu: NSMenu) { isTrackingMenu = true }
    func menuDidClose(_ menu: NSMenu) { isTrackingMenu = false }

    // MARK: Keyboard

    /// Keeps keys flowing to the panel while the slider is hidden (Settings).
    /// Otherwise the slider keeps focus, even after a click on empty glass.
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if editing {
            switch event.keyCode {
            case 36, 76: saveEditing()                 // Return, Enter
            case 53: cancelEditing()                   // Escape
            default: super.keyDown(with: event)
            }
            return
        }
        if event.keyCode == 53 { window?.cancelOperation(nil); return }
        keyHints.show([])
        let flags = event.modifierFlags
        guard !settingsOpen, !slider.dragging, section == .fan,
              let action = QuickAction.resolve(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                               command: flags.contains(.command), option: flags.contains(.option),
                                               control: flags.contains(.control), presetCount: model.presets.count),
              action != .settings else { super.keyDown(with: event); return }
        run(action)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "," { toggleSettings(); return true }
        return super.performKeyEquivalent(with: event)
    }
    private func run(_ action: QuickAction) {
        switch action {
        case .preset(let i):
            guard !model.stale else { NSSound.beep(); return }
            applyPreset(at: i, keyboard: true)
        case .automatic: model.chooseAutomatic()
        case .smart:
            guard !model.stale else { NSSound.beep(); return }
            model.chooseSmart()
        case .manual:
            guard !model.stale else { NSSound.beep(); return }
            request(model.shownPercent, motion: .instant)
        case .settings: toggleSettings()
        case .smartTarget(let steps):
            guard model.smartEnabled else { NSSound.beep(); return }
            chart.stepTarget(by: steps)
        }
    }
    /// Holding ⌘ alone shows each control's key on it; letting go, or any
    /// key, hides them. Nothing in the panel needs words for its shortcuts.
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        keyHints.show(flags == .command && section == .fan && !settingsOpen && !editing ? keyHintItems : [])
        super.flagsChanged(with: event)
    }
    private var keyHintItems: [KeyHintsView.Hint] {
        func rect(_ view: NSView) -> NSRect { convert(view.bounds, from: view) }
        var hints: [KeyHintsView.Hint] = [(rect(autoButton), "A"), (rect(smartButton), "S"), (rect(manualButton), "M"), (rect(settingsButton), "⌘,")]
        for (i, button) in presetButtons.enumerated() where !button.isHidden { hints.append((rect(button), "\(i + 1)")) }
        if model.smartEnabled { hints.append((convert(chart.handleFrame, from: chart), "[ ]")) }
        return hints
    }
    /// Escape peels one layer: an open preset editor cancels first. Returns
    /// false when there is nothing to peel and the panel should close.
    func dismissTopLayer() -> Bool {
        guard editing else { return false }
        cancelEditing(); return true
    }

    // MARK: Preset editor

    /// Ends any in-progress text edit so its value reaches the draft before
    /// the editor or settings are rebuilt.
    private func endTextEditing() {
        guard let window, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }
    private func focusControls() {
        guard let window, window.isVisible else { return }
        if !window.makeFirstResponder(preferredFirstResponder) { window.makeFirstResponder(self) }
    }
    private func openEditor() {
        endTextEditing()
        if draft == nil { draft = PresetDraft(model.presets) }
        if settingsOpen { settingsOpen = false; showSection(lowerView, from: -1) }
        rebuildEditor(); update(); layoutSubtreeIfNeeded()
        if let first = editorRows.first { window?.makeFirstResponder(first.name) } else { focusControls() }
    }
    private func saveEditing(focus: Bool = true) {
        endTextEditing()
        guard let draft else { return }
        model.presets = draft.resolved(minimum: model.minimumPercent); model.savePresets()
        closeEditor(focus: focus)
    }
    private func cancelEditing() {
        endTextEditing()
        closeEditor(focus: true)
    }
    private func closeEditor(focus: Bool) {
        draft = nil; rebuildEditor(); update()
        if focus { focusControls() }
    }
    private func rebuildEditor() {
        editorRows.forEach { $0.removeFromSuperview() }; editorRows.removeAll()
        [addButton, cancelButton, saveButton].forEach { $0.isHidden = !editing }
        guard let draft else { return }
        for (i, item) in draft.items.enumerated() {
            // Deferred: the delete button must not be torn down inside its own click.
            let row = PresetEditorRow(index: i) { [weak self] in DispatchQueue.main.async { self?.removePreset(at: i) } }
            row.configure(name: item.name, percent: PresetDraft.effective(item.percent, minimum: model.minimumPercent), position: i + 1)
            row.name.delegate = self; row.value.delegate = self
            editorRows.append(row); fanSection.addSubview(row)
        }
        // Tab runs name → speed → next row, then the actions.
        let fields = editorRows.flatMap { [$0.name as NSView, $0.value] }
        for (field, next) in zip(fields, Array(fields.dropFirst()) + [addButton]) { field.nextKeyView = next }
        addButton.nextKeyView = cancelButton; cancelButton.nextKeyView = saveButton; saveButton.nextKeyView = fields.first ?? addButton
        syncAddButton()
    }
    /// "Add 64%" names exactly what the button will store: the slider's speed.
    private func syncAddButton() {
        guard let draft else { return }
        let speed = Int(max(model.minimumPercent, min(100, slider.percent.rounded())))
        if addButton.title != "Add \(speed)%" { addButton.title = "Add \(speed)%"; needsLayout = true }
        addButton.isEnabled = !draft.isFull && model.sample != nil
        addButton.prominent = draft.isEmpty
        addButton.toolTip = draft.isFull ? "Six presets at most" : nil
        addButton.setAccessibilityLabel("Add a preset at \(speed) percent")
    }
    private func layoutEditor(at y: CGFloat, margin m: CGFloat, width w: CGFloat) {
        for (i, row) in editorRows.enumerated() {
            row.frame = NSRect(x: m, y: y + CGFloat(i) * (PresetEditorRow.height + 6), width: w, height: PresetEditorRow.height)
        }
        let actions = y + CGFloat(editorRows.count) * (PresetEditorRow.height + 6)
        let addWidth = ceil((addButton.title as NSString).size(withAttributes: [.font: Theme.font(12, .medium)]).width) + 16 + 6 + 22
        addButton.frame = NSRect(x: m - (addButton.prominent ? 0 : 6), y: actions, width: addWidth, height: 28)
        saveButton.frame = NSRect(x: m + w - 64, y: actions, width: 64, height: 28)
        cancelButton.frame = NSRect(x: saveButton.frame.minX - 6 - 70, y: actions, width: 70, height: 28)
    }
    private func removePreset(at i: Int) {
        guard editing else { return }
        endTextEditing()
        draft?.remove(at: i); rebuildEditor(); update()
        focusControls()
    }
    private func addPreset() {
        endTextEditing()
        guard draft?.isFull == false, model.sample != nil,
              draft?.add(percent: max(model.minimumPercent, min(100, slider.percent.rounded()))) != nil else { return }
        rebuildEditor(); update(); layoutSubtreeIfNeeded()
        guard let row = editorRows.last else { return }
        row.playEntrance()
        window?.makeFirstResponder(row.name); row.name.currentEditor()?.selectAll(nil)
    }
    private func editorRow(for field: NSTextField) -> (index: Int, row: PresetEditorRow)? {
        let i = field.tag / 10
        guard editorRows.indices.contains(i), editorRows[i].name === field || editorRows[i].value === field else { return nil }
        return (i, editorRows[i])
    }
    /// Edits go to the draft as you type; the tiles update only on Save.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let (i, row) = editorRow(for: field), draft != nil else { return }
        if field === row.name {
            let shown = draft?.rename(i, to: field.stringValue) ?? field.stringValue
            if shown != field.stringValue { field.stringValue = shown }
            row.remove.setAccessibilityLabel(shown.isEmpty ? "Delete preset \(i + 1)" : "Delete \(shown)")
        } else {
            draft?.setPercent(i, text: field.stringValue)
            row.showFloorWarning(PresetDraft.isBelowFloor(field.stringValue, minimum: model.minimumPercent), minimum: model.minimumPercent)
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let (i, row) = editorRow(for: field), let item = draft?.items[i] else { return }
        if field === row.value {
            // Show what will be stored: the last valid speed, raised to the floor.
            field.stringValue = "\(Int(PresetDraft.effective(item.percent, minimum: model.minimumPercent)))"
            row.showFloorWarning(false, minimum: model.minimumPercent)
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField, let (i, row) = editorRow(for: field) else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Leave the field editor's callback before tearing the rows down.
            DispatchQueue.main.async { [weak self] in self?.saveEditing() }; return true
        case #selector(NSResponder.cancelOperation(_:)):
            DispatchQueue.main.async { [weak self] in self?.cancelEditing() }; return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.moveUpAndModifySelection(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
            guard field === row.value else { return false }
            let up = selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveUpAndModifySelection(_:))
            let large = selector == #selector(NSResponder.moveUpAndModifySelection(_:)) || selector == #selector(NSResponder.moveDownAndModifySelection(_:))
            draft?.setPercent(i, text: field.stringValue)
            guard let value = draft?.step(i, by: (up ? 1 : -1) * (large ? 10 : 1), minimum: model.minimumPercent) else { return true }
            field.stringValue = "\(Int(value))"; textView.selectAll(nil)
            row.showFloorWarning(false, minimum: model.minimumPercent)
            return true
        default: return false
        }
    }

    // MARK: Settings

    private func toggleSettings() {
        if editing { saveEditing(focus: false) }
        endTextEditing()
        settingsOpen.toggle(); keyHints.show([])
        if settingsOpen {
            settingsPage.sync()
            settingsScroll.contentView.scroll(to: .zero); settingsScroll.reflectScrolledClipView(settingsScroll.contentView)
            showSection(settingsScroll, from: 1)
        } else {
            showSection(lowerView, from: -1)
        }
        update()
        focusControls()
    }
    /// Swaps the lower section in place: the incoming one slides a few
    /// points in from the side it lives on and fades up; the outgoing one
    /// leaves at once (exits are faster than entrances).
    /// What shows below the temperature when Settings is closed.
    private var lowerView: NSView? { section == .fan ? fanSection : section == .welcome ? welcomeCard : nil }
    private func showSection(_ incoming: NSView?, from direction: CGFloat) {
        for view in [fanSection, welcomeCard, settingsScroll] where view !== incoming { view.isHidden = true }
        guard let incoming else { return }
        incoming.isHidden = false
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

/// Cold air rising from the panel's lower edge, as strong as the fan is
/// actually running. The cooling counterpart of the heat aura: it is
/// measured, so it builds as the fan spins up rather than when a value is
/// requested. Changes only with new samples; never animates on its own.
final class ChillView: NSView {
    private let wash = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Radial and centred, so geometry flipping cannot move it; the owner
        // centres the view on the panel's lower edge.
        wash.type = .radial; wash.startPoint = CGPoint(x: 0.5, y: 0.5); wash.endPoint = CGPoint(x: 1, y: 1); wash.opacity = 0
        layer?.addSublayer(wash)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wash.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshColors() }
    private func refreshColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wash.colors = [Theme.cg(Theme.iceMid.withAlphaComponent(dark ? 0.2 : 0.11), effectiveAppearance),
                       Theme.cg(Theme.iceMid.withAlphaComponent(0), effectiveAppearance)]
        CATransaction.commit()
    }

    func apply(level: Double, effects: EffectsProfile, animated: Bool) {
        let target = Float(effects.aura * level)
        // RPM jitter between samples is not news: only a visible change
        // (or reaching/leaving zero) moves the wash, so a steady fan leaves
        // nothing animating while the panel is open.
        guard abs(wash.opacity - target) > 0.015 || (target == 0) != (wash.opacity == 0) else { return }
        let current = (wash.presentation() ?? wash).opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wash.opacity = target
        if animated && effects.animates {
            // Matches the sample cadence, so a spinning-up fan reads as
            // one continuous build rather than steps.
            let build = CABasicAnimation(keyPath: "opacity"); build.fromValue = current; build.toValue = target
            build.duration = 0.9; build.timingFunction = Theme.Ease.inOut
            wash.add(build, forKey: "level")
        } else { wash.removeAnimation(forKey: "level") }
        CATransaction.commit()
    }
}

/// Key badges over the controls while ⌘ is held: small capsules at each
/// control's top-right corner. Appear and leave in 120 ms (at once with
/// Reduce Motion); never intercept the pointer.
final class KeyHintsView: FlippedView {
    typealias Hint = (rect: NSRect, key: String)
    private var badges: [CATextLayer] = []
    private(set) var shown: [String] = []
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ hints: [Hint]) {
        let keys = hints.map(\.key)
        guard keys != shown else { return }
        shown = keys
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        badges.forEach { $0.removeFromSuperlayer() }; badges.removeAll()
        guard let layer, !hints.isEmpty else { return }
        let font = Theme.number(9, .semibold), scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for hint in hints where !hint.rect.isEmpty {
                let badge = CATextLayer()
                badge.string = hint.key; badge.font = font; badge.fontSize = 9; badge.alignmentMode = .center; badge.contentsScale = scale
                let width = max(14, ceil((hint.key as NSString).size(withAttributes: [.font: font]).width) + 8)
                badge.frame = CGRect(x: hint.rect.maxX - width + 3, y: hint.rect.minY - 5, width: width, height: 13)
                badge.cornerRadius = 4
                badge.backgroundColor = Theme.ink.withAlphaComponent(0.78).cgColor
                badge.foregroundColor = (Theme.dark ? NSColor.black : NSColor.white).cgColor
                layer.addSublayer(badge); self.badges.append(badge)
                if Theme.effects.animates {
                    let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.12
                    fade.timingFunction = Theme.Ease.out
                    badge.add(fade, forKey: "fade")
                }
            }
        }
    }
}

/// Inline settings: short row labels on the left, native controls on the
/// right. Every change applies and persists immediately.
final class SettingsView: FlippedView {
    let model: AppModel
    var editPresets: (() -> Void)?
    var quit: (() -> Void)?
    var changed: (() -> Void)?
    /// Whether the fan controls are shown (false: temperature only), and
    /// the setter; the introduction again.
    var fanControls: (() -> Bool)?
    var setFanControls: ((Bool) -> Void)?
    var replayIntroduction: (() -> Void)?
    private let prefs = PresentationPreferences.shared
    private let sensorValues = ["CPU", "GPU", "Warmer"]

    private let sensor = NSSegmentedControl(labels: ["CPU", "GPU", "Warmer"], trackingMode: .selectOne, target: nil, action: nil)
    private let units = NSSegmentedControl(labels: ["°C", "°F"], trackingMode: .selectOne, target: nil, action: nil)
    private let menuBar = NSSegmentedControl(labels: MenuBarContent.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let spacing = NSSegmentedControl(labels: MenuBarSpacing.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let effects = NSSegmentedControl(labels: EffectsLevel.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let sliderStyle = NSSegmentedControl(labels: SliderStyle.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let heat = NSSwitch(), autoReturn = NSSwitch(), login = NSSwitch(), lowPower = NSSwitch(), fanControl = NSSwitch()
    /// Smart's target, in whole degrees of the user's unit. Editing it never
    /// turns Smart on; the main selector does that.
    private let smartTarget = NSSlider(value: 80, minValue: 60, maxValue: 95, target: nil, action: nil)
    private let smartTargetValue = label("80 °C", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let smartHelp = NSButton(title: "", target: nil, action: nil)
    private let smartExplainer = SmartCoolingExplainer()
    private var smartExpanded = false
    private let returnSlider = NSSlider(value: 30, minValue: 5, maxValue: 120, target: nil, action: nil)
    private let returnValue = label("30 min", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let errorMessage = NSTextField(wrappingLabelWithString: "")
    private lazy var source = SoftButton("", glyph: .github) { NSWorkspace.shared.open(URL(string: "https://github.com/kirniy/aervane")!) }
    private lazy var editButton = SoftButton("Edit Presets") { [weak self] in self?.editPresets?() }
    private lazy var welcomeButton = SoftButton("Welcome") { [weak self] in self?.replayIntroduction?() }
    private lazy var quitButton = SoftButton("Quit", glyph: .power) { [weak self] in self?.quit?() }
    var buttons: [SoftButton] { [source, editButton, welcomeButton, quitButton] }
    private var rows: [(label: NSTextField, control: NSView)] = []

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        let entries: [(String, NSView, String?)] = [
            ("Sensor", sensor, nil), ("Units", units, nil), ("Menu bar", menuBar, nil), ("Spacing", spacing, "Menu bar item spacing"),
            ("Effects", effects, "Light, frost and motion. Reduce Motion and Reduce Transparency always apply."),
            ("Slider", sliderStyle, "How the fan slider looks. Changing it never changes the fan."),
            ("Heat color", heat, "Tint the temperature by how hot it is"),
            ("Smart target", smartTarget, "Working temperature for Smart cooling"),
            ("", smartExplainer, nil),
            ("Return to Auto", autoReturn, "Hand the fan back to macOS after a set time. Manual speeds only."),
            ("", returnSlider, nil),
            ("Open at login", login, nil), ("Low power", lowPower, "Read sensors less often while the panel is closed. Smart cooling keeps a 2-second pace."),
            ("Fan control", fanControl, "Show the fan controls, or only the temperature"),
        ]
        for (title, control, tip) in entries {
            let name = label(title, size: 12, color: .labelColor)
            name.toolTip = tip; control.toolTip = tip
            if !title.isEmpty { control.setAccessibilityLabel(title) }
            if let control = control as? NSControl { control.target = self; control.action = #selector(changedControl(_:)) }
            rows.append((name, control)); addSubview(name); addSubview(control)
        }
        for control in [sensor, units, menuBar, spacing, effects, sliderStyle] { control.controlSize = .small; control.segmentDistribution = .fillEqually; control.font = Theme.font(11, .medium) }
        for toggle in [heat, autoReturn, login, lowPower, fanControl] { toggle.controlSize = .small }
        smartTarget.controlSize = .small; smartTarget.isContinuous = true
        smartTargetValue.alignment = .right
        addSubview(smartTargetValue)
        smartHelp.bezelStyle = .helpButton; smartHelp.controlSize = .small
        smartHelp.target = self; smartHelp.action = #selector(toggleSmartHelp)
        smartHelp.setAccessibilityLabel("About Smart cooling"); smartHelp.toolTip = "How Smart cooling works"
        addSubview(smartHelp)
        returnSlider.controlSize = .small; returnSlider.isContinuous = true
        returnSlider.setAccessibilityLabel("Return to Auto after")
        returnValue.alignment = .right
        addSubview(returnValue)
        errorMessage.font = Theme.font(11); errorMessage.textColor = Theme.caution
        errorMessage.maximumNumberOfLines = 2; errorMessage.lineBreakMode = .byTruncatingTail
        addSubview(errorMessage)
        source.quiet = true; source.setAccessibilityLabel("Source code on GitHub"); source.toolTip = "Source code"
        editButton.quiet = true; quitButton.quiet = true; welcomeButton.quiet = true
        welcomeButton.setAccessibilityLabel("Show the introduction again")
        buttons.forEach(addSubview)
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Changes when the row set changes (the time slider shows only when
    /// Return to Auto is on).
    var layoutKey: String { "\(model.autoReturnEnabled)|\(smartExpanded)|\(model.fahrenheit)|\(note ?? "")" }
    /// A command error, else why Smart last stopped.
    private var note: String? { model.error ?? model.smartNotice }

    func updateStatus() {
        // No fan: read-only, and the tooltip says why.
        fanControl.isEnabled = model.fanAvailable
        fanControl.state = model.hasDetectedFan && fanControls?() != false ? .on : .off
        fanControl.toolTip = model.fanAvailable ? "Show the fan controls, or only the temperature" : (model.fanReadError ?? "No fan on this Mac")
        let text = note ?? ""
        if errorMessage.stringValue != text { errorMessage.stringValue = text; needsLayout = true }
        errorMessage.isHidden = text.isEmpty
        errorMessage.toolTip = note
        if smartExpanded { updateExplainer() }
    }
    /// The target row in the user's unit (a °F step is its own stored value).
    /// Also called when the target is chosen on the trend.
    func syncTarget() {
        let range = SmartTarget.displayRange(fahrenheit: model.fahrenheit)
        smartTarget.minValue = Double(range.lowerBound); smartTarget.maxValue = Double(range.upperBound)
        let shown = SmartTarget.display(model.smartTarget, fahrenheit: model.fahrenheit)
        smartTarget.doubleValue = Double(shown)
        showTarget(shown)
    }
    private func showTarget(_ shown: Int) {
        let unit = model.fahrenheit ? "°F" : "°C"
        smartTargetValue.stringValue = "\(shown) \(unit)"
        smartTarget.setAccessibilityValueDescription("\(shown) degrees \(model.fahrenheit ? "Fahrenheit" : "Celsius")")
    }
    private func updateExplainer() {
        let step = model.smartEnabled ? model.smartStep : nil
        smartExplainer.update(policy: model.smartPolicy.with(target: model.smartTarget), celsius: step?.celsius, target: step?.target,
                              floor: model.minimumPercent, fahrenheit: model.fahrenheit)
    }
    @objc private func toggleSmartHelp() {
        smartExpanded.toggle()
        if smartExpanded { updateExplainer() }
        needsLayout = true
        changed?()
    }

    func sync() {
        sensor.selectedSegment = sensorValues.firstIndex(of: model.selectedSensor) ?? 0
        units.selectedSegment = model.fahrenheit ? 1 : 0
        menuBar.selectedSegment = MenuBarContent.allCases.firstIndex(of: prefs.menuBarContent) ?? 0
        spacing.selectedSegment = MenuBarSpacing.allCases.firstIndex(of: prefs.menuBarSpacing) ?? 0
        effects.selectedSegment = EffectsLevel.allCases.firstIndex(of: prefs.effects) ?? 0
        sliderStyle.selectedSegment = SliderStyle.allCases.firstIndex(of: prefs.sliderStyle) ?? 0
        heat.state = prefs.heatColor ? .on : .off
        syncTarget()
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

    private var visibleRows: [(label: NSTextField, control: NSView)] {
        rows.filter { !($0.control === returnSlider && !model.autoReturnEnabled) && !($0.control === smartExplainer && !smartExpanded) }
    }
    private func rowHeight(_ control: NSView, width: CGFloat) -> CGFloat {
        control === smartExplainer ? smartExplainer.fittingHeight(width: width) + 6 : 30
    }

    func height(width: CGFloat, margin: CGFloat) -> CGFloat {
        visibleRows.reduce(0) { $0 + rowHeight($1.control, width: width - 2 * margin) } + 8 + 30 + 2 + (note == nil ? 0 : 40)
    }

    override func layout() {
        super.layout()
        let m: CGFloat = 16, w = bounds.width - 2 * m
        var y: CGFloat = 0
        for row in rows { row.label.isHidden = true; if row.control !== returnSlider && row.control !== smartExplainer { row.control.isHidden = false } }
        smartExplainer.isHidden = !smartExpanded
        for row in visibleRows {
            row.label.isHidden = false
            row.label.frame = NSRect(x: m, y: y + 5, width: 120, height: 16)
            if row.control === smartExplainer {
                let height = smartExplainer.fittingHeight(width: w)
                smartExplainer.frame = NSRect(x: m, y: y, width: w, height: height)
                y += height + 6; continue
            }
            if let toggle = row.control as? NSSwitch {
                let size = toggle.fittingSize
                toggle.frame = NSRect(x: m + w - size.width, y: y + (26 - size.height) / 2, width: size.width, height: size.height)
            } else if row.control === smartTarget {
                // Label, its help button, then the slider and its value.
                let help = smartHelp.fittingSize, labelWidth = ceil(row.label.attributedStringValue.size().width)
                smartHelp.frame = NSRect(x: m + labelWidth + 6, y: y + (26 - help.height) / 2, width: help.width, height: help.height)
                let start = m + 124
                smartTarget.frame = NSRect(x: start, y: y + 3, width: max(40, w - (start - m) - 58), height: 20)
                smartTargetValue.frame = NSRect(x: m + w - 54, y: y + 5, width: 54, height: 16)
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
        if note != nil {
            errorMessage.frame = NSRect(x: m, y: y, width: w, height: 32)
            y += 40
        }
        source.frame = NSRect(x: m - 6, y: y, width: 30, height: 28)
        editButton.frame = NSRect(x: m + 28, y: y, width: 96, height: 28)
        welcomeButton.frame = NSRect(x: m + 126, y: y, width: 80, height: 28)
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
        } else if sender === sliderStyle {
            prefs.sliderStyle = SliderStyle.allCases[max(0, sliderStyle.selectedSegment)]
        } else if sender === heat {
            prefs.heatColor = heat.state == .on
        } else if sender === smartTarget {
            // Whole display units; the model validates, stores °C, and applies
            // it on Smart's next reading (it never turns Smart on).
            let shown = Int(smartTarget.doubleValue.rounded())
            smartTarget.doubleValue = Double(shown)
            showTarget(shown)
            model.setSmartTarget(SmartTarget.celsius(fromDisplay: Double(shown), fahrenheit: model.fahrenheit))
            if smartExpanded { updateExplainer() }
            return
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
        } else if sender === fanControl {
            setFanControls?(fanControl.state == .on)
        }
        sync()
        changed?()
    }
}
