import Foundation
import SQLite3

final class NativeDocumentAIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let large = request.value(forHTTPHeaderField: "X-Test") == "large"
        let data = large ? Data(repeating: 32, count: NativeEmbeddingClient.maximumResponseBytes + 1) : Data("{\"ok\":true}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: data.count, by: 1024) { client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + 1024, data.count))) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum NativeDocumentAITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func reject(_ label: String, _ action: () async throws -> Void) async throws {
        do { try await action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: " + label)
    }
    static func vector(_ x: Float = 1) throws -> NativeEmbeddingVector { var values = [Float](repeating: 0, count: 1536); values[0] = x; return try NativeEmbeddingVector(values) }
    struct Reference: Decodable {
        struct Request: Decodable { struct Message: Decodable { let role: String, content: String }; let model: String; let max_tokens: Int; let messages: [Message] }
        struct Case: Decodable { let name: String, text: String, hash: String, category: String, rawClassification: String; let configured: Bool, enriched: Bool; let utf16Count: Int; let embeddings: [String]; let fullHash: String?; let summary: String?; let requests: [Request] }
        let cases: [Case]
    }
    final class Fixture {
        let root: URL, db: NativeDatabase, admin: CRMService, service: CRMService, bob: CRMService
        let store = NativeAIQAServices()
        var now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), key: String? = "qa-doc-original"
        var embeddings: [String] = [], summaries = 0, classifications = 0
        init(_ resources: URL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-DocumentAI-" + UUID().uuidString)
            let database = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            let owner = CRMService(db: database, identity: try CRMService.bootstrap(database, resources: resources.appendingPathComponent("../../prisma")))
            db = database; admin = owner
            func user(_ name: String) throws -> CRMService {
                let row = try database.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: owner.identity.id)
                return CRMService(db: database, identity: .init(id: row["id"].string, role: "user", partnerAccountID: nil))
            }
            service = try user("alice"); bob = try user("bob")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func worker(generate: NativeEmbeddingWorker.Generate? = nil, summarize: NativeDocumentAIWorker.Summary? = nil, classify: NativeDocumentAIWorker.Classify? = nil) -> NativeEmbeddingWorker {
            NativeEmbeddingWorker(db: db, store: store, environment: NativeAIEnvironment(lookup: { [unowned self] _ in self.key }), clock: { [unowned self] in self.now },
                generate: generate ?? { [unowned self] text, _ in self.embeddings.append(text); return try vector() },
                summarize: summarize ?? { [unowned self] _, _ in self.summaries += 1; return "日本語の要約です。内容を確認しました。" },
                classify: classify ?? { [unowned self] _, _, _, _ in self.classifications += 1; return "CONTRACT" })
        }
        func source(_ text: String, name: String = "文書.txt", type: String = "OTHER", replacing: NativeRecord? = nil) throws -> (row: NativeRecord, job: String) {
            var values: [String: SQLValue] = ["document_name": .text(name), "document_system_type": .text(type), "document_file_mimeType": .text("text/plain"), "document_file_url": .text("local"), "key": .text(UUID().uuidString), "content_hash": .text(NativeEmbeddingVector.hash(text)), "processing_status": .text("READY"), "summary": .null]
            let row: NativeRecord
            if let replacing { row = try db.update(replacing, changes: values, actor: service.identity.id) }
            else {
                values["createdBy"] = .text(service.identity.id); values["created_by_user"] = .text(service.identity.id); values["assigned_user"] = .text(service.identity.id); values["visibility"] = .text("private")
                row = try db.insert("Documents", values: values, actor: service.identity.id)
            }
            let job = try db.enqueue("document/uploaded", payload: ["documentId": row["id"].string], now: now)
            try db.reserveDocumentProcessing(row, jobID: job)
            guard let claimed = try db.claimJob(events: ["document/uploaded"], now: now), claimed.id == job else { throw NativeDBError.conflict }
            try db.saveDocumentProcessing(row, jobID: job, textBytes: text.utf8.count, thumbnail: nil, note: "") { append in
                let scalars = text.unicodeScalars; var start = scalars.startIndex
                while start != scalars.endIndex { let end = scalars.index(start, offsetBy: 4093, limitedBy: scalars.endIndex) ?? scalars.endIndex; try append(String(scalars[start..<end])); start = end }
            }
            try db.finishJob(claimed, result: ["outcome": "ready"], now: now)
            guard let ai = try db.enqueueDocumentAI(row, actor: service.identity.id, now: now) else { throw NativeDBError.conflict }
            return (row, ai)
        }
        func fresh(_ row: NativeRecord) throws -> NativeRecord { guard let value = try db.get("Documents", key: ["id": row["id"]]) else { throw NativeDBError.conflict }; return value }
        func job(_ id: String) throws -> NativeJob { guard let value = try db.job(id: id) else { throw NativeDBError.conflict }; return value }
        func sql(_ command: String) throws {
            var connection: OpaquePointer?; guard sqlite3_open(db.url.path, &connection) == SQLITE_OK else { throw NativeDBError.conflict }; defer { sqlite3_close(connection) }
            guard sqlite3_exec(connection, command, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(connection))) }
        }
        func chunks(_ row: NativeRecord) throws -> [NativeRecord] { try db.page("crm_Document_Chunks", fields: ["chunk_index", "chunk_text", "embedding"], equal: ["document_id": row["id"]], sort: "chunk_index").rows }
    }
    static func run(_ worker: NativeEmbeddingWorker) async throws { let done = try await worker.runNext(); try check(done, "document AI job claimed") }
    static func main() async {
        do {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: resources.appendingPathComponent("build/native-document-ai-reference.json")))
            try await references(reference, resources); try await provider(reference); try await resumeAndPublish(resources); try await inputLimitFallback(resources); try await invalidation(resources); try await cancellationAndBackfill(resources)
            print("Native document AI: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func references(_ reference: Reference, _ resources: URL) async throws {
        for item in reference.cases {
            let f = try Fixture(resources), text = String(decoding: Data(base64Encoded: item.text)!, as: UTF8.self)
            let input = try f.source(text, name: item.name, type: item.enriched ? "OTHER" : item.category)
            let reader = NativeDocumentAIText(db: f.db, documentID: input.row["id"].string), inspected = try reader.inspect()
            try check(inspected.utf16Count == item.utf16Count && inspected.hash == item.hash, "original JS UTF16 length and full hash \(item.name)")
            f.key = item.configured ? "qa-doc-original" : nil
            var summaryInput: String?, categoryInput: String?
            let worker = f.worker(summarize: { excerpt, _ in summaryInput = excerpt; return item.summary }, classify: { _, summary, excerpt, _ in
                try check(summary == item.summary, "classification uses completed summary"); categoryInput = excerpt; return item.category
            })
            try await run(worker)
            let row = try f.fresh(input.row), job = try f.job(input.job)
            try check(job.status == "done" && job.result["enriched"] == (item.enriched ? "true" : "false"), "original enriched outcome \(item.name)")
            try check(row["processing_status"] == .text("READY") && row["document_system_type"].string == item.category && row["summary"] == item.summary.map(SQLValue.text) ?? .null, "original final metadata \(item.name)")
            try check(f.embeddings.map { Data($0.utf8).base64EncodedString() } == item.embeddings, "original overlapping chunk bytes \(item.name)")
            if item.enriched {
                try check(Data((summaryInput ?? "").utf8).base64EncodedString() == item.requests[0].messages[1].content, "original 12000-unit summary excerpt")
                try check(categoryInput == NativeDocumentAIText.prefix(text, units: 4000), "classification excerpt bounded in UTF16")
                if let hash = item.fullHash {
                    try check(try NativeEmbeddingIndex(db: f.db).existing(.document, parentID: row["id"].string)?["content_hash"].string == hash && f.chunks(row).isEmpty, "single embedding replaces chunks")
                } else {
                    let chunks = try f.chunks(row)
                    try check(chunks.map { Data($0["chunk_text"].string.utf8).base64EncodedString() } == item.embeddings, "all original chunks persisted in order")
                    try check(try NativeEmbeddingIndex(db: f.db).existing(.document, parentID: row["id"].string) == nil, "chunked generation has no stale full vector")
                }
                try check(try f.db.stagedDocumentAICount(job) == 0, "published stage reclaimed")
            } else { try check(summaryInput == nil && categoryInput == nil && f.embeddings.isEmpty, "empty/unconfigured document has no provider requests") }
        }
        let pages = ["ab", "😀", "c", "", "def"]
        let reader = NativeDocumentAIText(page: { ($0 < pages.count ? pages[$0] : "", pages.count) })
        let first = try reader.window(from: .init(), limit: 4, overlap: 2), second = try reader.window(from: first.next, limit: 4, overlap: 2)
        try check(first.text == "ab😀" && second.text == "😀cd", "overlap cursor crosses extraction pages and empty page")
        try await reject("invalid cursor") { _ = try reader.window(from: .init(part: 50, offset: 0), limit: 4) }
    }
    static func provider(_ reference: Reference) async throws {
        for item in reference.cases where item.enriched {
            let text = String(decoding: Data(base64Encoded: item.text)!, as: UTF8.self); var call = 0
            let client = try NativeOpenAIChatClient(apiKey: "qa-not-a-real-key", request: { request in
                let expected = item.requests[call], body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                try check(request.url == NativeOpenAIChatClient.endpoint && request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer qa-not-a-real-key", "fixed authenticated chat request")
                try check(body["model"] as? String == expected.model && body["max_tokens"] as? Int == expected.max_tokens, "original model and output limits")
                let messages = body["messages"] as! [[String: String]]
                for (actual, original) in zip(messages, expected.messages) { try check(actual["role"] == original.role && Data(actual["content"]!.utf8).base64EncodedString() == original.content, "actual original chat prompt bytes") }
                let response = try JSONSerialization.data(withJSONObject: ["object": "chat.completion", "model": "gpt-4o-mini-2024-07-18", "choices": [["index": 0, "message": ["role": "assistant", "content": (call == 0 ? item.summary : item.rawClassification) as Any? ?? NSNull()]]]])
                call += 1; return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let summary = try await client.summary(excerpt: text), category = try await client.classification(name: item.name, summary: summary, excerpt: text)
            try check(summary == item.summary && category == item.category && call == 2, "original summary/null and ECMAScript classification normalization")
        }
        for status in [401, 429, 503] {
            let client = try NativeOpenAIChatClient(apiKey: "qa-key", request: { request in (Data("provider-secret-must-not-leak".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) })
            do { _ = try await client.summary(excerpt: "本文"); throw NativeDBError.conflict }
            catch let error as NativeAIError { try check(error.retryable == (status != 401) && !error.message.contains("provider-secret"), "safe status and retry policy") }
        }
        let bad = try NativeOpenAIChatClient(apiKey: "qa-key", request: { request in (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        try await reject("malformed chat response") { _ = try await bad.summary(excerpt: "本文") }
        for mode in ["good", "large"] {
            var request = URLRequest(url: NativeOpenAIChatClient.endpoint); request.setValue(mode, forHTTPHeaderField: "X-Test")
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NativeDocumentAIProtocol.self]
            if mode == "large" { try await reject("streamed oversized chat response") { _ = try await NativeEmbeddingClient.providerTransport(request, endpoint: NativeOpenAIChatClient.endpoint, configuration: config) } }
            else { let result = try await NativeEmbeddingClient.providerTransport(request, endpoint: NativeOpenAIChatClient.endpoint, configuration: config); try check(result.0 == Data("{\"ok\":true}".utf8), "actual Foundation chat byte stream") }
        }
        try await reject("foreign provider endpoint") { _ = try await NativeEmbeddingClient.providerTransport(URLRequest(url: URL(string: "https://example.invalid")!), endpoint: URL(string: "https://example.invalid")!) }
    }
    static func resumeAndPublish(_ resources: URL) async throws {
        let f = try Fixture(resources), input = try f.source(String(repeating: "日本語😀\n", count: 9000))
        let old = try NativeEmbeddingIndex(db: f.db).save(.document, source: input.row, vector: vector(-1), contentHash: NativeEmbeddingVector.hash("old complete generation"), actor: f.service.identity.id)
        var calls = 0, failed = false
        let generate: NativeEmbeddingWorker.Generate = { text, _ in
            calls += 1
            try check(try NativeEmbeddingIndex(db: f.db).existing(.document, parentID: input.row["id"].string)?["id"] == old["id"], "incomplete chunks do not replace old index")
            if calls == 3 && !failed { failed = true; throw NativeAIError(message: "一時的な混雑", retryable: true) }; return try vector()
        }
        try await run(f.worker(generate: generate))
        let interrupted = try f.job(input.job)
        try check(interrupted.status == "retry" && f.db.stagedDocumentAICount(interrupted) == 2 && f.fresh(input.row)["processing_status"] == .text("PENDING"), "failed third chunk preserves two completed chunks and visible retry state")
        f.now.addTimeInterval(10); try await run(f.worker(generate: generate))
        let completed = try f.job(input.job), chunks = try f.chunks(input.row)
        try check(completed.status == "done" && calls == chunks.count + 1 && f.summaries == 1 && f.classifications == 1, "retry resumes exact cursor without repeating paid chunks")
        try check(try NativeEmbeddingIndex(db: f.db).existing(.document, parentID: input.row["id"].string) == nil && f.db.stagedDocumentAICount(completed) == 0, "atomic completed generation replaces old vector and releases stage")

        let r = try Fixture(resources), doc = try r.source("要約と分類の検証")
        var summaryCalls = 0, categoryCalls = 0
        let summary: NativeDocumentAIWorker.Summary = { _, _ in summaryCalls += 1; if summaryCalls == 1 { throw NativeAIError(message: "混雑", retryable: true) }; return "要約" }
        let category: NativeDocumentAIWorker.Classify = { _, value, _, _ in categoryCalls += 1; try check(value == "要約", "resumed classification retains summary"); if categoryCalls == 1 { throw NativeAIError(message: "混雑", retryable: true) }; return "OFFER" }
        try await run(r.worker(summarize: summary, classify: category)); r.now.addTimeInterval(10)
        try await run(r.worker(summarize: summary, classify: category)); r.now.addTimeInterval(20)
        try await run(r.worker(summarize: summary, classify: category))
        try check(try r.job(doc.job).status == "done" && r.embeddings.count == 1 && summaryCalls == 2 && categoryCalls == 2, "summary/classification retry checkpoints avoid repeated completed calls")

        let a = try Fixture(resources), publication = try a.source("原子的な公開")
        _ = try NativeEmbeddingIndex(db: a.db).save(.document, source: publication.row, vector: vector(-1), contentHash: NativeEmbeddingVector.hash("prior"), actor: a.service.identity.id)
        try a.sql("CREATE TRIGGER reject_ai_publish BEFORE UPDATE ON Documents WHEN NEW.processing_status='READY' BEGIN SELECT RAISE(ABORT,'synthetic storage failure'); END")
        try await run(a.worker()); let failure = try a.job(publication.job)
        try check(try failure.status == "failed" && a.db.stagedDocumentAICount(failure) == 1 && NativeEmbeddingIndex(db: a.db).existing(.document, parentID: publication.row["id"].string)?["content_hash"].string == NativeEmbeddingVector.hash("prior"), "metadata publish failure rolls back index replacement")
        try a.sql("DROP TRIGGER reject_ai_publish"); try a.service.retryEmbeddingJob(failure); try await run(a.worker())
        try check(try a.job(publication.job).status == "done" && a.embeddings.count == 1 && a.summaries == 1 && a.classifications == 1, "publication-only retry reuses durable provider results")
    }
    static func inputLimitFallback(_ resources: URL) async throws {
        for status in [400, 413, 422] {
            let f = try Fixture(resources), body = String(repeating: "日本語の契約", count: 1000), input = try f.source(body)
            var wholeCalls = 0, chunkCalls = 0, completed: [String] = []
            let generate: NativeEmbeddingWorker.Generate = { text, _ in
                if text == body { wholeCalls += 1; throw NativeAIError(message: "入力上限", status: status) }
                chunkCalls += 1
                if chunkCalls == 2 { throw NativeAIError(message: "一時的な混雑", retryable: true, status: 429) }
                completed.append(text); return try vector()
            }
            try await run(f.worker(generate: generate))
            let retry = try f.job(input.job)
            try check(try retry.status == "retry" && retry.result["tokenFallback"] == "true" && f.db.stagedDocumentAICount(retry) == 1, "input-limit fallback and first chunk are durable")
            f.now.addTimeInterval(10); try await run(f.worker(generate: generate))
            let chunks = try f.chunks(input.row), result = try f.job(input.job)
            try check(result.status == "done" && result.result["single"] == "false" && wholeCalls == 1, "retry does not repeat rejected whole Japanese input")
            try check(chunks.map { $0["chunk_text"].string } == completed && chunkCalls == chunks.count + 1, "fallback resumes without repaying completed chunks")
            try check(chunks.allSatisfy { $0["chunk_text"].string.utf16.count <= NativeDocumentAIText.windowSize } && f.summaries == 1 && f.classifications == 1, "fallback bounds input and still summarizes and classifies")
        }
        for status in [401, 429] {
            let f = try Fixture(resources), input = try f.source(String(repeating: "日本語", count: 2000)); var calls = 0
            try await run(f.worker(generate: { _, _ in calls += 1; throw NativeAIError(message: "APIエラー", retryable: status == 429, status: status) }))
            try check(try calls == 1 && f.job(input.job).result["tokenFallback"] == nil, "credentials and rate limit failures never cause extra chunk requests")
        }
        let f = try Fixture(resources), input = try f.source("短い本文"); var calls = 0
        try await run(f.worker(generate: { _, _ in calls += 1; throw NativeAIError(message: "不正な入力", status: 400) }))
        try check(try calls == 1 && f.job(input.job).status == "failed", "short invalid input is not split repeatedly")
    }
    static func invalidation(_ resources: URL) async throws {
        for mode in ["replace", "owner", "key", "cancel", "reclaim", "manual"] {
            let f = try Fixture(resources), input = try f.source("処理中に変更される本文")
            var successor: NativeJob?
            let task = Task { try await f.worker(generate: { _, _ in
                let current = try f.fresh(input.row)
                switch mode {
                case "replace": _ = try f.source("新しい版の本文", replacing: current)
                case "owner": _ = try f.db.update(current, changes: ["createdBy": .text(f.bob.identity.id), "created_by_user": .text(f.bob.identity.id), "assigned_user": .text(f.bob.identity.id)], actor: f.admin.identity.id)
                case "key": f.key = "qa-new-key"
                case "cancel": withUnsafeCurrentTask { $0?.cancel() }
                case "reclaim": f.now.addTimeInterval(301); successor = try f.db.claimJob(events: [NativeDatabase.documentAIEvent], now: f.now)
                case "manual": _ = try f.db.update(current, changes: ["summary": .text("手動で編集した要約"), "document_system_type": .text("RECEIPT")], actor: f.service.identity.id)
                default: break
                }; return try vector()
            }).runNext() }
            _ = try await task.value
            let job = try f.job(input.job), indexed = try NativeEmbeddingIndex(db: f.db).existing(.document, parentID: input.row["id"].string)
            if mode == "manual" { try check(try job.status == "done" && f.fresh(input.row)["summary"] == .text("手動で編集した要約") && f.fresh(input.row)["document_system_type"] == .text("RECEIPT"), "manual summary/category edits win over automatic result") }
            else if mode == "reclaim" { try check(job == successor && indexed == nil, "reclaimed lease fences late document result") }
            else { try check(job.result["outcome"] != "enriched" && indexed == nil, "\(mode) prevents obsolete publication") }
            if mode == "cancel" { try check(try job.status == "retry" && f.fresh(input.row)["processing_status"] == .text("PENDING"), "cancelled process retains resumable document state") }
        }
        let f = try Fixture(resources), doc = try f.source("長い旧版の本文")
        _ = try NativeEmbeddingIndex(db: f.db).save(.document, source: doc.row, vector: vector(), contentHash: NativeEmbeddingVector.hash("old"), actor: f.service.identity.id)
        _ = try f.source("新版", replacing: f.fresh(doc.row))
        try check(try NativeEmbeddingIndex(db: f.db).existing(.document, parentID: doc.row["id"].string) == nil, "file replacement immediately invalidates stale published index")
        let waiting = try f.db.keysetPage("Documents", fields: ["key", "content_hash"], filter: .equal("id", doc.row["id"]), limit: 1).first!
        try check(try f.db.enqueueDocumentAI(waiting, actor: f.service.identity.id, now: f.now) == f.db.documentAIJob(doc.row["id"].string), "same pending extraction generation deduplicated")
    }
    static func cancellationAndBackfill(_ resources: URL) async throws {
        let f = try Fixture(resources), input = try f.source(String(repeating: "文書の本文", count: 8000))
        var generated = 0
        try await run(f.worker(generate: { _, _ in generated += 1; if generated == 2 { throw NativeAIError(message: "一時的な混雑", retryable: true) }; return try vector() }))
        let retry = try f.job(input.job)
        try check(try f.db.stagedDocumentAICount(retry) == 1, "cancellation fixture has a durable partial stage")
        try f.service.cancelEmbeddingJob(retry)
        try check(try f.job(input.job).status == "cancelled" && f.db.stagedDocumentAICount(retry) == 0 && f.db.documentAIJob(input.row["id"].string) == nil && f.fresh(input.row)["processing_status"] == .text("READY"), "explicit cancellation releases stage and leaves extracted document usable")
        let batch = try f.service.requestEmbeddingBackfill(now: f.now)
        try await run(f.worker()); try check(try f.job(batch).result["dispatched"] == "1", "full backfill includes writable processed document")
        try await run(f.worker()); try check(try f.fresh(input.row)["summary"] != .null, "backfill regenerates cancelled document")
        let publicDoc = try f.source("他の利用者に公開した文書")
        try f.service.cancelEmbeddingJob(f.job(publicDoc.job))
        _ = try f.db.update(f.fresh(publicDoc.row), changes: ["createdBy": .text(f.bob.identity.id), "created_by_user": .text(f.bob.identity.id), "assigned_user": .text(f.bob.identity.id), "visibility": .text("public")], actor: f.admin.identity.id)
        let second = try f.service.requestEmbeddingBackfill(now: f.now); try await run(f.worker())
        try check(try f.job(second).result["dispatched"] == "2", "original document write scope includes public documents")
        while try await f.worker().runNext() {}
        _ = try f.db.update(f.fresh(publicDoc.row), changes: ["visibility": .text("private")], actor: f.bob.identity.id)
        let third = try f.service.requestEmbeddingBackfill(now: f.now); try await run(f.worker())
        try check(try f.job(third).result["dispatched"] == "1", "private document owned by another actor excluded from backfill")
    }
}
