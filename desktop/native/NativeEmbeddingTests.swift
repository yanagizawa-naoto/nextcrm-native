import Foundation

/// Intercept the actual URLSession byte stream. No DNS, sockets, or live key.
final class NativeAIProtocolFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "X-Test-Mode") ?? "good"
        do {
            let vector = try NativeEmbeddingTests.vector(1)
            let good = try JSONSerialization.data(withJSONObject: ["object": "list", "model": NativeEmbeddingVector.model, "data": [["object": "embedding", "index": 0, "embedding": vector.bytes.base64EncodedString()]]])
            let bytes = mode.hasPrefix("large") ? Data(repeating: 32, count: NativeEmbeddingClient.maximumResponseBytes + 1) : good
            let headers = mode == "large-declared" ? ["Content-Length": String(bytes.count)] : [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: mode == "status" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for start in stride(from: 0, to: bytes.count, by: 1024) { client?.urlProtocol(self, didLoad: bytes.subdata(in: start..<min(start + 1024, bytes.count))) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main enum NativeEmbeddingTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label)
    }
    static func rejectsAsync(_ label: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label)
    }
    static func vector(_ x: Float, _ y: Float = 0) throws -> NativeEmbeddingVector {
        var values = [Float](repeating: 0, count: 1536); values[0] = x; values[1] = y
        return try NativeEmbeddingVector(values)
    }
    static func main() async {
        do { try await run(); print("Native embeddings: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        struct Reference: Decodable {
            struct Text: Decodable { let fields: [String?]; let text: String; let hash: String }
            let texts: [Text]; let a: String; let b: String; let similarity: Double
        }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: resources.appendingPathComponent("build/native-embedding-reference.json")))
        for (i, item) in reference.texts.enumerated() {
            let text = NativeEmbeddingVector.text(item.fields)
            try check(Array(text.utf8) == Array(item.text.utf8), "original JS text bytes \(i)")
            try check(NativeEmbeddingVector.hash(text) == item.hash, "original JS SHA256 \(i)")
        }
        let av = try NativeEmbeddingVector(bytes: Data(base64Encoded: reference.a)!), bv = try NativeEmbeddingVector(bytes: Data(base64Encoded: reference.b)!)
        try check(av.bytes.base64EncodedString() == reference.a, "little-endian float32 roundtrip")
        try check(abs(av.similarity(to: bv) - reference.similarity) < 1e-14, "independent 1536-dimension cosine reference")
        let x = try vector(1), y = try vector(0, 1), negative = try vector(-1)
        try check(x.similarity(to: x) == 1 && x.similarity(to: y) == 0 && x.similarity(to: negative) == -1, "cosine basis and sign")
        try check(try vector(3, 4).similarity(to: x) == 0.6, "non-normalized vectors")
        try rejects("zero norm") { _ = try vector(0) }
        try rejects("wrong dimensions") { _ = try NativeEmbeddingVector([1]) }
        try rejects("wrong byte size") { _ = try NativeEmbeddingVector(bytes: Data(repeating: 0, count: 6143)) }
        for invalid: Float in [.nan, .infinity, -.infinity] { try rejects("nonfinite") { _ = try vector(invalid) } }
        var top = try NativeEmbeddingTopK(limit: 3)
        for (id, score) in [("b", 0.1), ("a", 0.1), ("c", -0.3), ("b", 0.9), ("a", 0.0), ("d", 0.5), ("e", Double.nan)] { top.consider(id: id, similarity: score) }
        try check(top.hits.map(\.id) == ["b", "d", "a"], "top-k duplicate aggregation and limit")
        try rejects("invalid limit") { _ = try NativeEmbeddingTopK(limit: 0) }
        try await providerTests(x)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Embeddings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try NativeDatabase(url: folder.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let adminID = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db: db, identity: adminID)
        func user(_ name: String) throws -> NativeRecord { try db.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: adminID.id) }
        let alice = try user("alice"), bob = try user("bob")
        func service(_ row: NativeRecord) -> CRMService { CRMService(db: db, identity: .init(id: row["id"].string, role: row["role"].string, partnerAccountID: nil)) }
        let a = service(alice), b = service(bob), index = NativeEmbeddingIndex(db: db)
        let hash = NativeEmbeddingVector.hash("検索データ")
        func save(_ who: CRMService, _ model: String, _ values: [String: SQLValue]) throws -> NativeRecord { try who.save(CRMModule.find(model)!, original: nil, input: values) }
        var account = try save(a, "crm_Accounts", ["name": .text("公開候補")])
        let hidden = try save(b, "crm_Accounts", ["name": .text("非公開の最類似候補")])
        let first = try index.save(.account, source: account, vector: vector(3, 4), contentHash: hash, actor: a.identity.id)
        _ = try index.save(.account, source: hidden, vector: x, contentHash: hash, actor: b.identity.id)
        let result = try a.semanticMatches(.account, query: x, limit: 1)
        try check(result.hits.map(\.id) == [account["id"].string] && result.scanned == 1, "scope applied before top-k")
        try check(try b.semanticMatches(.account, query: x).hits.map(\.id) == [hidden["id"].string], "other owner isolated")
        try check(try admin.semanticMatches(.account, query: x).hits.count == 2, "admin CRM access")
        let updated = try index.save(.account, source: account, vector: y, contentHash: hash, actor: a.identity.id)
        try check(updated["id"] == first["id"] && updated.revision > first.revision, "unique upsert")
        let oldAccount = account; account = try db.update(account, changes: ["description": .text("内容変更")], actor: a.identity.id)
        try rejects("stale generation cannot overwrite") { _ = try index.save(.account, source: oldAccount, vector: x, contentHash: hash, actor: a.identity.id) }
        try check(try index.existing(.account, parentID: account["id"].string)?["embedding"] == .blob(y.bytes), "stale rejection preserves vector")
        _ = try db.setDeleted(account, deleted: true, actor: a.identity.id)
        try check(try a.semanticMatches(.account, query: x).hits.isEmpty, "deleted source hidden")
        try rejects("hash trailing newline") { _ = try index.save(.account, source: hidden, vector: x, contentHash: hash + "\n", actor: b.identity.id) }

        for (kind, values) in [(NativeEmbeddingKind.contact, ["first_name": SQLValue.text("太郎"), "last_name": .text("山田")]), (.lead, ["lastName": .text("佐藤")]), (.opportunity, ["name": .text("導入商談"), "currency": .text("JPY")])] {
            let row = try save(a, kind.parent, values)
            _ = try index.save(kind, source: row, vector: x, contentHash: hash, actor: a.identity.id)
            try check(try a.semanticMatches(kind, query: x).hits.map(\.id) == [row["id"].string], "\(kind) index and scope")
            try check(try b.semanticMatches(kind, query: x).hits.isEmpty, "\(kind) other owner denied")
        }
        func document(_ title: String, owner: NativeRecord, visibility: String = "private", parent: SQLValue = .null) throws -> NativeRecord {
            try db.insert("Documents", values: ["document_name": .text(title), "document_file_mimeType": .text("text/plain"), "document_file_url": .text("local"), "created_by_user": owner["id"], "createdBy": owner["id"], "visibility": .text(visibility), "parent_document_id": parent], actor: owner["id"].string)
        }
        let doc = try document("所有文書", owner: alice), secret = try document("他人の文書", owner: bob), publicDoc = try document("共有文書", owner: bob, visibility: "public")
        let version = try document("過去版", owner: alice, parent: doc["id"])
        for row in [doc, secret, publicDoc, version] { _ = try index.save(.document, source: row, vector: x, contentHash: hash, actor: adminID.id) }
        try check(Set(try a.semanticMatches(.document, query: x).hits.map(\.id)) == Set([doc["id"].string, publicDoc["id"].string]), "documents root-only and visibility")
        for (i, pair) in [(doc, y), (doc, x), (publicDoc, try vector(3, 4)), (secret, x), (version, x)].enumerated() {
            _ = try db.insert("crm_Document_Chunks", values: ["document_id": pair.0["id"], "chunk_index": .integer(Int64(i)), "chunk_text": .text("文書の一部"), "embedding": .blob(pair.1.bytes)], actor: adminID.id)
        }
        let chunks = try a.semanticMatches(.documentChunk, query: x)
        try check(chunks.hits.map(\.id) == [doc["id"].string, publicDoc["id"].string] && chunks.hits[0].similarity == 1 && chunks.scanned == 3, "chunks use per-document maximum and scope")
        try check(try a.semanticMatches(.documentChunk, query: x, minimumSimilarity: 0.7).hits.map(\.id) == [doc["id"].string], "strict semantic threshold")
        try rejects("invalid threshold") { _ = try a.semanticMatches(.document, query: x, minimumSimilarity: .nan) }
        _ = try db.update(publicDoc, changes: ["visibility": .text("private")], actor: b.identity.id)
        try check(try a.semanticMatches(.document, query: x).hits.map(\.id) == [doc["id"].string], "sharing revocation")
        func mailAccount(_ owner: NativeRecord) throws -> NativeRecord {
            try db.insert("EmailAccount", values: ["userId": owner["id"], "label": .text("テスト"), "imapHost": .text("example.invalid"), "imapPort": .integer(993), "smtpHost": .text("example.invalid"), "smtpPort": .integer(465), "username": .text("test"), "passwordEncrypted": .text("test-placeholder")], actor: owner["id"].string)
        }
        let mailA = try mailAccount(alice), mailB = try mailAccount(bob)
        var mails: [NativeRecord] = []
        for (owner, mailbox) in [(alice, mailA), (bob, mailB), (alice, mailB)] {
            let mail = try db.insert("Email", values: ["emailAccountId": mailbox["id"], "userId": owner["id"], "rfcMessageId": .text(UUID().uuidString), "folder": .text("INBOX")], actor: owner["id"].string)
            _ = try index.save(.email, source: mail, vector: x, contentHash: hash, actor: owner["id"].string); mails.append(mail)
        }
        try check(try a.semanticMatches(.email, query: x).hits.map(\.id) == [mails[0]["id"].string], "mail requires both message and account ownership")
        try check(try admin.semanticMatches(.email, query: x).hits.isEmpty, "admin does not inherit private email access")
        _ = try db.update(mails[0], changes: ["isDeleted": .integer(1)], actor: a.identity.id)
        try check(try a.semanticMatches(.email, query: x).hits.isEmpty, "deleted email excluded")

        try db.transaction {
            for i in 0..<1001 {
                let id = String(format: "10000000-0000-0000-0000-%012d", i)
                let row = try db.insert("crm_Accounts", values: ["id": .text(id), "v": .integer(0), "name": .text("大量データ \(i)"), "createdBy": alice["id"]], actor: a.identity.id)
                _ = try index.save(.account, source: row, vector: vector(Float(i + 1), Float(1001 - i)), contentHash: hash, actor: a.identity.id)
            }
        }
        let many = try a.semanticMatches(.account, query: x)
        try check(many.scanned == 1001 && many.hits.count == 10 && many.hits.first?.id == "10000000-0000-0000-0000-000000001000", "all 1001 vectors scanned with bounded top ten")
        let page1 = try db.keysetPage("crm_Accounts", fields: ["name"], filter: a.scope("crm_Accounts"))
        let page2 = try db.keysetPage("crm_Accounts", fields: ["name"], after: page1.last!["id"].string, filter: a.scope("crm_Accounts"))
        try check(page1.count == 100 && page2.count == 100 && Set(page1.map { $0["id"].string }).isDisjoint(with: page2.map { $0["id"].string }), "keyset boundary no duplication")
        try rejects("keyset invalid columns") { _ = try db.keysetPage("crm_Accounts", fields: ["DROP TABLE"]) }
        try rejects("keyset oversized page") { _ = try db.keysetPage("crm_Accounts", fields: [], limit: 101) }
        let corrupt = try index.existing(.account, parentID: many.hits.first!.id)!
        _ = try db.update(corrupt, changes: ["embedding": .blob(Data([1, 2, 3]))], actor: a.identity.id)
        let cleaned = try a.semanticMatches(.account, query: x)
        try check(cleaned.malformed == 1 && cleaned.hits.count == 10 && cleaned.hits.first?.id != many.hits.first?.id, "corrupt legacy vector reported and excluded")
        let oversized = try index.existing(.account, parentID: cleaned.hits.first!.id)!
        _ = try db.update(oversized, changes: ["embedding": .blob(Data(repeating: 1, count: 2_000_000))], actor: a.identity.id)
        try check(try index.existing(.account, parentID: cleaned.hits.first!.id)?["embedding"] == .null, "oversized BLOB excluded inside SQLite before Swift allocation")
        try check(try a.semanticMatches(.account, query: x).malformed == 2, "oversized BLOB counted as malformed")
        try rejects("BLOB bounds on text field") { _ = try db.keysetPage("crm_Accounts", fields: ["name"], maximumBlobBytes: ["name": 1]) }
        var validations = 0
        try rejects("revocation during scan") {
            _ = try index.nearest(.account, query: x, parentScope: a.scope("crm_Accounts"), validate: {
                validations += 1
                if validations == 2 { _ = try db.update(alice, changes: ["banned": .integer(1)], actor: adminID.id) }
                try a.authenticated()
            })
        }
        try check(validations == 2, "authorization checked each batch")
        try rejects("banned user cannot search") { _ = try a.semanticMatches(.account, query: x) }
    }

    static func providerTests(_ vector: NativeEmbeddingVector) async throws {
        func response(_ body: [String: Any], status: Int = 200, url: URL = NativeEmbeddingClient.endpoint) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        let good: [String: Any] = ["object": "list", "model": NativeEmbeddingVector.model, "data": [["object": "embedding", "index": 0, "embedding": vector.bytes.base64EncodedString()]]]
        let client = try NativeEmbeddingClient(apiKey: "fake-test-key", request: { req in
            try check(req.url == NativeEmbeddingClient.endpoint && req.httpMethod == "POST" && req.value(forHTTPHeaderField: "Authorization") == "Bearer fake-test-key", "fixed provider request")
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
            try check(body == ["model": "text-embedding-3-small", "input": "  日本語\n本文  ", "encoding_format": "base64"], "original model and untruncated input")
            return try response(good)
        })
        let generated = try await client.generate("  日本語\n本文  ")
        try check(generated.bytes == vector.bytes, "SDK-compatible base64 response")
        for key in ["", "bad\nkey", "bad key"] { try rejects("invalid key") { _ = try NativeEmbeddingClient(apiKey: key) } }
        try await rejectsAsync("empty input") { _ = try await client.generate("\u{FEFF}\n　") }
        for (status, retryable) in [(400, false), (401, false), (403, false), (429, true), (500, true), (302, false)] {
            let bad = try NativeEmbeddingClient(apiKey: "fake", request: { _ in try response(["error": "secret body fake-test-key"], status: status) })
            do { _ = try await bad.generate("test"); throw NativeDBError.message("unexpected success") }
            catch let error as NativeAIError { try check(error.status == status && error.retryable == retryable && !error.localizedDescription.contains("fake-test-key") && !error.localizedDescription.contains("secret body"), "safe HTTP \(status)") }
        }
        for value in [[:], ["object": "list", "model": "wrong", "data": good["data"]!], ["object": "list", "model": NativeEmbeddingVector.model, "data": []], ["object": "list", "model": NativeEmbeddingVector.model, "data": [["object": "embedding", "index": 1, "embedding": vector.bytes.base64EncodedString()]]], ["object": "list", "model": NativeEmbeddingVector.model, "data": [["object": "embedding", "index": 0, "embedding": "YQ=="]]]] as [[String: Any]] {
            let bad = try NativeEmbeddingClient(apiKey: "fake", request: { _ in try response(value) })
            try await rejectsAsync("malformed provider response") { _ = try await bad.generate("test") }
        }
        let redirected = try NativeEmbeddingClient(apiKey: "fake", request: { _ in try response(good, url: URL(string: "https://example.invalid/embeddings")!) })
        try await rejectsAsync("unexpected response origin") { _ = try await redirected.generate("test") }
        let oversized = try NativeEmbeddingClient(apiKey: "fake", request: { _ in (Data(repeating: 32, count: NativeEmbeddingClient.maximumResponseBytes + 1), try response(good).1) })
        try await rejectsAsync("oversized response") { _ = try await oversized.generate("test") }
        let cancel = try NativeEmbeddingClient(apiKey: "fake", request: { _ in throw CancellationError() })
        do { _ = try await cancel.generate("test"); throw NativeDBError.message("cancellation missing") } catch is CancellationError { checks += 1 }
        let transport = try NativeEmbeddingClient(apiKey: "fake", request: { _ in throw NSError(domain: "contains secret", code: 1) })
        do { _ = try await transport.generate("test"); throw NativeDBError.message("transport failure missing") }
        catch let error as NativeAIError { try check(error.retryable && !error.localizedDescription.contains("secret"), "transport failure redacted") }
        func streamingClient(_ mode: String) throws -> NativeEmbeddingClient {
            try NativeEmbeddingClient(apiKey: "fake", request: { req in
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NativeAIProtocolFixture.self]
                var request = req; request.setValue(mode, forHTTPHeaderField: "X-Test-Mode")
                return try await NativeEmbeddingClient.transport(request, configuration: config)
            })
        }
        let streamed = try await streamingClient("good").generate("日本語")
        try check(streamed.bytes == vector.bytes, "actual URLSession byte stream response")
        for mode in ["large-declared", "large-stream", "status"] {
            try await rejectsAsync("URLSession \(mode)") { _ = try await streamingClient(mode).generate("日本語") }
        }
        try await rejectsAsync("transport forbids arbitrary origins") {
            _ = try await NativeEmbeddingClient.transport(URLRequest(url: URL(string: "https://example.invalid/")!), configuration: .ephemeral)
        }
    }
}
