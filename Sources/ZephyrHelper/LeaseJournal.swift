import Foundation
import ZephyrCore

/// A deliberately narrow journal for recovery after a helper restart. The
/// default location is root-owned state under /var/db; tests can inject a
/// temporary URL. It never accepts a caller-provided path over XPC.
enum LeaseJournalPhase: String, Codable { case beforeWrite, afterWrite }

/// What the lease meant for one fan. Percentages are of that fan's own maximum.
struct FanLeaseRecord: Codable, Equatable {
    let index: Int
    /// The target the fan held before the write (the firmware's own target
    /// when it was automatic). Matches it only during `beforeWrite`.
    let previousTargetPercent: Double?
    /// The target this lease commands: max(requested, the fan's floor).
    let intendedTargetPercent: Double
}

/// Schema 1 (no `schemaVersion`) described fan 0 only. Schema 2 adds one
/// record per participating fan and keeps the schema 1 fields filled from
/// fan 0, so an older helper still reads it.
struct LeaseJournal: Codable, Equatable {
    static let currentSchema = 2

    let sessionID: UUID
    let previousTargetPercent: Double?
    let intendedPercent: Double
    let phase: LeaseJournalPhase
    let processID: Int32
    var schemaVersion: Int? = nil
    var fans: [FanLeaseRecord]? = nil
    /// Ftst state observed before the transaction, when present. Nil is the
    /// backward-compatible format used by helpers that predate Ftst support.
    var aggregateGate: Bool? = nil

    static let defaultURL = URL(fileURLWithPath: "/var/db/dev.kirniy.aervane/lease.json")

    /// A schema 2 record for every fan in `fans`.
    init(sessionID: UUID, requestedPercent: Double, phase: LeaseJournalPhase, processID: Int32,
         fans: [FanReading], previousTargets: [Int: Double], aggregateGate: Bool? = nil) {
        let records = fans.map { FanLeaseRecord(index: $0.index, previousTargetPercent: previousTargets[$0.index],
                                                intendedTargetPercent: FanSafety.expectedPercent(requestedPercent, fan: $0)) }
        self.init(sessionID: sessionID, previousTargetPercent: records.first?.previousTargetPercent,
                  intendedPercent: requestedPercent, phase: phase, processID: processID,
                  schemaVersion: Self.currentSchema, fans: records, aggregateGate: aggregateGate)
    }

    init(sessionID: UUID, previousTargetPercent: Double?, intendedPercent: Double, phase: LeaseJournalPhase,
         processID: Int32, schemaVersion: Int? = nil, fans: [FanLeaseRecord]? = nil, aggregateGate: Bool? = nil) {
        self.sessionID = sessionID; self.previousTargetPercent = previousTargetPercent
        self.intendedPercent = intendedPercent; self.phase = phase; self.processID = processID
        self.schemaVersion = schemaVersion; self.fans = fans; self.aggregateGate = aggregateGate
    }

    /// The per-fan view for recovery. A schema 1 entry describes fan 0 of a
    /// single-fan Mac (the old helper refused every other topology), so on
    /// any other topology it cannot be attributed and yields nil.
    func records(currentFanCount: Int) -> [FanLeaseRecord]? {
        if let fans { return fans }
        guard currentFanCount == 1 else { return nil }
        // The old intended value was not floor-clamped; recovery clamps it.
        return [FanLeaseRecord(index: 0, previousTargetPercent: previousTargetPercent, intendedTargetPercent: intendedPercent)]
    }

    var isLegacy: Bool { fans == nil }

    func validate() throws {
        func valid(_ value: Double) -> Bool { value.isFinite && (0...100).contains(value) }
        guard valid(intendedPercent), previousTargetPercent.map(valid) ?? true else { throw FanControlError.invalidPercent }
        if schemaVersion == nil && fans == nil { return }
        // An unknown or incomplete schema is never interpreted as ownership.
        guard schemaVersion == Self.currentSchema, let fans else { throw FanControlError.unauthorized }
        guard (1...FanInventoryReader.maximumFans).contains(fans.count),
              Set(fans.map(\.index)).count == fans.count,
              fans.allSatisfy({ (0..<FanInventoryReader.maximumFans).contains($0.index) && valid($0.intendedTargetPercent)
                  && ($0.previousTargetPercent.map(valid) ?? true) }) else { throw FanControlError.invalidPercent }
    }

    func write(to url: URL = defaultURL, fileManager: FileManager = .default, requireRootOwner: Bool = true) throws {
        try validate()
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [FileAttributeKey.posixPermissions: 0o700])
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == (requireRootOwner ? 0 : Int(geteuid())) else {
            throw FanControlError.unauthorized
        }
        if fileManager.fileExists(atPath: url.path) {
            _ = try Self.read(from: url, fileManager: fileManager, requireRootOwner: requireRootOwner)
        }
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(from url: URL = defaultURL, fileManager: FileManager = .default,
                     requireRootOwner: Bool = true) throws -> LeaseJournal? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (!requireRootOwner || (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0) else {
            throw FanControlError.unauthorized
        }
        let journal = try JSONDecoder().decode(LeaseJournal.self, from: Data(contentsOf: url))
        try journal.validate()
        return journal
    }

    static func remove(at url: URL = defaultURL, fileManager: FileManager = .default,
                       requireRootOwner: Bool = true) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        _ = try read(from: url, fileManager: fileManager, requireRootOwner: requireRootOwner)
        try fileManager.removeItem(at: url)
    }
}
