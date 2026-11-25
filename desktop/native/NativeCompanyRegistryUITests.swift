import AppKit

private final class RegistryUIProvider {
    let lock = NSLock()
    var _company: NativePluginRecord? = ["name": "株式会社テスト", "registrationNumber": "00000019", "country": "CZ", "city": "Praha"]
    var _vat = true, _failure = false, _delay: UInt64 = 0, _calls = 0
    func change(company: NativePluginRecord?? = nil, vat: Bool? = nil, failure: Bool? = nil, delay: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let company { _company = company }; if let vat { _vat = vat }; if let failure { _failure = failure }; if let delay { _delay = delay }
    }
    func snapshot() -> (NativePluginRecord?, Bool, Bool, UInt64) {
        lock.lock(); defer { lock.unlock() }; _calls += 1
        return (_company, _vat, _failure, _delay)
    }
    func registry(enabled: Bool = true) -> NativeCompanyRegistry {
        NativeCompanyRegistry(authenticate: {}, providers: { [self] in
            if !enabled { return [] }
            return [.init(countries: ["CZ"], lookup: { [self] _, _ in
                let (company, _, failure, delay) = snapshot()
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                if failure { throw NativePluginError(message: "offline") }; return company
            }, validateVat: { [self] _ in
                let (_, vat, failure, delay) = snapshot()
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                if failure { throw NativePluginError(message: "offline") }; return vat
            })]
        })
    }
}

@main enum NativeCompanyRegistryUITests {
    static var checks = 0
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("{\"checks\":\(checks),\"exit\":0}"); exit(0) }
            catch { print(try! NativePluginJSON.text(["checks": checks, "error": error.localizedDescription])); exit(1) }
        }
        app.run()
    }
    @MainActor static func check(_ value: Bool, _ name: String) throws {
        checks += 1; if !value { throw NativePluginError(message: name) }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func idle(_ button: NSButton) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !button.isEnabled && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(button.isEnabled, "operation completes")
    }
    @MainActor static func run() async throws {
        let fixture = RegistryUIProvider()
        var fields = ["name": "下書き", "company_id": "19", "vat": "CZ19", "billing_street": "既存の住所"]
        var applied = 0
        let controls = try NativeCompanyRegistryControls(registry: fixture.registry(), allowLookup: true, read: { fields }, apply: { fields.merge($0) { _, new in new }; applied += 1 })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = controls; panel.contentView!.layoutSubtreeIfNeeded()
        let buttons = descendants(controls).compactMap { $0 as? NSButton }
        let lookup = buttons.first { $0.title == "登録情報から入力" }!, vat = buttons.first { $0.title == "税務登録番号を確認" }!
        let status = descendants(controls).compactMap { $0 as? NSTextField }.first!
        try check(!controls.isHidden && !lookup.isHidden && !vat.isHidden, "enabled Japanese actions visible")
        try check(lookup.frame.width > 0 && vat.frame.width > 0, "buttons have layout bounds")
        fields["company_id"] = " "
        lookup.performClick(nil)
        try check(status.stringValue.contains("番号を入力"), "missing number has Japanese guidance")
        try check(applied == 0, "empty number makes no draft change")
        fields["company_id"] = "19"
        lookup.performClick(nil)
        try check(!lookup.isEnabled && !vat.isEnabled, "no concurrent lookup and VAT request")
        try await idle(lookup)
        try check(applied == 1, "result applied once")
        try check(fields["name"] == "株式会社テスト" && fields["company_id"] == "00000019", "name and normalized ID")
        try check(fields["billing_city"] == "Praha" && fields["billing_country"] == "チェコ", "localized billing address")
        try check(fields["billing_street"] == "既存の住所", "missing remote address preserves draft")
        try check(status.stringValue.contains("確認して保存"), "result remains an unsaved draft")
        fixture.change(delay: 200_000_000)
        lookup.performClick(nil); fields["name"] = "照会中の手入力"
        try await idle(lookup)
        try check(applied == 1 && fields["name"] == "照会中の手入力", "late result preserves edited fields")
        try check(status.stringValue.contains("変更されています"), "stale result asks to retry")
        lookup.performClick(nil); controls.cancel()
        try await Task.sleep(nanoseconds: 230_000_000)
        try check(applied == 1 && lookup.isEnabled, "closing cancellation prevents application")
        fixture.change(delay: 0)
        for (answer, failure, text) in [(true, false, "有効性を確認できました"), (false, false, "無効と回答"), (true, true, "確認できません")] {
            fixture.change(vat: answer, failure: failure)
            vat.performClick(nil); try await idle(vat)
            try check(status.stringValue.contains(text), "VAT states remain distinct")
            try check(applied == 1, "VAT check never edits the form")
        }
        fixture.change(failure: false, delay: 200_000_000)
        vat.performClick(nil); fields["vat"] = "CZ20"
        try await idle(vat)
        try check(status.stringValue.contains("番号が変更"), "old VAT result does not describe edited number")
        fields["vat"] = "123"
        vat.performClick(nil); try await idle(vat)
        try check(status.stringValue.contains("国コード"), "missing VAT country guidance")
        let disabled = try NativeCompanyRegistryControls(registry: fixture.registry(enabled: false), allowLookup: true, read: { fields }, apply: { _ in })
        try check(disabled.isHidden, "unavailable providers add no form UI")
        let existing = try NativeCompanyRegistryControls(registry: fixture.registry(), allowLookup: false, read: { fields }, apply: { _ in })
        let existingButtons = descendants(existing).compactMap { $0 as? NSButton }
        try check(existingButtons.first { $0.title == "登録情報から入力" }!.isHidden, "company lookup follows new-form-only source")
        try check(!existingButtons.first { $0.title == "税務登録番号を確認" }!.isHidden, "existing account can check VAT")
        do { _ = try NativeCompanyRegistryControls.formValues([:]); throw NativePluginError(message: "Malformed response accepted") }
        catch { try check(error.localizedDescription.contains("読み取れません"), "malformed response has Japanese error") }
        panel.contentView = nil; panel.close()
    }
}
