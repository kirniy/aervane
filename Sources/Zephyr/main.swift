import AppKit
import SMC
import ZephyrCore

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: MenuPanel!
    private var content: PanelView!
    private var model: AppModel!
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var ending = false
    private var surface: PanelSurface!
    /// Content height last asked for by the panel view (the body, without the pointer).
    private var bodyHeight: CGFloat = 300
    /// Frame the panel is at or animating to.
    private var panelTarget: NSRect?
    private var observers: [NSObjectProtocol] = []
    /// Heat band for the menu bar, kept current while the panel is closed.
    private var statusThermal = ThermalState.unknown
    private lazy var statusIcon: NSImage = { let icon = Glyphs.image(.airflow, size: 14); icon.isTemplate = true; return icon }()
    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installKeyboardCommands()
        // The introduction's state is read before the model can store
        // anything, so a first launch is told apart from an existing user
        // (saved preferences or a registered helper never see it by themselves).
        let helperStatus = HelperInstaller().status
        let onboarding = OnboardingFlow(store: OnboardingStore(), helperRegistered: helperStatus == .enabled || helperStatus == .requiresApproval)
        model = AppModel(); content = PanelView(model: model, onboarding: onboarding)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self; button.action = #selector(toggle); button.font = statusFont
            button.sendAction(on: .leftMouseDown)
            button.imageHugsTitle = true
            button.setAccessibilityLabel("Aervane temperature and fan control")
        }
        panel = MenuPanel(contentRect: .init(x: 0, y: 0, width: PanelView.width, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovable = false; panel.hidesOnDeactivate = false
        surface = PanelSurface(content: content)
        panel.contentView = surface
        // Escape peels one layer (an open preset editor cancels) before closing.
        panel.escape = { [weak self] in guard let self, !self.content.dismissTopLayer() else { return }; self.hide() }
        panel.initialFirstResponder = content.preferredFirstResponder
        content.resize = { [weak self] height in self?.resize(height) }; content.quit = { NSApp.terminate(nil) }
        content.thermalChanged = { [weak self] state in self?.tintGlass(for: state); self?.updateStatusItem() }
        model.changed = { [weak self] in self?.refresh() }; refresh()
        // Presentation choices and system accessibility settings apply at once.
        observers.append(NotificationCenter.default.addObserver(forName: PresentationPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.content.applyPresentation(); self.tintGlass(for: self.content.thermal); self.updateStatusItem()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.content.applyPresentation(); self.tintGlass(for: self.content.thermal); self.surface.updateColors()
        })
        // An open panel follows its item when the menu bar rearranges (other
        // items resizing) or displays change. Event-driven; nothing polls.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, self.panel.isVisible else { return }
                if let window = note.object as? NSWindow, window !== self.item.button?.window { return }
                self.positionPanel()
            })
        }
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.show() } }
        // First launch only: the panel opens once by itself under its item,
        // so a menu-bar-only app never looks like it did nothing. Never again.
        else if onboarding.shouldShowOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard onboarding.shouldShowOnLaunch else { return }
                onboarding.didShowOnLaunch(); self?.show()
            }
        }
        if CommandLine.arguments.contains("--enable-helper") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.show(); self.model.enableControl() } }
    }
    private func refresh() { updateStatusItem(); if panel.isVisible { content.update() } }

    /// Sizes the status item to its measured content plus a small native
    /// margin (no fixed width, no padding characters in the title).
    private func updateStatusItem() {
        guard let button = item.button else { return }
        let prefs = PresentationPreferences.shared, display = prefs.menuBarContent
        let readout = model.panelReadout
        let temperatureText = readout.text(fahrenheit: model.fahrenheit)
        let title = StatusItemLayout.title(temperatureText: temperatureText)
        let attributes: [NSAttributedString.Key: Any] = [.font: statusFont]
        let titleWidth = max((title as NSString).size(withAttributes: attributes).width,
                             (StatusItemLayout.reservedTitle as NSString).size(withAttributes: attributes).width)
        button.image = display.showsIcon ? statusIcon : nil
        button.imagePosition = display == .icon ? .imageOnly : display == .temperature ? .noImage : .imageLeading
        statusThermal = readout.celsius == nil ? .unknown : ThermalState.classify(readout.celsius, previous: statusThermal)
        if display.showsTemperature {
            // Hot readings may carry their heat colour; otherwise the system
            // label colour keeps menu bar vibrancy and highlight inversion.
            let state = statusThermal
            if prefs.heatColor && state >= .hot {
                button.attributedTitle = NSAttributedString(string: title, attributes: [.font: statusFont, .foregroundColor: Theme.heat(state)])
            } else {
                button.title = title
            }
        } else { button.title = "" }
        item.length = CGFloat(StatusItemLayout.length(content: display, spacing: prefs.menuBarSpacing,
                                                      iconWidth: Double(statusIcon.size.width), titleWidth: Double(titleWidth)))
        let sensor = readout.detail
        button.toolTip = "\(sensor) \(temperatureText)\(model.temperatureUnit)"
        button.setAccessibilityValue("\(sensor) \(temperatureText)\(model.temperatureUnit)")
    }

    /// The panel material, pointer included, carries a faint heat tint when
    /// the reading is warm or hotter. Reduce Transparency keeps it untinted.
    private func tintGlass(for state: ThermalState) {
        let prefs = PresentationPreferences.shared
        let tinted = prefs.heatColor && prefs.effects != .off && !Theme.reduceTransparency && state >= .warm
        surface.tint = tinted ? Theme.heat(state).withAlphaComponent(state == .warm ? 0.06 : state == .hot ? 0.09 : 0.12) : nil
    }
    private func installKeyboardCommands() {
        // Accessory apps still need an Edit menu for the field editor's native
        // command-key equivalents (including Select All and Paste).
        let menu = NSMenu()
        let application = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Aervane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu; menu.addItem(application)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; editMenu.insertItem(redo, at: 1)
        edit.submenu = editMenu; menu.addItem(edit)
        NSApp.mainMenu = menu
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }
    @objc private func toggle() { panel.isVisible ? hide() : show() }
    private func show() {
        guard !panel.isVisible else { return }
        model.panelVisible = true; content.update(); positionPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        item.button?.highlight(true)
        if #available(macOS 14, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        panel.alphaValue = Theme.reduceMotion ? 1 : 0; panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        panel.makeFirstResponder(content.preferredFirstResponder)
        content.playEntrance()
        if !Theme.reduceMotion {
            NSAnimationContext.runAnimationGroup({
                $0.duration = 0.16; $0.timingFunction = Theme.Ease.out
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isPointerOverStatusItem() else { return }; self.hide()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window != self.panel, !self.content.isTrackingMenu, !self.isPointerOverStatusItem() { self.hide() }; return event
        }
    }
    private func isPointerOverStatusItem() -> Bool {
        guard let button = item.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }
    private func hide() {
        content.prepareForHiding()
        panel.orderOut(nil); model.panelVisible = false; item.button?.highlight(false)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    /// Where a body of `height` goes: hanging from the status item with
    /// room below the menu bar and from the screen edges, its pointer on the
    /// item, aligned to the item's screen's pixels (see `PanelPlacement`).
    private func placement(bodyHeight height: CGFloat) -> PanelPlacement? {
        guard let button = item.button, let window = button.window else { return nil }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil)), screens = NSScreen.screens
        guard let screen = PanelPlacement.screenIndex(for: anchor, in: screens.map(\.frame)).map({ screens[$0] }) ?? window.screen ?? NSScreen.main else { return nil }
        return PanelPlacement(anchor: anchor, visibleFrame: screen.visibleFrame, bodySize: NSSize(width: PanelView.width, height: height), scale: screen.backingScaleFactor)
    }
    private func positionPanel() {
        guard let place = placement(bodyHeight: bodyHeight) else { return }
        surface.pointerX = place.pointerX
        panelTarget = place.frame
        if panel.frame != place.frame { panel.setFrame(place.frame, display: panel.isVisible); panel.invalidateShadow() }
    }
    /// `height` is the panel view's content height; the window adds the
    /// pointer above it, so content is never compressed. The top edge and
    /// pointer stay put while the body grows or shrinks.
    private func resize(_ height: CGFloat) {
        bodyHeight = height
        var frame: NSRect
        if let place = placement(bodyHeight: height) {
            surface.pointerX = place.pointerX; frame = place.frame
        } else {
            frame = panel.frame; let total = height + PanelMetrics.standard.pointerHeight
            frame.origin.y += frame.height - total; frame.size.height = total
        }
        guard frame != panelTarget else { return }
        panelTarget = frame
        if panel.isVisible && !Theme.reduceMotion {
            NSAnimationContext.runAnimationGroup({
                $0.duration = 0.18; $0.timingFunction = Theme.Ease.out
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        } else { panel.setFrame(frame, display: false); panel.invalidateShadow() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A command in flight may be taking control right now, so it also
        // needs the Auto request (queued behind it) before quitting.
        guard !ending, model.ownsControl || model.busy else { return .terminateNow }; ending = true
        var replied = false
        let replyOnce = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        model.restore(completion: replyOnce)
        // Quitting closes the XPC connection, and the helper restores a
        // dropped session's fan, so the bounded wait is only for a clean,
        // confirmed restore when the helper answers promptly.
        DispatchQueue.main.asyncAfter(deadline: .now() + FanSafety.commandReplyTimeout, execute: replyOnce)
        return .terminateLater
    }
}

if CommandLine.arguments.contains("--verify-control") {
    verifyFanControl()
} else if CommandLine.arguments.contains("--check-signing") {
    // Used by the signed build check. No service registration or fan writes.
    guard let team = SigningRequirement.currentTeamIdentifier(),
          SigningRequirement.requirement(identifier: HelperClient.serviceName) != nil else {
        fputs("Aervane cannot read its Apple signing identity.\n", stderr); exit(1)
    }
    print("Apple signing identity verified: \(team)")
} else if CommandLine.arguments.contains("--unregister-helper") {
    // Development maintenance for replacing an installed helper. Keep this
    // separate from normal launch; never disturb a running lease implicitly.
    do {
        let installer = HelperInstaller()
        if installer.status == .notRegistered || installer.status == .notFound {
            print("Aervane helper is not registered."); exit(0)
        }
        let smc = SMCBridge()
        guard try FanInventoryReader(smc: smc, model: SMCBridge.model, platform: SMCBridge.platform).read().fans.allSatisfy(\.automatic) else {
            fputs("Restore Auto and quit Aervane before replacing the helper.\n", stderr); exit(1)
        }
        try installer.disable(); print("Aervane helper unregistered.")
    }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--probe") {
    // Read-only. One line per fan plus a structured report (no writes).
    let smc = SMCBridge(), model = SMCBridge.model, platform = SMCBridge.platform
    let sensors = TemperatureSensors(smc: smc, model: model, platform: platform, hid: platform == .appleSilicon ? AppleSiliconHIDSource() : nil)
    let inventory = FanInventoryReader(smc: smc, model: model, platform: platform)
    let report = HardwareDiagnostics.collect(model: model, platform: platform, inventory: inventory, sensors: sensors)
    if let cpu = try? sensors.readCPU() {
        print("CPU \(String(format: "%.1f", cpu.average))°C | Hottest \(String(format: "%.1f", cpu.hottest))°C")
    }
    for fan in report.fans?.map(\.reading) ?? [] {
        let target = fan.targetPercent.map { String(format: "%.1f%%", $0) } ?? "Auto"
        print("Fan \(fan.index) | \(Int((fan.currentRPM / fan.maximumRPM * 100).rounded()))% (\(Int(fan.currentRPM.rounded())) RPM) | Target \(target) | Minimum \(Int(ceil(fan.floorPercent)))% | \(fan.mode.rawValue)")
    }
    print(report.json())
    if report.cpuError != nil || report.fanError != nil { exit(1) }
} else {
    let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
