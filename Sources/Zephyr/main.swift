import AppKit
import SMC

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel(); content = PanelView(model: model)
        item = NSStatusBar.system.statusItem(withLength: 70)
        if let button = item.button {
            button.target = self; button.action = #selector(toggle); button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            let icon = Glyphs.image(.airflow, size: 14); icon.isTemplate = true; button.image = icon; button.imagePosition = .imageLeading; button.imageHugsTitle = true
            button.toolTip = "Aervane · CPU temperature and fan control"; button.setAccessibilityLabel("Aervane temperature and fan control")
        }
        panel = MenuPanel(contentRect: .init(x: 0, y: 0, width: 380, height: 458), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovable = false; panel.hidesOnDeactivate = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds); glass.cornerRadius = 26; glass.style = .regular; glass.contentView = content; panel.contentView = glass
        } else {
            let glass = NSVisualEffectView(frame: content.bounds); glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active; glass.wantsLayer = true; glass.layer?.cornerRadius = 22; glass.layer?.masksToBounds = true; glass.addSubview(content); panel.contentView = glass
        }
        content.autoresizingMask = [.width, .height]
        panel.escape = { [weak self] in self?.hide() }
        content.resize = { [weak self] height in self?.resize(height) }; content.quit = { NSApp.terminate(nil) }
        model.changed = { [weak self] in self?.refresh() }; refresh()
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.show() } }
        if CommandLine.arguments.contains("--enable-helper") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.show(); self.model.enableControl() } }
    }
    private func refresh() { item.button?.title = " \(model.temperatureText)\(model.temperatureUnit)"; if panel.isVisible { content.update() } }
    @objc private func toggle() { panel.isVisible ? hide() : show() }
    private func show() {
        guard !panel.isVisible else { return }
        model.panelVisible = true; content.update(); positionPanel()
        panel.alphaValue = Theme.reduceMotion ? 1 : 0; panel.makeKeyAndOrderFront(nil)
        if !Theme.reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.16; $0.timingFunction = CAMediaTimingFunction(name: .easeOut); panel.animator().alphaValue = 1 } }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isPointerOverStatusItem() else { return }; self.hide()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window != self.panel, !self.isPointerOverStatusItem() { self.hide() }; return event
        }
        item.button?.highlight(true)
    }
    private func isPointerOverStatusItem() -> Bool {
        guard let button = item.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }
    private func hide() {
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
        guard !ending, model.ownsControl else { return .terminateNow }; ending = true
        model.restore { NSApp.reply(toApplicationShouldTerminate: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

if CommandLine.arguments.contains("--probe") {
    let reader = SMCReader()
    do { let fan = try reader.readFan(); let temp = try reader.readCPUTemperature(); print("CPU \(String(format: "%.1f", temp))°C | Fan \(Int((fan.currentRPM / fan.maximumRPM * 100).rounded()))% | Minimum \(Int(ceil(fan.minimumRPM / fan.maximumRPM * 100)))% | \(fan.automatic ? "Auto" : "Manual")") }
    catch { fputs("\(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
