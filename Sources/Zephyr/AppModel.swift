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
    /// True while connecting, setting up, or while a fan command is in flight.
    var busy: Bool { settingUp || requests.isBusy }
    private var settingUp = false
    private var requests = ControlRequestQueue()
    private var restoreWaiters: [() -> Void] = []
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
    /// Speed the user most recently asked for that the helper has not confirmed.
    var requestedPercent: Double? { pendingPercent ?? requests.pendingPercent }
    var shownPercent: Double { requestedPercent ?? sample?.targetPercent ?? actualPercent }
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
        guard !polling, !requests.isBusy else { return }; polling = true
        let sensor = selectedSensor
        let generation = controlGeneration
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<(FanSnapshot, Double), Error> = Result {
                let cpu = try self.reader.readCPUTemperature(), fan = try self.reader.readFan()
                var temp = cpu
                if sensor != "CPU" {
                    let gpu = try? self.reader.readGPUTemperature()
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
                        self.stopHeartbeat()
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
        error = nil; settingUp = true; changed?()
        if let other = competingApp {
            guard other.terminate() else { error = "Quit Macs Fan Control, then enable Aervane."; settingUp = false; changed?(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }; self.settingUp = false
                if self.competingApp == nil { self.enableControl() } else { self.error = "Macs Fan Control is still closing. Try Enable again."; self.changed?() }
            }; return
        }
        do {
            let status = try installer.enable()
            helperApprovalRequired = status == .requiresApproval
            if helperApprovalRequired {
                settingUp = false; changed?()
                SMAppService.openSystemSettingsLoginItems()
            } else { connectHelper() }
        } catch { self.error = error.localizedDescription; settingUp = false; changed?() }
    }
    func connectHelper() {
        settingUp = true; helperApprovalRequired = false
        controlGeneration &+= 1
        // Replies from the previous connection are discarded below, so its
        // queue must not wait for them.
        _ = requests.reset(); finishRestoreWaiters()
        // Closing the old connection makes the helper restore anything that
        // session owned; this app no longer owns control after reconnecting.
        ownsControl = false; controlDeadline = nil; stopHeartbeat()
        connectionGeneration = UUID(); let generation = connectionGeneration
        helper?.onDisconnect = nil; helper?.invalidate(); let client = HelperClient(); helper = client
        client.onDisconnect = { [weak self] in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }
            self.connectionGeneration = UUID()
            self.controlGeneration &+= 1
            // The helper restores Auto for a dropped session it owned, which
            // also satisfies any Auto request that was still queued here.
            _ = self.requests.reset()
            self.helperReady = false; self.ownsControl = false; self.settingUp = false
            self.controlDeadline = nil; self.stopHeartbeat()
            self.error = "Fan helper disconnected. Reconnecting…"
            self.finishRestoreWaiters()
            self.changed?()
        } }
        client.snapshot { [weak self] result in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }; self.settingUp = false
            switch result { case .success: self.helperReady = true; self.error = nil; if let pending = self.pendingPercent { self.setPercent(pending) }; case .failure(let failure): self.helperReady = false; self.error = failure.localizedDescription }
            self.changed?()
        } }
    }
    func setPercent(_ percent: Double) {
        guard percent.isFinite else { return }
        let bounded = max(minimumPercent, min(100, percent.rounded()))
        guard !stale else { error = "Waiting for a fresh sensor reading."; changed?(); return }
        guard helperReady, competingApp == nil, helper != nil else { pendingPercent = bounded; error = nil; changed?(); return }
        error = nil
        submit(.set(bounded))
    }
    /// Returns the fan to firmware control. Always accepted: while another
    /// command is in flight it is queued and runs next.
    func restore(completion: (() -> Void)? = nil) {
        pendingPercent = nil
        if let completion { restoreWaiters.append(completion) }
        guard helperReady, helper != nil else {
            ownsControl = false; controlDeadline = nil; stopHeartbeat()
            finishRestoreWaiters(); changed?(); return
        }
        // A set in flight may be about to take control, so Auto still has
        // to follow it. Otherwise there is nothing of ours to restore.
        guard ownsControl || requests.isBusy else { finishRestoreWaiters(); changed?(); return }
        submit(.automatic)
    }

    private func submit(_ command: ControlRequestQueue.Command) {
        if let now = requests.submit(command) { send(now) } else { changed?() }
    }
    private func send(_ command: ControlRequestQueue.Command) {
        guard let helper else { _ = requests.reset(); finishRestoreWaiters(); changed?(); return }
        controlGeneration &+= 1
        let operation = controlGeneration, connection = connectionGeneration
        changed?()
        let completion: (Result<FanSnapshot, Error>) -> Void = { [weak self] result in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == connection, self.controlGeneration == operation else { return }
            self.complete(command, result)
        } }
        switch command {
        case .set(let value): helper.set(percent: value, completion)
        case .automatic: helper.automatic(completion)
        }
    }
    private func complete(_ command: ControlRequestQueue.Command, _ result: Result<FanSnapshot, Error>) {
        controlGeneration &+= 1
        switch (command, result) {
        case (.set, .success(let snapshot)):
            pendingPercent = nil; sample = snapshot; error = nil
            ownsControl = !snapshot.automatic
            controlDeadline = .now.addingTimeInterval(manualDuration); startHeartbeat()
        case (.set, .failure(let failure)):
            // The helper rolls back failed writes itself and says whether Auto
            // verified. Ownership is then confirmed by the next readback. A
            // failed preview is not retried silently on a later reconnect.
            pendingPercent = nil
            error = failure.localizedDescription
        case (.automatic, .success(let snapshot)):
            sample = snapshot; error = nil
            ownsControl = false; controlDeadline = nil; stopHeartbeat()
        case (.automatic, .failure(let failure)):
            if case .notOwner? = HelperClient.classify(failure) {
                // The helper already ended this lease (safety restore,
                // expiry). There is nothing left for us to restore.
                ownsControl = false; controlDeadline = nil; stopHeartbeat()
            } else {
                error = "Could not restore automatic control: \(failure.localizedDescription)"
            }
        }
        if let next = requests.finish() { send(next) } else { finishRestoreWaiters() }
        changed?()
    }
    private func finishRestoreWaiters() {
        let waiters = restoreWaiters; restoreWaiters.removeAll()
        waiters.forEach { $0() }
    }
    private func startHeartbeat() {
        stopHeartbeat(); guard ownsControl else { return }
        let connection = connectionGeneration
        heartbeat = Timer.scheduledTimer(withTimeInterval: FanSafety.heartbeatInterval, repeats: true) { [weak self] _ in
            // A command in flight renews the helper lease itself; a heartbeat
            // would only queue behind it on the helper's serial queue.
            guard let self, !self.requests.isBusy else { return }
            self.helper?.heartbeat { error in
                guard let error else { return }
                DispatchQueue.main.async {
                    guard self.connectionGeneration == connection, self.ownsControl else { return }
                    // Only the helper's explicit answer means the lease ended;
                    // the helper stays connected and usable. Transport errors
                    // and timeouts arrive through the disconnect handler.
                    guard case .notOwner? = HelperClient.classify(error) else { return }
                    self.ownsControl = false; self.controlDeadline = nil; self.stopHeartbeat()
                    self.error = "The helper ended manual control and is returning the fan to Auto."
                    self.changed?()
                }
            }
        }
        heartbeat?.tolerance = 0.5
    }
    private func stopHeartbeat() { heartbeat?.invalidate(); heartbeat = nil }
    func savePresets() { if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "presets") }; changed?() }
    func toggleLogin() { do { if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }; changed?() } catch { self.error = error.localizedDescription; changed?() } }
}
