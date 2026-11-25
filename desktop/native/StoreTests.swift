import Foundation
import Darwin

@main
struct StoreTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw StoreError.message("Test failed: " + message) }
    }
    static func main() {
        umask(0o077)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nextcrm-native-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let url = directory.appendingPathComponent("accounts.sqlite")
            var db: AccountStore? = try AccountStore(url: url)
            try require(try db!.page().total == 0, "empty database")
            var row = Account(); row.name = "株式会社ＡＢＣ 日本語🙂"; row.email = "info@example.jp"; row.phone = "03-1234-5678"
            row.notes = "改行を含むメモ\n日本語と絵文字🙂"; row.street = "丸の内1-2-3"; row.sourceJSON = "{\"unmodeledField\":123}"
            let saved = try db!.save(row)
            try require(saved.revision == 1, "initial revision")
            try require(try db!.page(search: "abc").total == 1, "width/case insensitive search")
            try require(try db!.page().rows[0].notes.isEmpty, "list omits large notes")
            try require(try db!.page().rows[0].sourceJSON == "{}", "list omits source JSON")
            db = nil
            db = try AccountStore(url: url)
            try require(try db!.get(saved.id) == saved, "restart preserves full record")
            let other = try AccountStore(url: url)
            var fresh = saved; fresh.name += " 更新"; let updated = try db!.save(fresh)
            do { _ = try other.save(saved); throw StoreError.message("stale write was accepted") }
            catch StoreError.message(let text) { try require(text.contains("別の操作"), "stale edit protection") }
            try require(try db!.get(saved.id)?.revision == updated.revision, "revision persisted")
            var literal = Account(); literal.name = "100%_確認\\会社"; literal.status = "Inactive"
            _ = try db!.save(literal)
            try require(try db!.page(search: "%_").total == 1, "LIKE metacharacters are literal")
            try require(try db!.page(search: "' OR 1=1 --").total == 0, "query binding")
            try require(try db!.page(status: "Inactive").total == 1, "status filter")
            var invalid = Account(); invalid.name = "   "
            do { _ = try db!.save(invalid); throw StoreError.message("empty name accepted") }
            catch StoreError.message(let text) { try require(text.contains("会社名"), "empty name rejected") }

            let input = directory.appendingPathComponent("import.jsonl")
            FileManager.default.createFile(atPath: input.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: input)
            var ids: [String] = []
            for i in 0..<10003 {
                let id = UUID().uuidString.lowercased(); ids.append(id)
                let source: [String: Any] = ["id": id, "name": String(format: "検証用株式会社%05d", i), "status": "Active",
                                           "description": String(repeating: "保存する日本語メモ", count: 50), "custom": ["keep": true]]
                try output.write(contentsOf: JSONSerialization.data(withJSONObject: source)); try output.write(contentsOf: Data([10]))
            }
            try output.close()
            try require(try db!.importJSONLines(input) == 10003, "stream import count")
            try require(try db!.importJSONLines(input) == 0, "re-import does not overwrite")
            let first = try db!.page(search: "検証用株式会社")
            let last = try db!.page(search: "検証用株式会社", index: 100)
            try require(first.total == 10003 && first.rows.count == 100, "bounded first page")
            try require(last.rows.count == 3 && last.rows[2].name == "検証用株式会社10002", "last page")
            try require(try db!.get(ids[0])!.sourceJSON.contains("custom"), "preserves unmodeled source fields")
            let bad = directory.appendingPathComponent("bad.jsonl")
            let goodRow: [String: Any] = ["id": UUID().uuidString.lowercased(), "name": "失敗時に残らない"]
            var malformed = try JSONSerialization.data(withJSONObject: goodRow); malformed.append(Data("\n{broken}\n".utf8)); try malformed.write(to: bad)
            do { _ = try db!.importJSONLines(bad); throw StoreError.message("bad import accepted") }
            catch { try require(try db!.page(search: "失敗時に残らない").total == 0, "import transaction rollback") }
            let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            try require(mode == 0o600, "private database permissions")
            print("{\"ok\":true,\"bulkRecords\":10003,\"pageSize\":100,\"checks\":18}")
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
}
