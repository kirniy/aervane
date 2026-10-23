import XCTest
@testable import ZephyrCore

/// Fan inventory and control-path resolution over fake registers.
final class FanInventoryTests: XCTestCase {
    private func reader(_ smc: FakeSMC, model: String? = nil, platform: SMCPlatform? = nil) -> FanInventoryReader {
        FanInventoryReader(smc: smc, model: model.map(MacModel.init(identifier:)), platform: platform)
    }

    func testZeroFansIsMonitoringNotAnError() throws {
        let smc = FakeSMC(); smc.setFanCount(0)
        let inventory = try reader(smc).read()
        XCTAssertTrue(inventory.isEmpty)
        XCTAssertEqual(inventory.control.blocker, .noFans)
        XCTAssertFalse(inventory.control.isSupported)
    }

    func testMissingFNumMeansNoFansOnlyWithoutFanRegisters() throws {
        let fanless = FakeSMC()
        XCTAssertTrue(try reader(fanless, model: "MacBookAir10,1").read().isEmpty)
        let inconsistent = FakeSMC(); inconsistent.addFan(0, minimum: 1000, maximum: 5000)
        XCTAssertThrowsError(try reader(inconsistent).read())
        let busy = FakeSMC(); busy.transient.insert("FNum")
        XCTAssertThrowsError(try reader(busy).read(), "a failed FNum read is not zero fans")
    }

    func testFanCountIsValidated() {
        let smc = FakeSMC(); smc.setFanCount(11)
        XCTAssertThrowsError(try reader(smc).read())
        smc.set(SMCValue(key: "FNum", dataType: .ui16, bytes: [0, 1]))
        XCTAssertThrowsError(try reader(smc).read())
    }

    func testOneFanMac16_10() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 4900)])
        let inventory = try reader(smc, model: "Mac16,10").read()
        XCTAssertEqual(inventory.fans.count, 1)
        XCTAssertEqual(inventory.control, .supported(.uppercase))
        XCTAssertEqual(inventory.fans[0].mode, .automatic)
        XCTAssertNil(inventory.fans[0].targetRPM, "automatic mode hides the firmware target")
    }

    func testTwoAsymmetricFansKeepActualReadingsAndAnHonestAggregate() throws {
        let smc = FakeSMC(); smc.setFanCount(2)
        // A linked 30%: fan 0 at 30% of its maximum, fan 1 held at its own floor (33.3%).
        smc.addFan(0, minimum: 1200, maximum: 5000, actual: 1500, target: 1500, mode: 1)
        smc.addFan(1, minimum: 2000, maximum: 6000, actual: 2100, target: 2000, mode: 1, fpe2: true)
        let inventory = try reader(smc).read()
        XCTAssertEqual(inventory.fans.map(\.currentRPM), [1500, 2100])
        let snapshot = inventory.snapshot(temperatureCelsius: 60)
        XCTAssertTrue(snapshot.isConsistent)
        XCTAssertEqual(snapshot.fanCount, 2)
        XCTAssertEqual(snapshot.currentRPM, 1800); XCTAssertEqual(snapshot.maximumRPM, 5500)
        XCTAssertEqual(snapshot.floorPercent, 24, accuracy: 0.001, "the lowest per-fan floor")
        XCTAssertEqual(snapshot.targetPercent ?? -1, 30, accuracy: 0.001)
        XCTAssertFalse(snapshot.automatic)
    }

    func testUnlinkedManualTargetsReportTheirMean() {
        let fans = [FanReading(index: 0, currentRPM: 2000, minimumRPM: 1000, maximumRPM: 5000, targetRPM: 2000, mode: .manual),
                    FanReading(index: 1, currentRPM: 4000, minimumRPM: 1000, maximumRPM: 5000, targetRPM: 4000, mode: .manual)]
        XCTAssertEqual(FanSnapshot(fans: fans, temperatureCelsius: 50, control: nil).targetPercent ?? -1, 60, accuracy: 0.001)
        let mixed = [fans[0], FanReading(index: 1, currentRPM: 1500, minimumRPM: 1000, maximumRPM: 5000, targetRPM: nil, mode: .automatic)]
        let snapshot = FanSnapshot(fans: mixed, temperatureCelsius: 50, control: nil)
        XCTAssertNil(snapshot.targetPercent); XCTAssertFalse(snapshot.automatic)
    }

    func testSixFans() throws {
        let limits: [(minimum: Double, maximum: Double)] = [
            (800, 2500), (900, 2800), (1000, 3100),
            (1100, 3400), (1200, 3700), (1300, 4000)
        ]
        let smc = FakeSMC.obedient(fans: limits)
        let inventory = try reader(smc).read()
        XCTAssertEqual(inventory.fans.map(\.index), Array(0..<6))
        XCTAssertEqual(inventory.fans.map(\.maximumRPM), [2500, 2800, 3100, 3400, 3700, 4000])
    }

    func testAnyMissingOrCorruptFanRegisterFailsTheWholeRead() {
        let cases: [(FakeSMC) -> Void] = [
            { $0.remove("F1Mx") },
            { $0.set(FakeSMC.flt("F0Ac", .nan)) },
            { $0.set(SMCValue(key: "F1Ac", dataType: .fpe2, bytes: [1, 2, 3])) },
            { $0.set(FakeSMC.flt("F1Mx", 0)) },
            { $0.set(FakeSMC.flt("F0Mn", 6000)) },
            { $0.set(FakeSMC.flt("F0Mx", 1e9)) },
            { $0.set(SMCValue(key: "F1Md", dataType: .flt, bytes: [0, 0, 0, 0])) },
            { $0.transient.insert("F1Ac") },
        ]
        for (number, corrupt) in cases.enumerated() {
            let smc = FakeSMC.obedient(fans: [(1000, 5000), (1200, 6000)])
            let inventory = reader(smc)
            XCTAssertEqual(try inventory.read().fans.count, 2)
            corrupt(smc)
            XCTAssertThrowsError(try inventory.read(), "case \(number)")
        }
    }

    func testManualTargetAboveMaximumIsInvalid() {
        let smc = FakeSMC(); smc.setFanCount(1)
        smc.addFan(0, minimum: 1000, maximum: 5000, target: 5200, mode: 1)
        XCTAssertThrowsError(try reader(smc).read())
    }

    func testUnknownModeValueIsReportedNotGuessed() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000)])
        smc.set(SMCEncoder.uint8(2, key: "F0Md"))
        let fan = try reader(smc).read().fans[0]
        XCTAssertEqual(fan.mode, .unknown)
        XCTAssertFalse(FanSnapshot(fans: [fan], temperatureCelsius: 50, control: nil).automatic)
    }

    func testLowercaseModeKeysAreFoundByCapability() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)], scheme: .lowercase)
        let inventory = try reader(smc).read()
        XCTAssertEqual(inventory.control, .supported(.lowercase))
        smc.set(SMCEncoder.uint8(1, key: "F1md")); smc.set(FakeSMC.flt("F1Tg", 3000))
        XCTAssertEqual(try reader(smc).read().fans.map(\.mode), [.automatic, .manual])
    }

    func testModelThatRequiresLowercaseRejectsUppercaseOnlyHardware() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000)])
        let status = try reader(smc, model: "Mac16,9").read().control       // MacStudio3,1
        XCTAssertEqual(status.blocker, .missingModeKey); XCTAssertEqual(status.detail, "F0md")
        let lower = FakeSMC.obedient(fans: [(1000, 5000)], scheme: .lowercase)
        lower.set(SMCEncoder.uint8(0, key: "F0Md"))   // both spellings: the model's own is used
        XCTAssertEqual(try reader(lower, model: "Mac16,9").read().control, .supported(.lowercase))
    }

    func testFtstModelsAreControlledThroughAValidatedGate() throws {
        let smc = FakeSMC.obedient(fans: [(1200, 5700), (1200, 6400)], scheme: .lowercase)
        smc.set(SMCEncoder.uint8(1, key: "F1md")); smc.set(FakeSMC.flt("F1Tg", 6400))
        // MacBookPro22,1: lowercase keys plus Ftst. Without the gate register: monitoring only.
        let missing = try reader(smc, model: "Mac17,2").read()
        XCTAssertEqual(missing.control.blocker, .requiresFtst)
        XCTAssertEqual(missing.control.detail, "Ftst missing")
        XCTAssertEqual(missing.fans.map(\.mode), [.automatic, .manual], "another controller's manual fan stays visible")
        // A one-byte ui8 or flag gate makes the path supported, with the gate.
        for type in [FourCC.ui8, .flag] {
            smc.set(SMCValue(key: "Ftst", dataType: type, bytes: [0]))
            let inventory = try reader(smc, model: "Mac17,2").read()
            XCTAssertEqual(inventory.control, .supported(.lowercase, ftst: true))
        }
        // Any other type, length or value is never written.
        for bad in [SMCValue(key: "Ftst", dataType: .ui16, bytes: [0, 0]), SMCValue(key: "Ftst", dataType: .ui8, bytes: [7]),
                    SMCValue(key: "Ftst", dataType: .flt, bytes: [0, 0, 0, 0])] {
            smc.set(bad)
            XCTAssertEqual(try reader(smc, model: "Mac17,2").read().control.blocker, .requiresFtst)
        }
        // Models outside the predicate never touch Ftst.
        smc.clearLog()
        XCTAssertEqual(try reader(smc, model: "Mac16,9").read().control, .supported(.lowercase))
        XCTAssertFalse(smc.reads.contains("Ftst"))
    }

    func testIntelPrefersAValidFSMaskEvenWithPerFanKeys() throws {
        let smc = FakeSMC.obedient(fans: [(1300, 6000), (1200, 5500)], scheme: .legacyMask, fpe2: [0, 1])
        smc.setMask(0b1000_0000_0000_0110)   // fan 1 manual; bits 2 and 15 belong to something else
        smc.set(FakeSMC.fpe2("F1Tg", 3000))
        smc.set(SMCEncoder.uint8(0, key: "F0Md")); smc.set(SMCEncoder.uint8(0, key: "F1Md"))
        let intel = try reader(smc, model: "MacBookPro16,1", platform: .intel).read()
        XCTAssertEqual(intel.control, .supported(.legacyMask), "FS! wins on Intel even when F<n>Md exist")
        XCTAssertEqual(intel.fans.map(\.mode), [.automatic, .manual])
        XCTAssertEqual(intel.fans[1].targetRPM, 3000)
        // Without a valid aggregate, Intel uses validated per-fan keys.
        smc.set(SMCValue(key: "FS! ", dataType: .ui8, bytes: [0]))
        XCTAssertEqual(try reader(smc, model: "MacBookPro16,1", platform: .intel).read().control, .supported(.uppercase))
        smc.remove("FS! ")
        XCTAssertEqual(try reader(smc, platform: .intel).read().control, .supported(.uppercase))
        // Apple Silicon keeps per-fan keys first; FS! only without them.
        smc.setMask(0)
        XCTAssertEqual(try reader(smc, platform: .appleSilicon).read().control, .supported(.uppercase))
        smc.remove("F0Md"); smc.remove("F1Md")
        XCTAssertEqual(try reader(smc, platform: .appleSilicon).read().control, .supported(.legacyMask))
    }

    func testSelectedStrategyNeverSilentlySwitches() throws {
        let smc = FakeSMC.obedient(fans: [(1300, 6000), (1200, 5500)], scheme: .legacyMask, fpe2: [0, 1])
        let inventory = reader(smc, platform: .intel)
        XCTAssertEqual(try inventory.read().control, .supported(.legacyMask))
        // A later failure of the selected register fails the read; it does not fall back to F<n>Md.
        smc.set(SMCEncoder.uint8(0, key: "F0Md")); smc.set(SMCEncoder.uint8(0, key: "F1Md"))
        smc.transient.insert("FS! ")
        XCTAssertThrowsError(try inventory.read())
        // Even a topology change that re-probes cannot switch strategies.
        smc.transient.removeAll(); smc.remove("FS! "); smc.setFanCount(1)
        XCTAssertThrowsError(try inventory.read())
        let after = try inventory.read()
        XCTAssertEqual(after.control.blocker, .inconsistentModeKeys)
        XCTAssertFalse(after.control.isSupported)
    }

    func testInconsistentOrInvalidModeRegistersBlockControl() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        smc.remove("F1Md")
        let inventory = try reader(smc).read()
        XCTAssertEqual(inventory.control.blocker, .inconsistentModeKeys)
        XCTAssertEqual(inventory.fans.map(\.mode), [.unknown, .unknown])
        let invalid = FakeSMC.obedient(fans: [(1000, 5000)])
        invalid.set(SMCValue(key: "F0Md", dataType: .ui16, bytes: [0, 0]))
        XCTAssertEqual(try reader(invalid).read().control.blocker, .invalidModeRegister)
        let none = FakeSMC.obedient(fans: [(1000, 5000)]); none.remove("F0Md")
        let monitored = try reader(none).read()
        XCTAssertEqual(monitored.control.blocker, .missingModeKey)
        XCTAssertEqual(monitored.fans[0].mode, .automatic, "no mode register at all: firmware control is the only mode")
    }

    func testMissingTargetRegisterBlocksControl() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)]); smc.remove("F1Tg")
        let status = try reader(smc).read().control
        XCTAssertEqual(status.blocker, .invalidTargetRegister); XCTAssertEqual(status.detail, "F1Tg missing")
    }

    func testTransientModeProbeIsNotCachedAsUnsupported() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000)]); smc.transient.insert("F0Md")
        let inventory = reader(smc)
        XCTAssertThrowsError(try inventory.read())
        smc.transient.removeAll()
        XCTAssertEqual(try inventory.read().control, .supported(.uppercase))
    }

    func testFanCountChangesNeedConfirmationAndFailuresNeverShrinkTheInventory() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1200, 6000)])
        let inventory = reader(smc)
        XCTAssertEqual(try inventory.read().fans.count, 2)
        smc.transient.insert("F1Ac")
        XCTAssertThrowsError(try inventory.read())
        smc.transient.removeAll()
        smc.setFanCount(1)
        XCTAssertThrowsError(try inventory.read()) {
            XCTAssertEqual($0 as? FanInventoryError, .topologyUnconfirmed(previous: 2, reported: 1))
        }
        XCTAssertEqual(try inventory.read().fans.count, 1, "a repeated, valid count is accepted")
        smc.setFanCount(2)
        XCTAssertThrowsError(try inventory.read())
        XCTAssertEqual(try inventory.read().fans.count, 2)
    }

    func testControlStatusDecodesUnknownValuesAsUndetermined() throws {
        let decoded = try JSONDecoder().decode(FanControlStatus.self, from: Data(#"{"scheme":"F9xx"}"#.utf8))
        XCTAssertFalse(decoded.isSupported); XCTAssertEqual(decoded.blocker, .undetermined)
        let future = try JSONDecoder().decode(FanControlStatus.self, from: Data(#"{"scheme":"Md","blocker":"somethingNew"}"#.utf8))
        XCTAssertFalse(future.isSupported)
        let supported = try JSONDecoder().decode(FanControlStatus.self, from: JSONEncoder().encode(FanControlStatus.supported(.legacyMask)))
        XCTAssertEqual(supported, .supported(.legacyMask))
        XCTAssertEqual(try JSONDecoder().decode([FanModeState].self, from: Data(#"["manual","turbo"]"#.utf8)), [.manual, .unknown])
    }

    func testSnapshotsFromOlderHelpersDecode() throws {
        let old = #"{"fanCount":1,"currentRPM":2000,"minimumRPM":1000,"maximumRPM":5000,"targetPercent":40,"automatic":false,"temperatureCelsius":60,"sampledAt":0}"#
        let one = try JSONDecoder().decode(FanSnapshot.self, from: Data(old.utf8))
        XCTAssertEqual(one.fans.count, 1); XCTAssertEqual(one.fans[0].targetPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertNil(one.control); XCTAssertTrue(one.isConsistent)
        let two = try JSONDecoder().decode(FanSnapshot.self, from: Data(old.replacingOccurrences(of: #""fanCount":1"#, with: #""fanCount":2"#).utf8))
        XCTAssertTrue(two.fans.isEmpty); XCTAssertFalse(two.isConsistent, "aggregate-only multi-fan data never permits control")

        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1200, 6000)])
        let snapshot = try reader(smc).read().snapshot(temperatureCelsius: 55, sampledAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(try JSONDecoder().decode(FanSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testDiagnosticsAreStructuredAndLocal() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 4900)])
        for key in ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te09", "Te0H", "Te0S", "Te0U", "Te0V", "Tg04", "Tg12"] { smc.temperature(key, 50) }
        let model = MacModel(identifier: "Mac16,10")
        let report = HardwareDiagnostics.collect(model: model, platform: .appleSilicon,
                                                 inventory: FanInventoryReader(smc: smc, model: model),
                                                 sensors: TemperatureSensors(smc: smc, model: model, platform: .appleSilicon))
        XCTAssertEqual(report.catalogModel, "Macmini11,1")
        XCTAssertEqual(report.fans?.first?.label, "Exhaust")
        XCTAssertEqual(report.control, .supported(.uppercase))
        XCTAssertEqual(report.cpu?.keys.count, 10); XCTAssertEqual(report.gpu?.keys, ["Tg04", "Tg12"])
        XCTAssertNil(report.cpuError)
        let decoded = try JSONDecoder().decode(HardwareDiagnostics.self, from: Data(report.json().utf8))
        XCTAssertEqual(decoded, report)
    }
}
