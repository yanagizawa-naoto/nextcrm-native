import AppKit

@main enum NativeAISettingsUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func button(_ title: String, _ window: NSWindow) throws -> NSButton {
        guard let value = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativeDBError.message("button: " + title) }; return value
    }
    static func field(_ label: String, _ window: NSWindow) throws -> NSTextField {
        guard let value = views(window.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == label }) else { throw NativeDBError.message("field: " + label) }; return value
    }
    static func popup(_ label: String, _ window: NSWindow) throws -> NSPopUpButton {
        guard let value = views(window.contentView!).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == label }) else { throw NativeDBError.message("popup: " + label) }; return value
    }
    static func click(_ title: String, _ window: NSWindow) throws { let value = try button(title, window); try check(value.isEnabled, title + " enabled"); value.sendAction(value.action, to: value.target) }
    static func wait(_ condition: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(10)
        while Date() < end { if try condition() { return }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        throw NativeDBError.message("UI wait timed out")
    }
    static func ready(_ window: NSWindow) throws { try wait { try button("キーを保存", window).isEnabled } }
    static func layout(_ window: NSWindow) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        for item in views(window.contentView!).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
            // A table's full document intentionally extends beyond its scroll
            // viewport; validate the clipped visible region for that control.
            let frame = item.convert(item is NSTableView ? item.visibleRect : item.bounds, to: window.contentView), bounds = window.contentView!.bounds
            try check(frame.width > 0 && frame.height > 0 && frame.minX >= -1 && frame.maxX <= bounds.width + 1 && frame.minY >= -1 && frame.maxY <= bounds.height + 1, "control in bounds: " + (item.accessibilityLabel() ?? ""))
        }
    }
    static func main() {
        do { try run(); print("Native AI settings, jobs UI and runtime: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AIUI-" + UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let admin = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))), store = NativeAIQAServices()
        let keys = NativeAIKeys(service: admin, store: store, environment: NativeAIEnvironment(lookup: { _ in nil }))
        let editor = try NativeAISettingsWindow(keys: keys), window = editor.window
        try layout(window)
        try check(window.title == "AI連携の設定" && field("APIキー", window) is NSSecureTextField, "Japanese title and secure input")
        try check(try popup("サービス", window).numberOfItems == 4 && popup("保存先", window).numberOfItems == 2, "all providers and administrator scopes")
        for provider in NativeAIProvider.allCases { try check(try field(provider.title, window).stringValue == "未設定", "initial status") }
        try click("キーを保存", window); try ready(window)
        try check(try field("AI設定の結果", window).stringValue.contains("APIキー") && !keys.setting(.openai, scope: .user).isSet, "empty key rejected without persistence")
        var changes = 0; editor.onChanged = { changes += 1 }
        try field("APIキー", window).stringValue = "synthetic-personal-1234"
        try click("キーを保存", window); try ready(window)
        try check(try keys.resolve(.openai)?.key == "synthetic-personal-1234" && field("APIキー", window).stringValue.isEmpty && changes == 1, "personal save clears plaintext field")
        try check(try field("OpenAI", window).stringValue == "個人キー  ••••1234", "masked personal source")
        let selectedScope = try popup("保存先", window); selectedScope.selectItem(at: 1); selectedScope.sendAction(selectedScope.action, to: selectedScope.target)
        try field("APIキー", window).stringValue = "synthetic-shared-5678"
        try click("キーを保存", window); try ready(window)
        try check(try keys.resolve(.openai)?.key == "synthetic-shared-5678" && field("OpenAI", window).stringValue == "共通キー  ••••5678", "shared priority shown")
        try click("保存したキーを削除…", window)
        try wait { window.attachedSheet != nil }
        window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
        try wait { window.attachedSheet == nil }; try ready(window)
        try check(try keys.setting(.openai, scope: .system).isSet, "delete cancellation")
        try click("保存したキーを削除…", window); try wait { window.attachedSheet != nil }
        window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
        try wait { try !keys.setting(.openai, scope: .system).isSet }; try ready(window)
        try check(try field("OpenAI", window).stringValue == "個人キー  ••••1234", "delete falls back and refreshes status")
        selectedScope.selectItem(at: 0); selectedScope.sendAction(selectedScope.action, to: selectedScope.target)
        let stale = try NativeAISettingsWindow(keys: keys)
        try field("APIキー", window).stringValue = "newest-key-9012"; try click("キーを保存", window); try ready(window)
        try field("APIキー", stale.window).stringValue = "stale-key-3456"; try click("キーを保存", stale.window); try ready(stale.window)
        try check(try keys.resolve(.openai)?.key == "newest-key-9012" && !field("AI設定の結果", stale.window).stringValue.isEmpty, "stale UI cannot overwrite newer setting")
        try field("APIキー", stale.window).stringValue = ""
        try click("再読み込み", stale.window)
        try check(try field("OpenAI", stale.window).stringValue == "個人キー  ••••9012", "reload latest source")
        let selectedProvider = try popup("サービス", window)
        for index in 1..<4 {
            selectedProvider.selectItem(at: index); selectedProvider.sendAction(selectedProvider.action, to: selectedProvider.target)
            try field("APIキー", window).stringValue = "synthetic-other-7890"; try click("キーを保存", window); try ready(window)
            try check(try keys.resolve(NativeAIProvider.allCases[index])?.key == "synthetic-other-7890", "other provider save")
        }
        let env = NativeAIKeys(service: admin, store: store, environment: NativeAIEnvironment(lookup: { $0 == "OPENAI_API_KEY" ? "synthetic-env-0000" : nil }))
        let envUI = try NativeAISettingsWindow(keys: env)
        try check(try field("OpenAI", envUI.window).stringValue == "環境設定  ••••0000", "environment precedence visible")
        let row = try db.insert("Users", values: ["name": .text("担当者"), "email": .text("user@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: admin.identity.id)
        let owner = CRMService(db: db, identity: .init(id: row["id"].string, role: "user", partnerAccountID: nil))
        let ordinary = try NativeAISettingsWindow(keys: NativeAIKeys(service: owner, store: store, environment: NativeAIEnvironment(lookup: { _ in nil })))
        try check(try popup("保存先", ordinary.window).numberOfItems == 1 && field("OpenAI", ordinary.window).stringValue == "未設定", "ordinary user cannot manage common or see another personal key")
        try check(editor.confirmDiscard() && ordinary.confirmDiscard(), "saved panels can close")
        try layout(window); try layout(ordinary.window)
        try jobsRuntime(resources)
        try documentAI(resources)
        try NativeE2BSettingsTests.run(resources)
    }
    static func jobsRuntime(_ resources: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AIJobsUI-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
        let store = NativeAIQAServices(), environment = NativeAIEnvironment(lookup: { _ in nil })
        let keys = NativeAIKeys(service: service, store: store, environment: environment)
        let controller = try NativeAIJobsWindow(keys: keys), window = controller.window
        guard let table = views(window.contentView!).compactMap({ $0 as? NSTableView }).first else { throw NativeDBError.conflict }
        try check(window.title == "AI検索の処理" && table.numberOfRows == 0, "Japanese empty jobs screen")
        try click("全件の作成・更新を予約", window)
        try check(try field("AI検索処理の結果", window).stringValue.contains("APIキー") && service.embeddingJobs().total == 0, "UI rebuild requires usable credential")
        let row = try service.save(CRMModule.find("crm_Accounts")!, original: nil, input: ["name": .text("自動更新の確認")])
        var generated = 0
        let runtime = NativeEmbeddingRuntime(db: db, store: store, environment: environment, generate: { text, key in
            generated += 1; return try await NativeAIQAServices.generate(text, key)
        })
        defer { runtime.stop() }; runtime.resume()
        try wait { try service.embeddingJobs().rows.first?.status == "failed" && !runtime.isRunning }
        try check(runtime.nextWake == nil && generated == 0, "missing key causes no idle polling or API")
        try wait { table.numberOfRows == 1 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try check(try button("選択した処理を再実行", window).isEnabled && field("AI検索処理の詳細", window).stringValue.contains("APIキー"), "failed job actionable in UI")
        try keys.save(keys.setting(.openai, scope: .user), key: "qa-runtime-1234")
        try click("選択した処理を再実行", window)
        try wait { try service.embeddingJobs().rows.first?.status == "done" && !runtime.isRunning }
        try check(try generated == 1 && NativeEmbeddingIndex(db: db).existing(.account, parentID: row["id"].string) != nil && runtime.nextWake == nil, "UI retry wakes durable runtime and returns to timer-free idle")
        try click("再読み込み", window)
        let date = controller.tableView(table, objectValueFor: table.tableColumns.first { $0.identifier.rawValue == "created" }, row: 0) as? String
        try check(date?.contains("/") == true && date != "日時不明", "queued date localized")
        try check(try !button("選択した処理を再実行", window).isEnabled, "done job cannot be retried")
        try click("全件の作成・更新を予約", window)
        try wait { try service.embeddingJobs().total == 3 && service.embeddingJobs().rows.allSatisfy { $0.status == "done" } && !runtime.isRunning }
        try check(generated == 1 && runtime.nextWake == nil, "UI backfill processes cached records without provider call")
        runtime.stop()
        for i in 0..<103 { _ = try db.enqueue("crm/account.saved", payload: ["actorID": service.identity.id, "record_id": "pending-\(i)"]) }
        _ = try db.enqueue("crm/account.saved", payload: ["actorID": "another-user", "record_id": "private"])
        try click("再読み込み", window)
        try check(table.numberOfRows == 100 && service.embeddingJobs().total == 106, "UI pages hundred jobs and excludes other owner")
        try click("次へ", window); try check(table.numberOfRows == 6, "last page bounded")
        try click("前へ", window); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try click("選択した予約を取り消す", window)
        try check(try service.embeddingJobs().rows.first?.status == "cancelled", "UI cancels selected pending job")
        try layout(window)
        // Drain only the synthetic paging reservations before testing lifecycle.
        for offset in [0, 100] {
            for job in try service.embeddingJobs(offset: offset).rows where job.status == "pending" { try service.cancelEmbeddingJob(job) }
        }
        _ = try service.save(CRMModule.find("crm_Accounts")!, original: nil, input: ["name": .text("中断と再開")])
        var entered = false
        let interrupted = NativeEmbeddingRuntime(db: db, store: store, environment: environment, generate: { text, key in
            entered = true; try await Task.sleep(nanoseconds: 60_000_000_000); return try await NativeAIQAServices.generate(text, key)
        })
        interrupted.resume(); try wait { entered }; interrupted.stop()
        try wait { !interrupted.isRunning }
        guard let retry = try service.embeddingJobs().rows.first(where: { $0.status == "retry" }) else { throw NativeDBError.message("interrupted job not retained") }
        try check(interrupted.nextWake == nil, "stopped runtime cancels future wake")
        try service.retryEmbeddingJob(retry)
        let resumed = NativeEmbeddingRuntime(db: db, store: store, environment: environment, generate: NativeAIQAServices.generate)
        defer { resumed.stop() }; resumed.resume()
        try wait { try db.job(id: retry.id)?.status == "done" && !resumed.isRunning }
        try check(resumed.nextWake == nil, "fresh runtime resumes persisted interrupted job")
    }
    static func documentAI(_ resources: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-DocumentAIUI-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("data/crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
        let file = root.appendingPathComponent("日本語の契約.txt")
        try ("第1条 契約の目的。\n" + String(repeating: "契約期間と支払いの条件を確認します。\n", count: 2000)).write(to: file, atomically: true, encoding: .utf8)
        let document = try service.commitDocument(service.stageDocument(file))
        let extractor = DocumentProcessingWorker(db: db)
        let extraction = InvoiceJobRunner(db: db, events: DocumentProcessingWorker.events, runNext: { try await extractor.runNext() })
        let runtime = NativeEmbeddingRuntime(db: db, store: NativeAIQAServices(), environment: NativeAIEnvironment(lookup: { _ in "qa-document-ui" }), generate: NativeAIQAServices.generate, summarize: NativeAIQAServices.summarize, classify: NativeAIQAServices.classify)
        defer { extraction.stop(); runtime.stop() }; runtime.resume(); extraction.kick()
        try wait { try service.documentTextMetadata(document["id"].string)["summary"] != .null && !runtime.isRunning && !extraction.isRunning }
        let jobs = try service.embeddingJobs().rows
        try check(jobs.count == 1 && jobs[0].result["enriched"] == "true" && jobs[0].result["single"] == "false" && runtime.nextWake == nil, "real local extraction automatically wakes chunked document AI runtime")
        let reader = try CRMDocumentTextWindow(service: service, document: document, showSummary: true), window = reader.window
        guard let mode = views(window.contentView!).compactMap({ $0 as? NSSegmentedControl }).first,
              let text = views(window.contentView!).compactMap({ $0 as? NSTextView }).first else { throw NativeDBError.conflict }
        try check(mode.selectedSegment == 1 && text.string == "検証用の文書要約です。本文の内容を確認しました。" && !text.isEditable, "Japanese AI summary visible in read-only native viewer")
        try check(try !button("次へ", window).isEnabled && field("文書の処理情報", window).stringValue.contains("契約"), "summary shows classification and does not use body paging")
        mode.selectedSegment = 0; mode.sendAction(mode.action, to: mode.target)
        try check(try text.string.hasPrefix("第1条") && button("次へ", window).isEnabled, "switch to bounded extracted body")
        try click("次へ", window)
        try check(try field("文書の処理情報", window).stringValue.contains("本文 2"), "body page navigation preserved")
        mode.selectedSegment = 1; mode.sendAction(mode.action, to: mode.target)
        try check(try text.string.contains("検証用の文書要約") && !button("次へ", window).isEnabled, "summary switch independent of current body part")
        try layout(window)
        runtime.stop(); extraction.stop()
        var entered = false
        let fair = NativeEmbeddingRuntime(db: db, store: NativeAIQAServices(), environment: NativeAIEnvironment(lookup: { _ in "qa-document-ui" }), generate: { text, key in
            if text.hasPrefix("第1条") { entered = true; try await Task.sleep(nanoseconds: 60_000_000_000) }
            return try await NativeAIQAServices.generate(text, key)
        }, summarize: NativeAIQAServices.summarize, classify: NativeAIQAServices.classify)
        defer { fair.stop() }; fair.resume()
        _ = try service.requestEmbeddingBackfill()
        try wait { entered }
        let account = try service.save(CRMModule.find("crm_Accounts")!, original: nil, input: ["name": .text("長文処理中のCRM更新")])
        try wait { try NativeEmbeddingIndex(db: db).existing(.account, parentID: account["id"].string) != nil }
        try check(fair.isRunning, "CRM update completes while document provider is still suspended")
        let keys = NativeAIKeys(service: service, store: NativeAIQAServices(), environment: NativeAIEnvironment(lookup: { _ in "qa-document-ui" }))
        let operations = try NativeAIJobsWindow(keys: keys)
        guard let table = views(operations.window.contentView!).compactMap({ $0 as? NSTableView }).first,
              let index = try service.embeddingJobs().rows.firstIndex(where: { $0.event == NativeDatabase.documentAIEvent && $0.status == "running" }) else { throw NativeDBError.conflict }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try click("選択した予約を取り消す", operations.window)
        try wait { !fair.isRunning }
        try check(try fair.nextWake == nil && service.embeddingJobs().rows.contains { $0.event == NativeDatabase.documentAIEvent && $0.status == "cancelled" }, "UI cancellation promptly cancels in-flight provider without stopping CRM scheduler")
        try check(try service.documentTextMetadata(document["id"].string)["processing_status"] == .text("READY"), "cancelled AI leaves extracted document readable")
        let user = try db.get("Users", key: ["id": .text(service.identity.id)])!
        _ = try db.update(user, changes: ["userStatus": .text("INACTIVE")], actor: service.identity.id)
        try click("再読み込み", window)
        try check(text.string.isEmpty, "revoked authentication clears cached body and summary")
    }
}
