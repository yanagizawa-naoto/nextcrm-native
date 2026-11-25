import AppKit

@main enum NativeContactEnrichmentUITests {
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
        let root: URL, db: NativeDatabase, admin: CRMService, alice: CRMService, bob: CRMService, partner: CRMService
        let store = NativeAIQAServices()
        var openai: String? = "qa-openai", firecrawl: String? = "qa-firecrawl"
        init(_ resources: URL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-EnrichmentUI-" + UUID().uuidString)
            db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            let database = db, administrator = CRMService(db: database, identity: try CRMService.bootstrap(database, resources: resources.appendingPathComponent("../../prisma"))); admin = administrator
            func user(_ name: String, role: String = "user") throws -> CRMService {
                let row = try database.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text(role), "userStatus": .text("ACTIVE")], actor: administrator.identity.id)
                return CRMService(db: database, identity: .init(id: row["id"].string, role: role, partnerAccountID: nil))
            }
            alice = try user("担当者A"); bob = try user("担当者B"); partner = try user("パートナー", role: "partner")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var env: NativeAIEnvironment { .init(lookup: { [unowned self] in $0 == "OPENAI_API_KEY" ? self.openai : $0 == "FIRECRAWL_API_KEY" ? self.firecrawl : nil }) }
        func api(_ who: CRMService? = nil) -> NativeContactEnrichmentService { .init(service: who ?? alice, store: store, environment: env) }
        func contact(_ values: [String: SQLValue] = [:], who: CRMService? = nil) throws -> NativeRecord {
            let who = who ?? alice; var input: [String: SQLValue] = ["first_name": .text("日本"), "last_name": .text("太郎"), "email": .text("qa@example.invalid"), "v": .integer(0), "createdBy": .text(who.identity.id)]
            input.merge(values) { _, new in new }; return try db.insert("crm_Contacts", values: input, actor: who.identity.id)
        }
        func row(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model, key: db.key(for: row))! }
        func history(_ contact: NativeRecord, result: NativeEnrichmentOutput = output()) throws -> String {
            try db.insert(NativeContactEnrichment.model, values: ["contactId": contact["id"], "status": .text("COMPLETED"), "fields": .text(NativeContactEnrichment.json(result.enrichments.keys.sorted())), "result": .text(NativeContactEnrichment.json(result)), "triggeredBy": .text(alice.identity.id)], actor: alice.identity.id)["id"].string
        }
        func run(_ generate: @escaping NativeContactEnrichmentWorker.Enrich = { _, _, _, _, report in
            try await report(.init(message: "会社の情報を確認しています", kind: .agent)); return output()
        }) throws {
            let worker = NativeContactEnrichmentWorker(db: db, store: store, environment: env, enrich: generate)
            var completed = false, failure: Error?, processed = false
            Task { do { processed = try await worker.runNext() } catch { failure = error }; completed = true }
            try wait { completed }; if let failure { throw failure }; try check(processed, "real durable worker claimed request")
            NotificationCenter.default.post(name: InvoiceJobRunner.didProcess, object: nil, userInfo: ["database": db.url.path])
        }
    }
    static func output() -> NativeEnrichmentOutput {
        .init(enrichments: ["position": .init(field: "position", value: .string("営業部長"), confidence: 0.9, source: "https://example.invalid/about", sourceContext: [.init(url: "https://example.invalid/about", snippet: "日本太郎は営業部長です。")]),
            "website": .init(field: "website", value: .string("https://example.invalid"), confidence: 1),
            "従業員数": .init(field: "従業員数", value: .string("150人"), confidence: 0.8)], status: .completed)
    }
    static func main() {
        do { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); let resources = URL(fileURLWithPath: CommandLine.arguments[1]); try browsing(resources); try requests(resources); try results(resources); try histories(resources); print("Native contact enrichment browser and AppKit: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func browsing(_ resources: URL) throws {
        let f = try Fixture(resources), other = try f.contact(who: f.bob), deleted = try f.contact(); _ = try f.history(other); let deletedID = try f.history(deleted)
        _ = try f.db.setDeleted(deleted, deleted: true, actor: f.admin.identity.id)
        var visible: [NativeRecord] = []
        try f.db.transaction { for index in 0..<105 { let row = try f.contact(["last_name": .text(String(format: "連絡先番号%03d", index)), "description": .text(String(repeating: "本文", count: 1000))]); visible.append(row); _ = try f.history(row) } }
        let first = try f.api().historyPage(), second = try f.api().historyPage(offset: 100)
        try check(first.total == 105 && first.rows.count == 100 && second.rows.count == 5, "history uses scoped 100-row pages")
        try check(Set((first.rows + second.rows).map(\.id)).count == 105, "paging has no duplicate history")
        try check(first.rows.allSatisfy { $0.history["result"] == .null && $0.contact["description"] == .null && $0.actorName == "担当者A" }, "projected summaries and batched names")
        try check(try f.api().contactsPage().rows.count == 100 && f.api().contactsPage(offset: 100).rows.count == 5, "contact selector bounded")
        try check(try f.api().contactsPage(search: "連絡先番号104").total == 1, "search contacts")
        try rejects("hidden contact history") { _ = try f.api().historyPage(contactID: other["id"].string) }
        try rejects("deleted contact result") { _ = try f.api(f.admin).resultForReading(deletedID) }
        let account = try f.db.insert("crm_Accounts", values: ["name": .text("関連会社"), "createdBy": .text(f.alice.identity.id), "partnerUserId": .text(f.partner.identity.id), "v": .integer(0)], actor: f.admin.identity.id)
        let linked = try f.db.update(other, changes: ["accountsIDs": account["id"]], actor: f.bob.identity.id), linkedID = try f.history(linked)
        try check(try f.api().resultForReading(linkedID).contact["id"] == other["id"], "linked read-only history result")
        try rejects("linked reader cannot apply") { _ = try f.api().preview(linkedID) }
        try check(try f.api(f.partner).historyPage().total == 2 && f.api(f.partner).resultForReading(linkedID).result.status == .completed, "partner can read scoped history")
        try rejects("partner cannot select bulk contacts") { _ = try f.api(f.partner).contactsPage() }
        let user = try f.db.get("Users", key: ["id": .text(f.alice.identity.id)])!
        _ = try f.db.update(user, changes: ["banned": .integer(1)], actor: f.admin.identity.id)
        try rejects("revoked actor cannot browse") { _ = try f.api().historyPage() }
        let unsafe = NativeEnrichmentResult(field: "position", value: .string("役職"), confidence: 1, source: "https://example.invalid/a, javascript:alert(1), file:///tmp/local, https://u:p@example.invalid/private, https://example.invalid/a", sourceContext: [.init(url: "https://example.invalid/a", snippet: "引用")])
        try check(NativeEnrichmentPresentation.sourceURLs(unsafe).map(\.absoluteString) == ["https://example.invalid/a"], "evidence links reject local/script/credentials and deduplicate")
    }
    static func requests(_ resources: URL) throws {
        let f = try Fixture(resources), own = try f.contact(), noEmail = try f.contact(["email": .null])
        let single = try NativeContactEnrichmentRequestWindow(api: f.api(), contactID: own["id"].string); try layout(single.window)
        try check(try text("情報補完の選択件数", single.window).contains("4件"), "four original default fields")
        var settingsParent: NSWindow?; single.onSettings = { settingsParent = $0 }; try click("AI連携の設定…", single.window); try check(settingsParent === single.window, "nested settings owner")
        let input = try control(NSTextField.self, "任意の項目名", single.window); input.stringValue = "position"; try click("項目を追加", single.window)
        try check(try text("情報補完の予約結果", single.window).contains("重複"), "duplicate preset rejected")
        input.stringValue = "従業員数"; try click("項目を追加", single.window)
        let fields = try control(NSTableView.self, "補完する項目", single.window); try check(fields.numberOfRows == 10, "Japanese custom field added")
        fields.selectRowIndexes(IndexSet(integer: 9), byExtendingSelection: false); try click("選択行の任意項目を削除", single.window); try check(fields.numberOfRows == 9, "custom field removable")
        input.stringValue = "従業員数"; try click("項目を追加", single.window)
        f.openai = nil; try click("情報補完を開始", single.window); try check(single.requestedIDs.isEmpty && f.api().historyPage().total == 0, "missing credentials keeps selection without enqueue")
        f.openai = "qa-openai"; try click("情報補完を開始", single.window)
        try check(single.requestedIDs.count == 1, "single request enqueued")
        let job = try f.db.job(id: single.requestedIDs[0])!, requested = try NativeContactEnrichment.decode([NativeEnrichmentField].self, job.payload["fields"]!)
        try check(job.payload["mode"] == "review" && requested.count == 5 && requested.contains { $0.name == "従業員数" }, "single request persists exact field definitions")
        let empty = try NativeContactEnrichmentRequestWindow(api: f.api(), contactID: noEmail["id"].string); try click("情報補完を開始", empty.window); try check(empty.requestedIDs.isEmpty && text("情報補完の予約結果", empty.window).contains("メールアドレス"), "missing email shown")
        let bulk = try NativeContactEnrichmentRequestWindow(api: f.api()); try layout(bulk.window)
        try click("このページを選択", bulk.window); try check(try text("情報補完の選択件数", bulk.window).contains("連絡先 2件"), "bulk contacts selected")
        try click("連絡先の選択を解除", bulk.window); try check(try !control(NSButton.self, "情報補完を開始", bulk.window).isEnabled, "empty bulk cannot start")
        try click("このページを選択", bulk.window); try click("情報補完を開始", bulk.window); try check(bulk.requestedIDs.count == 2 && f.db.job(id: bulk.requestedIDs[0])?.payload["mode"] == "bulk", "bulk mode queued")
        let larger = try Fixture(resources); try larger.db.transaction { for index in 0..<101 { _ = try larger.contact(["last_name": .text(String(format: "%03d", index))]) } }
        let picker = try NativeContactEnrichmentRequestWindow(api: larger.api()); try click("このページを選択", picker.window); try click("次へ", picker.window)
        let table = try control(NSTableView.self, "補完する連絡先", picker.window); try check(table.numberOfRows == 1, "second contact page"); try toggle(table, row: 0, state: .on)
        try check(try text("情報補完の選択件数", picker.window).contains("連絡先 100件") && text("情報補完の予約結果", picker.window).contains("100件"), "100-contact cap enforced across pages")
        try click("前へ", picker.window); try toggle(table, row: 0, state: .off); try click("次へ", picker.window); try toggle(table, row: 0, state: .on); try check(try text("情報補完の選択件数", picker.window).contains("連絡先 100件"), "selection preserved across pages")
    }
    static func results(_ resources: URL) throws {
        let f = try Fixture(resources), own = try f.contact(["position": .text("担当者"), "website": .text("https://old.invalid")]), id = try f.history(own)
        var copied = "", opened: URL?, changed = 0
        let result = try NativeContactEnrichmentResultWindow(api: f.api(), id: id, openURL: { opened = $0 }, copyValue: { copied = $0 }); result.onChanged = { changed += 1 }; try layout(result.window)
        let table = try control(NSTableView.self, "現在値と取得結果の比較", result.window)
        let confidenceWidth = table.tableColumns.last!.width, lastColumnEdge = table.rect(ofColumn: table.numberOfColumns - 1).maxX, viewport = table.enclosingScrollView!.contentSize.width
        try check(confidenceWidth >= 70 && lastColumnEdge <= viewport + 2, "confidence column visible: width=\(confidenceWidth), edge=\(lastColumnEdge), viewport=\(viewport)")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try click("取得値をコピー", result.window); try click("根拠をブラウザで開く", result.window)
        try check(copied == "営業部長" && opened?.absoluteString == "https://example.invalid/about", "selected value copy and explicit source navigation")
        try check(try control(NSTextView.self, "取得値と根拠の詳細", result.window).string.contains("日本太郎は営業部長です。"), "source quote shown")
        try toggle(table, row: 1, state: .off); try click("選択した項目を反映", result.window)
        try check(try f.row(own)["position"] == .text("営業部長") && f.row(own)["website"] == .text("https://old.invalid") && changed == 1, "only chosen mapped field applied")
        try check(try !control(NSButton.self, "選択した項目を反映", result.window).isEnabled, "applied comparison cannot repeat")
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false); try click("取得値をコピー", result.window); try check(copied == "150人", "custom result retained and copied")
        let stale = try NativeContactEnrichmentResultWindow(api: f.api(), id: id)
        _ = try f.db.update(f.row(own), changes: ["position": .text("新しい手入力")], actor: f.alice.identity.id)
        try click("選択した項目を反映", stale.window); try check(try f.row(own)["position"] == .text("新しい手入力") && text("情報補完の反映結果", stale.window).contains("開き直し"), "stale comparison cannot overwrite edits")
        let account = try f.db.insert("crm_Accounts", values: ["name": .text("閲覧用"), "createdBy": .text(f.bob.identity.id), "v": .integer(0)], actor: f.admin.identity.id)
        _ = try f.db.update(f.row(own), changes: ["accountsIDs": account["id"]], actor: f.alice.identity.id)
        let readOnly = try NativeContactEnrichmentResultWindow(api: f.api(f.bob), id: id)
        try check(try !control(NSButton.self, "選択した項目を反映", readOnly.window).isEnabled, "linked reader receives read-only comparison")
        let revoked = try NativeContactEnrichmentResultWindow(api: f.api(f.bob), id: id, copyValue: { copied = $0 }); copied = ""
        _ = try f.db.setDeleted(account, deleted: true, actor: f.admin.identity.id); try click("取得値をコピー", revoked.window); try check(copied.isEmpty, "copy rechecks revoked access")
    }
    static func histories(_ resources: URL) throws {
        let f = try Fixture(resources), own = try f.contact()
        let fields = NativeEnrichmentField.contactPresets + [.init(name: "従業員数", displayName: "従業員数", description: "従業員数")]
        let id = try f.api().request(contactIDs: [own["id"].string], fields: fields, mode: .review)[0]
        let history = try NativeContactEnrichmentHistoryWindow(api: f.api(), contactID: own["id"].string, focusedID: id); try layout(history.window)
        try check(try text("情報補完の進捗", history.window).contains("待機中"), "pending history displayed")
        try f.run { _, _, _, _, report in try await report(.init(message: "会社の情報を確認しています", kind: .agent)); throw NativeAIError(message: "試験用エラー", retryable: false) }
        try wait { try control(NSButton.self, "再試行", history.window).isEnabled }
        try check(try text("情報補完の進捗", history.window).contains("試験用エラー"), "failure notification updates history")
        try click("再試行", history.window); try check(try f.db.job(id: id)?.status == "pending", "UI retries exact durable job")
        try f.run(); try wait { try control(NSButton.self, "結果を確認…", history.window).isEnabled }
        try check(try f.row(own)["position"] == .null, "single background completion does not apply")
        try click("結果を確認…", history.window); try wait { history.window.attachedSheet != nil }
        let sheet = history.window.attachedSheet!; try click("閉じる", sheet); try wait { history.window.attachedSheet == nil }
        let second = try f.api().request(contactIDs: [own["id"].string], fields: fields, mode: .review)[0]
        let cancellation = try NativeContactEnrichmentHistoryWindow(api: f.api(), focusedID: second)
        try click("処理を取り消す", cancellation.window); try check(try f.db.job(id: second)?.status == "cancelled" && text("情報補完の進捗", cancellation.window).contains("取消済み"), "UI cancels and shows durable cancellation")
        _ = try f.db.update(f.row(own), changes: ["email": .text("changed@example.invalid")], actor: f.alice.identity.id)
        let oldResult = try NativeContactEnrichmentResultWindow(api: f.api(), id: id)
        try check(try !control(NSButton.self, "選択した項目を反映", oldResult.window).isEnabled, "changed-email history remains readable without apply")
    }
}
