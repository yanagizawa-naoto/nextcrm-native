import Foundation

struct NativeTargetSpreadsheetParserTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("reference.json"))
        let source = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cases = source["parser"] as! [[String: Any]]
        var output: [[String: Any]] = []
        for item in cases {
            var header: [String] = [], rows: [[[String: Any]]] = []
            do {
                if (item["file"] as! String).hasSuffix(".csv") {
                try NativeTargetSpreadsheetCSVReader.parse(url: root.appendingPathComponent("source-fixtures/" + (item["file"] as! String)), headers: { header = $0 }, row: { row in
                    rows.append(row.entries.map { entry in ["name": entry.name, "value": entry.text.map { $0 as Any } ?? (entry.extra! as Any)] })
                })
                } else {
                    let draft = try NativeTargetSpreadsheetDraft()
                    try NativeTargetSpreadsheetXLSXReader.parse(url: root.appendingPathComponent("source-fixtures/" + (item["file"] as! String)), draft: draft, timeZone: (item["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!, numberText: NativePluginJSON.numberString)
                    header = try draft.allHeaders()
                    var offset: Int64 = -1
                    while offset < draft.rowCount - 1 {
                        try draft.rows(after: offset) { position, row in
                            offset = position
                            rows.append(row.entries.map { entry in ["name": entry.name, "value": entry.text.map { $0 as Any } ?? (entry.extra! as Any)] })
                        }
                    }
                }
                output.append(["id": item["id"]!, "headers": header, "rows": rows])
            } catch { output.append(["id": item["id"]!, "error": error.localizedDescription]) }
        }
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("parser-actual.json"))
        print("CSV/XLSX parser cases: \(output.count)")
    }
}
