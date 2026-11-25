import AppKit

struct NativeRestoreReviewWindowDecision {
    let source: NativeRestoreSourceTrustChoice
    let holds: [NativeRestoreExplicitHoldChoice]
    let authority: NativeRestoreReviewAuthority
}

/// An actual local administrator decision, bound to the displayed candidate.
/// This sheet produces no activation, provider validation, or startup receipt.
@MainActor final class NativeRestoreReviewWindow: NSObject, NSWindowDelegate {
    typealias Authorize = () async throws -> NativeRestoreReviewAuthority
    let window: NSWindow
    private let prompt: NativeRestoreHeldReviewPrompt, authorize: Authorize, clock: () -> Date
    private let sourceTrust = NSButton(checkboxWithTitle: "作成元と内容を確認し、この復元候補を信頼します", target: nil, action: nil)
    private var holdDescriptions: [NativeRestoreHeldReviewKind: NSTextField] = [:]
    private let proceed = NSButton(title: "閲覧専用で開く", target: nil, action: nil)
    private let cancelButton = NSButton(title: "戻る", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var continuation: CheckedContinuation<NativeRestoreReviewWindowDecision?, Never>?
    private var authorityTask: Task<Void, Never>?, expiryTimer: Timer?
    private var presented = false, closed = false, busy = false

    init(prompt: NativeRestoreHeldReviewPrompt, previousRoot: URL, candidateRoot: URL,
         clock: @escaping () -> Date = Date.init, authorize: @escaping Authorize) throws {
        guard previousRoot.isFileURL, candidateRoot.isFileURL,
              NativeMigrationCodec.validHash(prompt.fullSubjectSHA256),
              Set(prompt.kinds) == Set(NativeRestoreHeldReviewKind.allCases),
              prompt.kinds.count == NativeRestoreHeldReviewKind.allCases.count,
              Set(prompt.heldRuntimes) == Set(NativeRestoreRuntimeCatalog.heldAutomatic),
              prompt.heldRuntimes.count == NativeRestoreRuntimeCatalog.heldAutomatic.count else {
            throw NativeRestoreActivationFailure("reviewUI.invalidPrompt")
        }
        self.prompt = prompt; self.authorize = authorize; self.clock = clock
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 620),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(); window.title = "復元データへの切り替え"; window.delegate = self
        let heading = NSTextField(labelWithString: window.title); heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "アプリをいったん終了して、この復元候補を開きます。現在のデータは元の保存場所に残します。")
        let previous = Self.path("現在の保存場所", previousRoot), candidate = Self.path("開く復元候補", candidateRoot)
        let trust = NSTextField(wrappingLabelWithString: "自分で作成したバックアップなど、作成元を確認できるものを選んでください。ファイルの内容が一致するだけでは、作成者までは確認できません。")
        trust.textColor = .secondaryLabelColor
        sourceTrust.identifier = .init("restore-source-trust"); sourceTrust.target = self; sourceTrust.action = #selector(changed)
        let heldTitle = NSTextField(labelWithString: "未確認の処理は再開せず、閲覧専用で開きます")
        heldTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let heldHelp = NSTextField(wrappingLabelWithString: "「閲覧専用で開く」を押すと、以下の状態で切り替えを進めます。送信・同期を自動で再開することはありません。")
        let titles: [NativeRestoreHeldReviewKind: String] = [
            .sourceProvenance: "作成元の確認記録を残し、自動処理は保留",
            .credentials: "外部接続：接続先と認証情報を確認するまで保留",
            .jobs: "送信・自動処理：実行済みの履歴を照合するまで保留",
            .relayAndPluginState: "同期・連携：受信履歴と連携状態を確認するまで保留",
            .pendingAssets: "添付・写真：不足するファイルを確認するまで自動処理を保留",
            .runtimeStartup: "編集：再開の確認が完了するまで保留"
        ]
        var views: [NSView] = [heading, intro, previous, candidate, trust, sourceTrust, heldTitle, heldHelp]
        for kind in NativeRestoreHeldReviewKind.allCases {
            let label = NSTextField(labelWithString: "・" + titles[kind]!)
            label.identifier = .init("restore-hold-" + kind.rawValue); holdDescriptions[kind] = label; views.append(label)
        }
        message.setAccessibilityLabel("復元切り替えの確認結果"); message.maximumNumberOfLines = 3
        proceed.bezelStyle = .rounded; proceed.identifier = .init("restore-review-continue"); proceed.target = self; proceed.action = #selector(submit)
        cancelButton.bezelStyle = .rounded; cancelButton.identifier = .init("restore-review-cancel"); cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [cancelButton, NSView(), proceed]); footer.spacing = 12
        views += [message, NSView(), footer]
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        updateControls()
    }
    deinit { expiryTimer?.invalidate(); authorityTask?.cancel() }
    private static func path(_ title: String, _ url: URL) -> NSView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .semibold)
        let value = NSTextField(labelWithString: url.path); value.isSelectable = true; value.lineBreakMode = .byTruncatingMiddle
        value.toolTip = url.path; value.setAccessibilityLabel(title)
        let stack = NSStackView(views: [label, value]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        value.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    func present(on parent: NSWindow) async -> NativeRestoreReviewWindowDecision? {
        guard !presented, !closed else { return nil }; presented = true
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(nil); return }
                expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateControls() }
                }
                parent.beginSheet(window); updateControls()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.dismiss() } })
    }
    func dismiss() { finish(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }
    @objc private func changed() { updateControls() }
    private func updateControls() {
        let current = clock() < prompt.validUntil
        let editable = !closed && !busy && current
        sourceTrust.isEnabled = editable
        proceed.isEnabled = editable && sourceTrust.state == .on
        cancelButton.isEnabled = !closed
        if !current, !closed { message.textColor = .systemRed; message.stringValue = "確認の有効時間を過ぎました。戻って内容を読み直してください。" }
    }
    @objc private func submit() {
        guard !closed, !busy, clock() < prompt.validUntil, sourceTrust.state == .on else { updateControls(); return }
        busy = true; message.textColor = .secondaryLabelColor; message.stringValue = "現在の管理者権限を確認しています…"; updateControls()
        authorityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let authority = try await authorize()
                guard !closed, !Task.isCancelled else { return }
                guard clock() < prompt.validUntil, !authority.actorID.isEmpty, authority.actorID.utf8.count <= 256,
                      !authority.actorID.contains("\0"), NativeMigrationCodec.validHash(authority.evidenceSHA256) else {
                    throw NativeRestoreActivationFailure("reviewUI.authority")
                }
                let subject = prompt.fullSubjectSHA256
                // The explicit primary action accepts all six displayed holds;
                // no choice is inferred from merely opening this sheet.
                finish(.init(source: .trustReviewedCandidate(fullSubjectSHA256: subject),
                             holds: NativeRestoreHeldReviewKind.allCases.map { .init(kind: $0, fullSubjectSHA256: subject, decision: .keepHeld) },
                             authority: authority))
            } catch {
                guard !closed, !Task.isCancelled else { return }
                busy = false; authorityTask = nil; message.textColor = .systemRed
                message.stringValue = "管理者権限を確認できませんでした。現在の利用者と権限を確認してから、もう一度お試しください。"
                updateControls()
            }
        }
    }
    @objc private func cancel() { finish(nil) }
    private func finish(_ decision: NativeRestoreReviewWindowDecision?) {
        guard !closed else { return }; closed = true
        expiryTimer?.invalidate(); expiryTimer = nil; authorityTask?.cancel(); authorityTask = nil
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
        let current = continuation; continuation = nil; current?.resume(returning: decision)
    }
}
