import AppKit
import XCTest
@testable import Zephyr

/// The large temperature figure: stable geometry and a single, replaceable
/// crossfade that never delays the newest reading.
@MainActor final class TemperatureFigureTests: XCTestCase {
    private func figure(_ text: String = "72") -> NSTextField {
        let field = label(text, size: 52, weight: .light)
        field.font = TemperatureFigure.font(); field.wantsLayer = true
        return field
    }
    private func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: TemperatureFigure.font()]).size().width
    }

    /// Tabular digits: every reading with the same number of digits has the
    /// same width, so the unit and sensor tag beside it never shift.
    func testDigitsHaveFixedWidthSoTheUnitNeverShifts() {
        let reference = width("10")
        for text in ["11", "47", "73", "88", "99", "00"] {
            XCTAssertEqual(width(text), reference, accuracy: 0.01, "\(text) is as wide as 10")
        }
        XCTAssertEqual(width("100"), width("111"), accuracy: 0.01)
    }

    /// Same face as before: rounded light at 52 pt with the same vertical
    /// metrics, so the unit stays cap-aligned.
    func testKeepsTheRoundedFaceAndMetrics() {
        let font = TemperatureFigure.font(), before = Theme.rounded(52, .light)
        XCTAssertEqual(font.pointSize, 52)
        XCTAssertEqual(font.ascender, before.ascender, accuracy: 0.01)
        XCTAssertEqual(font.capHeight, before.capHeight, accuracy: 0.01)
        XCTAssertEqual(font.familyName, before.familyName)
    }

    func testFadeShowsTheNewReadingAtOnceWithOneShortCrossfade() {
        let field = figure("72")
        TemperatureFigure.show("73", in: field, motion: .fade)
        XCTAssertEqual(field.stringValue, "73", "The newest reading is set immediately")
        let fade = field.layer?.animation(forKey: TemperatureFigure.fadeKey) as? CATransition
        XCTAssertEqual(fade?.type, .fade, "A crossfade, not a push or roll")
        XCTAssertNil(fade?.subtype, "No direction: nothing slides")
        XCTAssertEqual(fade?.duration ?? 0, TemperatureMotion.duration, accuracy: 1e-9)
        XCTAssertEqual(field.layer?.animationKeys()?.count, 1)
    }

    /// Rapid readings replace the running fade; they never stack and never
    /// queue intermediate values.
    func testRapidReadingsReplaceRatherThanStack() {
        let field = figure("72")
        for text in ["73", "74", "73", "75"] { TemperatureFigure.show(text, in: field, motion: .fade) }
        XCTAssertEqual(field.stringValue, "75")
        XCTAssertEqual(field.layer?.animationKeys()?.count, 1, "One crossfade at most")
    }

    func testNoMotionChangesInstantlyAndCancelsARunningFade() {
        let field = figure("72")
        TemperatureFigure.show("73", in: field, motion: .fade)
        TemperatureFigure.show("163", in: field, motion: .none)
        XCTAssertEqual(field.stringValue, "163")
        XCTAssertNil(field.layer?.animation(forKey: TemperatureFigure.fadeKey), "A unit or source switch never fades")
    }

    func testAnUnchangedReadingAddsNothing() {
        let field = figure("72")
        TemperatureFigure.show("72", in: field, motion: .fade)
        XCTAssertNil(field.layer?.animationKeys(), "A repeated reading never animates")
    }
}
