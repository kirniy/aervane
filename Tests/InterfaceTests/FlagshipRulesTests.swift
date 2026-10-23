import XCTest
import ZephyrCore
@testable import Zephyr

/// Pure rules behind the flagship release: the Dot Grid's all-speed wave,
/// Smart's target on the trend, target keys and the introduction. Foundation
/// only, so they run anywhere (including the Linux rule check).
final class DotVitalityTests: XCTestCase {
    private let expressive = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
    private let subtle = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)

    /// The pace follows measured RPM over the maximum, faster as the fan
    /// works harder, and visibly moving even at the firmware idle.
    func testPaceFollowsTheActualFanAtEverySpeed() {
        XCTAssertEqual(DotVitality.fraction(rpm: 2450, maximumRPM: 4900), 0.5, accuracy: 1e-12)
        XCTAssertEqual(DotVitality.velocity(fraction: DotVitality.fraction(rpm: 1000, maximumRPM: 4900)), 6 + 104 * 1000 / 4900, accuracy: 1e-9)
        XCTAssertEqual(DotVitality.velocity(fraction: 1), 110, accuracy: 1e-9)
        var previous = 0.0
        for rpm in stride(from: 100.0, through: 4900, by: 100) {
            let v = DotVitality.velocity(fraction: DotVitality.fraction(rpm: rpm, maximumRPM: 4900))
            XCTAssertGreaterThan(v, previous); previous = v
        }
        XCTAssertGreaterThan(DotVitality.velocity(fraction: 0.2), 20, "The idle visibly drifts")
        XCTAssertEqual(DotVitality.fraction(rpm: 9000, maximumRPM: 4900), 1, "Over-range telemetry clamps")
    }

    func testStoppedUnknownOrInvalidStandsStill() {
        for (rpm, maximum) in [(0.0, 4900.0), (-5, 4900), (.nan, 4900), (2000, 0), (2000, .nan)] as [(Double, Double)] {
            XCTAssertEqual(DotVitality.velocity(fraction: DotVitality.fraction(rpm: rpm, maximumRPM: maximum)), 0)
        }
        XCTAssertEqual(DotVitality.fraction(rpm: nil, maximumRPM: 4900), 0)
        XCTAssertEqual(DotVitality.fraction(rpm: 2000, maximumRPM: nil), 0)
    }

    /// Subtle: same pace, half the presence; more expressive at high speed;
    /// Off and Reduce Motion: nothing.
    func testAmplitudeGrowsWithSpeedAndSubtleHalvesIt() {
        XCTAssertLessThan(DotVitality.amplitude(fraction: 0.2, effects: expressive), DotVitality.amplitude(fraction: 1, effects: expressive))
        XCTAssertEqual(DotVitality.amplitude(fraction: 0.6, effects: subtle), DotVitality.amplitude(fraction: 0.6, effects: expressive) / 2, accuracy: 1e-12)
        XCTAssertEqual(DotVitality.amplitude(fraction: 1, effects: expressive), 1, accuracy: 1e-12)
        for effects in [EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false),
                        EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false)] {
            XCTAssertEqual(DotVitality.amplitude(fraction: 0.6, effects: effects), 0)
            XCTAssertFalse(DotVitality.runs(visible: true, enabled: true, available: true, rpm: 2900, maximumRPM: 4900, effects: effects))
        }
    }

    func testRunsOnlyWhenShownEnabledFreshAndTurning() {
        XCTAssertTrue(DotVitality.runs(visible: true, enabled: true, available: true, rpm: 2900, maximumRPM: 4900, effects: expressive))
        XCTAssertTrue(DotVitality.runs(visible: true, enabled: true, available: true, rpm: 2900, maximumRPM: 4900, effects: subtle))
        XCTAssertFalse(DotVitality.runs(visible: false, enabled: true, available: true, rpm: 2900, maximumRPM: 4900, effects: expressive), "Hidden or Settings")
        XCTAssertFalse(DotVitality.runs(visible: true, enabled: false, available: true, rpm: 2900, maximumRPM: 4900, effects: expressive))
        XCTAssertFalse(DotVitality.runs(visible: true, enabled: true, available: false, rpm: 2900, maximumRPM: 4900, effects: expressive), "Stale")
        XCTAssertFalse(DotVitality.runs(visible: true, enabled: true, available: true, rpm: 0, maximumRPM: 4900, effects: expressive), "Stopped")
    }

    /// Jitter between samples does not re-time the wave; a real change does.
    func testRetimesOnlyForARealChangeOfPace() {
        XCTAssertFalse(DotVitality.needsRetime(current: 60, target: 61))
        XCTAssertTrue(DotVitality.needsRetime(current: 60, target: 70))
        XCTAssertTrue(DotVitality.needsRetime(current: 0, target: 30))
        XCTAssertFalse(DotVitality.needsRetime(current: 0, target: 0))
    }
}

final class SmartTargetOnTrendTests: XCTestCase {
    /// The trend always shows the target; without one the scale is exactly
    /// the original.
    func testScaleIncludesTheTargetAndIsUnchangedWithout() {
        let samples = [55.0, 58, 61]
        let plain = TrendScale.range(samples: samples, target: nil)
        XCTAssertEqual(plain.low, 52); XCTAssertEqual(plain.high, 64)
        let withTarget = TrendScale.range(samples: samples, target: 80)
        XCTAssertEqual(withTarget.low, 52); XCTAssertEqual(withTarget.high, 83)
        XCTAssertEqual(TrendScale.range(samples: [], target: nil).low, 27, "Empty history keeps the original default")
        XCTAssertEqual(TrendScale.y(80, range: withTarget, minY: 4, height: 38), 4 + 38 * (28.0 / 31), accuracy: 1e-9)
        XCTAssertEqual(TrendScale.y(200, range: withTarget, minY: 4, height: 38), 42, "Clamped to the plot")
    }

    /// Fixed mapping: four points of travel per whole degree, from the value
    /// at the grab, clamped to 60–95 °C (140–203 °F).
    func testScrubMapsTravelToWholeDegreesWithAFixedGain() {
        let scrub = SmartTargetScrub(celsius: 80, fahrenheit: false)
        XCTAssertEqual(scrub.display(travel: 0), 80)
        XCTAssertEqual(scrub.display(travel: 4), 81)
        XCTAssertEqual(scrub.display(travel: 5.9), 81)
        XCTAssertEqual(scrub.display(travel: -16), 76)
        XCTAssertEqual(scrub.display(travel: 400), 95, "Clamped high")
        XCTAssertEqual(scrub.display(travel: -400), 60, "Clamped low")
        XCTAssertEqual(scrub.display(travel: .nan), 80)
        XCTAssertEqual(scrub.celsius(travel: 8), 82)
        // The same travel always maps the same way: no feedback from the chart.
        XCTAssertEqual(scrub.display(travel: 12), scrub.display(travel: 12))
    }

    func testFahrenheitStepsAreWholeFahrenheitDegrees() {
        let scrub = SmartTargetScrub(celsius: 80, fahrenheit: true)
        XCTAssertEqual(scrub.start, 176)
        XCTAssertEqual(scrub.display(travel: 4), 177)
        XCTAssertEqual(scrub.celsius(travel: 4), (177 - 32) / 1.8, accuracy: 1e-9)
        XCTAssertEqual(scrub.display(travel: 4000), 203); XCTAssertEqual(scrub.display(travel: -4000), 140)
        XCTAssertEqual(SmartTargetScrub.stepped(80, by: 1, fahrenheit: true), (177 - 32) / 1.8, accuracy: 1e-9)
    }

    func testKeyAndVoiceOverStepsClamp() {
        XCTAssertEqual(SmartTargetScrub.stepped(80, by: 1, fahrenheit: false), 81)
        XCTAssertEqual(SmartTargetScrub.stepped(80, by: -5, fahrenheit: false), 75)
        XCTAssertEqual(SmartTargetScrub.stepped(95, by: 1, fahrenheit: false), 95)
        XCTAssertEqual(SmartTargetScrub.stepped(60, by: -5, fahrenheit: false), 60)
    }

    func testBracketKeysMoveTheTarget() {
        func resolve(_ key: String) -> QuickAction? {
            QuickAction.resolve(characters: key, keyCode: 0, command: false, option: false, control: false, presetCount: 3)
        }
        XCTAssertEqual(resolve("["), .smartTarget(-1)); XCTAssertEqual(resolve("]"), .smartTarget(1))
        XCTAssertEqual(resolve("{"), .smartTarget(-5)); XCTAssertEqual(resolve("}"), .smartTarget(5))
        XCTAssertNil(QuickAction.resolve(characters: "]", keyCode: 0, command: true, option: false, control: false, presetCount: 3))
        XCTAssertEqual(resolve("a"), .automatic, "Existing keys are unchanged")
    }
}

final class OnboardingTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "aervane.onboarding.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A first launch starts at the welcome and opens the panel once; an
    /// existing user (saved preferences or a registered helper) never sees
    /// the introduction by itself.
    func testFirstLaunchVersusExistingUsers() {
        let fresh = defaults()
        let flow = OnboardingFlow(store: OnboardingStore(defaults: fresh), helperRegistered: false)
        XCTAssertEqual(flow.state.stage, .welcome)
        XCTAssertTrue(flow.shouldShowOnLaunch)
        flow.didShowOnLaunch()
        XCTAssertFalse(OnboardingFlow(store: OnboardingStore(defaults: fresh), helperRegistered: false).shouldShowOnLaunch, "Only ever once")

        let returning = defaults(); returning.set(76.0, forKey: "smartTargetCelsius")
        let old = OnboardingFlow(store: OnboardingStore(defaults: returning), helperRegistered: false)
        XCTAssertEqual(old.state.stage, .finished); XCTAssertFalse(old.shouldShowOnLaunch)

        let presentation = defaults(); presentation.set("channel", forKey: PresentationPreferences.Key.sliderStyle)
        XCTAssertFalse(OnboardingFlow(store: OnboardingStore(defaults: presentation), helperRegistered: false).shouldShowOnLaunch)

        let helper = OnboardingFlow(store: OnboardingStore(defaults: defaults()), helperRegistered: true)
        XCTAssertEqual(helper.state, Onboarding(stage: .finished, choice: .control))
        XCTAssertFalse(helper.shouldShowOnLaunch)
    }

    /// Control: preview, then only an explicit setup leads to approval;
    /// "Connected" only once the helper is ready; Done finishes.
    func testControlPathNeedsExplicitSetupAndARealConnection() {
        var state = Onboarding()
        XCTAssertEqual(state.section(fanAvailable: true), .welcome)
        state.handle(.chooseControl)
        XCTAssertEqual(state.stage, .preview); XCTAssertEqual(state.section(fanAvailable: true), .fan)
        XCTAssertEqual(state.card(helperReady: false, fanAvailable: true), .none, "A preview is not setup")
        state.handle(.setupRequested)
        XCTAssertEqual(state.card(helperReady: false, fanAvailable: true), .approval)
        XCTAssertEqual(state.card(helperReady: true, fanAvailable: true), .connected, "Connected only when the helper answered")
        state.handle(.panelClosed)
        XCTAssertEqual(state.stage, .approval, "Waiting for approval survives closing the panel")
        state.handle(.helperConnected)
        XCTAssertEqual(state.stage, .connected)
        state.handle(.finish)
        XCTAssertEqual(state.stage, .finished); XCTAssertEqual(state.card(helperReady: true, fanAvailable: true), .none)
    }

    /// Temperature only is remembered; Settings brings the controls back;
    /// the welcome can be replayed.
    func testTemperatureOnlyIsRememberedAndReversible() {
        let store = OnboardingStore(defaults: defaults())
        let flow = OnboardingFlow(store: store, helperRegistered: false)
        flow.handle(.chooseTemperatureOnly)
        XCTAssertEqual(flow.state.section(fanAvailable: true), .temperatureOnly)
        let reloaded = OnboardingFlow(store: store, helperRegistered: false)
        XCTAssertEqual(reloaded.state, Onboarding(stage: .finished, choice: .temperatureOnly), "Remembered across launches")
        reloaded.handle(.fanControls(true))
        XCTAssertEqual(reloaded.state.section(fanAvailable: true), .fan)
        reloaded.handle(.replay)
        XCTAssertEqual(reloaded.state.section(fanAvailable: true), .welcome)
        reloaded.handle(.panelClosed)
        XCTAssertEqual(reloaded.state.stage, .finished, "Closing never makes the introduction insist")
    }

    /// No fan: temperature only, nothing to choose or set up.
    func testNoFanMeansTemperatureOnlyAndNoSetup() {
        for stage in Onboarding.Stage.allCases {
            let state = Onboarding(stage: stage, choice: .control)
            XCTAssertEqual(state.section(fanAvailable: false), .temperatureOnly)
            XCTAssertEqual(state.card(helperReady: false, fanAvailable: false), .none)
        }
    }

    /// Closing the welcome finishes it without a choice, so the ordinary
    /// panel (with its Set Up button) shows next time.
    func testClosingTheWelcomeDefersWithoutChoosing() {
        var state = Onboarding()
        state.handle(.panelClosed)
        XCTAssertEqual(state, Onboarding(stage: .finished, choice: .undecided))
        XCTAssertEqual(state.section(fanAvailable: true), .fan)
    }
}

final class OnboardingRecoveryTests: XCTestCase {
    func testFailedSetupCanBeRetried() {
        var flow = Onboarding(stage: .preview, choice: .control)
        flow.handle(.setupRequested)
        flow.handle(.setupFailed)
        XCTAssertEqual(flow.stage, .preview)
        XCTAssertEqual(flow.card(helperReady: false, fanAvailable: true), .none)
        flow.handle(.setupRequested)
        XCTAssertEqual(flow.card(helperReady: false, fanAvailable: true), .approval)
    }
    func testDisconnectedHelperNeverShowsConnectedCard() {
        var flow = Onboarding(stage: .connected, choice: .control)
        XCTAssertEqual(flow.card(helperReady: false, fanAvailable: true), .none)
        flow.handle(.setupRequested)
        XCTAssertEqual(flow.stage, .approval)
        XCTAssertEqual(flow.card(helperReady: false, fanAvailable: true), .approval)
    }
}
