import Foundation

extension NativeMCPLeadsTests {
    static func mailCases() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1])); defer { f.close() }
        let db = f.db, alice = id(1), bob = id(2)
        let session = try NativeAPITokens.authenticate(f.credentials[alice]!.raw, db: db, clock: { f.now })
        let owner = CRMService(db: db, identity: .init(id: alice, role: "user", partnerAccountID: nil))
        func run(_ name: String, _ input: [String: Any]) throws -> NativeRecord {
            let result = try session.withAccess { try NativeMCPLeads.run(name, arguments: input, service: $0) } as! [String: Any]
            let data = result["data"] as! [String: Any]
            return try db.get("crm_Leads", key: ["id": .text(data["id"] as! String)])!
        }
        func assigned(_ title: String) throws -> (NativeRecord, NativeJob) {
            let module = CRMModule.find("crm_Leads")!
            let lead = try owner.save(module, original: nil, input: ["lastName": .text(title), "description": .text("メールに含めない私的な説明")])
            let changed = try owner.save(module, original: lead, input: ["assigned_to": .text(bob)])
            let job = try db.jobs(events: [NativeMCPLeads.assignedEvent]).first { $0.payload["leadId"] == lead["id"].string }!
            return (changed, job)
        }
        var now = Date(timeIntervalSince1970: 1_800_000_000.25), calls = 0, code = 200, timeout = false, configured = true
        var credentials = InvoiceMailAccount(from: "lead@example.invalid", apiKey: "synthetic-lead-key")
        var bodies: [Data] = [], keys: [String] = []
        let receipt = UUID().uuidString.lowercased()
        let request: ResendMailClient.Request = { query, file in
            calls += 1; bodies.append(try Data(contentsOf: file)); keys.append(query.value(forHTTPHeaderField: "Idempotency-Key")!)
            if timeout { throw URLError(.timedOut) }
            return (try json(code == 200 ? ["id": receipt] : ["name": "synthetic_error"]), HTTPURLResponse(url: query.url!, statusCode: code, httpVersion: nil, headerFields: code == 503 ? ["Retry-After": "20"] : nil)!)
        }
        func worker(_ database: NativeDatabase = db) -> NativeMCPLeadsMailWorker {
            NativeMCPLeadsMailWorker(db: database, account: { guard configured else { throw Failure.assertion("synthetic missing credentials") }; return credentials }, request: request, clock: { now })
        }
        let w = worker()
        func drain(_ current: NativeMCPLeadsMailWorker = w) async throws {
            var count = 0
            while try await current.runNext() { count += 1; if count > 30 { throw Failure.assertion("mail queue did not settle") } }
        }
        func body() throws -> [String: Any] { try JSONSerialization.jsonObject(with: bodies.last!) as! [String: Any] }
        let (first, firstJob) = try assigned("最初の日本語見込み客")
        try await drain()
        try check(calls == 1 && db.job(id: firstJob.id)?.status == "done", "changed assignee receives one message")
        let message = try body(), text = message["text"] as! String
        try check(message["subject"] as? String == "見込み客の担当者に設定されました：最初の日本語見込み客" && text.contains("bob 様"), "Japanese lead subject and greeting")
        try check(!text.contains("メールに含めない"), "notification omits unrelated private description")
        try check(keys.last == "nextcrm/lead/" + firstJob.id, "stable distinct idempotency namespace")
        let link = try NativeMCPLeadLink(leadID: first["id"].string)
        try check(text.contains(link.string) && NativeMCPLeadLink(text: " \n" + link.string + "\t") == link, "typed native lead link")
        for invalid in [link.string + "?q=x", link.string + "#x", link.string + "/", "nextcrm-native://leads:7/" + link.leadID, "https://leads/" + link.leadID, "nextcrm-native://u:p@leads/" + link.leadID, "nextcrm-native://leads/%2F" + link.leadID, "nextcrm-native://leads/no-uuid", "nextcrm-native://orders/" + link.leadID] {
            do { _ = try NativeMCPLeadLink(text: invalid); throw Failure.assertion("invalid lead link accepted") } catch is NativeDBError { checks += 1 }
        }
        try check(!FileManager.default.fileExists(atPath: InvoiceMail.bodyURL(root: f.root, id: firstJob.id).path), "successful body cleaned up")
        let longTitle = String(repeating: "長", count: 600) + "\n日本語"
        let longLead = try run("crm_create_lead", ["lastName": longTitle])
        _ = try run("crm_update_lead", ["id": longLead["id"].string, "assigned_to": bob]); try await drain()
        let long = try body(), subject = long["subject"] as! String
        try check(subject.utf8.count <= 998 && !subject.contains("\n") && subject.hasSuffix("…") && (long["text"] as! String).contains(longTitle), "long or multiline API name retained in body and safe mail subject")
        let (_, retryJob) = try assigned("再試行の見込み客")
        code = 503; try await drain(); let frozen = bodies.last!, frozenKey = keys.last!
        try check(try db.job(id: retryJob.id)?.status == "retry" && db.job(id: retryJob.id)?.deliveryStartedAt != nil, "transient failure retains durable attempt")
        _ = try run("crm_update_lead", ["id": retryJob.payload["leadId"]!, "lastName": "通知予約後の名前"])
        now += 21; code = 200
        let reopened = try NativeDatabase(url: db.url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        try await drain(worker(reopened))
        try check(try db.job(id: retryJob.id)?.status == "done" && db.job(id: retryJob.id)?.attempts == 2 && bodies.last == frozen && keys.last == frozenKey, "restart retry reuses exact body and key")
        let (reassigned, reassignedJob) = try assigned("送信前に担当変更")
        _ = try run("crm_update_lead", ["id": reassigned["id"].string, "assigned_to": alice]); let beforeSkip = calls
        try await drain(); try check(try calls == beforeSkip && db.job(id: reassignedJob.id)?.result["outcome"] == "skipped", "current assignee is rechecked")
        let (_, bannedJob) = try assigned("送信前に宛先停止")
        try f.change("Users", id: bob, values: ["banned": .integer(1)]); try await drain()
        try check(try calls == beforeSkip && db.job(id: bannedJob.id)?.result["outcome"] == "skipped", "banned recipient does not receive private name")
        try f.change("Users", id: bob, values: ["banned": .integer(0)])
        let (_, addressJob) = try assigned("送信前に宛先変更")
        try f.change("Users", id: bob, values: ["email": .text("changed@example.invalid")]); try await drain()
        try check(try calls == beforeSkip && db.job(id: addressJob.id)?.result["outcome"] == "skipped", "changed mailbox not substituted")
        try f.change("Users", id: bob, values: ["email": .text("bob@example.invalid")])
        let (deleted, deletedJob) = try assigned("送信前に削除")
        _ = try run("crm_delete_lead", ["id": deleted["id"].string]); try await drain()
        try check(try calls == beforeSkip && db.job(id: deletedJob.id)?.result["outcome"] == "skipped", "deleted lead does not send")
        let (_, missingJob) = try assigned("設定なし")
        configured = false; try await drain(); try check(try calls == beforeSkip && db.job(id: missingJob.id)?.status == "failed", "missing credentials fail locally")
        configured = true; try owner.retryLeadJob(missingJob.id, now: now); try await drain()
        try check(try db.job(id: missingJob.id)?.status == "done", "owner can retry after configuration restored")
        let (_, unknownJob) = try assigned("結果不明の送信")
        timeout = true; try await drain(); timeout = false
        try check(try db.job(id: unknownJob.id)?.status == "retry" && db.job(id: unknownJob.id)?.deliveryStartedAt != nil, "ambiguous network result remains durable")
        try f.change("Users", id: bob, values: ["email": .text("changed@example.invalid")]); now += 301; let beforeReview = calls; try await drain()
        try check(try calls == beforeReview && db.job(id: unknownJob.id)?.status == "needs_review", "changed recipient after uncertain send requires review without retry")
        try f.change("Users", id: bob, values: ["email": .text("bob@example.invalid")])
        let (_, keyJob) = try assigned("送信開始後に鍵変更")
        code = 503; try await drain(); code = 200; credentials = .init(from: "lead@example.invalid", apiKey: "different-synthetic-key"); now += 21; let beforeKey = calls
        try await drain(); try check(try calls == beforeKey && db.job(id: keyJob.id)?.status == "needs_review", "changed key cannot duplicate an ambiguous delivery")
        let (_, canceledJob) = try assigned("取り消す通知")
        try owner.cancelLeadJob(canceledJob.id); try await drain()
        try check(try calls == beforeKey && db.job(id: canceledJob.id)?.status == "cancelled", "authorized cancellation sends nothing")
        let outsider = CRMService(db: db, identity: .init(id: id(4), role: "admin", partnerAccountID: nil))
        try check(try outsider.leadJobAccess(unknownJob.id).id == unknownJob.id, "admin can inspect ambiguous lead notification")
        try check(try owner.leadFromLink(link)["id"] == first["id"], "native link resolves current authorized local record")
        try db.transaction {
            for _ in 0..<205 { try db.enqueue(NativeMCPLeads.assignedEvent, payload: firstJob.payload) }
        }
        let firstPage = try owner.leadJobs(leadID: first["id"].string), secondPage = try owner.leadJobs(leadID: first["id"].string, offset: 100), lastPage = try owner.leadJobs(leadID: first["id"].string, offset: 200)
        try check(firstPage.count == 100 && secondPage.count == 100 && lastPage.count == 6, "lead notification SQL paging beyond200 rows")
        try check(Set((firstPage + secondPage + lastPage).map(\.id)).count == 206 && (firstPage + secondPage + lastPage).allSatisfy { $0.payload["leadId"] == first["id"].string }, "no duplicated pages or other lead notifications")
        let readonly = try db.insert("crm_Leads", values: ["v": .integer(1), "lastName": .text("閲覧だけの見込み客"), "assigned_to": .text(bob), "createdBy": .text(bob), "accountsIDs": .text(id(101))], actor: bob)
        let privateJob = try db.enqueue(NativeMCPLeads.assignedEvent, payload: ["leadId": readonly["id"].string, "recipientId": bob, "recipientEmail": "bob@example.invalid", "leadName": "非公開の宛先", "actorID": bob])
        try check(try owner.leadJobs(leadID: readonly["id"].string).isEmpty, "linked-account reader cannot see someone else's notification address")
        do { _ = try owner.leadJobAccess(privateJob); throw Failure.assertion("readonly user managed another recipient job") } catch is NativeDBError { checks += 1 }
        let strangerRow = try db.insert("Users", values: ["name": .text("stranger"), "email": .text("stranger@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: alice)
        let stranger = CRMService(db: db, identity: .init(id: strangerRow["id"].string, role: "user", partnerAccountID: nil))
        do { _ = try stranger.leadJobs(leadID: first["id"].string); throw Failure.assertion("unrelated user saw notification history") } catch is NativeDBError { checks += 1 }
        do { _ = try stranger.leadFromLink(link); throw Failure.assertion("link granted authority") } catch is NativeDBError { checks += 1 }
        print("Verified Japanese lead notification delivery with isolated transport, retry/reopen, current recipient checks and ambiguous-outcome handling")
    }
}
