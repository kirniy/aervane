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
    /// What Smart measured on its last evaluated sample, and its own history:
    /// a separate series so mode changes never mix different sensors.
    private(set) var smartSample: SmartSample?
    private(set) var smartHistory: [Double] = []
    /// The panel's temperature: Smart's own measurement while Smart runs,
    /// the selected sensor otherwise. The menu bar keeps the selected sensor.
    var panelReadout: TemperatureReadout {
        TemperatureReadout.panel(smartEnabled: control.smartEnabled, smart: smartSample, selectedSensor: selectedSensor,
                                 selectedCelsius: displayTemperature, stale: stale, now: Date())
    }
    var error: String?
    /// True while connecting, setting up, or while a fan command is in flight.
    var busy: Bool { settingUp || control.isBusy }
    private var settingUp = false
    /// Every fan command, Smart's session, sleep suspension and the Smart
    /// stop notice (pure; see FanCommandCoordinator).
    private var control: FanCommandCoordinator
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
    private var returnTimer: ManualReturnTimer
    /// Opt-in Smart cooling (off by default). Any user speed or Auto ends it.
    var smartEnabled: Bool { control.smartEnabled }
    /// What Smart last saw and wants, for display.
    var smartStep: SmartCoolingController.Step? { control.smart.lastStep }
    var smartPolicy: SmartCoolingPolicy { control.smart.controller.policy }
    /// Why Smart last stopped on its own and whether Auto is confirmed. Kept
    /// apart from `error` so a later successful command cannot erase it.
    var smartNotice: String? { control.notice?.message }
    /// The temperature Smart works to stay under, °C (kept while Smart is off).
    var smartTarget: Double { control.smartTarget }
    /// Smart is at full speed and the temperature is still over its target.
    var smartSaturated: Bool { control.smartSaturated }
    var controlDeadline: Date? { returnTimer.deadline }
    var autoReturnEnabled: Bool {
        get { returnTimer.enabled }
        set { configureReturnTimer(enabled: newValue, minutes: returnTimer.minutes) }
    }
    var autoReturnMinutes: Double {
        get { returnTimer.minutes }
        set { configureReturnTimer(enabled: returnTimer.enabled, minutes: newValue) }
    }
    var competingApp: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").first }
    var minimumPercent: Double { guard let s = sample, s.maximumRPM > 0 else { return 0 }; return ceil(s.minimumRPM / s.maximumRPM * 100) }
    var actualPercent: Double { guard let s = sample, s.maximumRPM > 0 else { return 0 }; return min(100, max(0, s.currentRPM / s.maximumRPM * 100)) }
    /// Speed the user most recently asked for that the helper has not confirmed.
    var requestedPercent: Double? { pendingPercent ?? control.pendingPercent }
    var shownPercent: Double { requestedPercent ?? sample?.targetPercent ?? actualPercent }
    var temperatureText: String { guard let temp = displayTemperature, !stale else { return "—" }; return String(Int((fahrenheit ? temp * 1.8 + 32 : temp).rounded())) }
    var temperatureUnit: String { fahrenheit ? "°F" : "°C" }
    var stale: Bool { sample.map { Date().timeIntervalSince($0.sampledAt) > 12 } ?? true }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    init() {
        let defaults = UserDefaults.standard
        returnTimer = ManualReturnTimer(enabled: defaults.bool(forKey: "autoReturnEnabled"),
                                       minutes: defaults.object(forKey: "autoReturnMinutes") as? Double ?? 30)
        // A Smart choice persists across launches; a fault turns it off (and
        // that persists too), so it never resumes after a failure on its own.
        control = FanCommandCoordinator(smartEnabled: defaults.bool(forKey: Self.smartKey),
                                        previousStop: defaults.string(forKey: Self.smartStopKey).flatMap(SmartStopReason.init(rawValue:)),
                                        targetCelsius: SmartTarget.clamp(defaults.object(forKey: Self.smartTargetKey) as? Double))
        selectedSensor = defaults.string(forKey: "sensor") ?? "CPU"
        fahrenheit = defaults.bool(forKey: "fahrenheit"); lowPower = defaults.bool(forKey: "lowPower")
        if let data = defaults.data(forKey: "presets"), let saved = try? JSONDecoder().decode([FanPreset].self, from: data) {
            presets = Array(saved.filter { !$0.name.isEmpty && $0.name.count <= 20 && $0.percent.isFinite && (0...100).contains($0.percent) }.prefix(6))
        } else { presets = [FanPreset(name: "Quiet", percent: 30), FanPreset(name: "Balanced", percent: 60), FanPreset(name: "Boost", percent: 100)] }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.willSleep() })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.control.wake(); self?.schedulePoll()
        })
        schedulePoll()
        let status = installer.status
        helperApprovalRequired = status == .requiresApproval
        if status == .enabled { connectHelper() }
    }
    deinit { for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; timer?.cancel(); heartbeat?.invalidate() }
    func schedulePoll() {
        timer?.cancel()
        // Smart needs fresh readings to react in time, so it keeps a 2 s
        // cadence with the panel closed, overriding Low power.
        let interval: TimeInterval = panelVisible ? 1 : control.smartActive ? 2 : lowPower ? 8 : 3
        let t = DispatchSource.makeTimerSource(queue: .main); t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(panelVisible ? 150 : 700)); t.setEventHandler { [weak self] in self?.poll() }; timer = t; t.resume()
    }
    private var polling = false
    func poll() {
        // Connecting to the helper must not pause read-only telemetry. Only
        // an in-flight hardware command needs to exclude an overlapping poll.
        guard !polling, !control.isBusy else { return }; polling = true
        let sensor = selectedSensor
        let generation = controlGeneration
        // Smart's own generation: a read begun before Smart was turned on,
        // off, suspended or resumed never drives it.
        let smartGeneration = control.sampleGeneration
        let wantsGPU = sensor != "CPU" || control.smartEnabled
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<(FanSnapshot, Double?, SmartCoolingReading), Error> = Result {
                let cpu = try self.reader.readCPUTemperatures(), fan = try self.reader.readFan()
                var temp: Double? = cpu.average
                let gpu = wantsGPU ? try? self.reader.readGPUTemperature() : nil
                // An unavailable optional display sensor must not end
                // manual control while CPU and fan telemetry are healthy.
                if sensor == "GPU" { temp = gpu }
                else if sensor != "CPU" { temp = max(cpu.average, gpu ?? cpu.average) }
                // Smart follows the hottest core (and a hotter GPU average)
                // whatever the menu bar shows.
                let smartReading = SmartCoolingReading(cpuHottest: cpu.hottest, gpu: gpu)
                return (FanSnapshot(currentRPM: fan.currentRPM, minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM, targetPercent: fan.targetPercent, automatic: fan.automatic, temperatureCelsius: cpu.average), temp, smartReading)
            }
            DispatchQueue.main.async {
                self.polling = false
                // A read begun before a fan command cannot describe its result.
                guard generation == self.controlGeneration, sensor == self.selectedSensor else { return }
                switch result {
                case .success(let (snapshot, temp, smartReading)):
                    self.sample = snapshot; self.displayTemperature = temp
                    if self.error?.hasPrefix("Sensor:") == true { self.error = nil }
                    if let temp {
                        self.history.append(temp); if self.history.count > 60 { self.history.removeFirst(self.history.count - 60) }
                    } else {
                        self.history.removeAll()
                        if self.error == nil { self.error = "Sensor: GPU temperature is unavailable on this Mac." }
                    }
                    if self.ownsControl && snapshot.automatic {
                        // The helper may already have restored Auto after a
                        // safety event. Readback confirms that transition; do
                        // not repeatedly ask a released lease to restore again.
                        self.ownsControl = false; self.returnTimer.cancel()
                        self.stopHeartbeat()
                        self.stopSmart(.controlLost)
                    } else if self.ownsControl && self.returnTimer.isDue(now: .now) { self.restore() }
                    self.control.observe(automatic: snapshot.automatic && !self.ownsControl)
                    self.runSmart(smartReading, generation: smartGeneration)
                case .failure(let failure):
                    self.error = "Sensor: \(failure.localizedDescription)"; self.displayTemperature = nil
                    // A read that fails across sleep is not Smart's failure.
                    if self.control.smartEnabled { if self.control.smartActive { self.stopSmart(.sensorFailed) } }
                    else if self.ownsControl { self.restore() }
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
        control.resetConnection(); finishRestoreWaiters()
        // Closing the old connection makes the helper restore anything that
        // session owned; this app no longer owns control after reconnecting.
        ownsControl = false; returnTimer.cancel(); stopHeartbeat()
        connectionGeneration = UUID(); let generation = connectionGeneration
        helper?.onDisconnect = nil; helper?.invalidate(); let client = HelperClient(); helper = client
        client.onDisconnect = { [weak self] in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }
            self.connectionGeneration = UUID()
            self.controlGeneration &+= 1
            // The helper restores Auto for a dropped session it owned, which
            // also satisfies any Auto request that was still queued here.
            self.control.resetConnection()
            self.helperReady = false; self.ownsControl = false; self.settingUp = false
            self.returnTimer.cancel(); self.stopHeartbeat()
            self.error = "Fan helper disconnected. Reconnecting…"
            self.finishRestoreWaiters()
            self.stopSmart(.helperDisconnected)
            self.changed?()
        } }
        client.snapshot { [weak self] result in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }; self.settingUp = false
            switch result { case .success: self.helperReady = true; self.error = nil; if let pending = self.pendingPercent { self.setPercent(pending) }; case .failure(let failure): self.helperReady = false; self.error = failure.localizedDescription }
            self.changed?()
        } }
    }
    /// A speed the user chose (slider, preset, Manual). Ends Smart first, so
    /// nothing automated can follow or overwrite it.
    func setPercent(_ percent: Double) {
        guard percent.isFinite else { return }
        let bounded = max(minimumPercent, min(100, percent.rounded()))
        guard !stale else { error = "Waiting for a fresh sensor reading."; changed?(); return }
        guard helperReady, competingApp == nil, helper != nil else {
            // Kept as a preview until setup; it still ends Smart now.
            _ = control.stopSmart(.manual, owns: false); persistSmart()
            pendingPercent = bounded; error = nil; changed?(); return
        }
        error = nil
        let ticket = control.userSet(bounded)
        persistSmart()
        if let ticket { send(ticket) } else { changed?() }
    }
    /// The user chose Auto: ends Smart and returns the fan to firmware control.
    func chooseAutomatic() {
        requestAutomatic(completion: nil) { owns in self.control.userAutomatic(owns: owns) }
    }
    /// Returns the fan to firmware control (sleep, quit, Return to Auto, a
    /// manual sensor failure). Always accepted: while another command is in
    /// flight it is queued and runs next. Smart's setting is unchanged.
    func restore(completion: (() -> Void)? = nil) {
        requestAutomatic(completion: completion) { owns in self.control.systemRestore(owns: owns) }
    }
    private func requestAutomatic(completion: (() -> Void)?, _ make: (Bool) -> FanCommandCoordinator.Ticket?) {
        pendingPercent = nil
        if let completion { restoreWaiters.append(completion) }
        guard helperReady, helper != nil else {
            // Nothing can be sent; never leave a ticket waiting on no helper.
            if make(false) != nil { control.resetConnection() }
            persistSmart()
            ownsControl = false; returnTimer.cancel(); stopHeartbeat()
            finishRestoreWaiters(); changed?(); return
        }
        // A set in flight may be about to take control, so Auto still has
        // to follow it. Otherwise there is nothing of ours to restore.
        let ticket = make(ownsControl)
        persistSmart()
        if let ticket { send(ticket) } else if !control.isBusy { finishRestoreWaiters(); changed?() } else { changed?() }
    }

    // MARK: Smart cooling

    private static let smartKey = "smartCooling", smartStopKey = "smartCoolingStopReason", smartTargetKey = "smartTargetCelsius"
    /// The main selector's Smart choice.
    func chooseSmart() { setSmartCooling(true) }
    /// A new target (validated and persisted). It never turns Smart on; while
    /// Smart runs, the next reading applies it.
    func setSmartTarget(_ celsius: Double) {
        let value = SmartTarget.clamp(celsius)
        guard value != control.smartTarget else { return }
        control.setSmartTarget(value)
        UserDefaults.standard.set(value, forKey: Self.smartTargetKey)
        changed?()
    }
    /// The user took hold of the slider or its keys: Manual at once, with no
    /// command until the user's speed is committed, so Smart never fights it.
    func beginManualAdjustment() {
        guard control.smartEnabled else { return }
        control.userBeganAdjusting()
        persistSmart(); schedulePoll(); changed?()
    }
    /// Turns Smart on (the main selector) or off. Off returns to firmware Auto.
    func setSmartCooling(_ on: Bool) {
        guard on != control.smartEnabled else { return }
        guard on else { stopSmart(.user); return }
        // Start from what the fan is doing now: the speed in flight or owned,
        // else the measured speed under firmware control.
        let owned = ownsControl && !control.isBusy && sample?.automatic == false
        let seed = control.pendingPercent ?? (owned ? sample?.targetPercent : nil) ?? (sample == nil ? nil : actualPercent)
        control.enableSmart(seed: seed, applied: owned && sample?.targetPercent != nil)
        clearSmartSample()
        pendingPercent = nil
        // The Return to Auto timer is for manual speeds only.
        returnTimer.cancel()
        persistSmart(); schedulePoll(); changed?()
    }
    private func stopSmart(_ reason: SmartStopReason) {
        guard control.smartEnabled else { return }
        clearSmartSample()
        let ticket = control.stopSmart(reason, owns: ownsControl)
        persistSmart()
        if let ticket { send(ticket) }
        schedulePoll(); changed?()
    }
    private func persistSmart() {
        let defaults = UserDefaults.standard
        defaults.set(control.smartEnabled, forKey: Self.smartKey)
        if let reason = control.notice?.reason { defaults.set(reason.rawValue, forKey: Self.smartStopKey) }
        else { defaults.removeObject(forKey: Self.smartStopKey) }
    }
    /// One Smart evaluation per fresh sample. It commands only through the
    /// serial queue, never while any command is in flight, and only with a
    /// ready helper and a fresh reading begun under the current generation.
    private func runSmart(_ reading: SmartCoolingReading, generation: UInt64) {
        guard control.smartActive else { return }
        let evaluations = control.smart.evaluations
        defer { recordSmartSample(after: evaluations) }
        if competingApp != nil { stopSmart(.competingController); return }
        let ready = helperReady && helper != nil && !settingUp && !stale
        let current = ownsControl ? (sample?.targetPercent ?? actualPercent) : actualPercent
        guard let ticket = control.sample(reading, generation: generation, at: ProcessInfo.processInfo.systemUptime,
                                          floor: minimumPercent, ready: ready, current: current) else { return }
        send(ticket)
    }
    /// Keeps what Smart measured, only when this sample was evaluated (a read
    /// from an older generation is not), with its own history.
    private func recordSmartSample(after evaluations: UInt64) {
        guard control.smart.evaluations != evaluations, let step = control.smart.lastStep else { return }
        smartSample = SmartSample(celsius: step.celsius, source: step.source, at: Date())
        if let celsius = step.celsius {
            smartHistory.append(celsius); if smartHistory.count > 60 { smartHistory.removeFirst(smartHistory.count - 60) }
        } else { smartHistory.removeAll() }
    }
    private func clearSmartSample() { smartSample = nil; smartHistory.removeAll() }
    /// Asleep, firmware owns the fan. Smart stays on, suspended, and resumes
    /// from the first reading begun after wake. Auto follows anything in
    /// flight, which may be about to take the fan.
    private func willSleep() {
        timer?.cancel(); timer = nil
        clearSmartSample()
        requestAutomatic(completion: nil) { owns in self.control.sleep(owns: owns) }
    }

    private func send(_ ticket: FanCommandCoordinator.Ticket) {
        guard let helper else { control.resetConnection(); finishRestoreWaiters(); changed?(); return }
        controlGeneration &+= 1
        let operation = controlGeneration, connection = connectionGeneration
        changed?()
        let completion: (Result<FanSnapshot, Error>) -> Void = { [weak self] result in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == connection, self.controlGeneration == operation else { return }
            self.complete(ticket, result)
        } }
        switch ticket.command {
        case .set(let value): helper.set(percent: value, completion)
        case .automatic: helper.automatic(completion)
        }
    }
    private func complete(_ ticket: FanCommandCoordinator.Ticket, _ result: Result<FanSnapshot, Error>) {
        controlGeneration &+= 1
        let outcome: FanCommandCoordinator.Outcome
        switch result {
        case .success(let snapshot): outcome = .applied(automatic: snapshot.automatic)
        case .failure(let failure):
            if case .notOwner? = HelperClient.classify(failure) { outcome = .notOwner } else { outcome = .failed(failure.localizedDescription) }
        }
        // Identity, not value: a reply for anything but the command in flight
        // (e.g. from before a reset) changes nothing.
        let smartBefore = control.smartEnabled
        guard let done = control.complete(id: ticket.id, outcome: outcome) else { changed?(); return }
        // Smart's own failed write ends it (see FanCommandCoordinator).
        if smartBefore != control.smartEnabled { schedulePoll() }
        switch (ticket.command, result) {
        case (.set, .success(let snapshot)):
            pendingPercent = nil; sample = snapshot; error = nil
            ownsControl = !snapshot.automatic
            // Return to Auto applies to a user's manual speed only; Smart's
            // writes, and replies that arrive after Smart took over, never
            // start or renew it.
            if ownsControl && done.startReturnTimer { returnTimer.start(now: .now) } else { returnTimer.cancel() }
            startHeartbeat()
        case (.set, .failure(let failure)):
            // The helper rolls back failed writes itself and says whether Auto
            // verified. Ownership is then confirmed by the next readback. A
            // failed preview is not retried silently on a later reconnect.
            pendingPercent = nil
            error = failure.localizedDescription
        case (.automatic, .success(let snapshot)):
            sample = snapshot; error = nil
            ownsControl = false; returnTimer.cancel(); stopHeartbeat()
        case (.automatic, .failure(let failure)):
            if case .notOwner? = HelperClient.classify(failure) {
                // The helper already ended this lease (safety restore,
                // expiry). There is nothing left for us to restore.
                ownsControl = false; returnTimer.cancel(); stopHeartbeat()
            } else {
                error = "Could not restore automatic control: \(failure.localizedDescription)"
            }
        }
        persistSmart()
        if let next = done.next { send(next) } else { finishRestoreWaiters() }
        changed?()
    }
    private func finishRestoreWaiters() {
        let waiters = restoreWaiters; restoreWaiters.removeAll()
        waiters.forEach { $0() }
    }
    private func startHeartbeat() {
        stopHeartbeat(); guard ownsControl else { return }
        let connection = connectionGeneration
        heartbeat = Timer(timeInterval: FanSafety.heartbeatInterval, repeats: true) { [weak self] _ in
            // A command in flight renews the helper lease itself; a heartbeat
            // would only queue behind it on the helper's serial queue.
            guard let self, !self.control.isBusy else { return }
            self.helper?.heartbeat { error in
                guard let error else { return }
                DispatchQueue.main.async {
                    guard self.connectionGeneration == connection, self.ownsControl else { return }
                    // Only the helper's explicit answer means the lease ended;
                    // the helper stays connected and usable. Transport errors
                    // and timeouts arrive through the disconnect handler.
                    guard case .notOwner? = HelperClient.classify(error) else { return }
                    self.ownsControl = false; self.returnTimer.cancel(); self.stopHeartbeat()
                    self.error = "The helper ended manual control and is returning the fan to Auto."
                    self.stopSmart(.controlLost)
                    self.changed?()
                }
            }
        }
        heartbeat?.tolerance = 0.5
        // Native controls track in a different run-loop mode. Holding a
        // button or dragging the optional time slider must not look like a
        // disconnected client to the helper.
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }
    private func stopHeartbeat() { heartbeat?.invalidate(); heartbeat = nil }
    private func configureReturnTimer(enabled: Bool, minutes: Double) {
        returnTimer.configure(enabled: enabled, minutes: minutes, manual: ownsControl && !control.smartEnabled, now: .now)
        UserDefaults.standard.set(returnTimer.enabled, forKey: "autoReturnEnabled")
        UserDefaults.standard.set(returnTimer.minutes, forKey: "autoReturnMinutes")
        changed?()
    }
    func savePresets() { if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "presets") }; changed?() }
    func toggleLogin() { do { if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }; changed?() } catch { self.error = error.localizedDescription; changed?() } }
}
