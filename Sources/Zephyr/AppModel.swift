import AppKit
import ServiceManagement
import SMC
import ZephyrCore

final class AppModel {
    var changed: (() -> Void)?
    private let queue = DispatchQueue(label: "dev.kirniy.aervane.sensors", qos: .utility)
    private let reader: TelemetryReader
    private let defaults: UserDefaults
    private let startsServices: Bool
    private var temperatureSampledAt: Date?
    private(set) var fanAvailable = false
    private(set) var fanReadError: String?
    private(set) var hasTelemetryRead = false
    private(set) var hasDetectedFan = false
    /// Unknown hardware keeps the initial layout; a once-readable fan stays
    /// visible through transient failures so recovery/errors cannot disappear.
    var offersFanControls: Bool { !hasTelemetryRead || hasDetectedFan }
    var temperatureStale: Bool { temperatureSampledAt.map { Date().timeIntervalSince($0) > 12 } ?? true }
    private var timer: DispatchSourceTimer?
    private var heartbeat: Timer?
    private var helper: HelperClient?
    private var connectionGeneration = UUID()
    private var controlGeneration: UInt64 = 0
    private var nextReconnect = Date.distantPast
    private var approvalCheckUntil = Date.distantPast
    private let installer = HelperInstaller()
    private var sleepObservers: [NSObjectProtocol] = []
    var sample: FanSnapshot?
    var history: [Double] = []
    /// What Smart measured on its last evaluated sample, and its own history:
    /// a separate series so mode changes never mix different sensors.
    private(set) var smartSample: SmartSample?
    private(set) var smartHistory: [Double] = []
    /// The panel's temperature: Smart's own measurement while Smart runs,
    /// the selected sensor otherwise. The menu bar uses this same readout.
    var panelReadout: TemperatureReadout {
        TemperatureReadout.panel(smartEnabled: control.smartEnabled, smart: smartSample, selectedSensor: selectedSensor,
                                 selectedCelsius: displayTemperature, stale: control.smartEnabled ? stale : temperatureStale, now: Date())
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
    var panelVisible = false {
        didSet {
            if panelVisible {
                nextReconnect = .distantPast
                if !oldValue && helperApprovalRequired { approvalCheckUntil = Date().addingTimeInterval(120) }
            }
            schedulePoll()
        }
    }
    var presets: [FanPreset]
    var selectedSensor: String { didSet { defaults.set(selectedSensor, forKey: "sensor"); poll() } }
    var displayTemperature: Double?
    var fahrenheit: Bool { didSet { defaults.set(fahrenheit, forKey: "fahrenheit"); changed?() } }
    var lowPower: Bool { didSet { defaults.set(lowPower, forKey: "lowPower"); schedulePoll() } }
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
    var temperatureText: String { panelReadout.text(fahrenheit: fahrenheit) }
    var temperatureUnit: String { fahrenheit ? "°F" : "°C" }
    var stale: Bool { sample.map { Date().timeIntervalSince($0.sampledAt) > 12 } ?? true }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    init(reader: TelemetryReader = .live(), defaults: UserDefaults = .standard, startsServices: Bool = true) {
        self.reader = reader; self.defaults = defaults; self.startsServices = startsServices
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
        guard startsServices else { return }
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
        guard startsServices else { return }
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
            let reading = self.reader.read(wantsGPU: wantsGPU)
            DispatchQueue.main.async {
                self.polling = false
                // A read begun before a fan command cannot describe its result.
                guard generation == self.controlGeneration, sensor == self.selectedSensor else { return }
                self.acceptTelemetry(reading, sensor: sensor, smartGeneration: smartGeneration)
                self.changed?()
                if self.startsServices, !self.helperReady, !self.busy, Date() >= self.nextReconnect {
                    // Reuse the visible panel's existing 1 s sensor cadence while
                    // approval is pending; after two minutes return to 10 s.
                    let fastApproval = self.panelVisible && self.helperApprovalRequired && Date() < self.approvalCheckUntil
                    self.nextReconnect = Date().addingTimeInterval(fastApproval ? 1 : 10)
                    let status = self.installer.status
                    self.helperApprovalRequired = status == .requiresApproval
                    if status == .enabled { self.connectHelper() }
                    else { self.changed?() }
                }
            }
        }
    }
    /// Kept separate from I/O so channel failures and recovery can be tested
    /// without connecting a helper or touching hardware.
    func acceptTelemetry(_ reading: TelemetryReading, sensor: String, smartGeneration: UInt64 = 0) {
        hasTelemetryRead = true
        fanAvailable = reading.fanAvailable; fanReadError = reading.fanError
        if fanAvailable { hasDetectedFan = true }
        displayTemperature = reading.temperature(sensor: sensor)
        if case .success = reading.cpu { temperatureSampledAt = reading.at }
        else { temperatureSampledAt = nil }
        if error?.hasPrefix("Sensor:") == true { error = nil }
        if let temp = displayTemperature {
            history.append(temp); if history.count > 60 { history.removeFirst(history.count - 60) }
        } else {
            history.removeAll()
            if let failure = reading.cpuError { error = "Sensor: \(failure)" }
            else if error == nil { error = "Sensor: GPU temperature is unavailable on this Mac." }
        }
        guard let snapshot = reading.snapshot, let smartReading = reading.smartReading else {
            // Never let the last good fan reading enable writes after a failure.
            sample = nil
            if control.smartEnabled { if control.smartActive { stopSmart(.sensorFailed) } }
            else if ownsControl { restore() }
            return
        }
        sample = snapshot
        if ownsControl && snapshot.automatic {
            ownsControl = false; returnTimer.cancel(); stopHeartbeat()
            stopSmart(.controlLost)
        } else if ownsControl && returnTimer.isDue(now: .now) { restore() }
        control.observe(automatic: snapshot.automatic && !ownsControl)
        runSmart(smartReading, generation: smartGeneration)
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
                approvalCheckUntil = Date().addingTimeInterval(120)
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
    func chooseAutomatic(completion: (() -> Void)? = nil) {
        requestAutomatic(completion: completion) { owns in self.control.userAutomatic(owns: owns) }
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
        defaults.set(value, forKey: Self.smartTargetKey)
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
        defaults.set(returnTimer.enabled, forKey: "autoReturnEnabled")
        defaults.set(returnTimer.minutes, forKey: "autoReturnMinutes")
        changed?()
    }
    func savePresets() { if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "presets") }; changed?() }
    func toggleLogin() { do { if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }; changed?() } catch { self.error = error.localizedDescription; changed?() } }
}
