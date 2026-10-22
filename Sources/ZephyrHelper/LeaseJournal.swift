import Foundation
import ZephyrCore

/// A deliberately narrow journal for recovery after a helper restart. The
/// default location is root-owned state under /var/db; tests can inject a
/// temporary URL. It never accepts a caller-provided path over XPC.
enum LeaseJournalPhase: String, Codable { case beforeWrite, afterWrite }

struct LeaseJournal: Codable, Equatable {
    let sessionID: UUID
    let previousTargetPercent: Double?
    let intendedPercent: Double
    let phase: LeaseJournalPhase
    let processID: Int32

    static let defaultURL = URL(fileURLWithPath: "/var/db/dev.kirniy.aervane/lease.json")

    func write(to url: URL = defaultURL, fileManager: FileManager = .default, requireRootOwner: Bool = true) throws {
        guard intendedPercent.isFinite, (0...100).contains(intendedPercent) else { throw FanControlError.invalidPercent }
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
        guard journal.intendedPercent.isFinite, (0...100).contains(journal.intendedPercent),
              journal.previousTargetPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true else {
            throw FanControlError.invalidPercent
        }
        return journal
    }

    static func remove(at url: URL = defaultURL, fileManager: FileManager = .default,
                       requireRootOwner: Bool = true) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        _ = try read(from: url, fileManager: fileManager, requireRootOwner: requireRootOwner)
        try fileManager.removeItem(at: url)
    }
}
