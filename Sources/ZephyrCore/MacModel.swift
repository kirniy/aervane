import Foundation

/// Which AppleSMC generation the running Mac exposes. Chosen from the
/// hardware (sysctl `hw.optional.arm64`), not from the process slice, so a
/// translated x86_64 process on Apple Silicon still reads Apple Silicon keys.
public enum SMCPlatform: String, Codable, Sendable, Equatable {
    case appleSilicon, intel
}

/// A model identifier normalized the way the compatibility catalog does:
/// `Mac<major>,<minor>` aliases map to their family identifier, then the
/// family is the leading letters and the version is every digit as one
/// decimal integer ("MacBookPro18,3" → MacBookPro, 183).
public struct MacModel: Equatable, Sendable, CustomStringConvertible {
    public enum Family: String, CaseIterable, Sendable {
        case macBook = "MacBook", macBookAir = "MacBookAir", macBookNeo = "MacBookNeo", macBookPro = "MacBookPro"
        case iMac, iMacPro, macmini = "Macmini", macStudio = "MacStudio", macPro = "MacPro", xserve = "Xserve", adp = "ADP"
    }

    /// As reported by `hw.model`.
    public let identifier: String
    /// After the alias table.
    public let normalized: String
    public let familyName: String
    public let family: Family?
    public let version: Int?

    public init(identifier: String) {
        self.identifier = identifier
        normalized = HardwareCatalog.modelAliases[identifier] ?? identifier
        let parts = Self.split(normalized)
        familyName = parts.0; version = parts.1
        family = Family(rawValue: parts.0)
    }

    public var description: String { normalized == identifier ? identifier : "\(identifier) (\(normalized))" }

    static func split(_ identifier: String) -> (String, Int?) {
        let isDigit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
        let letters = String(identifier.prefix { !isDigit($0) })
        let digits = identifier.filter(isDigit)
        // Real identifiers have at most four digits; anything longer is not a model.
        return (letters, digits.isEmpty || digits.count > 6 ? nil : Int(digits))
    }

    private func isFamily(_ family: Family, _ test: (Int) -> Bool) -> Bool {
        guard self.family == family, let version else { return false }
        return test(version)
    }

    // Static model predicates from control-keys.json. Each is evidence about
    // a model; none replaces reading the hardware.

    /// The model's manual-control path also uses the verified `Ftst` gate
    /// after its per-fan mode writes and before target writes.
    public var requiresFtst: Bool { isFamily(.macBookPro) { $0 > 201 } }
    /// The model's per-fan mode key is spelled `F<n>md`.
    public var requiresLowercaseMode: Bool { isFamily(.macBookPro) { $0 > 220 } || isFamily(.macStudio) { $0 > 30 } }
    /// The vendor marks control as not working on these models.
    public var vendorReportsControlNotWorking: Bool { isFamily(.macBookPro) { (202...215).contains($0) } }
    public var hasNoFans: Bool {
        isFamily(.macBook) { [81, 91, 101].contains($0) } || isFamily(.macBookAir) { $0 > 100 } || family == .macBookNeo
    }
}

/// One selector term of a catalog model list: "all", "MacBookPro18,1" or
/// "MacBookPro18,1+" (that version and newer in the same family). Family
/// names compare exactly, as written in the catalog.
public struct ModelSelector: Equatable, Sendable {
    public let terms: [(family: String, version: Int, orNewer: Bool)]?

    public init(_ text: String) {
        guard text != "all" else { terms = nil; return }
        terms = text.split(separator: ";").compactMap { raw in
            let orNewer = raw.hasSuffix("+")
            let (family, version) = MacModel.split(String(orNewer ? raw.dropLast() : raw))
            return version.map { (family, $0, orNewer) }
        }
    }

    public var matchesAll: Bool { terms == nil }

    public func matches(_ model: MacModel?) -> Bool {
        guard let terms else { return true }
        guard let model, let version = model.version else { return false }
        return terms.contains { $0.family == model.familyName && ($0.orNewer ? version >= $0.version : version == $0.version) }
    }

    public static func == (lhs: ModelSelector, rhs: ModelSelector) -> Bool {
        switch (lhs.terms, rhs.terms) {
        case (nil, nil): return true
        case let (a?, b?): return a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
        default: return false
        }
    }
}
