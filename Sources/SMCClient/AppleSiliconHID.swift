import Foundation
import Darwin
import ZephyrCore

/// Read-only HID temperature events. All private entry points are optional:
/// an OS without this interface keeps the SMC path. CF Create/Copy ownership
/// is balanced, and retained service objects live as long as the client.
public final class AppleSiliconHIDSource: TemperatureSensors.HIDSource, @unchecked Sendable {
    public static let cpuNames = ["eACC MTR Temp Sensor0", "eACC MTR Temp Sensor3", "pACC MTR Temp Sensor2", "pACC MTR Temp Sensor3", "pACC MTR Temp Sensor4", "pACC MTR Temp Sensor5", "pACC MTR Temp Sensor7", "pACC MTR Temp Sensor8", "pACC MTR Temp Sensor9"]
    public static let gpuNames = ["GPU MTR Temp Sensor1", "GPU MTR Temp Sensor4"]
    private let api: API?
    private let client: AnyObject?
    private let services: [String: AnyObject]
    private let lock = NSLock()

    public init() {
        let api = API.load()
        self.api = api
        guard let api, let pointer = api.create(nil) else { client = nil; services = [:]; return }
        let client = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        self.client = client
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = api.match(pointer, Unmanaged.passUnretained(matching).toOpaque())
        guard let arrayPointer = api.services(pointer) else { services = [:]; return }
        let arrayObject = Unmanaged<AnyObject>.fromOpaque(arrayPointer).takeRetainedValue()
        let array = unsafeBitCast(arrayObject, to: CFArray.self)
        let wanted = Set(Self.cpuNames + Self.gpuNames)
        var result: [String: AnyObject] = [:]
        let product = "Product" as CFString
        for index in 0..<CFArrayGetCount(array) {
            guard let value = CFArrayGetValueAtIndex(array, index),
                  let property = api.property(value, Unmanaged.passUnretained(product).toOpaque()) else { continue }
            let nameObject = Unmanaged<AnyObject>.fromOpaque(property).takeRetainedValue()
            guard let name = nameObject as? String, wanted.contains(name) else { continue }
            result[name] = Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        }
        services = result
    }

    public func sensorNames(for kind: SensorKind) -> [String] {
        (kind == .cpu ? Self.cpuNames : Self.gpuNames).filter { services[$0] != nil }
    }
    public func hasSensors(for kind: SensorKind) -> Bool { !sensorNames(for: kind).isEmpty }

    public func read(_ kind: SensorKind) throws -> [Double] {
        lock.lock(); defer { lock.unlock() }
        guard let api, client != nil else { throw HIDError.unavailable }
        let names = sensorNames(for: kind)
        guard !names.isEmpty else { throw HIDError.unavailable }
        return try names.map { name in
            let service = services[name]!
            guard let pointer = api.event(Unmanaged.passUnretained(service).toOpaque(), 15, 0, 0) else {
                throw HIDError.eventUnavailable(name)
            }
            let event = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
            // IOHIDFloat is double on both supported 64-bit architectures.
            return withExtendedLifetime(event) { api.value(pointer, 0xf0000) }
        }
    }

    public enum HIDError: Error, LocalizedError {
        case unavailable, eventUnavailable(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "HID temperature services are unavailable."
            case .eventUnavailable(let name): return "Temperature sensor \(name) did not provide an event."
            }
        }
    }

    private struct API {
        typealias Create = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
        typealias Match = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
        typealias Services = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
        typealias Property = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
        typealias Event = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
        typealias Value = @convention(c) (UnsafeRawPointer, Int32) -> Double
        let create: Create; let match: Match; let services: Services
        let property: Property; let event: Event; let value: Value
        // One process-lifetime framework handle. No per-poll dlopen or lookup.
        static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL)
        static func load() -> API? {
            guard let handle else { return nil }
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                guard let address = dlsym(handle, name) else { return nil }
                return unsafeBitCast(address, to: T.self)
            }
            guard let create = symbol("IOHIDEventSystemClientCreate", Create.self),
                  let match = symbol("IOHIDEventSystemClientSetMatching", Match.self),
                  let services = symbol("IOHIDEventSystemClientCopyServices", Services.self),
                  let property = symbol("IOHIDServiceClientCopyProperty", Property.self),
                  let event = symbol("IOHIDServiceClientCopyEvent", Event.self),
                  let value = symbol("IOHIDEventGetFloatValue", Value.self) else { return nil }
            return API(create: create, match: match, services: services, property: property, event: event, value: value)
        }
    }
}
