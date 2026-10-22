import Foundation

/// Serializes user fan requests on the app side. One helper command is in
/// flight at a time; while it runs, later requests coalesce to the newest
/// intent. Auto is a request like any other: it is never lost behind an
/// older speed, and only a newer user request can replace it.
public struct ControlRequestQueue: Equatable, Sendable {
    public enum Command: Equatable, Sendable { case set(Double), automatic }

    public private(set) var inFlight: Command?
    public private(set) var queued: Command?

    public init() {}

    /// Returns the command to send now, or nil when it was queued behind the
    /// command in flight.
    public mutating func submit(_ command: Command) -> Command? {
        guard inFlight != nil else { inFlight = command; return command }
        // The newest intent replaces anything queued. If it equals the
        // command already running, nothing more needs to be sent.
        queued = command == inFlight ? nil : command
        return nil
    }

    /// Completes the command in flight. Returns the next command to send.
    public mutating func finish() -> Command? {
        inFlight = queued
        queued = nil
        return inFlight
    }

    /// Drops everything, e.g. when the helper connection is lost. Returns
    /// whether Auto had been requested, so the caller can honour it.
    public mutating func reset() -> Bool {
        let wantedAuto = inFlight == .automatic || queued == .automatic
        inFlight = nil; queued = nil
        return wantedAuto
    }

    public var isBusy: Bool { inFlight != nil }
    public var pendingPercent: Double? {
        if case .set(let value) = queued { return value }
        if queued == nil, case .set(let value) = inFlight { return value }
        return nil
    }
}
