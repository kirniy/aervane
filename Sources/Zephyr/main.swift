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
    private var glass: NSView?
    private var observers: [NSObjectProtocol] = []
    /// Heat band for the menu bar, kept current while the panel is closed.
    private var statusThermal = ThermalState.unknown
    private lazy var statusIcon: NSImage = { let icon = Glyphs.image(.airflow, size: 14); icon.isTemplate = true; return icon }()
    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installKeyboardCommands()
        model = AppModel(); content = PanelView(model: model)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self; button.action = #selector(toggle); button.font = statusFont
            button.sendAction(on: .leftMouseDown)
            button.imageHugsTitle = true
            button.setAccessibilityLabel("Aervane temperature and fan control")
        }
        panel = MenuPanel(contentRect: .init(x: 0, y: 0, width: PanelView.width, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovable = false; panel.hidesOnDeactivate = false
        // The content view draws no backing of its own, so the system
        // material is what shows through everywhere.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds); glass.cornerRadius = 24; glass.style = .regular; glass.contentView = content; panel.contentView = glass
            self.glass = glass
        } else {
            let glass = NSVisualEffectView(frame: content.bounds); glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active; glass.wantsLayer = true; glass.layer?.cornerRadius = 20; glass.layer?.masksToBounds = true; glass.addSubview(content); panel.contentView = glass
            self.glass = glass
        }
        content.autoresizingMask = [.width, .height]
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
            guard let self else { return }; self.content.applyPresentation(); self.tintGlass(for: self.content.thermal)
        })
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.show() } }
        if CommandLine.arguments.contains("--enable-helper") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.show(); self.model.enableControl() } }
    }
    private func refresh() { updateStatusItem(); if panel.isVisible { content.update() } }

    /// Sizes the status item to its measured content plus a small native
    /// margin (no fixed width, no padding characters in the title).
    private func updateStatusItem() {
        guard let button = item.button else { return }
        let prefs = PresentationPreferences.shared, display = prefs.menuBarContent
        let title = StatusItemLayout.title(temperatureText: model.temperatureText)
        let attributes: [NSAttributedString.Key: Any] = [.font: statusFont]
        let titleWidth = max((title as NSString).size(withAttributes: attributes).width,
                             (StatusItemLayout.reservedTitle as NSString).size(withAttributes: attributes).width)
        button.image = display.showsIcon ? statusIcon : nil
        button.imagePosition = display == .icon ? .imageOnly : display == .temperature ? .noImage : .imageLeading
        statusThermal = model.stale ? .unknown : ThermalState.classify(model.displayTemperature, previous: statusThermal)
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
        let sensor = model.selectedSensor == "Warmer" ? "Warmer of CPU and GPU averages" : model.selectedSensor
        button.toolTip = "\(sensor) \(model.temperatureText)\(model.temperatureUnit)"
        button.setAccessibilityValue("\(sensor) \(model.temperatureText)\(model.temperatureUnit)")
    }

    /// On macOS 26 the glass itself carries a faint heat tint when the
    /// reading is warm or hotter. Reduce Transparency keeps it untinted.
    private func tintGlass(for state: ThermalState) {
        guard #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView else { return }
        let prefs = PresentationPreferences.shared
        let tinted = prefs.heatColor && prefs.effects != .off && !Theme.reduceTransparency && state >= .warm
        glass.tintColor = tinted ? Theme.heat(state).withAlphaComponent(state == .warm ? 0.06 : state == .hot ? 0.09 : 0.12) : nil
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
        NSApp.activate()
        panel.alphaValue = Theme.reduceMotion ? 1 : 0; panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content.preferredFirstResponder)
        content.playEntrance()
        if !Theme.reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.16; $0.timingFunction = CAMediaTimingFunction(name: .easeOut); panel.animator().alphaValue = 1 } }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isPointerOverStatusItem() else { return }; self.hide()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window != self.panel, !self.content.isTrackingMenu, !self.isPointerOverStatusItem() { self.hide() }; return event
        }
        item.button?.highlight(true)
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
    private func positionPanel() {
        guard let button = item.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil)), screen = window.screen ?? NSScreen.main!
        let x = min(max(screen.visibleFrame.minX + 8, rect.midX - panel.frame.width / 2), screen.visibleFrame.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(.init(x: x, y: max(screen.visibleFrame.minY + 8, rect.minY - panel.frame.height - 7)))
    }
    private func resize(_ height: CGFloat) {
        guard abs(panel.frame.height - height) > 1 else { return }
        var frame = panel.frame; frame.origin.y += frame.height - height; frame.size.height = height
        if panel.isVisible && !Theme.reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.18; $0.timingFunction = CAMediaTimingFunction(name: .easeOut); panel.animator().setFrame(frame, display: true) } }
        else { panel.setFrame(frame, display: false) }
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
        guard try SMCReader().readFan().automatic else {
            fputs("Restore Auto and quit Aervane before replacing the helper.\n", stderr); exit(1)
        }
        try installer.disable(); print("Aervane helper unregistered.")
    }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--probe") {
    let reader = SMCReader()
    do {
        let fan = try reader.readFan(), temp = try reader.readCPUTemperature(), hottest = try reader.readCPUHottestTemperature()
        let target = fan.targetPercent.map { String(format: "%.1f%%", $0) } ?? "Auto"
        print("CPU \(String(format: "%.1f", temp))°C | Hottest \(String(format: "%.1f", hottest))°C | Fan \(Int((fan.currentRPM / fan.maximumRPM * 100).rounded()))% | Target \(target) | Minimum \(Int(ceil(fan.minimumRPM / fan.maximumRPM * 100)))% | \(fan.automatic ? "Auto" : "Manual")")
        let raw = try reader.readFanRegisters()
        print("F0Md \(raw.mode) | F0Tg \(String(format: "%.1f", raw.targetRPM)) | F0Ac \(String(format: "%.1f", raw.actualRPM)) | F0Mn \(String(format: "%.1f", raw.minimumRPM)) | F0Mx \(String(format: "%.1f", raw.maximumRPM)) | FNum \(try reader.readFanCount())")
    }
    catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
