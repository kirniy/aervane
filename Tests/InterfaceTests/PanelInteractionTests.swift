import XCTest
import ZephyrCore
@testable import Zephyr

final class QuickActionTests: XCTestCase {
    private func resolve(_ characters: String?, keyCode: UInt16 = 0, command: Bool = false, option: Bool = false, control: Bool = false, presets: Int = 3) -> QuickAction? {
        QuickAction.resolve(characters: characters, keyCode: keyCode, command: command, option: option, control: control, presetCount: presets)
    }

    func testDigitsApplyOnlyExistingPresets() {
        XCTAssertEqual(resolve("1", keyCode: 18), .preset(0))
        XCTAssertEqual(resolve("3", keyCode: 20), .preset(2))
        XCTAssertNil(resolve("4", keyCode: 21), "No fourth preset: the key does nothing")
        XCTAssertEqual(resolve("6", keyCode: 22, presets: 6), .preset(5))
        XCTAssertNil(resolve("7", keyCode: 26, presets: 6))
        XCTAssertNil(resolve("0", keyCode: 29))
        XCTAssertNil(resolve("1", keyCode: 18, presets: 0))
    }

    /// AZERTY needs Shift for digits; the unshifted top-row key still means
    /// its position, and the keypad works everywhere.
    func testPresetKeysWorkByPositionOnOtherLayouts() {
        XCTAssertEqual(resolve("&", keyCode: 18), .preset(0))
        XCTAssertEqual(resolve("é", keyCode: 19), .preset(1))
        XCTAssertEqual(resolve("2", keyCode: 84), .preset(1))
    }

    func testLettersAndSettings() {
        XCTAssertEqual(resolve("a"), .automatic)
        XCTAssertEqual(resolve("A"), .automatic)
        XCTAssertEqual(resolve("m"), .manual)
        XCTAssertEqual(resolve("s"), .smart, "Auto · Smart · Manual: A, S, M")
        XCTAssertEqual(resolve("S"), .smart)
        XCTAssertNil(resolve("s", command: true), "⌘S passes through")
        XCTAssertEqual(resolve(",", command: true), .settings)
        XCTAssertNil(resolve(","), "Comma alone is not a shortcut")
        XCTAssertNil(resolve("x"))
    }

    /// System and app shortcuts (⌘Q, ⌘A, ⌥/⌃ combinations) pass through.
    func testModifiedKeysAreNeverCaptured() {
        XCTAssertNil(resolve("a", command: true))
        XCTAssertNil(resolve("q", command: true))
        XCTAssertNil(resolve("1", keyCode: 18, command: true))
        XCTAssertNil(resolve("a", option: true))
        XCTAssertNil(resolve("1", keyCode: 18, control: true))
        XCTAssertNil(resolve(nil))
    }
}

final class PresetDraftTests: XCTestCase {
    private let stored = [FanPreset(name: "Quiet", percent: 30), FanPreset(name: "Balanced", percent: 60), FanPreset(name: "Boost", percent: 100)]

    func testUntouchedDraftSavesExactlyWhatWasStored() {
        let draft = PresetDraft(stored)
        XCTAssertEqual(draft.resolved(minimum: 21), stored)
        XCTAssertFalse(draft.hasChanges(minimum: 21))
    }

    /// Cancel is a true undo: edits live only in the draft.
    func testEditsStayInTheDraftAndKeepIdentity() {
        var draft = PresetDraft(stored)
        draft.rename(0, to: "Night")
        draft.setPercent(1, text: "72 %")
        draft.remove(at: 2)
        XCTAssertTrue(draft.hasChanges(minimum: 21))
        let saved = draft.resolved(minimum: 21)
        XCTAssertEqual(saved.map(\.name), ["Night", "Balanced"])
        XCTAssertEqual(saved.map(\.percent), [30, 72])
        XCTAssertEqual(saved.map(\.id), [stored[0].id, stored[1].id])
    }

    func testSpeedsBelowTheFloorAreRaisedAndInvalidTextIsIgnored() {
        var draft = PresetDraft(stored)
        draft.setPercent(0, text: "10")
        XCTAssertTrue(PresetDraft.isBelowFloor("10", minimum: 21))
        XCTAssertFalse(PresetDraft.isBelowFloor("21", minimum: 20.4), "The floor is whole percent, rounded up")
        XCTAssertFalse(PresetDraft.isBelowFloor("fast", minimum: 21))
        XCTAssertNil(draft.setPercent(1, text: "fast"))
        XCTAssertNil(draft.setPercent(1, text: ""))
        draft.setPercent(2, text: "250")
        XCTAssertEqual(draft.resolved(minimum: 21).map(\.percent), [21, 60, 100])
        XCTAssertEqual(PresetDraft.parsePercent("64.6"), 65)
        XCTAssertNil(PresetDraft.parsePercent("nan"))
    }

    func testArrowStepsStayInsideTheHardwareRange() {
        var draft = PresetDraft(stored)
        XCTAssertEqual(draft.step(0, by: -10, minimum: 21), 21)
        XCTAssertEqual(draft.step(0, by: -1, minimum: 21), 21)
        XCTAssertEqual(draft.step(2, by: 10, minimum: 21), 100)
        XCTAssertEqual(draft.step(1, by: 1, minimum: 21), 61)
        XCTAssertNil(draft.step(9, by: 1, minimum: 21))
    }

    func testNamesAreSingleLineLimitedAndNeverSavedBlank() {
        var draft = PresetDraft(stored)
        XCTAssertEqual(draft.rename(0, to: "An overnight render preset"), "An overnight render ")
        XCTAssertEqual(draft.rename(1, to: "Two\nlines"), "Two lines")
        draft.rename(2, to: "   ")
        XCTAssertEqual(draft.items[2].name, "   ", "Blank is allowed while typing")
        let names = draft.resolved(minimum: 0).map(\.name)
        XCTAssertEqual(names, ["An overnight render", "Two lines", PresetDraft.fallbackName])
        XCTAssertTrue(names.allSatisfy { $0.count <= PresetDraft.nameLimit })
    }

    func testCapacityAndEmptyStates() {
        var draft = PresetDraft([])
        XCTAssertTrue(draft.isEmpty)
        for i in 0..<PresetDraft.capacity { XCTAssertEqual(draft.add(percent: Double(30 + i)), i) }
        XCTAssertTrue(draft.isFull)
        XCTAssertNil(draft.add(percent: 90), "A seventh preset is refused")
        XCTAssertEqual(draft.items.count, 6)
        draft.remove(at: 0); draft.remove(at: 42)
        XCTAssertFalse(draft.isFull)
        XCTAssertEqual(PresetDraft(Array(repeating: FanPreset(name: "X", percent: 50), count: 9)).items.count, 6)
    }
}

final class TrendInspectionTests: XCTestCase {
    func testPointerSnapsToTheNearestSampleAndClampsToThePlot() {
        XCTAssertEqual(TrendInspection.index(x: 3, minX: 3, width: 118, count: 60), 0)
        XCTAssertEqual(TrendInspection.index(x: 121, minX: 3, width: 118, count: 60), 59)
        XCTAssertEqual(TrendInspection.index(x: 62, minX: 3, width: 118, count: 60), 30)
        XCTAssertEqual(TrendInspection.index(x: -40, minX: 3, width: 118, count: 60), 0)
        XCTAssertEqual(TrendInspection.index(x: 500, minX: 3, width: 118, count: 60), 59)
        XCTAssertNil(TrendInspection.index(x: 10, minX: 3, width: 118, count: 0))
        XCTAssertNil(TrendInspection.index(x: .nan, minX: 3, width: 118, count: 5))
        XCTAssertEqual(TrendInspection.index(x: 10, minX: 3, width: 118, count: 1), 0)
    }

    /// The readout is the exact sample (one decimal), unlike the rounded headline.
    func testReadoutAndSummaryUseTheUsersUnit() {
        XCTAssertEqual(TrendInspection.readout(celsius: 72.64, fahrenheit: false), "72.6°")
        XCTAssertEqual(TrendInspection.readout(celsius: 100, fahrenheit: true), "212.0°")
        XCTAssertEqual(TrendInspection.summary([64.2, 78.4, 73.1], fahrenheit: false), "64 to 78 °C, now 73")
        XCTAssertEqual(TrendInspection.summary([40], fahrenheit: true), "104 to 104 °F, now 104")
        XCTAssertNil(TrendInspection.summary([], fahrenheit: false))
    }
}

final class CoolingArtworkRulesTests: XCTestCase {
    func testCrystalsAreConfinedToTheTopOfTheRange() {
        XCTAssertEqual(Frost.crystal(percent: 50), 0)
        XCTAssertEqual(Frost.crystal(percent: Frost.crystalOnset), 0)
        XCTAssertEqual(Frost.crystal(percent: 100), 1)
        XCTAssertEqual(Frost.crystal(percent: .nan), 0)
        let ramp = stride(from: 60.0, through: 100, by: 5).map { Frost.crystal(percent: $0) }
        XCTAssertEqual(ramp, ramp.sorted())
    }

    func testFrostGrainIsRestrained() {
        XCTAssertEqual(Frost.grains(amount: 0, noise: 1), 0)
        XCTAssertEqual(Frost.grains(amount: .nan, noise: 1), 0)
        for amount in stride(from: 0.0, through: 1, by: 0.1) {
            for noise in stride(from: 0.0, through: 1, by: 0.25) {
                XCTAssertLessThanOrEqual(Frost.grains(amount: amount, noise: noise), 4)
            }
        }
        XCTAssertLessThan(Frost.grains(amount: 0.2, noise: 0.5), Frost.grains(amount: 1, noise: 0.5))
    }

    /// Cold air follows the fan, not the request: nothing without a reading.
    func testChillFollowsMeasuredSpeed() {
        XCTAssertEqual(Airflow.chill(measuredPercent: nil), 0)
        XCTAssertEqual(Airflow.chill(measuredPercent: .nan), 0)
        XCTAssertEqual(Airflow.chill(measuredPercent: 100), 1)
        XCTAssertEqual(Airflow.chill(measuredPercent: 140), 1)
        XCTAssertLessThan(Airflow.chill(measuredPercent: 20), 0.15, "Firmware idle speeds stay nearly invisible")
        let ramp = stride(from: 0.0, through: 100, by: 10).map { Airflow.chill(measuredPercent: $0) }
        XCTAssertEqual(ramp, ramp.sorted())
    }
}

/// What the panel's big temperature shows, by mode. These protect sensor
/// semantics: Smart's figure is the measurement Smart regulates, never an
/// average standing in for it.
final class TemperatureReadoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func smart(_ celsius: Double?, _ source: SmartTemperatureSource? = .cpuPeak, age: TimeInterval = 1) -> SmartSample {
        SmartSample(celsius: celsius, source: source, at: now.addingTimeInterval(-age))
    }

    /// The reported case: menu sensor "Warmer" (max of averages) read 68 °C
    /// while Smart's hottest core was 79.5 °C over a 73 °C target. In Smart
    /// the panel shows 80 CPU PEAK; in Auto/Manual it returns to 68 WARMER.
    func testSmartShowsWhatItRegulatesNotTheSelectedAverage() {
        let inSmart = TemperatureReadout.panel(smartEnabled: true, smart: smart(79.5), selectedSensor: "Warmer", selectedCelsius: 68, stale: false, now: now)
        XCTAssertEqual(inSmart.celsius, 79.5)
        XCTAssertEqual(inSmart.text(fahrenheit: false), "80")
        XCTAssertEqual(inSmart.tag, "CPU PEAK")
        XCTAssertEqual(inSmart.series, .smart)
        let inAuto = TemperatureReadout.panel(smartEnabled: false, smart: smart(79.5), selectedSensor: "Warmer", selectedCelsius: 68, stale: false, now: now)
        XCTAssertEqual(inAuto.celsius, 68)
        XCTAssertEqual(inAuto.tag, "WARMER")
        XCTAssertEqual(inAuto.series, .selected)
        XCTAssertTrue(inAuto.detail.contains("averages"))
        XCTAssertEqual(SmartStatusText.chip(atMaximum: true, celsius: inSmart.celsius, target: 73, fahrenheit: false), "Above 73° · max cooling")
    }

    /// Missing, stale or old Smart data is unavailable, never the average.
    func testUnavailableSmartDataIsNotReplacedByAnAverage() {
        for sample in [nil, smart(nil), smart(77, age: 30)] as [SmartSample?] {
            let readout = TemperatureReadout.panel(smartEnabled: true, smart: sample, selectedSensor: "CPU", selectedCelsius: 66, stale: false, now: now)
            XCTAssertNil(readout.celsius)
            XCTAssertEqual(readout.text(fahrenheit: false), "—")
            XCTAssertEqual(readout.series, .smart)
        }
        XCTAssertNil(TemperatureReadout.panel(smartEnabled: true, smart: smart(77), selectedSensor: "CPU", selectedCelsius: 66, stale: true, now: now).celsius)
        XCTAssertNil(TemperatureReadout.panel(smartEnabled: false, smart: nil, selectedSensor: "CPU", selectedCelsius: 66, stale: true, now: now).celsius)
        // An unavailable selected GPU stays unavailable in Auto/Manual.
        let gpu = TemperatureReadout.panel(smartEnabled: false, smart: nil, selectedSensor: "GPU", selectedCelsius: nil, stale: false, now: now)
        XCTAssertNil(gpu.celsius); XCTAssertEqual(gpu.tag, "GPU AVG")
    }

    func testSourcesAndUnits() {
        let gpu = TemperatureReadout.panel(smartEnabled: true, smart: smart(81, .gpu), selectedSensor: "CPU", selectedCelsius: 60, stale: false, now: now)
        XCTAssertEqual(gpu.tag, "GPU")
        let held = TemperatureReadout.panel(smartEnabled: true, smart: smart(81, .gpuHeld), selectedSensor: "CPU", selectedCelsius: 60, stale: false, now: now)
        XCTAssertEqual(held.tag, "GPU HELD")
        XCTAssertTrue(held.detail.contains("Last GPU"))
        XCTAssertEqual(gpu.text(fahrenheit: true), "178")
    }

    /// "Above" only when the figure shown is visibly above the target shown,
    /// in the user's unit, and only at confirmed full speed.
    func testAboveIsConsistentWithWhatIsShown() {
        XCTAssertNil(SmartStatusText.chip(atMaximum: true, celsius: 73.4, target: 73, fahrenheit: false), "Shows 73 beside a 73 target")
        XCTAssertEqual(SmartStatusText.chip(atMaximum: true, celsius: 73.6, target: 73, fahrenheit: false), "Above 73° · max cooling")
        XCTAssertNil(SmartStatusText.chip(atMaximum: false, celsius: 90, target: 73, fahrenheit: false), "Not at confirmed full speed")
        XCTAssertNil(SmartStatusText.chip(atMaximum: true, celsius: nil, target: 73, fahrenheit: false))
        // In °F the comparison is made in °F, as shown: 73.2 °C shows as 164
        // beside a 163 target (visibly above); 72.9 °C shows as 163 (equal).
        XCTAssertEqual(SmartStatusText.chip(atMaximum: true, celsius: 73.2, target: 73, fahrenheit: true), "Above 163° · max cooling")
        XCTAssertNil(SmartStatusText.chip(atMaximum: true, celsius: 72.9, target: 73, fahrenheit: true))
    }

    /// Full speed below the target can reflect anticipation or filtered recent heat, not an exceeded target.
    func testSummaryExplainsRecentHeatAtFullSpeed() {
        let ahead = SmartStatusText.summary(enabled: true, celsius: 71, source: .cpuPeak, request: 100, target: 73, fahrenheit: false)
        XCTAssertTrue(ahead.contains("in response to recent heat"), ahead)
        XCTAssertTrue(ahead.contains("71°C cpu peak"))
        let limit = SmartStatusText.summary(enabled: true, celsius: 80, source: .cpuPeak, request: 100, target: 73, fahrenheit: false)
        XCTAssertFalse(limit.contains("in response to recent heat"))
        XCTAssertTrue(SmartStatusText.summary(enabled: false, celsius: nil, source: nil, request: nil, target: 73, fahrenheit: false).contains("around 73°C"))
        XCTAssertTrue(SmartStatusText.summary(enabled: true, celsius: nil, source: nil, request: nil, target: 73, fahrenheit: false).contains("waiting"))
    }
}
