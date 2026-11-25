import Foundation

@main enum NativeUnifiedSearchTests {
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
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-UnifiedSearch-" + UUID().uuidString)
            db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            source = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/native-search-reference.json"))) as! [String: Any]
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
            let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try Fixture(resources)
            try reference(fixture); try keyword(fixture); try scopeAndBounds(fixture); try await engine(fixture)
            print("Native unified search: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func reference(_ f: Fixture) throws {
        for item in f.source["cases"] as! [[String: Any]] {
            let role = item["role"] as! String, id = item["userId"] as! String, semantic = item["semantic"] as! Bool
            let service = CRMService(db: f.db, identity: .init(id: id, role: role, partnerAccountID: item["partnerAccountId"] as? String))
            let actual = try service.unifiedSearch("検索", vector: semantic ? vector() : nil)
            let expected = item["result"] as! [String: [[String: Any]]]
            for kind in NativeSearchKind.allCases {
                let hits = actual.hits.filter { $0.kind == kind }, matches = expected[kind.rawValue]!
                try check(hits.map(\.id) == matches.map { $0["id"] as! String }, "original IDs/order \(role) \(id) \(kind) semantic=\(semantic)")
                for (hit, match) in zip(hits, matches) {
                    try check(hit.title == match["title"] as! String && hit.subtitle == match["subtitle"] as! String, "original title/subtitle \(kind)")
                    try check(abs(hit.score - (match["score"] as! Double)) < 1e-12 && hit.match.rawValue == match["matchType"] as! String, "original score/match type \(kind)")
                }
            }
        }
    }
    static func keyword(_ f: Fixture) throws {
        let service = try f.service("alice")
        let long = try f.ownAccount(String(repeating: "長い名称", count: 200), description: String(repeating: "先頭の文章", count: 2000) + "末尾の検索語")
        let found = try service.unifiedSearch("末尾の検索語").hits
        try check(found.map(\.id) == [long["id"].string] && found[0].title.unicodeScalars.count == 512, "search matches beyond old 512-character index while returning bounded title")
        for (name, query) in [("ÉCOLE 東京", "école"), ("東京都庁", "京都"), ("Σίσυφος", "σίσυφοσ"), ("literal %_ code", "%_"), ("a\\b", "\\b"), ("aaaaab", "aaab")] {
            let row = try f.ownAccount(name)
            try check(try service.unifiedSearch(query).hits.contains { $0.id == row["id"].string }, "literal Unicode substring \(query)")
        }
        try check(try service.unifiedSearch("%_").hits.count == 1, "percent/underscore do not act as SQL wildcards")
        try check(try service.unifiedSearch("' OR 1=1--").hits.isEmpty, "SQL-shaped search remains a bound literal")
        try check(try service.unifiedSearch("検索 ").hits.contains { $0.kind == .accounts }, "keyword query whitespace preserved")
        let projected = try f.db.keysetPage("crm_Accounts", fields: ["name"], filter: .equal("id", long["id"]), limit: 1, maximumTextCharacters: ["name": 4])
        try check(projected[0]["name"].string == "長い名称", "SQL projection bound is Unicode-safe")
        let missing = try f.db.keysetPage("crm_Accounts", fields: ["email"], filter: .equal("id", long["id"]), limit: 1, maximumTextCharacters: ["email": 4])
        try check(missing[0]["email"] == .null, "bounded text retains NULL")
        let boundary = try f.ownAccount("大きな本文", description: String(repeating: "x", count: 16_383) + "🗼東京Boundary" + String(repeating: "y", count: 1_000_000))
        try check(try service.unifiedSearch("🗼東京").hits.map(\.id) == [boundary["id"].string], "UTF8 scalar and match survive incremental SQLite read boundary")
        try check(try service.unifiedSearch("ない文章").hits.isEmpty, "large field non-match scans to EOF")
    }
    static func scopeAndBounds(_ f: Fixture) throws {
        let alice = try f.service("alice"), bob = try f.service("bob"), index = NativeEmbeddingIndex(db: f.db)
        for i in 0..<15 {
            let row = try f.db.insert("crm_Contacts", values: ["last_name": .text("非公開\(i)"), "assigned_to": .text(bob.identity.id), "createdBy": .text(bob.identity.id)], actor: bob.identity.id)
            _ = try index.save(.contact, source: row, vector: vector(), contentHash: NativeEmbeddingVector.hash("private"), actor: bob.identity.id)
        }
        let hits = try alice.unifiedSearch("該当なし", vector: vector()).hits
        try check(hits.contains { $0.id == f.labels["own-contact"] }, "authorized semantic match survives more than ten closer private vectors")
        try check(!hits.contains { $0.id == f.labels["indirect-contact"] }, "report contact scope does not inherit account read access")
        try check(!hits.contains { $0.kind == .users }, "ordinary user cannot search user directory")
        let document = try f.db.insert("Documents", values: ["document_name": .text("公開資料の検証"), "document_file_mimeType": .text("text/plain"), "document_file_url": .text("local"), "visibility": .text("public"), "createdBy": .text(bob.identity.id)], actor: bob.identity.id)
        _ = try f.db.insert("DocumentsToAccounts", values: ["document_id": document["id"], "account_id": .text(f.labels["hidden"]!)], actor: bob.identity.id)
        try check(try alice.unifiedSearch("公開資料").hits.first?.subtitle == "", "public document cannot disclose inaccessible linked account name")
        let board = try f.row("Boards", "private-board")
        _ = try f.db.update(board, changes: ["deletedAt": .text("2026-01-01T00:00:00Z")], actor: bob.identity.id)
        try check(try !alice.unifiedSearch("検索").hits.contains { $0.id == f.labels["assigned-private-task"] }, "deleted board excludes assigned task")
        for i in 0..<35 { _ = try f.ownAccount("上限検証 \(i)") }
        try check(try alice.unifiedSearch("上限検証").hits.filter { $0.kind == .accounts }.count == 10, "global search keeps original ten results per kind")
        let candidate = try alice.unifiedSearch("末尾の検索語").hits[0]
        let current = try f.db.get("crm_Accounts", key: ["id": .text(candidate.id)])!
        _ = try f.db.update(current, changes: ["assigned_to": .text(bob.identity.id), "createdBy": .text(bob.identity.id)], actor: bob.identity.id)
        do { _ = try alice.searchDestination(candidate); throw NativeDBError.conflict }
        catch let error as NativeAIError { try check(error.message.contains("権限"), "stale result navigation rechecks current access") }
        let user = try f.service("admin").unifiedSearch("検索").hits.first { $0.kind == .users }!
        let profile = try f.service("admin").searchDestination(user)
        try check(profile.values["password"] == nil && profile.values["salt"] == nil && profile["email"] != .null, "user directory navigation never loads authentication secrets")
    }
    static func engine(_ f: Fixture) async throws {
        let alice = try f.service("alice"), store = NativeAIQAServices(); var key: String?, calls = 0
        let keys = NativeAIKeys(service: alice, store: store, environment: NativeAIEnvironment(lookup: { _ in key }))
        let engine = NativeSearchEngine(keys: keys, generate: { text, _ in calls += 1; try check(text == "検索", "provider gets trimmed query once"); return try vector() })
        let unconfigured = try await engine.search("検索", useAI: true)
        try check(unconfigured.aiState == .unconfigured && calls == 0 && !unconfigured.hits.isEmpty, "missing key falls back without provider call")
        key = "qa-local-search"
        let disabled = try await engine.search("検索", useAI: false)
        try check(disabled.aiState == .disabled && calls == 0, "explicit keyword-only search skips provider")
        let hybrid = try await engine.search("検索", useAI: true)
        try check(hybrid.aiState == .ready && calls == 1 && hybrid.hits.contains { $0.match == .both }, "one query embedding serves all semantic kinds")
        let unavailable = try await NativeSearchEngine(keys: keys, generate: { _, _ in throw NativeAIError(message: "synthetic-provider-secret", status: 401) }).search("検索", useAI: true)
        try check(unavailable.aiState == .unavailable && !unavailable.hits.isEmpty && !unavailable.aiState.message.contains("secret"), "provider failure keeps keyword results without leaking raw error")
        let rotated = try await NativeSearchEngine(keys: keys, generate: { _, _ in key = "qa-rotated"; return try vector() }).search("検索", useAI: true)
        try check(rotated.aiState == .unavailable && rotated.hits.allSatisfy { $0.match == .keyword }, "changed credential discards returned query vector")
        for query in ["", "東", " \u{feff} "] { try await reject("short/blank query") { _ = try await engine.search(query, useAI: false) } }
        _ = try await engine.search("😀", useAI: false); try check(true, "original JS UTF16 two-unit emoji is valid query")
        try await reject("cancelled search") {
            let task = Task { try await NativeSearchEngine(keys: keys, generate: { _, _ in withUnsafeCurrentTask { $0?.cancel() }; return try vector() }).search("検索", useAI: true) }
            _ = try await task.value
        }
        try await reject("revoked actor during provider await") {
            _ = try await NativeSearchEngine(keys: keys, generate: { _, _ in
                let user = try f.row("Users", "alice"); _ = try f.db.update(user, changes: ["userStatus": .text("INACTIVE")], actor: f.labels["admin"]!); return try vector()
            }).search("検索", useAI: true)
        }
    }
}
