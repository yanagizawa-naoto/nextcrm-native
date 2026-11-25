import Foundation
import CryptoKit

@main enum NativeMCPDocumentsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func id(_ value: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", value) }
    static func key(_ row: [String: Any]) -> String { row["id"] as? String ?? row.keys.filter { $0.hasSuffix("_id") }.sorted().map { row[$0] as! String }.joined(separator: ":") }
    static func values(_ object: [String: Any], model: NativeSchema.Model) throws -> [String: SQLValue] {
        try object.reduce(into: [:]) { result, pair in
            let (field, value) = pair
            if value is NSNull { result[field] = .null }
            else if model.field(field)?.type == "BigInt", let text = value as? String { result[field] = .integer(Int64(text)!) }
            else if let number = value as? NSNumber { result[field] = .integer(number.int64Value) }
            else if let text = value as? String { result[field] = .text(text) }
            else { result[field] = .text(String(decoding: try json(value), as: UTF8.self)) }
        }
    }
    actor Buffer { var bytes = Data(); func append(_ data: Data) { bytes.append(data) } }
    static func call(_ router: NativeMCPRequestRouter, tool: String, arguments: [String: Any], header: String) async throws -> [String: Any] {
        let request = NativeMCPHTTPRequest(method: "POST", path: "/api/mcp/mcp", headers: ["accept": "application/json, text/event-stream", "content-type": "application/json", "authorization": header], body: try json(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]))
        let response = await router.handle(request), buffer = Buffer(); try await response.writeBody { await buffer.append($0) }
        let line = String(decoding: await buffer.bytes, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("data: ") }!
        return (try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any])["result"] as! [String: Any]
    }
    static func payload(_ result: [String: Any]) throws -> [String: Any] {
        let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    static func normalized(_ value: Any, generated: String?, objectKey: String?) throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<sanitized>" }
            let isNew = generated != nil && object["id"] as? String == generated
            for (field, item) in object {
                if !(item is NSNull), ["updatedAt", "deletedAt", "last_updated"].contains(field) || isNew && ["createdAt", "date_created"].contains(field) {
                    try check((item as? String).flatMap(NativeMCPWire.canonicalUTC) != nil, "valid variable date " + field); object[field] = "<date>"
                } else if ["url", "presignedUrl"].contains(field) { object[field] = "<verified-signature>" }
                else {
                    let parsed = try normalized(item, generated: generated, objectKey: objectKey)
                    if ["accounts", "contacts", "leads", "opportunities", "tasks"].contains(field), let array = parsed as? [[String: Any]] { object[field] = array.sorted { key($0) < key($1) } }
                    else { object[field] = parsed }
                }
            }
            return object
        }
        if let array = value as? [Any] { return try array.map { try normalized($0, generated: generated, objectKey: objectKey) } }
        if let text = value as? String {
            if text == generated { return "<new>" }
            if let objectKey, text.contains(objectKey) { return text.replacingOccurrences(of: objectKey, with: "<new-object>" + URL(fileURLWithPath: objectKey).pathExtension) }
        }
        return value
    }
    static func main() async {
        do { try await run(); print("Native MCP documents: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-documents-reference.json"))) as! [String: Any]
        let seeds = reference["seeds"] as! [String: [[String: Any]]]
        let groups = ["Boards", "Sections", "Tasks", "tasksComments", "crm_Leads", "crm_Contacts", "crm_Opportunities", "Documents", "DocumentsToAccounts", "DocumentsToLeads", "DocumentsToContacts", "DocumentsToOpportunities", "DocumentsToTasks", "BoardWatchers"]
        var initial: [String: [String: NativeRecord]] = [:]
        for model in groups {
            initial[model] = [:]
            for seed in seeds[model]! {
                let row = try fixture.db.insert(model, values: values(seed, model: fixture.db.schema.model(model)), actor: fixture.admin.identity.id)
                initial[model]![key(seed)] = row
            }
        }
        func rows(_ model: String) throws -> [NativeRecord] {
            var result: [NativeRecord] = [], offset = 0
            let schema = try fixture.db.schema.model(model)
            while true {
                let page = try fixture.db.page(model, fields: schema.fields.map(\.name), includeDeleted: true, offset: offset, sort: schema.primaryKey[0])
                result += page.rows; if page.rows.count < 100 { return result }; offset += page.rows.count
            }
        }
        func recordKey(_ row: NativeRecord) -> String {
            if row.values["id"] != nil { return row["id"].string }
            return row.values.keys.filter { $0.hasSuffix("_id") }.sorted().map { row[$0].string }.joined(separator: ":")
        }
        func reset() throws {
            try fixture.db.transaction {
                for model in groups {
                    let current = try rows(model), found = Set(current.map(recordKey)), schema = try fixture.db.schema.model(model)
                    for row in current {
                        guard let original = initial[model]![recordKey(row)] else { try fixture.db.remove(row, actor: fixture.admin.identity.id); continue }
                        let immutable = schema.primaryKey + schema.fields.filter { $0.attributes.contains("@updatedAt") }.map(\.name)
                        let changes = original.values.filter { !immutable.contains($0.key) && row[$0.key] != $0.value }
                        if !changes.isEmpty { _ = try fixture.db.update(row, changes: changes, actor: fixture.admin.identity.id) }
                    }
                    for (key, row) in initial[model]! where !found.contains(key) { _ = try fixture.db.insert(model, values: row.values, actor: fixture.admin.identity.id) }
                }
            }
        }
        let epoch = NativeAPITokens.date(.text(reference["epoch"] as! String))!
        let local = try NativeMCPDocumentStorage.local(publicURL: "https://public.invalid:9443/base", bucket: "fixture-bucket", appURL: "http://127.0.0.1:45678/base", secret: "synthetic-local-secret-not-real", clock: { epoch })
        let s3 = try NativeMCPDocumentStorage.s3(publicURL: "https://public.invalid:9443/base", bucket: "fixture-bucket", accessKey: "SYNTHETICACCESS", secretKey: "synthetic-secret-not-real", clock: { epoch })
        let validator = try NativeMCPDocumentLocalSigner(appURL: "http://127.0.0.1:45678/base", secret: "synthetic-local-secret-not-real", clock: { epoch })
        for sample in reference["signatures"] as! [[String: Any]] {
            let storage: NativeMCPDocumentStorage
            if let endpoint = sample["endpoint"] as? String { storage = try .s3(publicURL: endpoint, bucket: "fixture-bucket", accessKey: "SYNTHETICACCESS", secretKey: "synthetic-secret-not-real", clock: { epoch }) }
            else { storage = sample["mode"] as! String == "local" ? local : s3 }
            let method = sample["method"] as! String, key = sample["key"] as! String, type = sample["contentType"] as! String, expires = sample["expiresIn"] as! Int
            let actual = try method == "PUT" ? storage.presignPut(key, contentType: type, expiresIn: expires) : storage.presignGet(key, expiresIn: expires)
            try check(actual == sample["url"] as! String, "exact original \(sample["mode"]!) \(method) signature for \(key): \(actual) != \(sample["url"]!)")
        }
        for sample in reference["validations"] as! [[String: Any]] {
            let actual = try validator.validate(URL(string: sample["url"] as! String)!, method: sample["method"] as! String, contentType: sample["contentType"] as! String)
            try check(actual == sample["key"] as? String, "original local validation " + (sample["mutation"] as! String))
        }
        for sample in reference["endpointCases"] as! [[String: Any]] { try check(NativeMCPDocumentStorage.publicEndpoint(sample["environment"] as! [String: String]) == sample["url"] as! String, "public endpoint fallback and trailing slash") }
        final class SigningProbe { var calls: [[String: Any]] = []; var fail = false }
        let probe = SigningProbe()
        let storage = NativeMCPDocumentStorage(publicURL: local.publicURL, bucket: local.bucket) { key, method, expiry, type in
            probe.calls.append(["key": key, "method": method, "expiresIn": expiry, "contentType": type])
            if probe.fail { throw NativeMCPFailure.internalError }
            return try method == "PUT" ? local.presignPut(key, contentType: type, expiresIn: expiry) : local.presignGet(key, expiresIn: expiry)
        }
        let handlers = NativeMCPDocuments.handlers(storage: storage), router = try fixture.router(handlers: handlers)
        try check(handlers.count == 8 && router.missingTools.count == 115, "eight original document operations")
        for sample in reference["cases"] as! [[String: Any]] {
            try reset(); probe.calls = []; probe.fail = sample["failSigning"] as! Bool
            let auditBefore = try Dictionary(uniqueKeysWithValues: groups.map { ($0, try fixture.db.auditCount($0)) })
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(tool) \(input)"
            let result = try await call(router, tool: tool, arguments: input, header: fixture.header(user))
            let actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            let generatedRow = tool == "crm_create_document" ? try rows("Documents").first { initial["Documents"]![$0["id"].string] == nil } : nil
            let generated = generatedRow?["id"].string, objectKey = generatedRow?["key"].string, expectedGenerated = generated == nil ? nil : id(9999)
            let expectedObjectKey = objectKey == nil ? nil : "documents/" + id(9998) + "." + URL(fileURLWithPath: objectKey!).pathExtension
            let left = try json(normalized(actual, generated: generated, objectKey: objectKey)), right = try json(normalized(expected, generated: expectedGenerated, objectKey: expectedObjectKey))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "source error flag " + label)
            if let data = actual["data"] as? [String: Any], let url = data["presignedUrl"] as? String ?? data["url"] as? String {
                let call = probe.calls.last!, valid = try validator.validate(URL(string: url)!, method: call["method"] as! String, contentType: call["contentType"] as! String)
                try check(valid == call["key"] as? String, "real returned URL signature validates " + label)
                let method = call["method"] as! String, originalURL = try method == "PUT" ? local.presignPut(call["key"] as! String, contentType: call["contentType"] as! String) : local.presignGet(call["key"] as! String, expiresIn: 3600)
                try check(url == originalURL, "expiry and URL fields exact " + label)
            }
            try check(try json(normalized(probe.calls, generated: nil, objectKey: objectKey)) == json(normalized(sample["signingCalls"]!, generated: nil, objectKey: expectedObjectKey)), "source provider call arguments " + label)
            let expectedState = sample["state"] as! [String: [String: Any]], writes = sample["writes"] as! [[String: String]]
            for model in groups {
                let delta = expectedState[model]!
                var wanted = Dictionary(uniqueKeysWithValues: seeds[model]!.map { (key($0), $0) })
                for row in delta["changed"] as! [[String: Any]] { wanted[key(row)] = row }
                for key in delta["removed"] as! [String] { wanted.removeValue(forKey: key) }
                let stored = try rows(model)
                try check(stored.count == delta["total"] as! Int, "exact row count \(model) " + label)
                let actualRows = try stored.map { try normalized(NativeMCPWire.record($0, schema: fixture.db.schema), generated: generated, objectKey: objectKey) as! [String: Any] }.sorted { key($0) < key($1) }
                let expectedRows = try wanted.values.map { try normalized($0, generated: expectedGenerated, objectKey: expectedObjectKey) as! [String: Any] }.sorted { key($0) < key($1) }
                if try json(actualRows) != json(expectedRows) {
                    let first = zip(actualRows, expectedRows).first { (try? json($0.0)) != (try? json($0.1)) }
                    throw Failure.assertion("complete state \(model) \(label); first difference \(String(describing: first))")
                }
                try check(true, "complete fields and relations " + model)
                let expectedWrites = writes.filter { $0["model"] == model }
                try check(try fixture.db.auditCount(model) == auditBefore[model]! + expectedWrites.count, "only source writes audited \(model) " + label)
                for change in expectedWrites {
                    var rawKey = change["key"]!; if rawKey == id(9999), let generated { rawKey = generated }
                    let schema = try fixture.db.schema.model(model), parts = rawKey.components(separatedBy: ":")
                    let identity = Dictionary(uniqueKeysWithValues: zip(schema.primaryKey.sorted(), parts).map { ($0, SQLValue.text($1)) })
                    try check(try fixture.db.history(NativeRecord(model: model, values: identity, revision: 0)).first?["actor"] == .text(user), "audit actor matches token " + label)
                }
            }
        }
        try reset()
        let auditBefore = try fixture.db.auditCount("Documents")
        let cancelStorage = NativeMCPDocumentStorage(publicURL: local.publicURL, bucket: local.bucket) { _, _, _, _ in withUnsafeCurrentTask { $0?.cancel() }; return "unreachable" }
        let canceledRouter = try fixture.router(handlers: NativeMCPDocuments.handlers(storage: cancelStorage))
        let canceled = Task { try await call(canceledRouter, tool: "crm_create_document", arguments: ["document_name": "cancel", "contentType": "text/plain"], header: fixture.header(id(1))) }
        do { _ = try await canceled.value; throw Failure.assertion("canceled creation committed") }
        catch is CancellationError { try check(true, "create cancellation propagates") }
        try check(try rows("Documents").count == seeds["Documents"]!.count, "cancellation rolls back new document")
        try check(try fixture.db.auditCount("Documents") == auditBefore, "cancellation rolls back document audit")
        probe.fail = false
        let saved = try payload(await call(router, tool: "crm_link_document", arguments: ["document_id": id(804), "entityType": "account", "entityId": id(101)], header: fixture.header(id(1))))
        try check(saved["data"] != nil, "source allows owner link on deleted document")
        let reopened = try NativeDatabase(url: fixture.db.url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        try check(try reopened.get("DocumentsToAccounts", key: ["document_id": .text(id(804)), "account_id": .text(id(101))]) != nil, "committed link survives independent database reopen")
        try check(try fixture.db.jobs(events: ["document/uploaded", "documents.file_cleanup"]).isEmpty, "MCP metadata handlers add no upload processing or file cleanup jobs")
        let providerReference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-documents-storage-reference.json"))) as! [String: Any]
        try await files(fixture.root, reference: providerReference)
        print("Compared \((reference["cases"] as! [Any]).count) original document cases plus exact AWS/local signatures, all stored state, provider calls, owner/read gates, persistence and cancellation rollback")
    }
    static func files(_ root: URL, reference: [String: Any]) async throws {
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let source = Dictionary(uniqueKeysWithValues: (reference["cases"] as! [[String: Any]]).map { ($0["label"] as! String, $0) })
        let block = Data((0..<65537).map { UInt8($0 % 251) })
        let upload = try NativeMCPDocumentUpload(dataRoot: root, contentType: "application/pdf")
        var expected = SHA256()
        for _ in 0..<20 { try upload.append(block); expected.update(data: block) }
        let metadata = try upload.finish()
        try check(metadata.bytes == Int64(block.count * 20) && metadata.sha256 == expected.finalize().map { String(format: "%02x", $0) }.joined(), "incremental exact bytes and SHA256")
        try check(metadata.bytes == (source["binary"]!["bytes"] as! NSNumber).int64Value && metadata.sha256 == source["binary"]!["sha256"] as! String && metadata.contentType == source["binary"]!["contentType"] as! String, "actual original binary put/get outcome")
        try upload.publish(); upload.retainAfterCommit()
        let reader = try NativeMCPDocumentObjectReader(dataRoot: root, metadata: metadata)
        var received: Int64 = 0, chunks = 0, hash = SHA256()
        while let data = try reader.readChunk() { try check(data.count <= 256 * 1024, "bounded binary download chunk"); received += Int64(data.count); chunks += 1; hash.update(data: data) }
        try check(received == metadata.bytes && chunks == 6 && hash.finalize().map { String(format: "%02x", $0) }.joined() == metadata.sha256, "durable exact file roundtrip")
        let pending = try NativeMCPDocumentUpload(dataRoot: root, contentType: "text/plain")
        try pending.append(Data("discard".utf8)); let discarded = try pending.finish(); try pending.publish(); pending.discard()
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(discarded.fileKey).path), "published staging rollback removes uncommitted blob")
        let canceled = Task { () throws -> Void in
            let staged = try NativeMCPDocumentUpload(dataRoot: root, contentType: "text/plain")
            try staged.append(block); withUnsafeCurrentTask { $0?.cancel() }; _ = try staged.finish()
        }
        do { try await canceled.value; throw Failure.assertion("canceled file staging finished") }
        catch is CancellationError { try check(true, "upload cancellation propagates") }
        try check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("native-documents").path).allSatisfy { !$0.hasPrefix(".stage-") }, "staging cleanup after cancellation")
        let zero = try NativeMCPDocumentUpload(dataRoot: root, contentType: "text/plain")
        let empty = try zero.finish(); try zero.publish(); zero.retainAfterCommit()
        try check(empty.bytes == 0 && empty.sha256 == digest(Data()), "empty body hash matches source ETag")
        try check("\"" + empty.sha256 + "\"" == source["empty"]!["ETag"] as! String, "original empty ETag")
        let emptyReader = try NativeMCPDocumentObjectReader(dataRoot: root, metadata: empty)
        try check(try emptyReader.readChunk() == nil, "empty body has no extra bytes")
        // Existing immutable document readers use the very same physical file.
        let existing = try NativeDocumentFiles(dataRoot: root).verifiedURL(key: metadata.fileKey, bytes: metadata.bytes, sha256: metadata.sha256)
        try check(existing == root.appendingPathComponent(metadata.fileKey), "existing native store reads MCP binary without duplicate storage")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("native-documents").path).count
        for type in ["text/plain\r\ninjected", "text/plain\rinjected", "text/plain\ninjected", String(repeating: "a", count: 257), String(repeating: "😀", count: 129)] {
            do { _ = try NativeMCPDocumentUpload(dataRoot: root, contentType: type); throw Failure.assertion("invalid MIME accepted") }
            catch is NativeMCPFailure { try check(true, "invalid MIME rejected before filesystem changes") }
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("native-documents").path).count == before, "invalid MIME leaves no blob")
        let old = try NativeMCPDocumentUpload(dataRoot: root, contentType: "text/plain"); try old.append(Data("old".utf8)); let oldInfo = try old.finish(); try old.publish(); old.retainAfterCommit()
        let oldReader = try NativeMCPDocumentObjectReader(dataRoot: root, metadata: oldInfo)
        let new = try NativeMCPDocumentUpload(dataRoot: root, contentType: "application/custom"); try new.append(Data("new\0bytes".utf8)); let newInfo = try new.finish(); try new.publish(); new.retainAfterCommit()
        // A logical mapping replacement can safely unlink the superseded file:
        // this already-open reader retains its original inode like the source.
        try NativeDocumentFiles(dataRoot: root).removeUnreferenced(key: oldInfo.fileKey)
        let oldBytes = try oldReader.readChunk()!
        try check(digest(oldBytes) == source["replace-keeps-open-inode"]!["oldSHA256"] as! String, "original open inode survives replacement cleanup")
        try check(try oldReader.readChunk() == nil, "old reader exact EOF")
        let newReader = try NativeMCPDocumentObjectReader(dataRoot: root, metadata: newInfo), newBytes = try newReader.readChunk()!
        try check(digest(newBytes) == source["replace-keeps-open-inode"]!["newSHA256"] as! String && newInfo.contentType == source["replace-keeps-open-inode"]!["newType"] as! String, "replacement MIME and embedded NUL binary preserve source bytes")
        try check(try newReader.readChunk() == nil, "new reader exact EOF")
        let files = try NativeDocumentFiles(dataRoot: root)
        try files.removeUnreferenced(key: empty.fileKey); try files.removeUnreferenced(key: empty.fileKey)
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(empty.fileKey).path), "idempotent physical cleanup matches source deletion")
        do {
            _ = try NativeMCPDocumentObjectReader(dataRoot: root, metadata: .init(fileKey: "native-documents/../escape.txt", contentType: "text/plain", bytes: 0, sha256: empty.sha256))
            throw Failure.assertion("physical path traversal accepted")
        } catch is NativeDBError { try check(true, "logical opaque keys never become physical traversal paths") }
    }
}
