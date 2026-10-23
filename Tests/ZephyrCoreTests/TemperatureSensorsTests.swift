import XCTest
@testable import ZephyrCore

/// Catalog-driven CPU/GPU discovery. The first five cases carry over the
/// former SMCReader sensor tests with the same expectations.
final class TemperatureSensorsTests: XCTestCase {
    private final class HIDFake: TemperatureSensors.HIDSource, @unchecked Sendable {
        var values: [SensorKind: [Double]] = [:]
        var failures: [SensorKind: Error] = [:]
        func hasSensors(for kind: SensorKind) -> Bool { values[kind] != nil }
        func read(_ kind: SensorKind) throws -> [Double] {
            if let error = failures[kind] { throw error }
            return values[kind] ?? []
        }
    }
    private var clock = Date(timeIntervalSince1970: 1000)
    private func sensors(_ smc: FakeSMC, model: String?, platform: SMCPlatform = .appleSilicon) -> TemperatureSensors {
        TemperatureSensors(smc: smc, model: model.map(MacModel.init(identifier:)), platform: platform, clock: { [unowned self] in self.clock })
    }

    func testMissingPreviouslyDiscoveredHotCoreFailsSafe() throws {
        let smc = FakeSMC(); smc.temperature("Tp01", 65); smc.temperature("Tp05", 91)
        let reader = sensors(smc, model: nil)
        XCTAssertEqual(try reader.readCPU().hottest, 91)
        smc.transient.insert("Tp05")
        XCTAssertThrowsError(try reader.readCPU())
        smc.transient.removeAll(); smc.remove("Tp05")
        XCTAssertThrowsError(try reader.readCPU(), "a vanished core is not dropped after discovery")
        XCTAssertEqual(reader.discovery(.cpu)?.keys, ["Tp01", "Tp05"])
    }

    func testIntelPackageSensorSupportsSafetyMaximum() throws {
        let smc = FakeSMC(); smc.set(FakeSMC.sp78("TC0P", 74))
        let reader = sensors(smc, model: nil, platform: .intel)
        XCTAssertEqual(try reader.readCPU().hottest, 74, accuracy: 0.01)
        XCTAssertEqual(reader.discovery(.cpu)?.keys, ["TC0P"])
    }

    func testMac16_10UsesAllTenMappedCPUSensorsIncludingTe0UAndTe0V() throws {
        let keys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te09", "Te0H", "Te0S", "Te0U", "Te0V"]
        let smc = FakeSMC()
        for (index, key) in keys.enumerated() { smc.temperature(key, Double(60 + index)) }
        smc.temperature("Tm1p", 99)   // memory proximity on this model: never CPU
        let reader = sensors(smc, model: "Mac16,10")
        XCTAssertEqual(reader.plan(.cpu).source, .catalog)
        XCTAssertEqual(reader.plan(.cpu).candidates.map(\.key), keys)
        let cpu = try reader.readCPU()
        XCTAssertEqual(cpu.average, 64.5, accuracy: 0.001); XCTAssertEqual(cpu.hottest, 69, accuracy: 0.001)
    }

    func testMac16_10GPUUsesMappedKeysOnly() throws {
        let smc = FakeSMC(); smc.temperature("Tg04", 70); smc.temperature("Tg12", 74); smc.temperature("Tg0D", 110)
        XCTAssertEqual(try sensors(smc, model: "Mac16,10").readGPU(), 72, accuracy: 0.001)
    }

    func testGPUDiscoveryRecoversAfterTransientReadFailure() throws {
        let smc = FakeSMC(); smc.temperature("Tg04", 70); smc.transient.insert("Tg04")
        let reader = sensors(smc, model: "Mac16,10")
        XCTAssertThrowsError(try reader.readGPU())
        smc.transient.removeAll()
        XCTAssertEqual(try reader.readGPU(), 70)
    }

    // MARK: New coverage

    func testIntelCatalogUsesCoreGroupAndModelExclusions() throws {
        let smc = FakeSMC()
        // MacBookPro16,1 matches "MacBookPro13,2+": TC1C...TC8C cores, TC0c excluded.
        smc.set(FakeSMC.sp78("TC0c", 40)); smc.set(FakeSMC.sp78("TC1C", 80)); smc.set(FakeSMC.sp78("TC2C", 84))
        smc.set(FakeSMC.sp78("TC0P", 60)); smc.set(FakeSMC.sp78("TCXC", 90))
        let reader = sensors(smc, model: "MacBookPro16,1", platform: .intel)
        let cpu = try reader.readCPU()
        XCTAssertEqual(cpu.hottest, 84, accuracy: 0.01); XCTAssertEqual(cpu.average, 82, accuracy: 0.01)
        XCTAssertEqual(reader.discovery(.cpu)?.keys, ["TC1C", "TC2C"], "per-core sensors win; TC0c is excluded for this model")
        XCTAssertFalse(reader.plan(.cpu).candidates.map(\.key).contains("TC0c"))
    }

    func testIntelPackageSensorsPreferDieOverProximityAndHeatsink() throws {
        let smc = FakeSMC()
        smc.set(FakeSMC.sp78("TC0H", 50)); smc.set(FakeSMC.sp78("TC0P", 60)); smc.set(FakeSMC.sp78("TC0D", 71))
        let reader = sensors(smc, model: "iMac19,1", platform: .intel)
        XCTAssertEqual(try reader.readCPU().average, 71, accuracy: 0.01)
        XCTAssertEqual(reader.discovery(.cpu)?.keys, ["TC0D"])
        XCTAssertNotNil(reader.discovery(.cpu)?.skipped["TC0P"])
    }

    func testUnpopulatedZeroCoresAreSkippedAtDiscovery() throws {
        let smc = FakeSMC(); smc.set(FakeSMC.sp78("TC1C", 70)); smc.set(FakeSMC.sp78("TC5C", 0))
        let reader = sensors(smc, model: "MacBookPro16,1", platform: .intel)
        XCTAssertEqual(try reader.readCPU().average, 70, accuracy: 0.01)
        XCTAssertEqual(reader.discovery(.cpu)?.skipped["TC5C"], "reads 0 °C (unpopulated)")
    }

    func testUnknownAppleSiliconModelFallsBackWithoutUnrelatedKeys() throws {
        let plan = SensorPlan.make(kind: .cpu, model: MacModel(identifier: "Mac99,1"), platform: .appleSilicon)
        XCTAssertEqual(plan.source, .fallback)
        let keys = Set(plan.candidates.map(\.key))
        XCTAssertTrue(keys.isSuperset(of: ["Tp01", "Te05", "Tp0D"]))
        // Tm04 is a CPU core on MacBookPro22,2+ but memory on MacBookPro18: not a fallback CPU.
        XCTAssertFalse(keys.contains("Tm04"))
        XCTAssertFalse(keys.contains(where: { $0.hasPrefix("Tg") }))
        XCTAssertLessThan(plan.candidates.count, 120, "discovery work stays bounded")

        let smc = FakeSMC(); smc.temperature("Tp01", 50); smc.temperature("Tp09", 58); smc.temperature("Tm04", 99)
        let reader = sensors(smc, model: "Mac99,1")
        XCTAssertEqual(try reader.readCPU().hottest, 58)
        XCTAssertEqual(reader.discovery(.cpu)?.source, .fallback)
    }

    func testM1BaseModelsUseTheFallbackBecauseTheCatalogMapsThemOnlyThroughIOKit() {
        XCTAssertEqual(SensorPlan.make(kind: .cpu, model: MacModel(identifier: "Macmini9,1"), platform: .appleSilicon).source, .fallback)
        XCTAssertEqual(SensorPlan.make(kind: .cpu, model: MacModel(identifier: "MacBookPro18,3"), platform: .appleSilicon).source, .catalog)
    }

    func testMappedHIDSourceIsPreferredAndReadsCPUAndGPU() throws {
        let smc = FakeSMC(); smc.temperature("Tp01", 40)
        let hid = HIDFake(); hid.values = [.cpu: [71, 83], .gpu: [64, 69]]
        let reader = TemperatureSensors(smc: smc, model: MacModel(identifier: "Macmini9,1"), platform: .appleSilicon, hid: hid,
                                        clock: { [unowned self] in self.clock })
        XCTAssertEqual(try reader.readCPU().hottest, 83)
        XCTAssertEqual(try reader.readGPU(), 66.5, accuracy: 0.001)
        XCTAssertTrue(smc.reads.isEmpty, "HID-backed models do not probe unrelated SMC keys")
    }

    func testHIDReadFailureDoesNotSilentlyFallBackToSMC() throws {
        let smc = FakeSMC(); smc.temperature("Tp01", 40)
        let hid = HIDFake(); hid.values[.cpu] = [71]; hid.failures[.cpu] = FakeSMC.Transient(key: "hid")
        let reader = TemperatureSensors(smc: smc, model: MacModel(identifier: "Macmini9,1"), platform: .appleSilicon, hid: hid,
                                        clock: { [unowned self] in self.clock })
        XCTAssertThrowsError(try reader.readCPU())
        XCTAssertTrue(smc.reads.isEmpty)
    }

    func testMappedModelsKeepExactSemantics() {
        let studio = SensorPlan.make(kind: .gpu, model: MacModel(identifier: "Mac15,14"), platform: .appleSilicon)
        XCTAssertEqual(studio.candidates.map(\.key), ["Tg05", "Tg0z", "Tg22", "Tg2I", "Tg34", "Tg3K"])
        let mini = SensorPlan.make(kind: .cpu, model: MacModel(identifier: "Mac14,3"), platform: .appleSilicon)
        XCTAssertTrue(mini.candidates.map(\.key).contains("Tp0n"), "Macmini10,1 adds its own row to the shared set")
        let newer = SensorPlan.make(kind: .cpu, model: MacModel(identifier: "Mac17,9"), platform: .appleSilicon)
        XCTAssertTrue(newer.candidates.map(\.key).contains("Tm04"), "on MacBookPro22,2+ Tm04 is a mapped CPU core")
    }

    func testOptionalGPUClustersDoNotFailTheSample() throws {
        let smc = FakeSMC(); smc.temperature("Tg05", 60); smc.temperature("Tg0z", 66)
        let reader = sensors(smc, model: "Mac15,8")    // MacBookPro20,3: add_no_fail clusters
        XCTAssertEqual(try reader.readGPU(), 63, accuracy: 0.001)
        smc.transient.insert("Tg0z")
        XCTAssertEqual(try reader.readGPU(), 60, accuracy: 0.001)
        XCTAssertEqual(reader.discovery(.gpu)?.optionalKeys, ["Tg05", "Tg0z"])
    }

    func testTransientDiscoveryIsRetriedAndBounded() throws {
        let smc = FakeSMC(); smc.temperature("Tp01", 60); smc.temperature("Tp05", 70); smc.transient.insert("Tp05")
        let reader = sensors(smc, model: "Mac16,10")
        for attempt in 1..<TemperatureSensors.discoveryAttempts {
            XCTAssertThrowsError(try reader.readCPU()) { XCTAssertEqual($0 as? TemperatureSensors.Failure, .discovering(.cpu, attempt: attempt)) }
        }
        // Exhaustion backs off without accepting a permanently incomplete set.
        XCTAssertThrowsError(try reader.readCPU())
        XCTAssertNil(reader.discovery(.cpu))
        let probes = smc.reads.count
        XCTAssertThrowsError(try reader.readCPU())
        XCTAssertEqual(smc.reads.count, probes)
        smc.transient.removeAll()
        smc.temperature("Tp05", 99)
        clock.addTimeInterval(TemperatureSensors.emptyRetryInterval + 1)
        XCTAssertEqual(try reader.readCPU().hottest, 99)
        XCTAssertEqual(Set(reader.discovery(.cpu)!.keys), ["Tp01", "Tp05"])
    }

    func testOutOfRangeAndWrongTypeCandidates() throws {
        let smc = FakeSMC(); smc.temperature("Tp01", 60); smc.temperature("Tp05", 300)
        smc.set(SMCValue(key: "Tp09", dataType: .ui8, bytes: [40]))
        let reader = sensors(smc, model: "Mac16,10")
        XCTAssertThrowsError(try reader.readCPU())
        XCTAssertThrowsError(try reader.readCPU())
        XCTAssertThrowsError(try reader.readCPU())
        XCTAssertNil(reader.discovery(.cpu))
        smc.temperature("Tp05", 80)
        clock.addTimeInterval(TemperatureSensors.emptyRetryInterval + 1)
        XCTAssertEqual(try reader.readCPU().hottest, 80)
        XCTAssertNotNil(reader.discovery(.cpu)?.skipped["Tp09"])
        // After discovery, an out-of-range sample of a used key fails the sample.
        smc.temperature("Tp01", .nan)
        XCTAssertThrowsError(try reader.readCPU())
    }

    func testEmptyDiscoveryBacksOffInsteadOfProbingEveryPoll() {
        let smc = FakeSMC()
        let reader = sensors(smc, model: "Mac99,1")
        XCTAssertThrowsError(try reader.readCPU())
        let probes = smc.reads.count
        XCTAssertGreaterThan(probes, 0)
        XCTAssertThrowsError(try reader.readCPU())
        XCTAssertEqual(smc.reads.count, probes, "no second sweep inside the retry interval")
        clock.addTimeInterval(TemperatureSensors.emptyRetryInterval + 1)
        smc.temperature("Tp01", 55)
        XCTAssertEqual(try reader.readCPU().hottest, 55)
    }
    func testGPUControlUsesHottestDieAndRejectsLostDiscoveredCluster() throws {
        let smc = FakeSMC(); smc.temperature("Tg04", 50); smc.temperature("Tg12", 100)
        let reader = sensors(smc, model: "Mac16,10")
        XCTAssertEqual(try reader.readGPU(), 75)
        XCTAssertEqual(try reader.readGPUHottest(), 100)
        smc.transient.insert("Tg12")
        XCTAssertThrowsError(try reader.readGPUHottest())
    }

    func testOptionalDiscoveredGPUClusterIsRequiredForControl() throws {
        let smc = FakeSMC(); smc.temperature("Tg05", 60); smc.temperature("Tg0z", 99)
        let reader = sensors(smc, model: "Mac15,8")
        XCTAssertEqual(try reader.readGPUHottest(), 99)
        smc.transient.insert("Tg0z")
        XCTAssertThrowsError(try reader.readGPUHottest())
        XCTAssertEqual(try reader.readGPU(), 60, "monitoring may still report available optional sensors")
    }

}
