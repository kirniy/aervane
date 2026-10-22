import AppKit
import ServiceManagement
import SMC
import ZephyrCore

final class AppModel {
    var changed: (() -> Void)?
    private let queue = DispatchQueue(label: "dev.kirniy.aervane.sensors", qos: .utility)
    private let reader = SMCReader()
    private var timer: DispatchSourceTimer?
    private var heartbeat: Timer?
    private var helper: HelperClient?
    private var connectionGeneration = UUID()
    private var controlGeneration: UInt64 = 0
    private var nextReconnect = Date.distantPast
    private let installer = HelperInstaller()
    private var sleepObservers: [NSObjectProtocol] = []
    var sample: FanSnapshot?
    var history: [Double] = []
    var error: String?
    var busy = false
    var ownsControl = false
    var pendingPercent: Double?
    var helperReady = false
    var helperApprovalRequired = false
    var setupMessage: String? { helperApprovalRequired ? "Allow Aervane in System Settings → Login Items. macOS may ask for your password." : nil }
    var panelVisible = false { didSet { if panelVisible { nextReconnect = .distantPast }; schedulePoll() } }
    var presets: [FanPreset]
    var selectedSensor: String { didSet { UserDefaults.standard.set(selectedSensor, forKey: "sensor"); poll() } }
    var displayTemperature: Double?
    var fahrenheit: Bool { didSet { UserDefaults.standard.set(fahrenheit, forKey: "fahrenheit"); changed?() } }
    var lowPower: Bool { didSet { UserDefaults.standard.set(lowPower, forKey: "lowPower"); schedulePoll() } }
    var controlDeadline: Date?
    var manualDuration: TimeInterval = 1800
    var competingApp: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").first }
    var minimumPercent: Double { guard let s = sample, s.maximumRPM > 0 else { return 0 }; return ceil(s.minimumRPM / s.maximumRPM * 100) }
    var actualPercent: Double { guard let s = sample, s.maximumRPM > 0 else { return 0 }; return min(100, max(0, s.currentRPM / s.maximumRPM * 100)) }
    var shownPercent: Double { pendingPercent ?? sample?.targetPercent ?? actualPercent }
    var temperatureText: String { guard let temp = displayTemperature, !stale else { return "—" }; return String(Int((fahrenheit ? temp * 1.8 + 32 : temp).rounded())) }
    var temperatureUnit: String { fahrenheit ? "°F" : "°C" }
    var stale: Bool { sample.map { Date().timeIntervalSince($0.sampledAt) > 12 } ?? true }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    init() {
        let defaults = UserDefaults.standard
        selectedSensor = defaults.string(forKey: "sensor") ?? "CPU"
        fahrenheit = defaults.bool(forKey: "fahrenheit"); lowPower = defaults.bool(forKey: "lowPower")
        if let data = defaults.data(forKey: "presets"), let saved = try? JSONDecoder().decode([FanPreset].self, from: data) {
            presets = Array(saved.filter { !$0.name.isEmpty && $0.name.count <= 20 && $0.percent.isFinite && (0...100).contains($0.percent) }.prefix(6))
        } else { presets = [FanPreset(name: "Quiet", percent: 30), FanPreset(name: "Balanced", percent: 60), FanPreset(name: "Boost", percent: 100)] }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in if self?.ownsControl == true { self?.restore() }; self?.timer?.cancel(); self?.timer = nil })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.schedulePoll() })
        schedulePoll()
        let status = installer.status
        helperApprovalRequired = status == .requiresApproval
        if status == .enabled { connectHelper() }
    }
    deinit { for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; timer?.cancel(); heartbeat?.invalidate() }
    func schedulePoll() {
        timer?.cancel()
        let interval: TimeInterval = panelVisible ? 1 : lowPower ? 8 : 3
        let t = DispatchSource.makeTimerSource(queue: .main); t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(panelVisible ? 150 : 700)); t.setEventHandler { [weak self] in self?.poll() }; timer = t; t.resume()
    }
    private var polling = false
    func poll() {
        // Connecting to the helper must not pause read-only telemetry. Only
        // an in-flight hardware command needs to exclude an overlapping poll.
        guard !polling, !busy || !helperReady else { return }; polling = true
        let sensor = selectedSensor
        let generation = controlGeneration
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<(FanSnapshot, Double), Error> = Result {
                let cpu = try self.reader.readCPUTemperature(), fan = try self.reader.readFan()
                var temp = cpu
                if sensor != "CPU" {
                    let gpu = ["Tg0D", "Tg0G", "Tg0H", "TG0D"].compactMap { try? self.reader.readTemperature($0) }.filter { $0.isFinite && (0..<130).contains($0) }.max()
                    if sensor == "GPU" { guard let gpu else { throw FanControlError.hardwareFailure("GPU temperature is unavailable on this Mac.") }; temp = gpu }
                    else { temp = max(cpu, gpu ?? cpu) }
                }
                return (FanSnapshot(currentRPM: fan.currentRPM, minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM, targetPercent: fan.targetPercent, automatic: fan.automatic, temperatureCelsius: cpu), temp)
            }
            DispatchQueue.main.async {
                self.polling = false
                // A read begun before a fan command cannot describe its result.
                guard generation == self.controlGeneration, sensor == self.selectedSensor else { return }
                switch result {
                case .success(let (snapshot, temp)):
                    self.sample = snapshot; self.displayTemperature = temp
                    self.history.append(temp); if self.history.count > 60 { self.history.removeFirst(self.history.count - 60) }
                    if self.error?.hasPrefix("Sensor:") == true { self.error = nil }
                    if self.ownsControl && snapshot.automatic {
                        // The helper may already have restored Auto after a
                        // safety event. Readback confirms that transition; do
                        // not repeatedly ask a released lease to restore again.
                        self.ownsControl = false; self.controlDeadline = nil
                        self.heartbeat?.invalidate(); self.heartbeat = nil
                    } else if self.ownsControl && (self.controlDeadline.map { $0 < .now } ?? false) { self.restore() }
                case .failure(let failure): self.error = "Sensor: \(failure.localizedDescription)"; self.displayTemperature = nil; if self.ownsControl { self.restore() }
                }
                self.changed?()
                if !self.helperReady, !self.busy, Date() >= self.nextReconnect {
                    self.nextReconnect = Date().addingTimeInterval(10)
                    let status = self.installer.status
                    self.helperApprovalRequired = status == .requiresApproval
                    if status == .enabled { self.connectHelper() }
                    else { self.changed?() }
                }
            }
        }
    }
    func enableControl() {
        guard !busy else { return }
        error = nil; busy = true; changed?()
        if let other = competingApp {
            guard other.terminate() else { error = "Quit Macs Fan Control, then enable Aervane."; busy = false; changed?(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }; if self.competingApp == nil { self.busy = false; self.enableControl() } else { self.busy = false; self.error = "Macs Fan Control is still closing. Try Enable again."; self.changed?() }
            }; return
        }
        do {
            let status = try installer.enable()
            helperApprovalRequired = status == .requiresApproval
            if helperApprovalRequired {
                busy = false; changed?()
                SMAppService.openSystemSettingsLoginItems()
            } else { connectHelper() }
        } catch { self.error = error.localizedDescription; busy = false; changed?() }
    }
    func connectHelper() {
        busy = true; helperApprovalRequired = false
        controlGeneration &+= 1
        connectionGeneration = UUID(); let generation = connectionGeneration
        helper?.onDisconnect = nil; helper?.invalidate(); let client = HelperClient(); helper = client
        client.onDisconnect = { [weak self] in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }
            self.connectionGeneration = UUID()
            self.controlGeneration &+= 1
            self.helperReady = false; self.ownsControl = false; self.busy = false
            self.controlDeadline = nil; self.heartbeat?.invalidate()
            self.error = "Fan helper disconnected. Reconnecting…"
            self.changed?()
        } }
        client.snapshot { [weak self] result in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }; self.busy = false
            switch result { case .success: self.helperReady = true; self.error = nil; if let pending = self.pendingPercent { self.setPercent(pending) }; case .failure(let failure): self.helperReady = false; self.error = failure.localizedDescription }
            self.changed?()
        } }
    }
    func setPercent(_ percent: Double) {
        guard !busy else { return }
        guard percent.isFinite else { return }
        let bounded = max(minimumPercent, min(100, percent.rounded()))
        guard !stale else { error = "Waiting for a fresh sensor reading."; changed?(); return }
        guard helperReady, competingApp == nil, let helper else { pendingPercent = bounded; error = nil; changed?(); return }
        controlGeneration &+= 1
        let operation = controlGeneration, connection = connectionGeneration
        busy = true; error = nil; changed?()
        helper.set(percent: bounded) { [weak self] result in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == connection, self.controlGeneration == operation else { return }
            self.controlGeneration &+= 1
            self.busy = false
            switch result {
            case .success(let snapshot): self.pendingPercent = nil; self.sample = snapshot; self.ownsControl = !snapshot.automatic; self.controlDeadline = .now.addingTimeInterval(self.manualDuration); self.startHeartbeat()
            case .failure(let failure): self.error = failure.localizedDescription
            }
            self.changed?()
        } }
    }
    private func startHeartbeat() {
        heartbeat?.invalidate(); guard ownsControl else { return }
        let connection = connectionGeneration
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.helper?.heartbeat { error in
                if let error { DispatchQueue.main.async {
                    guard let self, self.connectionGeneration == connection, self.ownsControl else { return }
                    self.controlGeneration &+= 1
                    self.error = error.localizedDescription; self.helperReady = false; self.ownsControl = false
                    self.busy = false; self.controlDeadline = nil; self.heartbeat?.invalidate(); self.changed?()
                } }
            }
        }
        heartbeat?.tolerance = 0.5
    }
    func restore(completion: (() -> Void)? = nil) {
        pendingPercent = nil
        guard ownsControl else { changed?(); completion?(); return }
        controlGeneration &+= 1
        let operation = controlGeneration, connection = connectionGeneration
        busy = true
        heartbeat?.invalidate(); controlDeadline = nil
        guard let helper, helperReady else { ownsControl = false; busy = false; changed?(); completion?(); return }
        changed?()
        helper.automatic { [weak self] result in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == connection, self.controlGeneration == operation else { completion?(); return }
            self.controlGeneration &+= 1
            self.busy = false
            switch result { case .success(let snapshot): self.sample = snapshot; self.ownsControl = false; case .failure(let failure): self.error = "Could not restore automatic control: \(failure.localizedDescription)" }
            self.changed?(); completion?()
        } }
    }
    func savePresets() { if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "presets") }; changed?() }
    func toggleLogin() { do { if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }; changed?() } catch { self.error = error.localizedDescription; changed?() } }
}
