import AppKit
import WebKit

private enum PreviewRendererTestFailure:LocalizedError {case message(String);var errorDescription:String?{switch self{case let .message(text):return text}}}

@main enum NativeCampaignTemplatePreviewRendererTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws{guard try value()else{throw PreviewRendererTestFailure.message(label)};checks+=1}
    static func wait(_ label:String,_ predicate:()->Bool)throws{let end=Date().addingTimeInterval(15);while Date()<end{if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.01))};throw PreviewRendererTestFailure.message("Timeout: "+label)}
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("NativeCampaignTemplatePreviewRendererTests: \(error)\n".utf8));exit(1)}}
    static func run()throws{
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),rows=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("documents.json"))) as! [[String:String]]
        let window=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:920,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        var renderer:NativeMailHTMLRenderer?,loaded=false
        weak var web:WKWebView?
        var measured:[[String:Any]]=[]
        try autoreleasepool {
        renderer=NativeMailHTMLRenderer();web=renderer!.webView
        window.contentView!.addSubview(renderer!.webView);renderer!.webView.frame=window.contentView!.bounds
        renderer!.onLoaded={loaded=true}
        defer{renderer?.close();renderer=nil}
        func js(_ source:String)throws->Any?{
            var result:Result<Any,Error>?
            renderer!.webView.evaluateJavaScript(source,in:nil,in:.defaultClient){result=$0}
            try wait("JavaScript client inspection"){result != nil};return try result!.get()
        }
        func load(_ html:String)throws{
            loaded=false;renderer!.load(try .init(subject:"比較用",html:html),externalContent:false)
            try wait("document render"){loaded}
        }
        let metrics="""
        (()=>{const c=document.querySelector('.campaign-content');return JSON.stringify({
          text:c.textContent,tags:[...c.querySelectorAll('*')].map(e=>e.tagName),
          tables:[...c.querySelectorAll('table')].map(e=>({width:e.getBoundingClientRect().width,rows:e.rows.length,cells:[...e.querySelectorAll('td,th')].map(x=>x.textContent)})),
          styled:[...c.querySelectorAll('[style]')].map(e=>{const s=getComputedStyle(e);return {tag:e.tagName,color:s.color,background:s.backgroundColor,weight:s.fontWeight,padding:s.padding,width:e.tagName==='TABLE'?s.width:null}}),
          images:[...c.querySelectorAll('img')].map(e=>({src:e.getAttribute('src'),alt:e.getAttribute('alt'),width:e.width,height:e.height,naturalWidth:e.naturalWidth})),
          active:c.querySelectorAll('script,iframe,form,input').length
        })})()
        """
        for row in rows {
            try load(row["sourceHTML"]!);let source=try js(metrics) as! String
            try load(row["html"]!);let native=try js(metrics) as! String
            let sourceValue=try JSONSerialization.jsonObject(with:Data(source.utf8)) as! NSDictionary
            let nativeValue=try JSONSerialization.jsonObject(with:Data(native.utf8)) as! NSDictionary
            try check(sourceValue==nativeValue,"source/native rendered content differs: "+row["id"]!)
            try check((try js("document.querySelector('.campaign-content').querySelectorAll('script,iframe,form,input').length") as? Int)==0,"active content removed")
            try check((try js("window.previewExecuted===true") as? Bool)==false,"source script never executed")
            try check(!renderer!.webView.configuration.websiteDataStore.isPersistent,"ephemeral renderer")
            measured.append(["id":row["id"]!,"metrics":nativeValue,"matched":true])
        }
        // Source campaign sanitizer rejects data: image src. The already-shared
        // viewer can still display data images in mail documents; prove that
        // separate capability without pretending template sanitizer keeps them.
        let pixel=try String(contentsOf:folder.appendingPathComponent("pixel-base64.txt"),encoding:.utf8)
        try load("<!doctype html><html><body><img src=\"data:image/png;base64,"+pixel+"\"></body></html>")
        try check((try js("document.querySelector('img').naturalWidth") as? Int)==8,"existing viewer data image decode")
        renderer!.close();renderer=nil
        }
        try wait("renderer released"){web==nil}
        try check(web==nil,"renderer/webview released after close");window.close()
        try JSONSerialization.data(withJSONObject:["checks":checks,"rows":measured,"scope":"Actual existing isolated WebKit renderer; compare source/native content DOM, allowed styles, tables, Japanese and image metadata. Remote images stay disabled; no external provider endpoint was used and remote opt-in stayed false; request counts were not instrumented. Outer React Email/native wrapper pixel identity is not claimed."],options:[.sortedKeys,.prettyPrinted]).write(to:folder.appendingPathComponent("render-measurements.json"))
        print("CampaignTemplateRenderer: \(checks) checks passed")
    }
}
