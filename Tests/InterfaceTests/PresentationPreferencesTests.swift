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

    /// The slider style is a persisted presentation choice: Channel by
    /// default, Dot Grid kept as the original look.
    func testSliderStyleDefaultsToChannelAndPersists() {
        let center = NotificationCenter()
        var notes = 0
        let token = center.addObserver(forName: PresentationPreferences.didChange, object: nil, queue: nil) { _ in notes += 1 }
        defer { center.removeObserver(token) }
        let prefs = PresentationPreferences(defaults: defaults, center: center)
        XCTAssertEqual(prefs.sliderStyle, .channel)
        prefs.sliderStyle = .dotGrid; prefs.sliderStyle = .dotGrid
        XCTAssertEqual(notes, 1)
        XCTAssertEqual(PresentationPreferences(defaults: defaults, center: center).sliderStyle, .dotGrid)
        defaults.set("velvet", forKey: PresentationPreferences.Key.sliderStyle)
        XCTAssertEqual(PresentationPreferences(defaults: defaults, center: center).sliderStyle, .channel)
        XCTAssertEqual(SliderStyle.allCases.map(\.title), ["Channel", "Dot Grid"])
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

    /// Drag-speed reactions: full on Expressive, gentler on Subtle, none on
    /// Off; Reduce Motion removes them at every level.
    func testDragReactionsFollowEffectsLevel() {
        let expressive = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
        let subtle = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)
        let off = EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(expressive.motion, 1); XCTAssertTrue(expressive.wake)
        XCTAssertGreaterThan(subtle.motion, 0); XCTAssertLessThan(subtle.motion, expressive.motion); XCTAssertFalse(subtle.wake)
        XCTAssertEqual(off.motion, 0); XCTAssertFalse(off.wake)
        for level in EffectsLevel.allCases {
            let reduced = EffectsProfile(level: level, reduceMotion: true, reduceTransparency: false)
            XCTAssertEqual(reduced.motion, 0); XCTAssertFalse(reduced.wake)
        }
        XCTAssertEqual(EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: true).motion, 1,
                       "Reduce Transparency dims light, not movement")
    }

    func testSliderEnergyIncreasesProgressively() {
        XCTAssertEqual(SliderEnergy.level(percent: 0), 0)
        XCTAssertEqual(SliderEnergy.level(percent: 100), 1)
        XCTAssertEqual(SliderEnergy.level(percent: 140), 1)
        XCTAssertEqual(SliderEnergy.level(percent: .nan), 0)
        let samples = stride(from: 0.0, through: 100, by: 5).map { SliderEnergy.level(percent: $0) }
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertLessThan(SliderEnergy.level(percent: 50), 0.5, "Energy accelerates toward the top of the range")
    }

    func testCoolantCoolsFromMintThroughCyanToIce() {
        for p in Array(stride(from: -10.0, through: 110, by: 2.5)) + [Double.nan, .infinity] {
            let t = SliderEnergy.tone(percent: p)
            XCTAssertEqual(t.low + t.mid + t.high, 1, accuracy: 1e-9, "\(p)")
            XCTAssertTrue([t.low, t.mid, t.high].allSatisfy { (0...1).contains($0) }, "\(p)")
        }
        XCTAssertEqual(SliderEnergy.tone(percent: 0).low, 1)
        XCTAssertEqual(SliderEnergy.tone(percent: 60).mid, 1, accuracy: 1e-9)
        XCTAssertEqual(SliderEnergy.tone(percent: 100).high, 1)
        // Warm hues never appear: the ramp only ever mixes the three ice tones,
        // and ice only joins above cyan.
        XCTAssertEqual(SliderEnergy.tone(percent: 59).high, 0)
        let density = stride(from: 0.0, through: 100, by: 5).map { SliderEnergy.coolant(percent: $0) }
        XCTAssertEqual(density, density.sorted())
        XCTAssertGreaterThanOrEqual(density.first!, 0.45, "The floor is visibly filled, never empty")
        XCTAssertLessThan(density.last!, 1, "Glass shows through even at full cooling")
    }
}

final class SliderGeometryTests: XCTestCase {
    func testChannelIsCentredAndTheThumbStaysInsideIt() {
        let bounds = CGRect(x: 0, y: 0, width: 344, height: 34)
        let channel = SliderGeometry.channel(in: bounds)
        XCTAssertEqual(channel.height, SliderGeometry.channelHeight)
        XCTAssertEqual(channel.minX, SliderGeometry.inset)
        XCTAssertEqual(channel.maxX, bounds.width - SliderGeometry.inset)
        XCTAssertEqual(channel.midY, bounds.midY, accuracy: 0.5)
        XCTAssertEqual(SliderGeometry.x(percent: 0, width: 344) - SliderGeometry.thumb.width / 2, channel.minX)
        XCTAssertEqual(SliderGeometry.x(percent: 100, width: 344) + SliderGeometry.thumb.width / 2, channel.maxX)
        XCTAssertEqual(SliderGeometry.x(percent: -20, width: 344), SliderGeometry.x(percent: 0, width: 344))
        XCTAssertEqual(SliderGeometry.x(percent: .nan, width: 344), SliderGeometry.x(percent: 0, width: 344))
        // The thumb is taller than the channel, so it reads as a handle on it.
        XCTAssertGreaterThan(SliderGeometry.thumb.height, SliderGeometry.channelHeight * 1.5)
        XCTAssertLessThanOrEqual(SliderGeometry.thumb.height, bounds.height)
    }

    func testPointerMappingRoundTrips() {
        for width in [120.0, 344, 512] as [CGFloat] {
            for p in stride(from: 0.0, through: 100, by: 7) {
                XCTAssertEqual(SliderGeometry.percent(atX: SliderGeometry.x(percent: p, width: width), width: width), p, accuracy: 1e-9)
            }
            XCTAssertLessThan(SliderGeometry.percent(atX: 0, width: width), 0, "Unclamped: the control applies the hardware floor")
        }
        XCTAssertGreaterThan(SliderGeometry.travel(width: 10), 0, "Degenerate widths never divide by zero")
    }
}

final class DotGridGeometryTests: XCTestCase {
    /// The restored style keeps the original lattice mapping exactly
    /// (7bd4997: 3 pt pitch, 2 pt dots, centred, 16 pt ends).
    func testLatticeMatchesTheOriginalControl() {
        XCTAssertEqual(DotGridGeometry.columns(width: 372), 113)
        let grid = DotGridGeometry.grid(width: 372, height: 34)
        XCTAssertEqual(grid, CGRect(x: 17, y: 10, width: 338, height: 14))
        XCTAssertEqual(DotGridGeometry.x(percent: 0, width: 372), 18)
        XCTAssertEqual(DotGridGeometry.x(percent: 100, width: 372), 354)
        XCTAssertEqual(DotGridGeometry.x(percent: 150, width: 372), 354)
        XCTAssertEqual(DotGridGeometry.x(percent: .nan, width: 372), 18)
        XCTAssertEqual(DotGridGeometry.thumb, CGSize(width: 6, height: 20))
        for p in stride(from: 0.0, through: 100, by: 9) {
            XCTAssertEqual(DotGridGeometry.percent(atX: DotGridGeometry.x(percent: p, width: 344), width: 344), p, accuracy: 1e-9)
        }
    }

    func testStyleDispatchesGeometry() {
        for p in [0.0, 21, 64, 100] {
            XCTAssertEqual(SliderStyle.channel.x(percent: p, width: 344), SliderGeometry.x(percent: p, width: 344))
            XCTAssertEqual(SliderStyle.dotGrid.x(percent: p, width: 344), DotGridGeometry.x(percent: p, width: 344))
            for style in SliderStyle.allCases {
                XCTAssertEqual(style.percent(atX: style.x(percent: p, width: 344), width: 344), p, accuracy: 1e-9)
            }
        }
        XCTAssertNotEqual(SliderStyle.channel.x(percent: 0, width: 344), SliderStyle.dotGrid.x(percent: 0, width: 344),
                          "Floor marks must follow the selected style")
    }

    func testDotSizeStaysWithinTheLattice() {
        XCTAssertLessThan(SliderEnergy.dotSize(percent: 0), SliderEnergy.dotSize(percent: 100))
        XCTAssertLessThanOrEqual(SliderEnergy.dotSize(percent: 100), 2.4)
    }
}

final class SliderMotionTests: XCTestCase {
    func testSmoothingFollowsElapsedTimeAndSurvivesBadSamples() {
        var v = 0.0
        for _ in 0..<40 { v = SliderMotion.smoothed(previous: v, sample: 900, interval: 1.0 / 120) }
        XCTAssertEqual(v, 900, accuracy: 5, "Converges on a steady drag")
        let oneLongStep = SliderMotion.smoothed(previous: 0, sample: 900, interval: 0.05)
        var twoShort = 0.0
        for _ in 0..<2 { twoShort = SliderMotion.smoothed(previous: twoShort, sample: 900, interval: 0.025) }
        XCTAssertEqual(oneLongStep, twoShort, accuracy: 1e-9, "Event rate does not change the result")
        XCTAssertEqual(SliderMotion.smoothed(previous: 300, sample: .nan, interval: 0.01), 300)
        XCTAssertEqual(SliderMotion.smoothed(previous: .nan, sample: .nan, interval: 0.01), 0)
        XCTAssertTrue(SliderMotion.smoothed(previous: 0, sample: 500, interval: 0).isFinite)
        XCTAssertTrue(SliderMotion.smoothed(previous: 0, sample: 500, interval: -1).isFinite)
    }

    func testSpeedResponseHasADeadZoneAndSaturates() {
        XCTAssertEqual(SliderMotion.intensity(velocity: 0), 0)
        XCTAssertEqual(SliderMotion.intensity(velocity: 35), 0, "Slow, precise adjustment stays still")
        XCTAssertEqual(SliderMotion.intensity(velocity: .infinity), 0)
        XCTAssertEqual(SliderMotion.intensity(velocity: 400), SliderMotion.intensity(velocity: -400))
        let ramp = stride(from: 0.0, through: 4000, by: 100).map { SliderMotion.intensity(velocity: $0) }
        XCTAssertEqual(ramp, ramp.sorted())
        XCTAssertLessThanOrEqual(ramp.last!, 1)
        XCTAssertGreaterThan(SliderMotion.intensity(velocity: 1500), 0.9)
    }

    func testThumbLeansWithTravelWithinBounds() {
        XCTAssertGreaterThan(SliderMotion.lean(velocity: 800, gain: 1), 0)
        XCTAssertLessThan(SliderMotion.lean(velocity: -800, gain: 1), 0)
        XCTAssertEqual(SliderMotion.lean(velocity: 800, gain: 1), -SliderMotion.lean(velocity: -800, gain: 1))
        XCTAssertEqual(SliderMotion.lean(velocity: 10, gain: 1), 0)
        XCTAssertEqual(SliderMotion.lean(velocity: 800, gain: 0), 0)
        XCTAssertLessThanOrEqual(abs(SliderMotion.lean(velocity: 1e9, gain: 5)), SliderMotion.maxLean)
        XCTAssertLessThan(SliderMotion.lean(velocity: 800, gain: 0.45), SliderMotion.lean(velocity: 800, gain: 1))
        XCTAssertLessThanOrEqual(SliderMotion.stretch(velocity: 1e9, gain: 1), 0.35)
        XCTAssertLessThanOrEqual(SliderMotion.surge(velocity: 1e9, gain: 1), 0.9)
        XCTAssertEqual(SliderMotion.stretch(velocity: 800, gain: .nan), 0)
    }

    func testWakeGrowsWithSpeedAndCoolingEnergy() {
        XCTAssertEqual(SliderMotion.wake(velocity: 20, energy: 1).opacity, 0)
        let slow = SliderMotion.wake(velocity: 300, energy: 0.5), fast = SliderMotion.wake(velocity: 1500, energy: 0.5)
        XCTAssertGreaterThan(fast.length, slow.length)
        XCTAssertGreaterThan(fast.opacity, slow.opacity)
        XCTAssertGreaterThan(SliderMotion.wake(velocity: 900, energy: 1).opacity, SliderMotion.wake(velocity: 900, energy: 0).opacity)
        let extreme = SliderMotion.wake(velocity: -1e9, energy: 9)
        XCTAssertLessThanOrEqual(extreme.opacity, 1)
        XCTAssertLessThanOrEqual(extreme.length, 88)
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
        let crystals = stride(from: 60.0, through: 100, by: 2.5).map { Frost.crystal(percent: $0) }
        XCTAssertEqual(crystals, crystals.sorted())
        XCTAssertEqual(Frost.crystal(percent: Frost.crystalOnset), 0); XCTAssertEqual(Frost.crystal(percent: 100), 1)
        XCTAssertGreaterThan(Frost.crystalOnset, Frost.onset, "Rime comes first; the sheet forms only near the top")
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
