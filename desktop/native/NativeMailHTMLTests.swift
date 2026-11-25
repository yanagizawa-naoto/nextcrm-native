import AppKit
import WebKit

@main enum NativeMailHTMLTests {
    static var checks = 0
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws { guard try value() else { throw NSError(domain:name,code:1) }; checks += 1 }
    static func wait(_ label:String,_ predicate:() -> Bool) throws {
        let end = Date().addingTimeInterval(15)
        while Date() < end { if predicate() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        throw NSError(domain:"Timeout: "+label,code:2)
    }
    static func main() { do { try run() } catch { print("NativeMailHTMLTests FAIL: \(error)"); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-HTMLTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("input")
        let original = try NativeMailHTMLDocument(subject:"日本語 🌸",html:"<!doctype html><p>日本語 & \"quoted\"</p>")
        FileManager.default.createFile(atPath:file.path,contents:nil)
        let output = try FileHandle(forWritingTo:file); try original.write(to:output); try output.close()
        let input = try FileHandle(forReadingFrom:file); let decoded = try NativeMailHTMLDocument.read(from:input); try input.close()
        try check(decoded.html == original.html && decoded.subject == original.subject,"UTF8 pipe protocol round trip")
        func reject(_ data:Data) throws {
            try data.write(to:file); let reader = try FileHandle(forReadingFrom:file); defer { try? reader.close() }
            var rejected = false; do { _ = try NativeMailHTMLDocument.read(from:reader) } catch { rejected = true }; try check(rejected,"invalid protocol rejected")
        }
        for raw in ["{\"version\":2,\"length\":1,\"subject\":\"\"}\nx","{\"version\":1,\"length\":8388609,\"subject\":\"\"}\n", "{\"version\":1,\"length\":3,\"subject\":\"\"}\nx", "{\"version\":1,\"length\":1,\"subject\":\"\"}\nxy",String(repeating:"x",count:8193)] { try reject(Data(raw.utf8)) }
        var invalidUTF8 = Data("{\"version\":1,\"length\":1,\"subject\":\"\"}\n".utf8); invalidUTF8.append(255); try reject(invalidUTF8)
        let broken = Pipe(); try broken.fileHandleForReading.close(); var brokenRejected = false
        do { try original.write(to:broken.fileHandleForWriting) } catch { brokenRejected = true }; try? broken.fileHandleForWriting.close()
        try check(brokenRejected,"broken viewer pipe does not terminate CRM")
        let base = CommandLine.arguments[1]
        let pixel = "data:image/png;base64,"+CommandLine.arguments[2]
        let html = """
        <!doctype html><html lang="ja"><head><style>body{font-family:system-ui;background:#f2f5fb}.card{margin:32px;padding:28px;background:white;border:1px solid #ccd}table{border-collapse:collapse;width:600px}td,th{padding:12px;border:1px solid #aac}.color{color:rgb(17,34,51)}</style><link rel="stylesheet" href="\(base)/style.css"><script src="\(base)/script.js"></script></head><body><main class="card"><h1 id="title">お見積もりのご案内 🌸</h1><p id="color" class="color">日本語 &amp; 配置</p><table><tr><th>商品</th><th>金額</th></tr><tr><td>サポート</td><td>12,000円</td></tr></table><img id="inline" alt="埋め込み画像" src="\(pixel)"><img id="remote" alt="外部画像" src="\(base)/image.png"><p id="external">外部スタイル</p><a id="web" target="_blank" href="https://example.test/path">詳細を見る</a><a id="unsafe" href="file:///etc/passwd">危険なリンク</a><a id="scriptlink" href="javascript:document.body.dataset.ran='yes'">スクリプト</a><form action="\(base)/form"><input name="secret" value="fixture"><button id="submit">送信</button></form><iframe src="\(base)/frame"></iframe><iframe srcdoc="<p>nested</p>"></iframe><script>document.body.dataset.ran='yes';fetch('\(base)/fetch');window.open('\(base)/popup')</script><img src="bad:" onerror="document.body.dataset.ran='yes'"><p id="escape">&lt;/iframe&gt;&lt;script&gt; &quot;quotes&quot;</p></main></body></html>
        """
        let document = try NativeMailHTMLDocument(subject:"日本語HTML試験",html:html)
        let renderer = NativeMailHTMLRenderer(), window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = renderer.webView
        var loaded = false, links:[URL] = []; renderer.onLoaded = { loaded = true }; renderer.openLink = { links.append($0) }
        func load(_ doc:NativeMailHTMLDocument,_ external:Bool) throws { loaded = false; renderer.load(doc,externalContent:external); try wait("HTML load"){loaded} }
        func js(_ source:String) throws -> Any {
            var answer:Result<Any,Error>?
            renderer.webView.evaluateJavaScript(source,in:nil,in:.defaultClient){ answer = $0 }
            try wait("DOM evaluation"){answer != nil}; return try answer!.get()
        }
        func requests() throws -> [String] {
            var result:Result<Data,Error>?
            URLSession.shared.dataTask(with:URL(string:base+"/events")!){data,_,error in result = error.map{.failure($0)} ?? .success(data ?? Data())}.resume()
            try wait("fixture events"){result != nil}; return try JSONDecoder().decode([String].self,from:result!.get())
        }
        try load(document,false)
        try check(try js("document.getElementById('title').textContent") as? String == "お見積もりのご案内 🌸","Japanese text and emoji survive rendering")
        try check(try js("document.compatMode") as? String == "CSS1Compat","original HTML doctype preserved")
        try check(try js("getComputedStyle(document.getElementById('color')).color") as? String == "rgb(17, 34, 51)","style block and class preserved")
        try check(try js("document.querySelector('table').getBoundingClientRect().width") as? Double == 600,"table layout preserved")
        try check(try js("document.getElementById('inline').naturalWidth") as? Int == 8,"embedded data image decodes")
        try check(try js("document.getElementById('remote').naturalWidth") as? Int == 0,"external image blocked by default")
        try check(try requests().isEmpty,"no remote resources requested before opt-in")
        try check(try js("document.body.dataset.ran || 'no'") as? String == "no","inline handlers and scripts disabled")
        try check(try js("document.getElementById('escape').textContent") as? String == "</iframe><script> \"quotes\"","HTML entities preserved without wrapper rewriting")
        _ = try js("document.getElementById('unsafe').click();document.getElementById('scriptlink').click();document.getElementById('submit').click();'done'")
        try check(links.isEmpty && (try requests()).isEmpty,"file/javascript/form actions do not escape")
        _ = try js("document.getElementById('web').click();'done'"); try wait("explicit external link"){links.count == 1}
        try check(links[0].absoluteString == "https://example.test/path","explicit web link passed to system browser once")
        try load(document,true)
        try check(try js("document.getElementById('remote').naturalWidth") as? Int == 8,"opt-in remote image decodes")
        try check(try js("getComputedStyle(document.getElementById('external')).color") as? String == "rgb(0, 85, 0)","opt-in external stylesheet applied")
        let events = try requests()
        try check(Set(events) == Set(["/image.png","/style.css"]),"even with opt-in scripts, frames, forms and connections stay blocked")
        try check(try js("document.body.dataset.ran || 'no'") as? String == "no","scripts stay disabled after opt-in")
        try load(try .init(subject:"refresh",html:"<meta http-equiv='refresh' content='0;url=\(base)/refresh'><p id='still'>残る本文</p>"),true)
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        try check(try js("document.getElementById('still').textContent") as? String == "残る本文" && requests() == events,"automatic navigation blocked")
        for value in ["file:///etc/passwd","javascript:alert(1)","data:text/html,test","https://user:password@example.test","nextcrm://task/1"] { try check(!NativeMailHTMLRenderer.externalLink(URL(string:value)!),"non-web/private links rejected") }
        try check(!renderer.webView.configuration.websiteDataStore.isPersistent,"viewer uses ephemeral website storage")
        renderer.close(); window.close()
        print("NativeMailHTMLTests: \(checks) checks passed; bounded pipe, actual WebKit Japanese HTML/style/table/images, opt-in resources and navigation restrictions")
    }
}
