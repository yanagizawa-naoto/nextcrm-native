import AppKit

@main enum NativeMailHTMLApp {
    static func main() {
        let parent = getppid(); guard parent > 1 else { exit(2) }
        _ = NSApplication.shared
        let delegate = NativeMailHTMLAppDelegate(parent:parent); NSApp.delegate = delegate
        NSApp.setActivationPolicy(.regular); NSApp.run()
        withExtendedLifetime(delegate) {}
    }
}
final class NativeMailHTMLAppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private let parent:pid_t
    private var parentExit:DispatchSourceProcess?, inputTimeout:DispatchWorkItem?
    private var document:NativeMailHTMLDocument?, renderer:NativeMailHTMLRenderer?
    private let window = NSWindow(contentRect:NSRect(x:0,y:0,width:920,height:720),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    private let notice = NSTextField(wrappingLabelWithString:"メールを読み込んでいます…")
    private let external = NSButton(checkboxWithTitle:"外部コンテンツを表示",target:nil,action:nil)
    init(parent:pid_t) { self.parent = parent; super.init() }
    func applicationDidFinishLaunching(_ notification:Notification) {
        window.title = "HTMLメール"; window.delegate = self; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:640,height:420)
        let quit = NSButton(title:"閉じる",target:self,action:#selector(close)); quit.bezelStyle = .rounded; quit.keyEquivalent = "\u{1b}"
        let retry = NSButton(title:"再表示",target:self,action:#selector(reload)); retry.bezelStyle = .rounded
        external.target = self; external.action = #selector(reload); external.isEnabled = false
        let footer = NSStackView(views:[external,NSView(),retry,quit]); footer.spacing = 12
        let stack = NSStackView(views:[notice,footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12),footer.widthAnchor.constraint(equalTo:stack.widthAnchor),notice.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        let renderer = NativeMailHTMLRenderer(); self.renderer = renderer; let web = renderer.webView; web.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(web)
        NSLayoutConstraint.activate([web.topAnchor.constraint(equalTo:content.topAnchor),web.leadingAnchor.constraint(equalTo:content.leadingAnchor),web.trailingAnchor.constraint(equalTo:content.trailingAnchor),web.bottomAnchor.constraint(equalTo:stack.topAnchor,constant:-12)])
        renderer.onError = { [weak self] in self?.notice.stringValue = "HTMLを表示できませんでした。「再表示」で再試行できます。" }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let monitor = DispatchSource.makeProcessSource(identifier:parent,eventMask:.exit,queue:.main); parentExit = monitor; monitor.setEventHandler{ NSApp.terminate(nil) }; monitor.resume()
        guard getppid() == parent else { NSApp.terminate(nil); return }
        let timeout = DispatchWorkItem { exit(2) }; inputTimeout = timeout; DispatchQueue.main.asyncAfter(deadline:.now()+15,execute:timeout)
        DispatchQueue.global(qos:.utility).async {
            let result = Result { try NativeMailHTMLDocument.read(from:.standardInput) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.inputTimeout?.cancel(); self.inputTimeout = nil
                guard case let .success(document) = result else { exit(2) }
                self.document = document; self.window.title = (document.subject.isEmpty ? "（件名なし）" : document.subject)+" — HTMLメール"
                self.external.isEnabled = true; self.reload()
            }
        }
    }
    @objc private func reload() {
        guard let document else { return }
        notice.stringValue = external.state == .on ? "外部の画像・スタイルを表示しています。送信者に閲覧が伝わる場合があります。" : "外部の画像・スタイルは読み込んでいません。メール内の埋め込み画像は表示します。"
        renderer?.load(document,externalContent:external.state == .on)
    }
    @objc private func close() { NSApp.terminate(nil) }
    func windowWillClose(_ notification:Notification) { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification:Notification) { inputTimeout?.cancel(); parentExit?.cancel(); renderer?.close(); renderer = nil; document = nil }
}
