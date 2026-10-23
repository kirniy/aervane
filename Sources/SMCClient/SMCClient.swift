import Foundation
import CSMC
#if canImport(Darwin)
import Darwin
#endif

public struct SMCReading: Sendable { public let key: String; public let dataType: UInt32; public let bytes: [UInt8] }
public enum SMCError: Error, CustomStringConvertible, LocalizedError {
    case readFailed(String, Int32), writeFailed(String, Int32)
    /// AppleSMC reports that the key does not exist.
    case notFound(String)
    public var description: String {
        switch self {
        case let .readFailed(k, c): return "AppleSMC read \(k) failed (\(Self.code(c)))"
        case let .writeFailed(k, c): return "AppleSMC write \(k) failed (\(Self.code(c)))"
        case let .notFound(k): return "AppleSMC key \(k) does not exist"
        }
    }
    /// IOKit returns are clearer in hex (e.g. 0xe00002c2 kIOReturnBadArgument).
    private static func code(_ value: Int32) -> String { value < -1000 ? String(format: "0x%08x", UInt32(bitPattern: value)) : String(value) }
    public var errorDescription: String? { description }
}

/// Raw AppleSMC access: single-key reads, single-key writes to fan control
/// registers, and the hardware identity. Decoding, sensor discovery and fan
/// control policy live in ZephyrCore.
public final class SMCReader: @unchecked Sendable {
    /// kIOReturnNotFound, returned by the C layer only for absent keys.
    static let notFoundCode = Int32(bitPattern: 0xE000_02F0)

    // The C connection is shared by all readers in this process and closes
    // when the process exits. Destroying one reader must not invalidate another.
    private let readOverride: ((String) throws -> SMCReading)?
    public init() { readOverride = nil }
    init(read: @escaping (String) throws -> SMCReading) { readOverride = read }

    /// `hw.model`, e.g. "Mac16,10" or "MacBookPro16,1".
    public static func hardwareModel() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
        #else
        return nil
        #endif
    }

    /// Whether the Mac itself is Apple Silicon. `hw.optional.arm64` is 1 on
    /// Apple Silicon even for a translated x86_64 process, so the SMC key
    /// set is chosen by the hardware, not by the running slice.
    public static func isAppleSiliconHardware() -> Bool {
        #if canImport(Darwin)
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        }
        return value == 1
        #else
        return false
        #endif
    }

    public func read(_ key: String) throws -> SMCReading {
        guard key.utf8.count == 4 else { throw SMCError.readFailed(key, -1) }
        if let readOverride { return try readOverride(key) }
        var bytes = [UInt8](repeating: 0, count: 32); var length = 0; var type: UInt32 = 0
        let result = bytes.withUnsafeMutableBytes { zsmc_read_key_name(key, $0.baseAddress, $0.count, &length, &type) }
        if result == Self.notFoundCode { throw SMCError.notFound(key) }
        guard result == 0 else { throw SMCError.readFailed(key, result) }
        return SMCReading(key: key, dataType: type, bytes: Array(bytes.prefix(length)))
    }

    /// Fan control registers only: F<n>Tg, F<n>Md, F<n>md (n = 0...9), the
    /// legacy FS! mask and the Ftst gate. Everything else is refused before
    /// reaching IOKit.
    public static func isWritableControlKey(_ key: String) -> Bool {
        let chars = Array(key.utf8)
        guard chars.count == 4 else { return false }
        if key == "FS! " || key == "Ftst" { return true }
        let suffix = String(decoding: chars[2...], as: UTF8.self)
        return chars[0] == UInt8(ascii: "F") && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(chars[1])
            && ["Tg", "Md", "md"].contains(suffix)
    }

    /// One write of exactly `bytes`; the C layer requires the key to exist
    /// with this type and length.
    public func writeControlKey(_ key: String, dataType: UInt32, bytes: [UInt8]) throws {
        guard Self.isWritableControlKey(key), !bytes.isEmpty, bytes.count <= 32 else { throw SMCError.writeFailed(key, -1) }
        let result = bytes.withUnsafeBytes { zsmc_write_key_name(key, $0.baseAddress, $0.count, dataType) }
        if result == Self.notFoundCode { throw SMCError.notFound(key) }
        guard result == 0 else { throw SMCError.writeFailed(key, result) }
    }
}
