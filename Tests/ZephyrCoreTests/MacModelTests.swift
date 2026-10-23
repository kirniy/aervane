import XCTest
@testable import ZephyrCore

/// Alias normalization and the static model predicates of control-keys.json.
final class MacModelTests: XCTestCase {
    func testAliasesNormalizeToFamilyAndDecimalVersion() {
        let mini = MacModel(identifier: "Mac16,10")
        XCTAssertEqual(mini.normalized, "Macmini11,1")
        XCTAssertEqual(mini.family, .macmini); XCTAssertEqual(mini.version, 111)
        XCTAssertEqual(MacModel(identifier: "MacBookPro18,3").version, 183)
        XCTAssertEqual(MacModel(identifier: "MacBookPro16,1").family, .macBookPro)
        XCTAssertEqual(MacModel(identifier: "iMacPro1,1").family, .iMacPro)
        XCTAssertEqual(MacModel(identifier: "ADP3,2").version, 32)
        let future = MacModel(identifier: "Mac99,7")
        XCTAssertNil(future.family); XCTAssertEqual(future.familyName, "Mac")
        XCTAssertNil(MacModel(identifier: "VirtualMac").version)
    }

    func testFtstModelsAreMacBookProAbove201() {
        XCTAssertFalse(MacModel(identifier: "Mac15,3").requiresFtst)          // MacBookPro20,1
        XCTAssertTrue(MacModel(identifier: "Mac15,6").requiresFtst)           // MacBookPro20,2
        XCTAssertTrue(MacModel(identifier: "Mac16,1").requiresFtst)           // MacBookPro21,1
        XCTAssertFalse(MacModel(identifier: "Mac16,10").requiresFtst)         // Macmini11,1
        XCTAssertFalse(MacModel(identifier: "MacBookPro16,1").requiresFtst)
        XCTAssertFalse(MacModel(identifier: "Mac16,9").requiresFtst)          // MacStudio3,1
    }

    func testLowercaseModeModels() {
        XCTAssertTrue(MacModel(identifier: "Mac17,2").requiresLowercaseMode)  // MacBookPro22,1
        XCTAssertFalse(MacModel(identifier: "Mac16,1").requiresLowercaseMode) // MacBookPro21,1 (= 211)
        XCTAssertTrue(MacModel(identifier: "Mac16,9").requiresLowercaseMode)  // MacStudio3,1 (31 > 30)
        XCTAssertTrue(MacModel(identifier: "Mac15,14").requiresLowercaseMode) // MacStudio3,2
        XCTAssertFalse(MacModel(identifier: "Mac14,13").requiresLowercaseMode) // MacStudio2,1
        XCTAssertFalse(MacModel(identifier: "Mac16,10").requiresLowercaseMode)
    }

    func testVendorNotWorkingAndFanlessPredicates() {
        XCTAssertTrue(MacModel(identifier: "MacBookPro20,2").vendorReportsControlNotWorking)
        XCTAssertTrue(MacModel(identifier: "MacBookPro21,5").vendorReportsControlNotWorking)
        XCTAssertFalse(MacModel(identifier: "MacBookPro22,1").vendorReportsControlNotWorking)
        XCTAssertTrue(MacModel(identifier: "MacBookAir10,1").hasNoFans)
        XCTAssertTrue(MacModel(identifier: "Mac14,2").hasNoFans)               // MacBookAir11,1
        XCTAssertTrue(MacModel(identifier: "Mac17,5").hasNoFans)               // MacBookNeo1,1
        XCTAssertTrue(MacModel(identifier: "MacBook10,1").hasNoFans)
        XCTAssertFalse(MacModel(identifier: "MacBookAir9,1").hasNoFans)
        XCTAssertFalse(MacModel(identifier: "Mac16,10").hasNoFans)
    }

    func testSelectorsMatchExactVersionsOrNewerWithinTheFamily() {
        let selector = ModelSelector("MacBookPro9,1;MacBookPro13,2+")
        XCTAssertTrue(selector.matches(MacModel(identifier: "MacBookPro9,1")))
        XCTAssertFalse(selector.matches(MacModel(identifier: "MacBookPro9,2")))
        XCTAssertTrue(selector.matches(MacModel(identifier: "MacBookPro13,2")))
        XCTAssertTrue(selector.matches(MacModel(identifier: "MacBookPro16,4")))
        XCTAssertFalse(selector.matches(MacModel(identifier: "MacBookAir13,2")))
        XCTAssertFalse(selector.matches(nil))
        XCTAssertTrue(ModelSelector("all").matches(nil))
        // Family names compare exactly as the catalog writes them.
        XCTAssertFalse(ModelSelector("MacMini3,1").matches(MacModel(identifier: "Macmini3,1")))
        XCTAssertTrue(ModelSelector("Macmini8,1+").matches(MacModel(identifier: "Mac16,10")))
    }

    func testFanLabelsComeFromTheCatalog() {
        XCTAssertEqual(HardwareCatalog.fanLabel(model: MacModel(identifier: "MacPro7,1"), fan: 3), "Intake 3")
        XCTAssertEqual(HardwareCatalog.fanLabel(model: MacModel(identifier: "MacBookPro18,3"), fan: 1), "Right side")
        XCTAssertEqual(HardwareCatalog.fanLabel(model: MacModel(identifier: "Mac16,10"), fan: 0), "Exhaust")
        XCTAssertNil(HardwareCatalog.fanLabel(model: MacModel(identifier: "Mac16,10"), fan: 1))
    }
}
