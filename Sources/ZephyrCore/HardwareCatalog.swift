import Foundation

/// One AppleSMC sensor row of the embedded compatibility catalog.
public struct CatalogSensorRow: Sendable, Equatable {
    public enum Resource: String, Sendable { case legacy = "smcSensors-legacy", appleSilicon = "smcSensors-arm" }
    public enum Role: String, Sendable { case cpu, gpu, psu, ssd, airport, opticalDrive = "odd", other = "" }

    public let resource: Resource
    let selectorIndex: Int
    public let key: String
    public let role: Role
    /// The catalog's averaging group ("CPU Core Average"), or empty.
    public let group: String
    public let label: String
    /// Removes this key for the selected models, even when an "all" row adds it.
    public let excluded: Bool
    /// `add_no_fail`: the vendor keeps the sensor when it cannot be read.
    public let optional: Bool

    init(_ resource: Resource, _ selectorIndex: Int, _ key: String, _ role: Role,
         group: String, label: String, excluded: Bool = false, optional: Bool = false) {
        self.resource = resource; self.selectorIndex = selectorIndex; self.key = key; self.role = role
        self.group = group; self.label = label; self.excluded = excluded; self.optional = optional
    }

    public var models: String { HardwareCatalog.selectors[selectorIndex] }
    var selector: ModelSelector { HardwareCatalog.parsedSelectors[selectorIndex] }
}

public struct CatalogFanRow: Sendable, Equatable {
    public let models: String
    public let fan: Int
    public let label: String
}

/// Read-only queries over the embedded tables (HardwareCatalogData.swift).
/// Nothing is loaded from disk at run time.
public enum HardwareCatalog {
    static let parsedSelectors: [ModelSelector] = selectors.map(ModelSelector.init)

    /// Rows of the platform's table that apply to `model`, in catalog order.
    /// Without a model only the "all" rows apply.
    public static func rows(for model: MacModel?, platform: SMCPlatform) -> [CatalogSensorRow] {
        let resource: CatalogSensorRow.Resource = platform == .appleSilicon ? .appleSilicon : .legacy
        return sensorRows.filter { $0.resource == resource && $0.selector.matches(model) }
    }

    /// The vendor's position label for a fan ("Left side"), if catalogued.
    public static func fanLabel(model: MacModel?, fan: Int) -> String? {
        guard let model else { return nil }
        return fanRows.first { $0.fan == fan && ModelSelector($0.models).matches(model) }?.label
    }
}

public enum SensorKind: String, Codable, Sendable, CaseIterable {
    case cpu, gpu
    var role: CatalogSensorRow.Role { self == .cpu ? .cpu : .gpu }
}

/// The ordered sensor candidates for one kind on one Mac.
public struct SensorPlan: Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Rows mapped for this model (including the catalog's "all" rows).
        case catalog
        /// No mapped rows: every key the platform table only ever uses for
        /// this kind, probed for presence. Keys the table also uses for any
        /// other role are left out, so an unrelated sensor is never
        /// substituted.
        case fallback
        /// Exact catalog service names, read through Apple Silicon HID events.
        case hid
    }
    public struct Candidate: Equatable, Sendable {
        public let key: String
        public let label: String
        /// Per-core or per-cluster sensors. When any is present, only these
        /// are used; otherwise the single best package-level sensor is.
        public let perCore: Bool
        /// Package-level preference: die/PECI first, heatsink last.
        public let rank: Int
        public let optional: Bool
    }

    public let kind: SensorKind
    public let source: Source
    public let candidates: [Candidate]

    public static func make(kind: SensorKind, model: MacModel?, platform: SMCPlatform) -> SensorPlan {
        let applicable = HardwareCatalog.rows(for: model, platform: platform)
        let excluded = Set(applicable.filter(\.excluded).map(\.key))
        let mapped = unique(applicable.filter { $0.role == kind.role && !$0.excluded && !excluded.contains($0.key) })
        if !mapped.isEmpty { return SensorPlan(kind: kind, source: .catalog, candidates: mapped.map(candidate)) }

        let resource: CatalogSensorRow.Resource = platform == .appleSilicon ? .appleSilicon : .legacy
        let table = HardwareCatalog.sensorRows.filter { $0.resource == resource }
        let otherRoles = Set(table.filter { $0.role != kind.role }.map(\.key))
        let fallback = unique(table.filter { $0.role == kind.role && !$0.excluded && !otherRoles.contains($0.key) })
        return SensorPlan(kind: kind, source: .fallback, candidates: fallback.map(candidate))
    }

    private static func unique(_ rows: [CatalogSensorRow]) -> [CatalogSensorRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.key).inserted }
    }

    private static func candidate(_ row: CatalogSensorRow) -> Candidate {
        let label = row.label.lowercased()
        let perCore = !row.group.isEmpty || label.contains("core") || label.contains("cluster")
        let rank = label.contains("peci") || label.contains("diode") ? 0
            : label.contains("proximity") ? 1 : label.contains("heatsink") ? 3 : 2
        return Candidate(key: row.key, label: row.label, perCore: perCore, rank: rank, optional: row.optional)
    }
}
