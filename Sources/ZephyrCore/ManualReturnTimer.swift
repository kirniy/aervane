import Foundation

/// An opt-in user timer, separate from the helper's connection watchdog.
/// With the default disabled, elapsed time never ends manual control.
public struct ManualReturnTimer: Equatable, Sendable {
    public private(set) var enabled: Bool
    public private(set) var minutes: Double
    public private(set) var deadline: Date?

    public init(enabled: Bool = false, minutes: Double = 30) {
        self.enabled = enabled
        self.minutes = Self.boundedMinutes(minutes)
    }

    public mutating func configure(enabled: Bool, minutes: Double, manual: Bool, now: Date) {
        let minutes = Self.boundedMinutes(minutes)
        guard self.enabled != enabled || self.minutes != minutes else { return }
        self.enabled = enabled
        self.minutes = minutes
        if manual { start(now: now) } else { cancel() }
    }

    public mutating func start(now: Date) {
        deadline = enabled ? now.addingTimeInterval(minutes * 60) : nil
    }

    public mutating func cancel() { deadline = nil }

    public func isDue(now: Date) -> Bool { deadline.map { now >= $0 } ?? false }

    private static func boundedMinutes(_ value: Double) -> Double {
        guard value.isFinite else { return 30 }
        return min(120, max(5, (value / 5).rounded() * 5))
    }
}
