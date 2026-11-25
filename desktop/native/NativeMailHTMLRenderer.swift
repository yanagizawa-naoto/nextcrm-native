import AppKit
import WebKit

/// Only the disposable helper links this file and WebKit.
final class NativeMailHTMLRenderer:NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView:WKWebView
    private let source = NativeMailHTMLSource()
    private var mainLoadAllowed = false
    var onLoaded:(() -> Void)?, onError:(() -> Void)?
    var openLink:(URL) -> Void = { NSWorkspace.shared.open($0) }
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(source,forURLScheme:"nextcrm-mail")
        webView = WKWebView(frame:.zero,configuration:configuration)
        super.init(); webView.navigationDelegate = self; webView.uiDelegate = self
        webView.setAccessibilityLabel("HTMLメールの本文")
    }
    func load(_ document:NativeMailHTMLDocument,externalContent:Bool = false) {
        webView.stopLoading(); source.prepare(document,externalContent:externalContent); mainLoadAllowed = true
        webView.load(URLRequest(url:source.url))
    }
    static func externalLink(_ url:URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        guard let scheme = url.scheme?.lowercased(), !lower.contains("%0a"), !lower.contains("%0d") else { return false }
        if scheme == "mailto" { return !url.path.isEmpty }
        return ["https","http"].contains(scheme) && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated {
            if Self.externalLink(url) { openLink(url) }
            else if action.targetFrame?.isMainFrame == true, url.fragment != nil, url.absoluteString.components(separatedBy:"#").first == source.url.absoluteString { decisionHandler(.allow); return }
            decisionHandler(.cancel); return
        }
        if mainLoadAllowed && action.targetFrame?.isMainFrame == true && url == source.url {
            mainLoadAllowed = false; decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
    }
    func webView(_ webView:WKWebView,decidePolicyFor response:WKNavigationResponse,decisionHandler:@escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for action:WKNavigationAction,windowFeatures:WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { onLoaded?() }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { if (error as NSError).code != NSURLErrorCancelled { onError?() } }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { if (error as NSError).code != NSURLErrorCancelled { onError?() } }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) { onError?() }
    func close() { webView.stopLoading(); source.clear(); webView.navigationDelegate = nil; webView.uiDelegate = nil; webView.removeFromSuperview() }
}

/// Only the single supplied document is addressable. No filesystem or network
/// lookup is possible through this scheme. Response policy precedes all markup.
private final class NativeMailHTMLSource:NSObject,WKURLSchemeHandler {
    private(set) var url = URL(string:"nextcrm-mail://message/"+UUID().uuidString)!
    private var html = "", external = false
    func prepare(_ document:NativeMailHTMLDocument,externalContent:Bool) { url = URL(string:"nextcrm-mail://message/"+UUID().uuidString)!; html = document.html; external = externalContent }
    func clear() { html = "" }
    func webView(_ webView:WKWebView,start task:WKURLSchemeTask) {
        guard task.request.url == url, task.request.httpMethod == "GET", !html.isEmpty else { task.didFailWithError(URLError(.unsupportedURL)); return }
        let network = external ? " https: http:" : ""
        let policy = "default-src 'none'; script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; connect-src 'none'; frame-src 'none'; style-src 'unsafe-inline'"+network+"; img-src data:"+network+"; font-src data:"+network+"; media-src 'none'; sandbox allow-popups allow-popups-to-escape-sandbox"
        let headers = ["Content-Type":"text/html; charset=utf-8","Content-Length":String(html.utf8.count),"Content-Security-Policy":policy,"Referrer-Policy":"no-referrer","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"]
        task.didReceive(HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:headers)!)
        // Synchronous bounded callbacks: a stop cannot interleave on the main queue.
        var chunk = Data(); chunk.reserveCapacity(32_768)
        for byte in html.utf8 { chunk.append(byte); if chunk.count == 32_768 { task.didReceive(chunk); chunk.removeAll(keepingCapacity:true) } }
        if !chunk.isEmpty { task.didReceive(chunk) }; task.didFinish()
    }
    func webView(_ webView:WKWebView,stop task:WKURLSchemeTask) {}
}
