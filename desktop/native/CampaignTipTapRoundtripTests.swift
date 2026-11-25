import AppKit
import WebKit

private final class CampaignTipTapProbe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var web: WKWebView!; let folder: URL; var fixtures: [[String:Any]] = []
    init(_ folder: URL) { self.folder=folder }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            fixtures = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "fixtures.json"))) as! [[String:Any]]
            for i in fixtures.indices where fixtures[i]["nativeHTML"] == nil {
                let loaded=try CampaignRichText.load(fixtures[i]["html"] as! String), value=try CampaignRichText.serialize(loaded.text)
                fixtures[i]["nativeHTML"]=value.html;fixtures[i]["nativeJSON"]=value.json;fixtures[i]["protectedBlocks"]=loaded.protectedBlocks
            }
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
            web=WKWebView(frame:NSRect(x:0,y:0,width:800,height:600),configuration:config);web.navigationDelegate=self
            web.loadHTMLString("<!doctype html><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:\"><body></body>",baseURL:nil)
            DispatchQueue.main.asyncAfter(deadline:.now()+60){self.finish(NativeDBError.message("WKWebView timeout"))}
        } catch { finish(error) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                _=try await web.evaluateJavaScript(String(contentsOf:folder.appendingPathComponent("source.js"),encoding:.utf8))
                let input=String(decoding:try JSONSerialization.data(withJSONObject:fixtures),as:UTF8.self)
                let raw=try await web.evaluateJavaScript("JSON.stringify(window.runTipTap("+input+"))") as! String
                let parsed=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
                try JSONSerialization.data(withJSONObject:["fixtures":fixtures,"oracle":parsed],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("results.json"))
                print("CampaignTipTapRoundtripTests: \(fixtures.count) actual upstream/native fixtures");finish(nil)
            }catch{finish(error)}
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) { decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel) }
    func finish(_ error: Error?) { if let error { FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1) };exit(0) }
}
@main enum CampaignTipTapRoundtripTests { static func main(){let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let p=CampaignTipTapProbe(URL(fileURLWithPath:CommandLine.arguments[1]));app.delegate=p;withExtendedLifetime(p){app.run()}} }
