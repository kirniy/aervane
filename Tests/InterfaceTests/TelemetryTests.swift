import XCTest
import ZephyrCore
@testable import Zephyr

extension FanInventory {
    /// One automatic fan with supported uppercase control.
    static func single(current: Double, minimum: Double, maximum: Double) -> FanInventory {
        FanInventory(fans: [FanReading(index: 0, currentRPM: current, minimumRPM: minimum, maximumRPM: maximum, targetRPM: nil, mode: .automatic)],
                     control: .supported(.uppercase))
    }
}

final class TelemetryTests: XCTestCase {
    enum Failure: Error { case missingFan, missingCPU, missingGPU }
    private func reader(cpuFails: Bool = false, fanFails: Bool = false, gpu: Double? = nil) -> TelemetryReader {
        TelemetryReader(cpu: { if cpuFails { throw Failure.missingCPU }; return (68, 74) }, fan: {
            if fanFails { throw Failure.missingFan }
            return .single(current: 2000, minimum: 1000, maximum: 4900)
        }, gpu: { guard let gpu else { throw Failure.missingGPU }; return gpu })
    }
    private func model(smart: Bool = false) -> AppModel {
        let name = "Aervane.TelemetryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(smart, forKey: "smartCooling")
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppModel(reader: reader(), defaults: defaults, startsServices: false)
    }
    func testMissingFanKeepsThermometerAndDisablesControl() {
        let model = model()
        model.acceptTelemetry(reader().read(wantsGPU: false), sensor: "CPU")
        XCTAssertFalse(model.stale)
        model.acceptTelemetry(reader(fanFails: true).read(wantsGPU: false), sensor: "CPU")
        XCTAssertEqual(model.temperatureText, "68")
        XCTAssertEqual(model.panelReadout.celsius, 68)
        XCTAssertFalse(model.temperatureStale)
        XCTAssertNil(model.sample)
        XCTAssertTrue(model.stale)
        XCTAssertFalse(model.fanAvailable)
        XCTAssertNotNil(model.fanReadError)
        XCTAssertNil(model.error, "A missing fan must not label good temperature data as broken")
        XCTAssertEqual(model.history, [68, 68])
        model.setPercent(76)
        XCTAssertNil(model.pendingPercent, "A missing fan cannot accept a control preview")
    }
    func testFanRecoversWithoutLosingTemperature() {
        let model = model()
        model.acceptTelemetry(reader(fanFails: true).read(wantsGPU: false), sensor: "CPU")
        model.acceptTelemetry(reader().read(wantsGPU: false), sensor: "CPU")
        XCTAssertTrue(model.fanAvailable)
        XCTAssertNil(model.fanReadError)
        XCTAssertFalse(model.stale)
        XCTAssertEqual(model.temperatureText, "68")
    }
    func testCPUFailureStillAttemptsFanButCannotPermitControl() {
        var fanReads = 0
        var source = reader(cpuFails: true)
        source.fan = { fanReads += 1; return .single(current: 2000, minimum: 1000, maximum: 4900) }
        let reading = source.read(wantsGPU: false)
        XCTAssertEqual(fanReads, 1)
        let model = model()
        model.acceptTelemetry(reading, sensor: "CPU")
        XCTAssertTrue(model.fanAvailable)
        XCTAssertTrue(model.temperatureStale)
        XCTAssertTrue(model.stale)
        XCTAssertEqual(model.temperatureText, "—")
        XCTAssertNotNil(model.error)
    }
    func testMissingFanEndsSmartAndKeepsFreshTemperature() {
        let model = model(smart: true)
        XCTAssertTrue(model.smartEnabled)
        model.acceptTelemetry(reader(fanFails: true).read(wantsGPU: false), sensor: "CPU")
        XCTAssertFalse(model.smartEnabled)
        XCTAssertEqual(model.panelReadout.celsius, 68)
        XCTAssertNotNil(model.smartNotice)
    }
    func testOwnedFanFailureTakesExistingRestorePath() {
        let model = model()
        model.ownsControl = true
        model.acceptTelemetry(reader(fanFails: true).read(wantsGPU: false), sensor: "CPU")
        // With no helper the existing restore path relinquishes the local
        // lease. Real XPC restoration is covered separately, not claimed here.
        XCTAssertFalse(model.ownsControl)
        XCTAssertEqual(model.temperatureText, "68")
    }
    func testOptionalGPUAndIndependentFreshness() {
        let model = model()
        let old = Date().addingTimeInterval(-20)
        model.acceptTelemetry(reader(fanFails: true, gpu: 79).read(wantsGPU: true, at: old), sensor: "Warmer")
        XCTAssertEqual(model.displayTemperature, 79)
        XCTAssertEqual(model.temperatureText, "—")
        model.acceptTelemetry(reader(fanFails: true, gpu: 79).read(wantsGPU: true), sensor: "Warmer")
        XCTAssertEqual(model.temperatureText, "79")
        model.acceptTelemetry(reader(fanFails: true).read(wantsGPU: true), sensor: "GPU")
        XCTAssertNil(model.displayTemperature)
        XCTAssertEqual(model.temperatureText, "—")
        XCTAssertNotNil(model.error)
    }
    func testMenuBarAndPanelShareSmartReadoutAndUnit() {
        let model = model(smart: true)
        model.acceptTelemetry(reader().read(wantsGPU: false), sensor: "CPU")
        XCTAssertEqual(model.displayTemperature, 68)
        // Smart can evaluate telemetry without permission to command hardware.
        // Both surfaces must show its peak, never substitute the average.
        XCTAssertEqual(model.temperatureText, "74")
        XCTAssertEqual(model.temperatureText, model.panelReadout.text(fahrenheit: false))
        model.fahrenheit = true
        XCTAssertEqual(model.temperatureText, model.panelReadout.text(fahrenheit: true))
        model.chooseAutomatic()
        XCTAssertFalse(model.smartEnabled)
        XCTAssertEqual(model.temperatureText, "154")
        XCTAssertEqual(model.temperatureText, model.panelReadout.text(fahrenheit: true))
    }
    func testMenuBarAndPanelBothHideStaleReadings() {
        let model = model()
        model.acceptTelemetry(reader().read(wantsGPU: false, at: Date().addingTimeInterval(-20)), sensor: "CPU")
        XCTAssertEqual(model.temperatureText, "—")
        XCTAssertEqual(model.temperatureText, model.panelReadout.text(fahrenheit: false))
    }
    func testFanlessMacIsMonitoringOnlyWithoutAnError() {
        var source = reader()
        source.fan = { FanInventory(fans: [], control: .unavailable(.noFans)) }
        let model = model(smart: true)
        model.acceptTelemetry(source.read(wantsGPU: false), sensor: "CPU")
        XCTAssertEqual(model.temperatureText, "68")
        XCTAssertFalse(model.fanAvailable); XCTAssertNil(model.fanReadError)
        XCTAssertFalse(model.hasDetectedFan); XCTAssertFalse(model.offersFanControls)
        XCTAssertNil(model.sample); XCTAssertNil(model.error)
        XCTAssertFalse(model.smartEnabled); XCTAssertNil(model.smartNotice, "no fault is reported for a Mac without fans")
    }
    func testTransientFanFailureAfterDetectionKeepsFanControlsVisible() {
        let model = model()
        model.acceptTelemetry(reader().read(wantsGPU: false), sensor: "CPU")
        model.acceptTelemetry(reader(fanFails: true).read(wantsGPU: false), sensor: "CPU")
        XCTAssertTrue(model.hasDetectedFan); XCTAssertTrue(model.offersFanControls)
        XCTAssertFalse(model.fanAvailable); XCTAssertNotNil(model.fanReadError)
    }
    func testTwoFansUseTheLowestFloorAndHonestAggregate() {
        var source = reader()
        source.fan = {
            FanInventory(fans: [FanReading(index: 0, currentRPM: 1500, minimumRPM: 1200, maximumRPM: 5000, targetRPM: nil, mode: .automatic),
                                FanReading(index: 1, currentRPM: 2500, minimumRPM: 2000, maximumRPM: 6000, targetRPM: nil, mode: .automatic)],
                         control: .supported(.uppercase))
        }
        let model = model()
        model.acceptTelemetry(source.read(wantsGPU: false), sensor: "CPU")
        XCTAssertEqual(model.minimumPercent, 24)
        XCTAssertEqual(model.actualPercent, 4000.0 / 11000 * 100, accuracy: 0.001)
        XCTAssertEqual(model.sample?.fans.map(\.currentRPM), [1500, 2500])
    }
    func testUnsupportedControlPathIsExplainedAndNeverCommanded() {
        var source = reader()
        source.fan = {
            FanInventory(fans: [FanReading(index: 0, currentRPM: 2000, minimumRPM: 1000, maximumRPM: 4900, targetRPM: nil, mode: .automatic)],
                         control: .unavailable(.requiresFtst, "Ftst missing"))
        }
        let model = model()
        model.acceptTelemetry(source.read(wantsGPU: false), sensor: "CPU")
        XCTAssertTrue(model.fanAvailable)
        XCTAssertNotNil(model.fanControlUnavailable)
        model.setPercent(80)
        XCTAssertNil(model.pendingPercent)
        XCTAssertEqual(model.error, model.fanControlUnavailable)
        model.setSmartCooling(true)
        XCTAssertFalse(model.smartEnabled)
    }
    func testUnrequestedGPUIsNotRead() {
        var source = reader()
        source.gpu = { XCTFail("Unrequested optional GPU should not be read"); return 90 }
        XCTAssertNil(source.read(wantsGPU: false).gpu)
    }
    func testFailedGPUBlocksSmartWithoutLosingCPUMonitoringOrFanSnapshot() {
        let reading = reader().read(wantsGPU: true)
        XCTAssertNotNil(reading.gpuFailure)
        XCTAssertNil(reading.smartReading)
        XCTAssertNotNil(reading.snapshot)
        XCTAssertEqual(reading.temperature(sensor: "CPU"), 68)
        let model = model(smart: true)
        model.acceptTelemetry(reading, sensor: "CPU")
        XCTAssertFalse(model.smartEnabled)
        XCTAssertEqual(model.temperatureText, "68")
    }

    func testAbsentGPUSensorsStillAllowCPUDrivenSmart() {
        var source = reader()
        source.gpu = { throw TemperatureSensors.Failure.unavailable(.gpu) }
        let reading = source.read(wantsGPU: true)
        XCTAssertNil(reading.gpuFailure)
        XCTAssertNotNil(reading.smartReading)
        XCTAssertEqual(reading.smartReading?.cpuHottest, 74)
    }

}
