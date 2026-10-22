import Foundation
import ZephyrCore

public final class HelperClient: NSObject, @unchecked Sendable {
    public static let serviceName = "dev.kirniy.aervane.helper"
    private static let requestTimeout: TimeInterval = 5

    private let connection: NSXPCConnection
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    private var activated = false
    private var disconnectNotified = false
    private var configurationError: Error?
    private var disconnectHandler: (() -> Void)?

    public convenience init(serviceName: String = HelperClient.serviceName) {
        self.init(serviceName: serviceName,
                  requirementProvider: { SigningRequirement.requirement(identifier: "dev.kirniy.aervane.helper") })
    }

    init(serviceName: String, requestTimeout: TimeInterval = HelperClient.requestTimeout,
         requirementProvider: @escaping () -> String?) {
        connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        self.requestTimeout = requestTimeout
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in self?.notifyDisconnected() }
        connection.interruptionHandler = { [weak self] in self?.notifyDisconnected() }
        guard let requirement = requirementProvider() else {
            configurationError = FanControlError.unauthorized
            return
        }
        connection.setCodeSigningRequirement(requirement)
    }

    public var onDisconnect: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return disconnectHandler }
        set { lock.lock(); disconnectHandler = newValue; lock.unlock() }
    }

    public func snapshot(_ reply: @escaping (Result<FanSnapshot, Error>) -> Void) {
        perform(reply) { remote, completion in remote.snapshot(withReply: completion) }
    }

    public func set(percent: Double, _ reply: @escaping (Result<FanSnapshot, Error>) -> Void) {
        perform(reply) { remote, completion in remote.setFanPercent(percent, withReply: completion) }
    }

    public func automatic(_ reply: @escaping (Result<FanSnapshot, Error>) -> Void) {
        perform(reply) { remote, completion in remote.restoreAutomatic(withReply: completion) }
    }

    public func heartbeat(_ reply: @escaping (Error?) -> Void = { _ in }) {
        if let readyError = ensureReady() { reply(readyError); return }
        let gate = HelperReplyGate<Error?>(timeout: requestTimeout) { [weak self] in
            self?.invalidate()
            reply(FanControlError.unavailable)
        }
        guard let remote = proxy(error: { error in gate.finish(error) { reply($0) } }) else {
            gate.finish(FanControlError.unavailable) { reply($0) }
            return
        }
        remote.heartbeat { error in gate.finish(error) { reply($0) } }
    }

    public func invalidate() { connection.invalidate() }

    private func perform(_ reply: @escaping (Result<FanSnapshot, Error>) -> Void,
                         _ invoke: @escaping (FanControlXPCProtocol, @escaping (Data?, Error?) -> Void) -> Void) {
        if let readyError = ensureReady() { reply(.failure(readyError)); return }
        let gate = HelperReplyGate<Result<FanSnapshot, Error>>(timeout: requestTimeout) { [weak self] in
            self?.invalidate()
            reply(.failure(FanControlError.unavailable))
        }
        guard let remote = proxy(error: { error in gate.finish(.failure(error)) { reply($0) } }) else {
            gate.finish(.failure(FanControlError.unavailable)) { reply($0) }
            return
        }
        invoke(remote) { data, error in gate.finish(Self.decode(data, error)) { reply($0) } }
    }

    private func ensureReady() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if let configurationError { return configurationError }
        if !activated {
            connection.activate()
            activated = true
        }
        return nil
    }

    private func proxy(error: @escaping (Error) -> Void) -> FanControlXPCProtocol? {
        connection.remoteObjectProxyWithErrorHandler(error) as? FanControlXPCProtocol
    }

    private func notifyDisconnected() {
        lock.lock()
        guard !disconnectNotified else { lock.unlock(); return }
        disconnectNotified = true
        let handler = disconnectHandler
        lock.unlock()
        handler?()
    }

    private static func decode(_ data: Data?, _ error: Error?) -> Result<FanSnapshot, Error> {
        if let error { return .failure(error) }
        guard let data else { return .failure(FanControlError.unavailable) }
        do { return .success(try JSONDecoder().decode(FanSnapshot.self, from: data)) }
        catch { return .failure(error) }
    }
}

internal final class HelperReplyGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var timeoutWork: DispatchWorkItem?
    private let timeout: TimeInterval
    private let onTimeout: () -> Void

    init(timeout: TimeInterval, onTimeout: @escaping () -> Void) {
        self.timeout = timeout
        self.onTimeout = onTimeout
        // The deadline owns the gate even if XPC drops its reply closures.
        // Break the temporary cycle on either completion path below.
        let work = DispatchWorkItem { self.timeoutFired() }
        timeoutWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func finish(_ value: Value, _ deliver: @escaping (Value) -> Void) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        deliver(value)
    }

    private func timeoutFired() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        timeoutWork = nil
        lock.unlock()
        onTimeout()
    }
}
