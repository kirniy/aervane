import Foundation

/// The first-launch introduction, inside the panel: a live temperature, a
/// truthful glance at the fan, and one choice (control the fan, or just the
/// temperature). Choosing control is only a preview until the person asks
/// for setup; setup waits for their approval in Login Items, and the card
/// says "Connected" only once the helper has actually answered. Nothing here
/// ever changes the fan speed.
///
/// Pure and injectable (`OnboardingStore` takes any `UserDefaults`), so every
/// transition is testable without AppKit or hardware.
struct Onboarding: Equatable {
    enum Stage: String, CaseIterable { case welcome, preview, approval, connected, finished }
    enum FanChoice: String, CaseIterable { case undecided, control, temperatureOnly }
    enum Event: Equatable {
        case chooseControl, chooseTemperatureOnly, setupRequested, setupFailed, helperConnected, panelClosed, finish, replay
        /// Settings: show the fan controls again (true) or only the temperature.
        case fanControls(Bool)
    }
    /// What the panel shows below the temperature.
    enum Section: Equatable { case welcome, fan, temperatureOnly }
    /// The setup card inside the fan section.
    enum Card: Equatable { case none, approval, connected }

    private(set) var stage: Stage
    private(set) var choice: FanChoice

    init(stage: Stage = .welcome, choice: FanChoice = .undecided) { self.stage = stage; self.choice = choice }

    /// No fan (or no readable fan) means temperature only, with no choice to
    /// make and nothing to set up.
    func section(fanAvailable: Bool) -> Section {
        guard fanAvailable else { return .temperatureOnly }
        if stage == .welcome { return .welcome }
        return choice == .temperatureOnly ? .temperatureOnly : .fan
    }
    /// The approval card while setup waits; "Connected" only once the helper
    /// is ready (a verified answer, never assumed).
    func card(helperReady: Bool, fanAvailable: Bool) -> Card {
        guard fanAvailable, choice != .temperatureOnly else { return .none }
        switch stage {
        case .approval: return helperReady ? .connected : .approval
        case .connected: return helperReady ? .connected : .none
        default: return .none
        }
    }
    /// Whether the panel opens by itself once (first launch only).
    var wantsFirstShow: Bool { stage == .welcome }

    mutating func handle(_ event: Event) {
        switch event {
        case .chooseControl:
            choice = .control; stage = .preview
        case .chooseTemperatureOnly:
            choice = .temperatureOnly; stage = .finished
        case .setupRequested:
            // Only an explicit setup click leads here.
            choice = .control
            stage = .approval
        case .setupFailed:
            if stage == .approval { stage = .preview }
        case .helperConnected:
            if stage == .approval || stage == .preview { stage = .connected }
        case .panelClosed:
            // Closing is a choice too: the introduction never insists, and a
            // finished setup leaves the card behind. Waiting for approval
            // survives closing (System Settings is often in front).
            if stage == .welcome || stage == .connected { stage = .finished }
        case .finish:
            stage = .finished
        case .replay:
            stage = .welcome
        case .fanControls(let shown):
            choice = shown ? .control : .temperatureOnly
            if stage == .welcome { stage = .finished }
        }
    }
}

/// Where the introduction's progress is remembered.
struct OnboardingStore {
    static let stageKey = "onboarding.stage", choiceKey = "onboarding.fanChoice", firstShowKey = "onboarding.firstShowDone"
    /// Keys only an earlier Aervane writes (a preference changed, presets,
    /// Smart). Present → this is not a first launch.
    static let priorKeys = ["presets", "sensor", "fahrenheit", "lowPower", "smartCooling", "smartCoolingStopReason", "smartTargetCelsius",
                            "autoReturnEnabled", "autoReturnMinutes", PresentationPreferences.Key.menuBarContent, PresentationPreferences.Key.menuBarSpacing,
                            PresentationPreferences.Key.effects, PresentationPreferences.Key.heatColor, PresentationPreferences.Key.sliderStyle]

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Earlier use: any saved preference, or a helper already registered
    /// (enabled or awaiting approval).
    static func isExistingUser(defaults: UserDefaults, helperRegistered: Bool) -> Bool {
        helperRegistered || priorKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// The saved state; on first run a new user starts at the welcome and an
    /// existing user is never shown the introduction automatically.
    func load(helperRegistered: Bool) -> Onboarding {
        if let stage = defaults.string(forKey: Self.stageKey).flatMap(Onboarding.Stage.init(rawValue:)) {
            let choice = defaults.string(forKey: Self.choiceKey).flatMap(Onboarding.FanChoice.init(rawValue:)) ?? .undecided
            return Onboarding(stage: stage, choice: choice)
        }
        let state = Self.isExistingUser(defaults: defaults, helperRegistered: helperRegistered)
            ? Onboarding(stage: .finished, choice: helperRegistered ? .control : .undecided) : Onboarding()
        save(state)
        if state.stage == .finished { firstShowDone = true }
        return state
    }
    func save(_ state: Onboarding) {
        defaults.set(state.stage.rawValue, forKey: Self.stageKey); defaults.set(state.choice.rawValue, forKey: Self.choiceKey)
    }
    /// The panel opened by itself once already.
    var firstShowDone: Bool {
        get { defaults.bool(forKey: Self.firstShowKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.firstShowKey) }
    }
}

/// The live introduction: state plus persistence on every change.
final class OnboardingFlow {
    private let store: OnboardingStore
    private(set) var state: Onboarding { didSet { if state != oldValue { store.save(state); changed?() } } }
    var changed: (() -> Void)?

    init(store: OnboardingStore, helperRegistered: Bool) {
        self.store = store; state = store.load(helperRegistered: helperRegistered)
    }
    func handle(_ event: Onboarding.Event) { state.handle(event) }
    /// True once: the very first launch opens the panel by itself.
    var shouldShowOnLaunch: Bool { state.wantsFirstShow && !store.firstShowDone }
    func didShowOnLaunch() { store.firstShowDone = true }
}
