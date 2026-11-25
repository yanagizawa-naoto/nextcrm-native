import Foundation

/// Separate synthetic benchmark data; never writes the user's application-support directory.
@main enum BenchmarkFixture {
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("BenchmarkFixture: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let input = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let folder = resources.appendingPathComponent("../artifacts/native-crm-benchmark-1000").standardizedFileURL
        guard input.lastPathComponent == "benchmark-1000.jsonl" else { throw NativeDBError.message("既存の架空データ用ファイルを指定してください。") }
        let old = try AccountStore(url: folder.appendingPathComponent("accounts.sqlite"))
        _ = try old.importJSONLines(input)
        guard try old.page().total == 1000 else { throw NativeDBError.message("ベンチマークは1,000件を使用します。") }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        _ = try LegacyMigration.run(source:folder.appendingPathComponent("accounts.sqlite"),database:db,actor:identity)
        let service = CRMService(db:db,identity:identity)
        let module = CRMModule.find("crm_Accounts")!
        let page = try service.list(module)
        guard page.total == 1000, page.rows.count == 100, try db.integrityCheck() else { throw NativeDBError.message("ベンチマークデータの件数・整合性が一致しません。") }
        // Verify every copied detail as well as the bounded list projection.
        for index in 0..<10 {
            for summary in try old.page(index:index).rows {
                guard let account = try old.get(summary.id) else { throw NativeDBError.message("旧版の詳細が見つかりません。") }
                guard let row = try db.get("crm_Accounts",key:["id":.text(account.id)]), row["name"] == .text(account.name), row["description"].string == account.notes, row["email"].string == account.email else { throw NativeDBError.message("移行内容が一致しません。") }
            }
        }
        print("{\"ok\":true,\"syntheticRecords\":1000,\"detailsVerified\":1000,\"pageSize\":100,\"directory\":\"\(folder.path)\"}")
    }
}
