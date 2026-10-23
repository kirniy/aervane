import XCTest
@testable import Zephyr

/// The temperature figure's motion policy: a calm fade only for a real
/// change of a real reading the person is watching; nothing else moves.
final class TemperatureMotionTests: XCTestCase {
    private func motion(_ old: String, _ new: String, sameSeries: Bool = true, sameUnit: Bool = true,
                        visible: Bool = true, allowed: Bool = true) -> TemperatureMotion {
        TemperatureMotion.between(old, new, sameSeries: sameSeries, sameUnit: sameUnit, visible: visible, allowed: allowed)
    }

    func testARealChangeFadesBriefly() {
        XCTAssertEqual(motion("72", "73"), .fade)
        XCTAssertEqual(motion("99", "100"), .fade)
        XCTAssertEqual(motion("-2", "1"), .fade)
        XCTAssertLessThanOrEqual(TemperatureMotion.duration, 0.25, "Finishes well before the next 1 s sample")
        XCTAssertGreaterThan(TemperatureMotion.duration, 0.1, "Long enough to read as a crossfade, not a flicker")
    }

    func testNoChangeNoMotion() {
        XCTAssertEqual(motion("73", "73"), .none, "A repeated reading never animates")
    }

    /// No false motion: these are not a temperature changing.
    func testSourceUnitAndStaleTransitionsDoNotAnimate() {
        XCTAssertEqual(motion("73", "81", sameSeries: false), .none, "Switching source (Smart ↔ selected sensor)")
        XCTAssertEqual(motion("73", "163", sameUnit: false), .none, "Switching °C ↔ °F")
        XCTAssertEqual(motion("—", "73"), .none, "First reading or stale → valid")
        XCTAssertEqual(motion("73", "—"), .none, "Valid → stale")
        XCTAssertEqual(motion("", "73"), .none, "Startup")
    }

    func testHiddenOffAndReduceMotionDoNotAnimate() {
        XCTAssertEqual(motion("72", "73", visible: false), .none)
        for effects in [EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false),
                        EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false)] {
            XCTAssertEqual(motion("72", "73", allowed: effects.rolls), .none)
        }
        XCTAssertEqual(motion("72", "73", allowed: EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false).rolls), .fade)
    }
}
