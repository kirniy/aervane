import XCTest
import ZephyrCore
@testable import Zephyr

final class TelemetryTests: XCTestCase {
    enum Failure: Error { case missingFan, missingCPU, missingGPU }
    private func reader(cpuFails: Bool = false, fanFails: Bool = false, gpu: Double? = nil) -> TelemetryReader {
        TelemetryReader(cpu: { if cpuFails { throw Failure.missingCPU }; return (68, 74) }, fan: {
            if fanFails { throw Failure.missingFan }
            return (2000, 1000, 4900, nil, true)
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
        source.fan = { fanReads += 1; return (2000, 1000, 4900, nil, true) }
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
    func testUnrequestedGPUIsNotRead() {
        var source = reader()
        source.gpu = { XCTFail("Unrequested optional GPU should not be read"); return 90 }
        XCTAssertNil(source.read(wantsGPU: false).gpu)
    }
}
