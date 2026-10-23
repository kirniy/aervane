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

    /// The slider style is a persisted presentation choice: Dot Grid by
    /// default, with Channel available as an alternative.
    func testSliderStyleDefaultsToDotGridAndPersists() {
        let center = NotificationCenter()
        var notes = 0
        let token = center.addObserver(forName: PresentationPreferences.didChange, object: nil, queue: nil) { _ in notes += 1 }
        defer { center.removeObserver(token) }
        let prefs = PresentationPreferences(defaults: defaults, center: center)
        XCTAssertEqual(prefs.sliderStyle, .dotGrid)
        prefs.sliderStyle = .channel; prefs.sliderStyle = .channel
        XCTAssertEqual(notes, 1)
        XCTAssertEqual(PresentationPreferences(defaults: defaults, center: center).sliderStyle, .channel)
        defaults.set("velvet", forKey: PresentationPreferences.Key.sliderStyle)
        XCTAssertEqual(PresentationPreferences(defaults: defaults, center: center).sliderStyle, .dotGrid)
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
        let bounds = CGRect(x: 0, y: 0, width: 344, height: SliderGeometry.frameHeight)
        let channel = SliderGeometry.channel(in: bounds)
        XCTAssertEqual(channel.height, SliderGeometry.channelHeight)
        XCTAssertEqual(channel.minX, SliderGeometry.inset)
        XCTAssertEqual(channel.maxX, bounds.width - SliderGeometry.inset)
        XCTAssertEqual(channel.midY, bounds.midY, accuracy: 0.5)
        XCTAssertEqual(SliderGeometry.x(percent: 0, width: 344) - SliderGeometry.thumb.width / 2, channel.minX)
        XCTAssertEqual(SliderGeometry.x(percent: 100, width: 344) + SliderGeometry.thumb.width / 2, channel.maxX)
        XCTAssertEqual(SliderGeometry.x(percent: -20, width: 344), SliderGeometry.x(percent: 0, width: 344))
        XCTAssertEqual(SliderGeometry.x(percent: .nan, width: 344), SliderGeometry.x(percent: 0, width: 344))
        // A thick tube with a knob that stands proud of it, inside the frame
        // with room for rime above and below.
        XCTAssertGreaterThanOrEqual(SliderGeometry.channelHeight, 28)
        XCTAssertGreaterThan(SliderGeometry.thumb.height, SliderGeometry.channelHeight)
        XCTAssertLessThanOrEqual(SliderGeometry.thumb.height + 12, bounds.height)
        XCTAssertGreaterThan(SliderGeometry.channelHeight - 2 * SliderGeometry.wall, SliderGeometry.channelHeight / 2)
        XCTAssertEqual(SliderStyle.dotGrid.frameHeight, DotGridGeometry.frameHeight)
        XCTAssertGreaterThanOrEqual(SliderStyle.dotGrid.frameHeight, 48, "The Dot Grid is now a tall control, not the old 34 pt strip")
        XCTAssertEqual(SliderStyle.channel.frameHeight, SliderGeometry.frameHeight)
        XCTAssertEqual(SliderGeometry.ticks, SliderGeometry.ticks.sorted())
        XCTAssertTrue(SliderGeometry.ticks.allSatisfy { (0...100).contains($0) })
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
    /// A tall lattice, centred, with the handle standing proud of it and
    /// inside the frame.
    func testTallLatticeIsCentredAndHoldsTheHandle() {
        XCTAssertEqual(DotGridGeometry.columns(width: 344), 78)
        let grid = DotGridGeometry.grid(width: 344, height: DotGridGeometry.frameHeight)
        XCTAssertEqual(grid.minX, 16); XCTAssertEqual(grid.minY, 11)
        XCTAssertEqual(grid.width, 310.6, accuracy: 1e-9); XCTAssertEqual(grid.height, 26.6, accuracy: 1e-9)
        XCTAssertEqual(DotGridGeometry.rows, 7)
        XCTAssertEqual(DotGridGeometry.x(percent: 0, width: 344), 17.3, accuracy: 1e-9)
        XCTAssertEqual(DotGridGeometry.x(percent: 100, width: 344), 325.3, accuracy: 1e-9)
        XCTAssertEqual(DotGridGeometry.x(percent: 150, width: 344), DotGridGeometry.x(percent: 100, width: 344))
        XCTAssertEqual(DotGridGeometry.x(percent: .nan, width: 344), DotGridGeometry.x(percent: 0, width: 344))
        XCTAssertEqual(DotGridGeometry.thumb, CGSize(width: 9, height: 38))
        XCTAssertGreaterThan(DotGridGeometry.thumb.height, grid.height + 8, "The handle stands proud of the lattice")
        XCTAssertLessThanOrEqual(DotGridGeometry.thumb.height + 10, DotGridGeometry.frameHeight, "Room for the handle's shadow and frost")
        for width in [200.0, 344, 512] as [CGFloat] {
            for p in stride(from: 0.0, through: 100, by: 9) {
                XCTAssertEqual(DotGridGeometry.percent(atX: DotGridGeometry.x(percent: p, width: width), width: width), p, accuracy: 1e-9)
            }
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
        // Lit dots are drawn 1.25× larger and must never touch.
        XCTAssertLessThan(SliderEnergy.dotSize(percent: 100) * 1.25, DotGridGeometry.pitch - 0.5)
    }
}

final class RotorMotionTests: XCTestCase {
    private let expressive = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
    private let subtle = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)

    /// The rotors turn in proportion to the fan's actual RPM: one visual
    /// revolution per second per 2000 RPM, under the aliasing guard.
    func testSpinIsProportionalToActualRPM() {
        XCTAssertEqual(RotorMotion.revolutionsPerSecond(rpm: 1200), 0.6, accuracy: 1e-12)
        XCTAssertEqual(RotorMotion.revolutionsPerSecond(rpm: 4900), 2.45, accuracy: 1e-12)
        for rpm in stride(from: 100.0, through: 7900, by: 100) {
            XCTAssertEqual(RotorMotion.revolutionsPerSecond(rpm: rpm) / RotorMotion.revolutionsPerSecond(rpm: 1000), rpm / 1000, accuracy: 1e-9,
                           "Twice the RPM, twice the visual speed")
        }
        XCTAssertEqual(RotorMotion.revolutionsPerSecond(rpm: 20_000), RotorMotion.fastest, "Implausible telemetry is capped")
        // A five-blade rotor repeats every 72°: under 36° per 60 Hz frame
        // there is no wagon-wheel aliasing, even at the cap.
        XCTAssertLessThan(RotorMotion.fastest * 360 / 60, 36)
    }

    func testActualZeroOrUnknownStandsStill() {
        for rpm in [nil, 0, -5, .nan, .infinity] as [Double?] {
            XCTAssertEqual(RotorMotion.revolutionsPerSecond(rpm: rpm), 0)
        }
        XCTAssertFalse(RotorMotion.spins(visible: true, enabled: true, available: true, rpm: 0, effects: expressive), "A stopped fan stops the rotors")
    }

    /// Effects choose whether the rotors move, never how fast: speed stays
    /// proportional to the real fan at every level.
    func testEffectsGateMotionButNeverRescaleSpeed() {
        XCTAssertTrue(RotorMotion.spins(visible: true, enabled: true, available: true, rpm: 2400, effects: subtle))
        for effects in [EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false),
                        EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false),
                        EffectsProfile(level: .subtle, reduceMotion: true, reduceTransparency: true)] {
            XCTAssertEqual(effects.ambient, 0)
            XCTAssertFalse(RotorMotion.spins(visible: true, enabled: true, available: true, rpm: 2400, effects: effects))
        }
        XCTAssertEqual(EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: true).ambient, 1,
                       "Reduce Transparency dims light, not motion")
    }

    func testSpinsOnlyWhenShownEnabledAndFresh() {
        XCTAssertTrue(RotorMotion.spins(visible: true, enabled: true, available: true, rpm: 2400, effects: expressive))
        XCTAssertFalse(RotorMotion.spins(visible: false, enabled: true, available: true, rpm: 2400, effects: expressive))
        XCTAssertFalse(RotorMotion.spins(visible: true, enabled: false, available: true, rpm: 2400, effects: expressive))
        XCTAssertFalse(RotorMotion.spins(visible: true, enabled: true, available: false, rpm: 2400, effects: expressive))
        XCTAssertFalse(RotorMotion.spins(visible: true, enabled: true, available: true, rpm: nil, effects: expressive))
    }

    /// The Channel's rotor row: bounded, evenly spaced, inside the tube.
    func testChannelRotorRowIsBoundedAndInsideTheTube() {
        for width in [120.0, 312, 480] as [CGFloat] {
            let centres = SliderGeometry.rotorCenters(channelWidth: width), d = SliderGeometry.rotorDiameter
            XCTAssertFalse(centres.isEmpty); XCTAssertLessThanOrEqual(centres.count, 14)
            XCTAssertGreaterThanOrEqual(centres.first!.x - d / 2, 0); XCTAssertLessThanOrEqual(centres.last!.x + d / 2, width)
            XCTAssertTrue(centres.allSatisfy { $0.y == SliderGeometry.channelHeight / 2 })
            let gaps = zip(centres, centres.dropFirst()).map { $1.x - $0.x }
            XCTAssertTrue(gaps.allSatisfy { abs($0 - gaps[0]) < 1e-9 && $0 >= SliderGeometry.rotorPitch })
        }
        XCTAssertTrue(SliderGeometry.rotorCenters(channelWidth: 40).isEmpty, "No room, no rotors")
        XCTAssertLessThan(SliderGeometry.rotorDiameter, SliderGeometry.channelHeight - 2 * SliderGeometry.wall)
    }
}

final class IceFlowTests: XCTestCase {
    private let expressive = EffectsProfile(level: .expressive, reduceMotion: false, reduceTransparency: false)
    private let subtle = EffectsProfile(level: .subtle, reduceMotion: false, reduceTransparency: false)

    /// The full-cooling flow runs only for formed ice that is on screen,
    /// enabled, fresh and allowed to move.
    func testFlowRunsOnlyWhenFrozenVisibleAndAllowed() {
        XCTAssertTrue(IceFlow.runs(visible: true, enabled: true, available: true, frozen: true, effects: expressive))
        XCTAssertTrue(IceFlow.runs(visible: true, enabled: true, available: true, frozen: true, effects: subtle))
        XCTAssertFalse(IceFlow.runs(visible: true, enabled: true, available: true, frozen: false, effects: expressive), "Below 100% nothing loops")
        XCTAssertFalse(IceFlow.runs(visible: false, enabled: true, available: true, frozen: true, effects: expressive), "Hidden or Settings open")
        XCTAssertFalse(IceFlow.runs(visible: true, enabled: false, available: true, frozen: true, effects: expressive))
        XCTAssertFalse(IceFlow.runs(visible: true, enabled: true, available: false, frozen: true, effects: expressive), "Stale")
        for effects in [EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false),
                        EffectsProfile(level: .expressive, reduceMotion: true, reduceTransparency: false)] {
            XCTAssertFalse(IceFlow.runs(visible: true, enabled: true, available: true, frozen: true, effects: effects))
        }
    }

    /// Subtle is calmer (slower loops) and fainter.
    func testSubtleFlowsCalmerAndFainter() {
        XCTAssertEqual(IceFlow.pace(effects: expressive), 1)
        XCTAssertGreaterThan(IceFlow.pace(effects: subtle), 1.5)
        XCTAssertLessThan(IceFlow.strength(effects: subtle), IceFlow.strength(effects: expressive))
        XCTAssertEqual(IceFlow.strength(effects: EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false)), 0)
        XCTAssertTrue(IceFlow.pace(effects: EffectsProfile(level: .off, reduceMotion: false, reduceTransparency: false)).isFinite)
    }
}

final class IceCoverTests: XCTestCase {
    /// Formation needs an animated (visible) crossing and Expressive motion.
    func testFormationPlaysOnlyForVisibleCrossings() {
        XCTAssertTrue(IceCover.forms(animated: true, allowed: true))
        XCTAssertFalse(IceCover.forms(animated: false, allowed: true), "Keys, hidden and startup refreshes are instant")
        XCTAssertFalse(IceCover.forms(animated: true, allowed: false), "Subtle, Off and Reduce Motion never play it")
    }

    /// Total frost: the whole track is covered, thickest at the thumb end.
    func testIceCoversTheWholeTrack() {
        XCTAssertEqual(IceCover.weight(at: 0), IceCover.edge)
        XCTAssertGreaterThanOrEqual(IceCover.edge, 0.85, "Total frost: dense across the whole track, not huddled near the thumb")
        XCTAssertEqual(IceCover.weight(at: 1), 1)
        var previous = 0.0
        for f in stride(from: 0.0, through: 1, by: 0.02) {
            let w = IceCover.weight(at: f); XCTAssertGreaterThanOrEqual(w, previous); previous = w
        }
        XCTAssertEqual(IceCover.weight(at: -1), IceCover.edge); XCTAssertEqual(IceCover.weight(at: 3), 1)
        XCTAssertEqual(IceCover.weight(at: .nan), IceCover.edge)
    }

    /// The front crawls in spurts but always forward, over the whole track,
    /// and a formation that interrupts a melt continues from where it is.
    func testCrawlIsMonotonicAndResumable() {
        let crawl = IceCover.crawl
        XCTAssertEqual(crawl.first!.time, 0); XCTAssertEqual(crawl.first!.reach, 0)
        XCTAssertEqual(crawl.last!.time, 1); XCTAssertEqual(crawl.last!.reach, 1)
        XCTAssertTrue(zip(crawl, crawl.dropFirst()).allSatisfy { $1.time > $0.time && $1.reach >= $0.reach })
        let speeds = zip(crawl, crawl.dropFirst()).map { ($1.reach - $0.reach) / ($1.time - $0.time) }
        XCTAssertGreaterThan(speeds.max()! / speeds.min()!, 3, "Growth spurts, not a linear wipe")
        let resumed = IceCover.crawl(from: 0.5)
        XCTAssertEqual(resumed.first!.reach, 0.5); XCTAssertEqual(resumed.last!.reach, 1)
        XCTAssertEqual(resumed.map(\.time), crawl.map(\.time))
        XCTAssertEqual(IceCover.crawl(from: .nan).map(\.reach), crawl.map(\.reach))
        XCTAssertEqual(IceCover.crawl(from: 7).map(\.reach), Array(repeating: 1, count: crawl.count))
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
