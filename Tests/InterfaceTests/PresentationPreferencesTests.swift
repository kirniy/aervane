import XCTest
@testable import Zephyr

final class PresentationPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "dev.kirniy.aervane.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaultsAreCompactIconAndTemperatureExpressive() {
        let prefs = PresentationPreferences(defaults: defaults, center: NotificationCenter())
        XCTAssertEqual(prefs.menuBarContent, .iconAndTemperature)
        XCTAssertEqual(prefs.menuBarSpacing, .compact)
        XCTAssertEqual(prefs.effects, .expressive)
        XCTAssertTrue(prefs.heatColor)
    }

    func testChoicesPersistAndNotifyOnlyOnChange() {
        let center = NotificationCenter()
        var notes = 0
        let token = center.addObserver(forName: PresentationPreferences.didChange, object: nil, queue: nil) { _ in notes += 1 }
        defer { center.removeObserver(token) }
        let prefs = PresentationPreferences(defaults: defaults, center: center)
        prefs.menuBarContent = .icon; prefs.menuBarSpacing = .comfortable; prefs.effects = .off; prefs.heatColor = false
        prefs.effects = .off
        XCTAssertEqual(notes, 4)
        let reloaded = PresentationPreferences(defaults: defaults, center: center)
        XCTAssertEqual(reloaded.menuBarContent, .icon)
        XCTAssertEqual(reloaded.menuBarSpacing, .comfortable)
        XCTAssertEqual(reloaded.effects, .off)
        XCTAssertFalse(reloaded.heatColor)
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        defaults.set("sparkles", forKey: PresentationPreferences.Key.effects)
        defaults.set(3, forKey: PresentationPreferences.Key.menuBarContent)
        let prefs = PresentationPreferences(defaults: defaults, center: NotificationCenter())
        XCTAssertEqual(prefs.effects, .expressive)
        XCTAssertEqual(prefs.menuBarContent, .iconAndTemperature)
    }

    /// Regression: the status item was a fixed 70 pt with a leading-space
    /// title, leaving wide empty margins around short content.
    func testStatusItemHugsContentWithMinimalPadding() {
        XCTAssertEqual(StatusItemLayout.title(temperatureText: "69"), "69°")
        XCTAssertEqual(StatusItemLayout.title(temperatureText: "—"), "—°")
        XCTAssertFalse(StatusItemLayout.title(temperatureText: "69").hasPrefix(" "))
        let both = StatusItemLayout.length(content: .iconAndTemperature, spacing: .compact, iconWidth: 14, titleWidth: 22)
        XCTAssertEqual(both, 14 + 3 + 22 + 8)
        XCTAssertLessThan(both, 70)
        XCTAssertEqual(StatusItemLayout.length(content: .icon, spacing: .compact, iconWidth: 14, titleWidth: 22), 22)
        XCTAssertEqual(StatusItemLayout.length(content: .temperature, spacing: .compact, iconWidth: 14, titleWidth: 22), 30)
        XCTAssertGreaterThan(StatusItemLayout.length(content: .iconAndTemperature, spacing: .comfortable, iconWidth: 14, titleWidth: 22), both)
        XCTAssertEqual(StatusItemLayout.length(content: .temperature, spacing: .compact, iconWidth: 14, titleWidth: 21.2), 30)
    }

    func testThermalBandsAndHysteresis() {
        XCTAssertEqual(ThermalState.classify(nil), .unknown)
        XCTAssertEqual(ThermalState.classify(.nan), .unknown)
        XCTAssertEqual(ThermalState.classify(40), .cool)
        XCTAssertEqual(ThermalState.classify(55), .steady)
        XCTAssertEqual(ThermalState.classify(70), .warm)
        XCTAssertEqual(ThermalState.classify(82), .hot)
        XCTAssertEqual(ThermalState.classify(102), .peak)
        // Falling just below a bound keeps the band; clearly below drops it.
        XCTAssertEqual(ThermalState.classify(81, previous: .hot), .hot)
        XCTAssertEqual(ThermalState.classify(80.4, previous: .hot), .warm)
        XCTAssertEqual(ThermalState.classify(60, previous: .peak), .steady)
        // Rising is immediate.
        XCTAssertEqual(ThermalState.classify(82, previous: .warm), .hot)
    }

    func testEffectsRespectSystemAccessibilitySettings() {
        let full = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
        XCTAssertTrue(full.sweep && full.bloom && full.rolls && full.animates)
        XCTAssertEqual(full.glow, 1)
        let reduced = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: true)
        XCTAssertFalse(reduced.sweep || reduced.bloom || reduced.rolls || reduced.animates)
        XCTAssertEqual(reduced.glow, 0.5)
        let off = EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(off.glow, 0); XCTAssertEqual(off.aura, 0)
        XCTAssertFalse(off.sweep || off.bloom || off.rolls)
        XCTAssertTrue(off.animates, "Continuity transitions follow Reduce Motion, not the effects level")
        let subtle = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
        XCTAssertFalse(subtle.sweep); XCTAssertLessThan(subtle.glow, full.glow)
    }

    func testSliderEnergyIncreasesProgressively() {
        XCTAssertEqual(SliderEnergy.level(percent: 0), 0)
        XCTAssertEqual(SliderEnergy.level(percent: 100), 1)
        XCTAssertEqual(SliderEnergy.level(percent: 140), 1)
        XCTAssertEqual(SliderEnergy.level(percent: .nan), 0)
        let samples = stride(from: 0.0, through: 100, by: 5).map { SliderEnergy.level(percent: $0) }
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertLessThan(SliderEnergy.level(percent: 50), 0.5, "Energy accelerates toward the top of the range")
        XCTAssertLessThan(SliderEnergy.dotSize(percent: 0), SliderEnergy.dotSize(percent: 100))
        XCTAssertLessThanOrEqual(SliderEnergy.dotSize(percent: 100), 2.4)
    }
}

final class FrostAndArtworkTests: XCTestCase {
    func testFrostGrowsWithCoolingAndCrownsOnlyAtMaximum() {
        XCTAssertEqual(Frost.amount(percent: 30), 0)
        XCTAssertEqual(Frost.amount(percent: Frost.onset), 0)
        XCTAssertEqual(Frost.amount(percent: 100), 1)
        let ramp = stride(from: 40.0, through: 100, by: 5).map { Frost.amount(percent: $0) }
        XCTAssertEqual(ramp, ramp.sorted())
        XCTAssertFalse(Frost.crowned(percent: 99))
        XCTAssertTrue(Frost.crowned(percent: 100))
    }

    func testFrostFollowsEffectsLevelAndSystemSettings() {
        let expressive = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(expressive.frost, 1); XCTAssertTrue(expressive.forms)
        let subtle = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
        XCTAssertGreaterThan(subtle.frost, 0); XCTAssertFalse(subtle.forms)
        XCTAssertEqual(EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false).frost, 0)
        let reduced = EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: true)
        XCTAssertFalse(reduced.forms, "Reduce Motion shows ice without the formation animation")
        XCTAssertEqual(reduced.frost, 0.5)
    }

    func testDurationTextIsConcise() {
        XCTAssertEqual(DurationText.short(minutes: 5), "5 min")
        XCTAssertEqual(DurationText.short(minutes: 30), "30 min")
        XCTAssertEqual(DurationText.short(minutes: 60), "1 hr")
        XCTAssertEqual(DurationText.short(minutes: 90), "1 hr 30 min")
        XCTAssertEqual(DurationText.short(minutes: 120), "2 hr")
        XCTAssertEqual(DurationText.spoken(minutes: 65), "1 hour 5 minutes")
    }

    func testGitHubMarkParsesToAClosedShapeInsideItsBox() {
        let segments = VectorPath.parse(VectorPath.githubMark)
        // M, C, 22 relative cubics, one sub-90° arc cubic, c, z.
        XCTAssertEqual(segments.count, 27)
        XCTAssertEqual(segments.first, .move(CGPoint(x: 8, y: 0)))
        XCTAssertEqual(segments.last, .close)
        var points: [CGPoint] = []
        for segment in segments {
            switch segment {
            case .move(let p), .line(let p): points.append(p)
            case .curve(_, _, let p): points.append(p)
            case .close: break
            }
        }
        XCTAssertTrue(points.allSatisfy { (-0.01...16.01).contains($0.x) && (-0.01...16.01).contains($0.y) }, "\(points.filter { !(-0.01...16.01).contains($0.x) || !(-0.01...16.01).contains($0.y) })")
        // The packed arc ("0016 8") must land exactly on its endpoint.
        XCTAssertTrue(points.contains(CGPoint(x: 16, y: 8)))
    }

    func testPathParserHandlesRelativeAndArcCommands() {
        let square = VectorPath.parse("M0 0h10v10H0z")
        XCTAssertEqual(square, [.move(.zero), .line(CGPoint(x: 10, y: 0)), .line(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 0, y: 10)), .close])
        let half = VectorPath.parse("M0 5A5 5 0 0 1 10 5")
        guard case .curve(_, _, let end)? = half.last else { return XCTFail("no arc") }
        XCTAssertEqual(end, CGPoint(x: 10, y: 5))
        XCTAssertEqual(half.count, 3, "A 180° arc becomes two quarter-circle cubics")
    }
}
