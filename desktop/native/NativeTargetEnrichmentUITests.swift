import AppKit

@main enum NativeTargetEnrichmentUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func rejects(_ label: String, _ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label) }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func control<T: NSView>(_ type: T.Type, _ label: String, _ window: NSWindow) throws -> T {
        guard let value = views(window.contentView!).compactMap({ $0 as? T }).first(where: { $0.accessibilityLabel() == label || ($0 as? NSButton)?.title == label }) else { throw NativeDBError.message("control: " + label) }; return value
    }
    static func click(_ label: String, _ window: NSWindow) throws { let button = try control(NSButton.self, label, window); try check(button.isEnabled, label + " enabled"); button.performClick(nil) }
    static func text(_ label: String, _ window: NSWindow) throws -> String { try control(NSTextField.self, label, window).stringValue }
    static func wait(_ condition: () throws -> Bool) throws { let end = Date().addingTimeInterval(10); while Date() < end { if try condition() { return }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }; throw NativeDBError.message("UI wait timeout") }
    static func layout(_ window: NSWindow) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        guard let stack = window.contentView!.subviews.first as? NSStackView else { throw NativeDBError.conflict }
        for view in stack.arrangedSubviews { let frame = view.convert(view.bounds, to: window.contentView); try check(frame.minY >= 0 && frame.maxY <= window.contentView!.bounds.height && frame.minX >= 0 && frame.maxX <= window.contentView!.bounds.width && frame.width > 0, "top level view fits: \(type(of: view)) \(frame)") }
        for table in views(stack).compactMap({ $0 as? NSTableView }) {
            // Offscreen table tiling may retain the scroll view's 1pt border
            // on each side. Permit only those 2pt, not a clipped data column.
            try check(table.rect(ofColumn: table.numberOfColumns - 1).maxX <= table.enclosingScrollView!.contentSize.width + 2, "all initial columns fit: \(table.accessibilityLabel() ?? ""), edge=\(table.rect(ofColumn: table.numberOfColumns - 1).maxX), viewport=\(table.enclosingScrollView!.contentSize.width), table=\(table.frame), scroll=\(table.enclosingScrollView!.frame)")
        }
    }
    static func toggle(_ table: NSTableView, row: Int, state: NSControl.StateValue) throws {
        guard let button = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton else { throw NativeDBError.message("missing checkbox") }
        try check(button.isEnabled, "checkbox enabled"); if button.state != state { button.performClick(nil) }
    }
    final class Fixture {
        let root: URL, db: NativeDatabase, admin: CRMService, alice: CRMService, bob: CRMService
        let store = NativeAIQAServices()
        var secrets = ["OPENAI_API_KEY": "qa-openai", "FIRECRAWL_API_KEY": "qa-firecrawl", "ANTHROPIC_API_KEY": "qa-anthropic", "E2B_API_KEY": "qa-e2b"]
        init(_ resources: URL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-TargetUI-" + UUID().uuidString)
            db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            let database = db, administrator = CRMService(db: database, identity: try CRMService.bootstrap(database, resources: resources.appendingPathComponent("../../prisma"))); admin = administrator
            func user(_ name: String) throws -> CRMService {
                let row = try database.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: administrator.identity.id)
                return .init(db: database, identity: .init(id: row["id"].string, role: "user", partnerAccountID: nil))
            }
            alice = try user("担当者A"); bob = try user("担当者B")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var env: NativeAIEnvironment { .init(lookup: { [unowned self] in self.secrets[$0] }) }
        func api(_ who: CRMService? = nil) -> NativeTargetEnrichmentService { .init(service: who ?? alice, store: store, environment: env) }
        func target(_ values: [String: SQLValue] = [:], who: CRMService? = nil) throws -> NativeRecord {
            let who = who ?? alice
            return try db.insert("crm_Targets", values: ["first_name": .text("太郎"), "last_name": .text("山田"), "email": .text("qa@example.invalid"), "company": .text("日本商事"), "company_website": .text("https://nihon.invalid"), "created_by": .text(who.identity.id)].merging(values) { _, new in new }, actor: who.identity.id)
        }
        func row(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model, key: db.key(for: row))! }
        func history(_ target: NativeRecord, result: String? = nil) throws -> String {
            try db.insert(NativeTargetEnrichment.model, values: ["targetId": target["id"], "status": .text("COMPLETED"), "fields": .text("[\"position\",\"personal_website\"]"), "result": .text(result ?? NativeContactEnrichment.json(output())), "triggeredBy": .text(alice.identity.id)], actor: alice.identity.id)["id"].string
        }
        func run(fail: Bool = false) throws {
            let worker = NativeTargetEnrichmentWorker(db: db, store: store, environment: env, review: { context, _, _, report in
                if fail { throw NativeAIError(message: "検証用の失敗") }; try await report(.init(message: "本人の情報を照合しています。", kind: .agent))
                let names = Set(context.fields.map(\.name)); return .init(enrichments: output().enrichments.filter { names.contains($0.key) }, status: .completed)
            }, agent: { context, _, _, _ in
                .init(target: ["industry": "情報通信", "company_website": "https://nihon.invalid"], contacts: [.init(name: context.name ?? "山田 太郎", email: context.email, title: "営業部長", linkedinUrl: "https://linkedin.com/in/taro", phone: "03-0000-0000", source: "https://nihon.invalid/team")], confidence: [:])
            })
            var completed = false, failure: Error?, processed = false
            Task { do { processed = try await worker.runNext() } catch { failure = error }; completed = true }
            try wait { completed }; if let failure { throw failure }; try check(processed, "durable target worker claimed request")
            NotificationCenter.default.post(name: InvoiceJobRunner.didProcess, object: nil, userInfo: ["database": db.url.path])
        }
    }
    static func output() -> NativeEnrichmentOutput {
        .init(enrichments: ["position": .init(field: "position", value: .string("営業部長"), confidence: 0.9, sourceContext: [.init(url: "https://nihon.invalid/team", snippet: "日本商事の山田太郎は営業部長です。")]),
            "personal_website": .init(field: "personal_website", value: .string("https://taro.invalid"), confidence: 0.8, sourceContext: [.init(url: "https://nihon.invalid/team", snippet: "本人のサイトはhttps://taro.invalidです。")])], status: .completed)
    }
    static func main() {
        do { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            try browsing(resources); try requests(resources); try results(resources); try contacts(resources); try histories(resources)
            print("Native target enrichment browser and AppKit: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func browsing(_ resources: URL) throws {
        let f = try Fixture(resources), other = try f.target(who: f.bob), deleted = try f.target(); _ = try f.history(other); let deletedID = try f.history(deleted)
        _ = try f.db.setDeleted(deleted, deleted: true, actor: f.admin.identity.id)
        var visible: [NativeRecord] = []
        try f.db.transaction { for index in 0..<105 { let target = try f.target(["last_name": .text(String(format: "番号%03d", index)), "description": .text(String(repeating: "本文", count: 1000))]); visible.append(target); _ = try f.history(target) } }
        let first = try f.api().historyPage(), second = try f.api().historyPage(offset: 100)
        try check(first.total == 105 && first.rows.count == 100 && second.rows.count == 5 && Set((first.rows + second.rows).map(\.id)).count == 105, "scoped history paginates without duplicate rows")
        try check(first.rows.allSatisfy { $0.history["result"] == .null && $0.target["description"] == .null && $0.actorName == "担当者A" }, "history metadata excludes result and batched parent/actor projection")
        try check(try f.api().targetsPage().rows.count == 100 && f.api().targetsPage(offset: 100).rows.count == 5 && f.api().targetsPage(search: "番号104").total == 1, "selector paging and Japanese search")
        try rejects("foreign target history") { _ = try f.api().historyPage(targetID: other["id"].string) }
        try rejects("foreign target contact list") { _ = try f.api().contactsPage(targetID: other["id"].string) }
        try rejects("deleted result even for admin") { _ = try f.api(f.admin).resultForReading(deletedID) }
        let target = visible[0], id = target["id"].string
        try f.db.transaction { for index in 0..<105 { _ = try f.api().addContact(targetID: id, name: "担当者\(index)", email: "person\(index)@example.invalid", phone: "", linkedinURL: "") } }
        try check(try f.api().contactsPage(targetID: id).rows.count == 100 && f.api().contactsPage(targetID: id, offset: 100).rows.count == 5, "contact browser reads at most100 rows")
        try check(try f.api().contactsPage(targetID: id, search: "person104@").total == 1, "contact browser search")
        try rejects("duplicate contact") { _ = try f.api().addContact(targetID: id, name: "重複", email: "person0@example.invalid", phone: "", linkedinURL: "") }
        try rejects("empty manual contact") { _ = try f.api().addContact(targetID: id, name: "　", email: " ", phone: "", linkedinURL: "") }
        try rejects("foreign target create") { _ = try f.api().addContact(targetID: other["id"].string, name: "禁止", email: "", phone: "", linkedinURL: "") }
        for _ in 0..<2 { let row = try f.api().addContact(targetID: id, name: "氏名だけ", email: "", phone: "", linkedinURL: ""); try check(row["email"] == .null && row["source"] == .text("manual") && row["enrichStatus"] == .text("PENDING"), "name-only contacts preserve nullable email and original defaults") }
        let link = try f.api().addContact(targetID: id, name: "リンク", email: "", phone: "", linkedinURL: "https://linkedin.com/in/test")
        try rejects("duplicate LinkedIn") { _ = try f.api().addContact(targetID: id, name: "重複", email: "", phone: "", linkedinURL: link["linkedinUrl"].string) }
    }
    static func requests(_ resources: URL) throws {
        let f = try Fixture(resources), target = try f.target(), id = target["id"].string
        let request = try NativeTargetEnrichmentRequestWindow(api: f.api(), targetID: id); try layout(request.window)
        let scenario = try control(NSPopUpButton.self, "営業先の調査対象", request.window), mode = try control(NSPopUpButton.self, "営業先の情報反映方法", request.window)
        try check(scenario.indexOfSelectedItem == 0 && mode.indexOfSelectedItem == 0, "email target defaults to personal review")
        try click("情報補完を開始", request.window)
        let job = try f.db.job(id: request.requestedIDs[0])!, fields = try NativeContactEnrichment.decode([NativeEnrichmentField].self, job.payload["fields"]!)
        try check(job.payload["mode"] == "review" && fields.map(\.name) == NativeTargetEnrichment.personalNames.filter { NativeTargetEnrichment.personalDefaults.contains($0) } && fields.first { $0.name == "social_linkedin" }?.subject == .person, "request stores personal default fields and subject")
        try f.run(); try check(try f.api().preview(job.id).result.enrichments["position"]?.value == .string("営業部長"), "requested review runs and is available for selection")
        let automatic = try NativeTargetEnrichmentRequestWindow(api: f.api(), targetID: id)
        let autoMode = try control(NSPopUpButton.self, "営業先の情報反映方法", automatic.window); autoMode.selectItem(at: 1); NSApp.sendAction(autoMode.action!, to: autoMode.target, from: autoMode)
        let force = try control(NSButton.self, "過去7日以内の取得済み対象も調べ直す", automatic.window); force.state = .on
        try click("情報補完を開始", automatic.window); let autoJob = try f.db.job(id: automatic.requestedIDs[0])!
        try check(autoJob.payload["mode"] == "automatic" && autoJob.payload["force"] == "true", "automatic force mode persisted")
        try check(try NativeContactEnrichment.decode([NativeEnrichmentField].self, autoJob.payload["fields"]!).allSatisfy { $0.subject == .company }, "automatic defaults target company social pages")
        try f.run(); try check(try f.row(target)["industry"] == .text("情報通信"), "automatic request fills blank target field")
        let unavailable = try NativeTargetEnrichmentRequestWindow(api: f.api(), targetID: id); f.secrets.removeValue(forKey: "OPENAI_API_KEY")
        try click("情報補完を開始", unavailable.window); try check(unavailable.requestedIDs.isEmpty && !(try text("営業先情報補完の予約結果", unavailable.window)).isEmpty, "missing credentials leave form open with error")
        f.secrets["OPENAI_API_KEY"] = "qa-openai"
        try f.db.transaction { for index in 0..<104 { _ = try f.target(["last_name": .text(String(format: "一括%03d", index))]) } }
        let bulk = try NativeTargetEnrichmentRequestWindow(api: f.api()); try layout(bulk.window)
        try click("このページを選択", bulk.window); try click("次へ", bulk.window); try click("このページを選択", bulk.window)
        try check(try text("営業先情報補完の選択件数", bulk.window).contains("100件") && text("営業先情報補完の予約結果", bulk.window).contains("100件を超え"), "cross-page selection cannot exceed100")
        try click("営業先の選択を解除", bulk.window); try click("このページを選択", bulk.window); try click("情報補完を開始", bulk.window)
        try check(bulk.requestedIDs.count == 5 && (try f.db.job(id: bulk.requestedIDs[0])?.payload["mode"]) == "bulk", "paged bulk request admits only selected IDs")
    }
    static func results(_ resources: URL) throws {
        let f = try Fixture(resources), target = try f.target(), id = try f.history(target)
        var copied: [String] = [], opened: [URL] = []
        let result = try NativeTargetEnrichmentResultWindow(api: f.api(), id: id, openURL: { opened.append($0) }, copyValue: { copied.append($0) }); try layout(result.window)
        let table = try control(NSTableView.self, "現在値と取得結果の比較", result.window); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try click("取得値をコピー", result.window); try click("根拠をブラウザで開く", result.window)
        try check(copied == ["営業部長"] && opened.first?.absoluteString == "https://nihon.invalid/team", "copy and source open use selected finding")
        try toggle(table, row: 1, state: .off); try click("選択した項目を反映", result.window)
        try check(try f.row(target)["position"] == .text("営業部長") && f.row(target)["personal_website"] == .null, "only checked review field applied")
        let stale = try NativeTargetEnrichmentResultWindow(api: f.api(), id: id)
        _ = try f.db.update(f.row(target), changes: ["position": .text("手動で変更")], actor: f.alice.identity.id)
        try click("選択した項目を反映", stale.window); try check(try f.row(target)["position"] == .text("手動で変更") && text("情報補完の反映結果", stale.window).contains("開き直し"), "stale result cannot overwrite manual edit")
        let agent = NativeTargetAgentOutput(target: ["industry": "情報通信"], contacts: [.init(name: "担当者", email: "person@example.invalid")], confidence: [:])
        let autoID = try f.history(target, result: NativeContactEnrichment.json(agent)), auto = try NativeTargetEnrichmentResultWindow(api: f.api(), id: autoID); try layout(auto.window)
        try check(!(try control(NSButton.self, "選択した項目を反映", auto.window)).isEnabled, "automatic result is read-only")
        let autoTable = try control(NSTableView.self, "現在値と取得結果の比較", auto.window)
        let confidence = auto.tableView(autoTable, viewFor: autoTable.tableColumns.last, row: 0) as! NSTextField
        try check(confidence.stringValue == "未提供", "missing agent confidence is not displayed as certainty")
        let reading = try f.api().resultForReading(autoID); try check(reading.contacts.count == 1 && reading.missingConfidence == ["industry"], "raw acquired contacts retained for reading")
        let bad = NativeEnrichmentOutput(enrichments: ["position": .init(field: "position", value: .string("不正値"), confidence: 1e100)], status: .completed)
        let badID = try f.history(target, result: NativeContactEnrichment.json(bad))
        try rejects("malformed historical confidence cannot crash display") { _ = try NativeTargetEnrichmentResultWindow(api: f.api(), id: badID) }
        let blocked = try NativeTargetEnrichmentResultWindow(api: f.api(), id: id, copyValue: { copied.append($0) })
        _ = try f.db.setDeleted(f.row(target), deleted: true, actor: f.alice.identity.id)
        try click("取得値をコピー", blocked.window); try check(copied.count == 1, "copy rechecks current parent access")
        try rejects("deleted result opening") { _ = try NativeTargetEnrichmentResultWindow(api: f.api(), id: id) }
    }
    static func contacts(_ resources: URL) throws {
        let f = try Fixture(resources), target = try f.target(), id = target["id"].string
        let contacts = try NativeTargetContactsWindow(api: f.api(), targetID: id); try layout(contacts.window)
        try control(NSTextField.self, "担当者の氏名", contacts.window).stringValue = "山田 太郎"
        try control(NSTextField.self, "担当者のメール", contacts.window).stringValue = "taro@example.invalid"
        try control(NSTextField.self, "担当者の電話", contacts.window).stringValue = "03-1111-2222"
        try click("担当者を追加", contacts.window)
        try check(try text("営業先担当者の操作結果", contacts.window) == "担当者を追加しました。" && contacts.confirmDiscard(), "manual add clears dirty form")
        let rows = try f.api().contactsPage(targetID: id).rows; try check(rows.count == 1 && rows[0]["phone"] == .text("03-1111-2222"), "manual input persisted")
        let jobID = try f.api().requestContact(rows[0]["id"].string, targetID: id); try f.run()
        try wait { (try? f.db.job(id: jobID)?.status) == "done" }
        try check(try f.row(rows[0])["title"] == .text("営業部長") && f.row(rows[0])["phone"] == .text("03-1111-2222"), "contact enrichment preserves manual phone")
        let reading = try f.api().resultForReading(jobID)
        try check(reading.isContact && reading.result.enrichments.count == 3 && reading.currentValue("phone") == "03-1111-2222" && reading.result.enrichments["phone"]?.value == .string("03-0000-0000"), "contact result compares actual contact fields instead of an empty target object")
        let result = try NativeTargetEnrichmentResultWindow(api: f.api(), id: jobID); try layout(result.window)
        let compared = try control(NSTableView.self, "現在値と取得結果の比較", result.window)
        try check(result.numberOfRows(in: compared) == 3 && !(try control(NSButton.self, "選択した項目を反映", result.window)).isEnabled, "contact result exposes all3 fields read-only")
        _ = try f.db.update(f.row(rows[0]), changes: ["name": .text("後から編集した名前"), "email": .text("changed@example.invalid")], actor: f.alice.identity.id)
        try check(try f.api().resultForReading(jobID).result.enrichments.count == 3, "historical contact matching uses captured identity after current identity changes")
        try f.db.remove(f.row(rows[0]), actor: f.alice.identity.id)
        try check(try f.api().resultForReading(jobID).contact == nil && f.api().resultForReading(jobID).currentValue("phone").contains("削除済み"), "deleted contact history preserves findings without cross-target current values")
        var opened: [URL] = [], access = true
        let raw = (0..<205).map { NativeTargetAgentOutput.Contact(name: "担当者\($0)", source: $0 == 0 ? "file:///etc/passwd" : "https://nihon.invalid/team/\($0)") }
        let acquired = NativeTargetAcquiredContactsWindow(contacts: raw, requireAccess: { if !access { throw NativeDBError.conflict } }, openURL: { opened.append($0) }); try layout(acquired.window)
        let table = try control(NSTableView.self, "取得した担当者一覧", acquired.window)
        try check(acquired.numberOfRows(in: table) == 100, "raw result table renders only100 rows")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); try check(!(try control(NSButton.self, "出典を開く", acquired.window)).isEnabled, "unsafe source cannot open")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); try click("出典を開く", acquired.window)
        try click("次へ", acquired.window); try click("次へ", acquired.window); try check(acquired.numberOfRows(in: table) == 5, "raw result last page bounded")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); access = false; try click("出典を開く", acquired.window)
        try check(opened.count == 1, "raw source opening rechecks access")
        try click("前へ", acquired.window); try check(acquired.numberOfRows(in: table) == 0, "raw paging clears data after access revoked")
    }
    static func histories(_ resources: URL) throws {
        let f = try Fixture(resources), target = try f.target(), fields = NativeTargetEnrichment.fields(["position"], scenario: .personal)
        let id = try f.api().request(targetIDs: [target["id"].string], fields: fields, mode: .review)[0]
        let history = try NativeTargetEnrichmentHistoryWindow(api: f.api(), targetID: target["id"].string, focusedID: id); try layout(history.window)
        try click("処理を取り消す", history.window); try check(try f.db.job(id: id)?.status == "cancelled", "history cancels selected pending job")
        let failure = try f.api().request(targetIDs: [target["id"].string], fields: fields, mode: .review)[0]; try f.run(fail: true)
        let failed = try NativeTargetEnrichmentHistoryWindow(api: f.api(), focusedID: failure); try click("再試行", failed.window)
        try check(try f.db.job(id: failure)?.status == "pending" && f.db.job(id: failure)?.payload["mode"] == "review", "history retry preserves review mode")
        try f.run(); try click("再読み込み", failed.window); try check((try control(NSButton.self, "結果を確認…", failed.window)).isEnabled, "completed history exposes result")
        _ = try f.db.update(f.row(target), changes: ["created_by": .text(f.bob.identity.id)], actor: f.admin.identity.id)
        try click("再読み込み", failed.window)
        try check((try control(NSTableView.self, "情報補完の履歴一覧", failed.window)).numberOfRows == 0, "history removes rows after access revoked")
    }
}
