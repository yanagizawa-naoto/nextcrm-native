import AppKit

/// Created only for an account form with an enabled registry extension.
/// Results remain an unsaved form draft; VAT validation is informational.
final class NativeCompanyRegistryControls: NSStackView {
    private let registry: NativeCompanyRegistry
    private let read: () -> [String: String], apply: ([String: String]) throws -> Void
    private let country = NSPopUpButton(), lookupButton = NSButton(), vatButton = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var operation: Task<Void, Never>?, generation = 0

    init(registry: NativeCompanyRegistry, allowLookup: Bool, read: @escaping () -> [String: String], apply: @escaping ([String: String]) throws -> Void) throws {
        self.registry = registry; self.read = read; self.apply = apply
        let countries = allowLookup ? try registry.countries() : [], hasVat = try registry.canValidateVat()
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 4
        country.addItems(withTitles: countries); country.setAccessibilityLabel("企業登録情報の国")
        lookupButton.title = "登録情報から入力"; lookupButton.target = self; lookupButton.action = #selector(lookup); lookupButton.bezelStyle = .rounded
        vatButton.title = "税務登録番号を確認"; vatButton.target = self; vatButton.action = #selector(checkVat); vatButton.bezelStyle = .rounded
        country.isHidden = countries.isEmpty; lookupButton.isHidden = countries.isEmpty; vatButton.isHidden = !hasVat
        let row = NSStackView(views: [country, lookupButton, vatButton, NSView()]); row.spacing = 8
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 2
        status.setAccessibilityLabel("企業登録情報の照会結果")
        addArrangedSubview(row); addArrangedSubview(status)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        isHidden = countries.isEmpty && !hasVat
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { operation?.cancel() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow == nil { cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
    func cancel() { generation += 1; operation?.cancel(); operation = nil; setBusy(false) }
    private func setBusy(_ value: Bool) { country.isEnabled = !value; lookupButton.isEnabled = !value; vatButton.isEnabled = !value }
    private func show(_ text: String, error: Bool = false) { status.stringValue = text; status.textColor = error ? .systemRed : .secondaryLabelColor }
    @objc private func lookup() {
        guard operation == nil, !lookupButton.isHidden, let cc = country.titleOfSelectedItem else { return }
        let initial = read(), number = initial["company_id"] ?? ""
        guard !number.trimmingCharacters(in: NativeAres.whitespace).isEmpty else { show("法人番号・企業登録番号を入力してください。", error: true); return }
        generation += 1; let version = generation, registry = registry
        setBusy(true); show("企業登録情報を照会しています…")
        operation = Task.detached { [weak self] in
            let result: Result<NativePluginRecord?, Error>
            do { result = .success(try await registry.lookup(country: cc, number: number)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == version else { return }
                self.operation = nil; self.setBusy(false)
                switch result {
                case let .success(record?):
                    do {
                        let patch = try Self.formValues(record)
                        let current = self.read()
                        guard current["company_id"] == initial["company_id"], patch.keys.allSatisfy({ current[$0] == initial[$0] }) else {
                            self.show("入力内容が変更されています。もう一度照会してください。", error: true); return
                        }
                        try self.apply(patch); self.show("登録情報を入力しました。内容を確認して保存してください。")
                    } catch { self.show(error.localizedDescription, error: true) }
                case .success(nil): self.show("企業登録情報が見つからないか、現在照会できません。", error: true)
                case .failure: self.show("企業登録情報を照会できません。利用権限と連携設定を確認してください。", error: true)
                }
            }
        }
    }
    @objc private func checkVat() {
        guard operation == nil, !vatButton.isHidden else { return }
        let value = read()["vat"] ?? ""
        guard !value.trimmingCharacters(in: NativeAres.whitespace).isEmpty else { show("税務登録番号を入力してください。", error: true); return }
        generation += 1; let version = generation, registry = registry
        setBusy(true); show("税務登録番号を確認しています…")
        operation = Task.detached { [weak self] in
            let result: NativeCompanyRegistry.VatResult
            do { result = try await registry.validateVat(value) } catch { result = .unavailable }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == version else { return }
                self.operation = nil; self.setBusy(false)
                guard self.read()["vat"] == value else { self.show("番号が変更されています。もう一度確認してください。", error: true); return }
                switch result {
                case .valid: self.show("税務登録番号の有効性を確認できました。")
                case .invalid: self.show("この税務登録番号は無効と回答されました。", error: true)
                case .unavailable: self.show("現在、有効性を確認できません。入力内容はそのまま保存できます。")
                case .noPrefix: self.show("番号の先頭に国コードを入力してください（例：CZ）。", error: true)
                case .noProvider: self.show("税務登録番号の確認に対応する連携が有効になっていません。", error: true)
                }
            }
        }
    }
    static func formValues(_ record: NativePluginRecord) throws -> [String: String] {
        guard let name = record["name"] as? String, let number = record["registrationNumber"] as? String, let country = record["country"] as? String else {
            throw NativePluginError(message: "照会先の企業情報を読み取れませんでした。")
        }
        var patch = ["name": name, "company_id": number, "billing_country": Locale(identifier: "ja").localizedString(forRegionCode: country) ?? country]
        for (key, field) in [("vat", "vat"), ("street", "billing_street"), ("city", "billing_city"), ("postalCode", "billing_postal_code")] {
            if let value = record[key] as? String, !value.isEmpty { patch[field] = value }
        }
        return patch
    }
}
