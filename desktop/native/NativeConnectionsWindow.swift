import AppKit

/// A local entry point. Opening this sheet performs no authentication or I/O.
final class NativeConnectionsWindow: NSObject {
    enum Destination { case mail, calendar, chatGPT, apiKeys }
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                         styleMask: [.titled], backing: .buffered, defer: false)
    private(set) var selection: Destination?

    init(mailAllowed: Bool, calendarAllowed: Bool, aiAllowed: Bool) {
        super.init()
        window.title = "アカウントを接続"
        let title = NSTextField(labelWithString: window.title)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString:
            "使いたいサービスを選び、自分のアカウントで接続します。接続しなくても、このMacで顧客や商談を管理できます。")
        let mail = button("Googleでメールを接続…", #selector(openMail))
        let calendar = button("Googleカレンダーを接続…", #selector(openCalendar))
        let chatGPT = button("ChatGPTを接続…", #selector(openChatGPT))
        mail.isEnabled = mailAllowed; calendar.isEnabled = calendarAllowed; chatGPT.isEnabled = aiAllowed
        let mailHelp = help("Gmailの受信・返信。ほかのメールサービスはメール設定から追加できます。")
        let calendarHelp = help("読み取りだけ、または予定の作成・変更も許可する接続を選べます。")
        let aiHelp = help("対応するChatGPTの契約と利用上限でAIを使います。自動処理への利用は別に許可します。")
        let advanced = button("APIキーの詳細設定…", #selector(openAPIKeys)); advanced.isEnabled = aiAllowed
        let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [advanced, NSView(), close]); footer.spacing = 12
        let note = help("連携先へ送る情報と権限は、それぞれの接続画面で確認できます。企業調査・通知メール配信などは追加のサービス設定が必要です。")
        InvoiceMailUI.layout(window, [title, introduction, mail, mailHelp, calendar, calendarHelp,
                                     chatGPT, aiHelp, note, footer])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = InvoiceMailUI.button(title, target: self, action: action)
        result.setAccessibilityLabel(title); return result
    }
    private func help(_ text: String) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.textColor = .secondaryLabelColor; result.font = .systemFont(ofSize: 12); return result
    }
    private func choose(_ destination: Destination) {
        guard window.attachedSheet == nil, let parent = window.sheetParent else { return }
        selection = destination; parent.endSheet(window, returnCode: .OK)
    }
    func confirmDiscard() -> Bool { window.attachedSheet == nil }
    @objc private func openMail() { choose(.mail) }
    @objc private func openCalendar() { choose(.calendar) }
    @objc private func openChatGPT() { choose(.chatGPT) }
    @objc private func openAPIKeys() { choose(.apiKeys) }
    @objc private func close() { window.sheetParent?.endSheet(window, returnCode: .cancel) }
}
