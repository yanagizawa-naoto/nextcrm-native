import Foundation

@main enum NativeSearchPickerTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func reject(_ label: String, _ action: () async throws -> Void) async throws { do { try await action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: " + label) }
    static func vector(_ x: Double = 1, _ y: Double = 0) throws -> NativeEmbeddingVector { var values = [Float](repeating: 0, count: 1536); values[0] = Float(x); values[1] = Float(y); return try NativeEmbeddingVector(values) }
    static func sql(_ value: Any) throws -> SQLValue {
        if value is NSNull { return .null }
        if let string = value as? String { return .text(string) }
        if let number = value as? NSNumber { return .integer(number.int64Value) }
        return .text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
    final class Fixture {
        let root: URL, db: NativeDatabase, source: [String: Any], labels: [String: String]
        init(_ resources: URL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-SearchPickers-" + UUID().uuidString)
            db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            source = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/native-search-pickers-reference.json"))) as! [String: Any]
            labels = source["labels"] as! [String: String]
            let records = source["records"] as! [String: [[String: Any]]]
            for model in ["Users", "crm_Accounts", "AccountWatchers", "crm_Contacts", "crm_Leads", "crm_Opportunities", "Boards", "BoardWatchers", "Sections", "Tasks", "Documents", "DocumentsToAccounts"] {
                for input in records[model] ?? [] {
                    var fields = try input.mapValues(sql)
                    if model == "Users" { fields.removeValue(forKey: "partnerAccountId") }
                    _ = try db.insert(model, values: fields, actor: labels["admin"]!)
                }
            }
            let partner = try row("Users", "partner")
            _ = try db.update(partner, changes: ["partnerAccountId": .text(labels["company"]!)], actor: labels["admin"]!)
            let index = NativeEmbeddingIndex(db: db); var chunkCounts: [String: Int] = [:]
            for value in source["vectors"] as! [[String: Any]] {
                let kind = NativeEmbeddingKind(rawValue: value["kind"] as! String)!, id = value["parentID"] as! String, numbers = value["values"] as! [Double]
                let embedding = try vector(numbers[0], numbers[1])
                if kind == .documentChunk {
                    let count = chunkCounts[id, default: 0]; chunkCounts[id] = count + 1
                    _ = try db.insert(kind.table, values: ["document_id": .text(id), "chunk_index": .integer(Int64(count)), "chunk_text": .text("検索用の文書の部分"), "embedding": .blob(embedding.bytes)], actor: labels["admin"]!)
                } else { _ = try index.save(kind, source: db.get(kind.parent, key: ["id": .text(id)])!, vector: embedding, contentHash: NativeEmbeddingVector.hash("fixture"), actor: labels["admin"]!) }
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func row(_ model: String, _ label: String) throws -> NativeRecord { try db.get(model, key: ["id": .text(labels[label]!)])! }
        func service(_ name: String) throws -> CRMService {
            let user = try row("Users", name)
            return CRMService(db: db, identity: .init(id: user["id"].string, role: user["role"].string, partnerAccountID: user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        }
        func ownAccount(_ name: String, description: String = "") throws -> NativeRecord {
            try db.insert("crm_Accounts", values: ["v": .integer(0), "name": .text(name), "description": .text(description), "createdBy": .text(labels["alice"]!), "assigned_to": .text(labels["alice"]!)], actor: labels["alice"]!)
        }
    }
    static func main() async {
        do {
            let f = try Fixture(URL(fileURLWithPath: CommandLine.arguments[1]))
            try reference(f); try bounds(f); try await cancellation(f); try await engine(f)
            print("Native search pickers: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func actor(_ f: Fixture, _ item: [String: Any]) -> CRMService {
        CRMService(db: f.db, identity: .init(id: item["userId"] as! String, role: item["role"] as! String, partnerAccountID: item["partnerAccountId"] as? String))
    }
    static func reference(_ f: Fixture) throws {
        for item in f.source["accountCases"] as! [[String: Any]] {
            let expected = item["result"] as! [String: Any], rows = expected["accounts"] as! [[String: Any]], offset = item["skip"] as! Int
            let actual = try actor(f,item).references("crm_Accounts", search: item["search"] as! String, offset: offset)
            try check(actual.rows.map { $0["id"].string } == rows.map { $0["id"] as! String }, "original scoped account IDs and name order")
            try check(actual.total == expected["total"] as! Int && (offset+100 < actual.total) == expected["hasMore"] as! Bool, "original account count and page boundary")
            for (row,match) in zip(actual.rows,rows) {
                try check(row["name"].string == String(String.UnicodeScalarView((match["name"] as! String).unicodeScalars.prefix(512))), "bounded original account name")
                try check(Set(row.values.keys) == ["id","name"], "reference projection excludes unrelated fields")
            }
        }
        for item in f.source["documentCases"] as! [[String: Any]] {
            let expected = item["result"] as! [[String: Any]]
            let actual = try actor(f,item).documentCandidateSearch(item["query"] as! String, vector: item["semantic"] as! Bool ? vector() : nil)
            try check(actual.hits.map(\.id) == expected.map { $0["id"] as! String }, "original document candidate IDs and keyword-first order")
            for (hit,match) in zip(actual.hits,expected) {
                try check(hit.title == match["name"] as! String && hit.subtitle == (match["summary"] as? String ?? ""), "original document name and summary")
                try check(hit.documentAccountName == match["accountName"] as? String && hit.documentSystemType == match["systemType"] as? String, "document category and authorized account name")
            }
        }
    }
    static func bounds(_ f: Fixture) throws {
        let service = try f.service("alice")
        let page = try service.references("crm_Accounts", search: "候補")
        try check(page.total == 108 && page.rows.count == 100, "full count exceeds one page and excludes email-only match")
        try check(try service.references("crm_Accounts", search: "候補", offset: 100).rows.count == 8, "last partial page")
        try check(try service.references("crm_Accounts", search: "末尾候補").rows.map { $0["id"].string } == [f.labels["late-name"]!], "name search beyond cached512character prefix")
        let huge = try f.ownAccount(String(repeating:"あ",count:350_000)+"終端検索")
        let found = try service.references("crm_Accounts", search:"終端検索")
        try check(found.total == 1 && found.rows[0]["id"] == huge["id"] && found.rows[0]["name"].string.unicodeScalars.count == 512, "megabyte name streamed to end with bounded display prefix")
        let literal = try f.ownAccount("%_\\ literal")
        try check(try service.references("crm_Accounts",search:"%_\\").rows.map{$0["id"]} == [literal["id"]], "literal wildcard and slash matching")
        try check(try service.references("crm_Accounts",search:"候補",matching:.equal("id",.text(f.labels["picker-0"]!))).total == 1, "caller scope combines with full-field search")
        let row = try f.db.insert("Documents", values:["document_name":.text("説明だけ"),"description":.text("候補限定の文章"),"document_file_url":.text("local"),"document_file_mimeType":.text("text/plain"),"createdBy":.text(service.identity.id)],actor:service.identity.id)
        try check(try service.documentCandidateSearch("候補限定").hits.isEmpty, "candidate keywords exclude description")
        try check(try service.unifiedSearch("候補限定").hits.map(\.id) == [row["id"].string], "global search still includes description")
        _ = try f.db.insert("crm_Document_Chunks",values:["document_id":row["id"],"chunk_index":.integer(0),"chunk_text":.text("断片"),"embedding":.blob(vector().bytes)],actor:service.identity.id)
        try check(try !service.documentCandidateSearch("語句なし",vector:vector()).hits.contains{$0.id == row["id"].string}, "command candidates do not use chunk vectors")
        _ = try NativeEmbeddingIndex(db:f.db).save(.document,source:row,vector:vector(3,4),contentHash:NativeEmbeddingVector.hash("low"),actor:service.identity.id)
        try check(try !service.documentCandidateSearch("語句なし",vector:vector()).hits.contains{$0.id == row["id"].string}, "similarity0.6 excluded")
        // Private perfect vectors cannot consume the visible top-five budget.
        for i in 0..<7 {
            let privateDoc = try f.db.insert("Documents",values:["document_name":.text("秘密"+String(i)),"document_file_url":.text("local"),"document_file_mimeType":.text("text/plain"),"createdBy":.text(f.labels["bob"]!),"visibility":.text("private")],actor:f.labels["bob"]!)
            _ = try NativeEmbeddingIndex(db:f.db).save(.document,source:privateDoc,vector:vector(),contentHash:NativeEmbeddingVector.hash("private"),actor:f.labels["bob"]!)
        }
        let semantic = try service.documentCandidateSearch("語句なし",vector:vector()).hits
        try check(semantic.count == 5 && semantic.allSatisfy{$0.match == .semantic}, "authorized semantic top-five survives closer private rows")
    }
    static func cancellation(_ f: Fixture) async throws {
        let service = try f.service("alice")
        let result = await Task.detached { () -> Bool in
            var checks = 0
            do {
                _ = try f.db.textSearchPage("crm_Accounts",field:"name",query:"候補",filter:service.scope("crm_Accounts"),validate:{ checks += 1; if checks == 3 { withUnsafeCurrentTask { $0?.cancel() } } })
                return false
            } catch { return Task.isCancelled }
        }.value
        try check(result, "cancel interrupts scan and unwinds temporary table transaction")
        try check(try service.references("crm_Accounts",search:"候補").total == 108, "subsequent scan works after cancellation without database changes")
        try await reject("invalid negative offset") { _ = try service.references("crm_Accounts",search:"候補",offset:-1) }
    }
    static func engine(_ f: Fixture) async throws {
        let service = try f.service("alice"), keys = NativeAIKeys(service:service,store:NativeAIQAServices(),environment:NativeAIEnvironment(lookup:{_ in "qa-document-search"}))
        var calls = 0
        let engine = NativeSearchEngine(keys:keys,generate:{_,_ in calls += 1; return try vector()},documentCandidates:true)
        let actual = try await engine.search("検索",useAI:true)
        try check(calls == 1 && actual.aiState == .ready && actual.hits == service.documentCandidateSearch("検索",vector:vector(),aiState:.ready).hits, "engine dispatches document candidate mode with one embedding")
        let fallback = try await NativeSearchEngine(keys:keys,generate:{_,_ in throw NativeAIError(message:"private provider failure")},documentCandidates:true).search("検索",useAI:true)
        try check(fallback.aiState == .unavailable && fallback.hits.count == 5 && fallback.hits.allSatisfy{$0.match == .keyword}, "candidate provider failure keeps keyword-first fallback")
    }
}
