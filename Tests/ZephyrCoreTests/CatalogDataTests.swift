import XCTest
@testable import ZephyrCore

/// The embedded catalog must equal the reviewed exports row by row. The
/// app never reads these files; only this test does, from the source tree.
final class CatalogDataTests: XCTestCase {
    private func csv(_ name: String) throws -> [[String: String]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/compatibility/mfc-1.5.21/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name) is not in this checkout") }
        let rows = Self.parse(try String(contentsOf: url, encoding: .utf8))
        guard let header = rows.first else { return [] }
        return rows.dropFirst().filter { $0.count == header.count }.map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
    }

    /// RFC 4180 subset: quoted fields, doubled quotes, LF or CRLF.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var iterator = Array(text).makeIterator(), pending: Character?
        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else { field.append(char) }
            } else if char == "\"" { quoted = true }
            else if char == "," { row.append(field); field = "" }
            else if char == "\n" || char == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if char != "\r" { field.append(char) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private func attribute(_ json: String, _ name: String) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        return object?[name]
    }

    func testSensorRowsMatchTheExportExactly() throws {
        let rows = try csv("sensors-by-model.csv").filter { $0["kind"] == "smc" }
        XCTAssertEqual(rows.count, 385)
        XCTAssertEqual(HardwareCatalog.sensorRows.count, rows.count)
        for (row, embedded) in zip(rows, HardwareCatalog.sensorRows) {
            let context = "\(row["models"]!) \(row["key"]!)"
            XCTAssertEqual(embedded.resource.rawValue, row["resource"], context)
            XCTAssertEqual(embedded.models, row["models"], context)
            XCTAssertEqual(embedded.key, row["key"], context)
            XCTAssertEqual(embedded.group, row["group"], context)
            XCTAssertEqual(embedded.label, row["label"], context)
            XCTAssertEqual(embedded.role.rawValue, try attribute(row["attrs"]!, "type") ?? "", context)
            XCTAssertEqual(embedded.excluded, try attribute(row["attrs"]!, "exclude") == "1", context)
            XCTAssertEqual(embedded.optional, try attribute(row["attrs"]!, "add_no_fail") == "1", context)
            XCTAssertEqual(embedded.key, try attribute(row["attrs"]!, "name"), context)
        }
    }

    func testAliasesAndFanRowsMatchTheExport() throws {
        let aliases = try csv("model-aliases.csv")
        XCTAssertEqual(aliases.count, 46)
        XCTAssertEqual(HardwareCatalog.modelAliases.count, aliases.count)
        for alias in aliases { XCTAssertEqual(HardwareCatalog.modelAliases[alias["from"]!], alias["to"]) }

        let fans = try csv("fans-by-model.csv")
        XCTAssertEqual(HardwareCatalog.fanRows.count, fans.count)
        for (row, embedded) in zip(fans, HardwareCatalog.fanRows) {
            XCTAssertEqual(embedded.models, row["models"]); XCTAssertEqual("fan\(embedded.fan)", row["fan"]); XCTAssertEqual(embedded.label, row["label"])
        }
    }

    func testEveryCatalogSelectorParses() {
        for selector in HardwareCatalog.selectors where selector != "all" {
            let parsed = ModelSelector(selector)
            XCTAssertEqual(parsed.terms?.count, selector.split(separator: ";").count, selector)
        }
    }
}
