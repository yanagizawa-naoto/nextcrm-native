import AppKit

final class PreviewNoSecrets:NativeAISecretStore {
    var calls=0
    func load(id:String,interactive:Bool)throws->Data?{calls+=1;throw NativeDBError.conflict}
    func save(id:String,data:Data)throws{calls+=1;throw NativeDBError.conflict}
    func remove(id:String)throws{calls+=1;throw NativeDBError.conflict}
}
final class PreviewFakeViewer:NativeMailHTMLDrainingViewing {
    var closes=0,completion:(()->Void)?
    func close(){closes+=1}
    func closeAndDrain(_ completion:@escaping()->Void){close();self.completion=completion}
    func finish(){let work=completion;completion=nil;work?()}
}

private final class PreviewRenderCalls {
    private let lock=NSLock();private var storage:[String]=[]
    func append(_ value:String)->Int{lock.lock();defer{lock.unlock()};storage.append(value);return storage.count}
    var values:[String]{lock.lock();defer{lock.unlock()};return storage}
}

@main enum NativeCampaignTemplatePreviewTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
    static func wait(_ label:String,_ predicate:()throws->Bool)throws{let end=Date().addingTimeInterval(12);while Date()<end{if try predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.005))};throw NativeDBError.message("Timeout: "+label)}
    static func views(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(views)}
    static func mode(_ editor:CampaignTemplateEditor,_ index:Int)throws{let control=views(editor.window.contentView!).compactMap{$0 as? NSSegmentedControl}.first!;control.selectedSegment=index;_ = control.target?.perform(control.action,with:control)}
    static func button(_ editor:CampaignTemplateEditor,_ title:String)throws->NSButton{guard let result=views(editor.window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title})else{throw NativeDBError.message(title)};return result}
    static func save(_ editor:CampaignTemplateEditor)throws{try button(editor,"保存").performClick(nil);try wait("save"){!editor.isSaving}}
    static func cancel(_ editor:CampaignTemplateEditor,choosing title:String)throws {
        var clicked=false,attempts=0
        let timer=Timer(timeInterval:0.01,repeats:true){timer in
            attempts+=1
            if let window=NSApp.modalWindow,let content=window.contentView,
               let button=views(content).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) {
                clicked=true;timer.invalidate();button.performClick(nil)
            } else if attempts>300 {timer.invalidate();NSApp.abortModal()}
        }
        RunLoop.main.add(timer,forMode:.modalPanel)
        defer{timer.invalidate()}
        try button(editor,"キャンセル").performClick(nil)
        try check(clicked,"actual dirty-discard choice "+title)
    }
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("NativeCampaignTemplatePreviewTests: \(error)\n".utf8));exit(1)}}
    static func run()throws{
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let native=URL(fileURLWithPath:CommandLine.arguments[1]),folder=URL(fileURLWithPath:CommandLine.arguments[2])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-TemplatePreview-"+UUID().uuidString)
        defer{NSApp.windows.forEach{$0.close()};try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("db.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
        let service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:native.appendingPathComponent("../../prisma")))
        let secrets=PreviewNoSecrets(),ai=CampaignAIService(keys:NativeAIKeys(service:service,store:secrets),generate:{_,_ in throw NativeDBError.conflict})
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("reference.json"))) as! [String:Any]
        var documents:[[String:String]]=[]
        for row in fixture["fixtures"] as! [[String:Any]] {
            let html=row["input"] as! String,document=try CampaignTemplatePreviewDocument.make(html:html,subject:"合成の件名")
            try check(document.html.contains("campaign-content"),"rendered layout")
            try check(!document.html.contains(CampaignRichText.rawLabel),"protected label absent from render")
            documents.append(["id":row["id"] as! String,"html":document.html,"sourceHTML":row["sourceHTML"] as! String])
        }
        try JSONSerialization.data(withJSONObject:documents,options:.sortedKeys).write(to:folder.appendingPathComponent("documents.json"))
        let html="<h1>ご案内😀</h1><p>{{first_name}}様</p><table><tr><td>保持する表</td></tr></table><img src=\"https://example.invalid/image.png\" alt=\"商品\">"
        let original=try service.saveCampaignTemplate(nil,input:["name":.text("元テンプレート"),"subject_default":.text("件名"),"content_html":.text(html),"content_json":.text("{\"original\":true}")])
        var captured:[NativeMailHTMLDocument]=[],viewers:[PreviewFakeViewer]=[]
        let editor=try CampaignTemplateEditor(service:service,record:original,ai:ai,makePreviewViewer:{doc,_ in let v=PreviewFakeViewer();captured.append(doc);viewers.append(v);return v})
        editor.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        let rich=editor.body.attributedString().copy() as! NSAttributedString
        try mode(editor,2);try wait("initial preview"){captured.count==1}
        try check(captured[0].html.contains("花子様") && captured[0].html.contains("<table>"),"merged Japanese/table preview")
        try check(editor.body.attributedString().isEqual(to:rich),"preview does not rewrite rich document")
        try check(try service.campaignTemplate(original["id"].string).values==original.values && service.campaignTemplate(original["id"].string).revision==original.revision,"preview no DB update")
        try button(editor,"プレビューを再表示").performClick(nil)
        try check(viewers[0].closes==1 && captured.count==1,"reopen waits for old helper")
        try mode(editor,0);viewers[0].finish();RunLoop.current.run(until:Date().addingTimeInterval(0.04))
        try check(captured.count==1,"cancel while draining does not spawn")
        try mode(editor,2);try wait("second preview"){captured.count==2}
        try button(editor,"キャンセル").performClick(nil)
        try check(viewers[1].closes==1,"clean cancel closes viewer without dirty prompt")
        viewers[1].finish();try check(try service.campaignTemplate(original["id"].string).values==original.values && service.campaignTemplate(original["id"].string).revision==original.revision,"cancel preserves exact row")
        try mode(editor,1);editor.htmlEditor.string=html+"<p>HTMLで追記</p>";editor.textDidChange(Notification(name:NSText.didChangeNotification,object:editor.htmlEditor))
        try mode(editor,2);try wait("dirty preview"){captured.count==3}
        try check(captured.last!.html.contains("HTMLで追記"),"preview uses unsaved HTML")
        try check(try service.campaignTemplate(original["id"].string).values==original.values && service.campaignTemplate(original["id"].string).revision==original.revision,"dirty preview still does not persist")
        try save(editor);try check(viewers[2].closes==1,"save success closes viewer");viewers[2].finish()
        let saved=try service.campaignTemplate(original["id"].string)
        try check(saved["content_html"].string==html+"<p>HTMLで追記</p>","dirty save exact raw HTML")
        let reopened=try CampaignTemplateEditor(service:service,record:saved,ai:ai,makePreviewViewer:{doc,_ in let v=PreviewFakeViewer();captured.append(doc);viewers.append(v);return v})
        try mode(reopened,2);try wait("reopened saved preview"){captured.count==4}
        reopened.window.close();try check(viewers[3].closes==1,"window close closes preview");viewers[3].finish()
        try check(try service.campaignTemplate(saved["id"].string).values==saved.values && service.campaignTemplate(saved["id"].string).revision==saved.revision,"reopen/close no row change")
        let discarded=try CampaignTemplateEditor(service:service,record:saved,ai:ai,makePreviewViewer:{doc,_ in let v=PreviewFakeViewer();captured.append(doc);viewers.append(v);return v})
        try mode(discarded,1);discarded.htmlEditor.string=html+"<p>保存しない変更</p>";discarded.textDidChange(Notification(name:NSText.didChangeNotification,object:discarded.htmlEditor))
        try mode(discarded,2);try wait("discard draft preview"){captured.count==5}
        try cancel(discarded,choosing:"編集を続ける")
        try check(viewers[4].closes==0 && captured.last!.html.contains("保存しない変更"),"continue editing retains preview and dirty draft")
        try cancel(discarded,choosing:"破棄する")
        try check(viewers[4].closes==1,"discard closes owned preview");viewers[4].finish()
        try check(try service.campaignTemplate(saved["id"].string).values==saved.values && service.campaignTemplate(saved["id"].string).revision==saved.revision,"discard does not save dirty body")
        // Controller lifecycle: stale renderer output and lost authority cannot
        // publish a viewer, even when the renderer ignores cancellation.
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),calls=PreviewRenderCalls()
        var latest:[NativeMailHTMLDocument]=[], latestViewer:PreviewFakeViewer?
        let controlled=CampaignTemplatePreview(authorize:{},makeViewer:{document,_ in latest.append(document);let v=PreviewFakeViewer();latestViewer=v;return v},render:{html,subject,_ in if calls.append(html)==1 {entered.signal();release.wait()};return try .init(subject:subject,html:html)})
        controlled.show(html:"<p>old</p>",subject:"");try check(entered.wait(timeout:.now()+3) == .success,"controlled render entered")
        for n in 1...100 {controlled.show(html:"<p>"+String(repeating:"draft",count:4000)+" latest=\(n)</p>",subject:"\(n)")}
        try check(controlled.isPreparing && calls.values.count==1,"100 switches retain one active render")
        release.signal();try wait("coalesced latest preview"){latest.count==1}
        try check(calls.values.count==2 && calls.values.last!.hasSuffix("latest=100</p>"),"only one latest pending render executes")
        try check(latest[0].subject=="100" && latest[0].html.hasSuffix("latest=100</p>"),"stale noncooperative result never displayed")
        controlled.close();latestViewer?.finish()
        let closeEntered=DispatchSemaphore(value:0),closeRelease=DispatchSemaphore(value:0),closeCalls=PreviewRenderCalls();var spawned=0
        let closing=CampaignTemplatePreview(authorize:{},makeViewer:{_,_ in spawned+=1;return PreviewFakeViewer()},render:{html,subject,_ in _=closeCalls.append(html);closeEntered.signal();closeRelease.wait();return try .init(subject:subject,html:html)})
        closing.show(html:"<p>active</p>",subject:"");try check(closeEntered.wait(timeout:.now()+3) == .success,"closing noncooperative render entered")
        for n in 1...100 {closing.show(html:"<p>cancelled \(n)</p>",subject:"")}
        closing.close();try check(closing.isPreparing,"close keeps active slot until actual completion")
        closeRelease.signal();try wait("closed render finished"){!closing.isPreparing}
        try check(closeCalls.values.count==1 && spawned==0,"100 pending then close starts no render or viewer")
        var allowed=true;let gated=CampaignTemplatePreview(authorize:{if !allowed{throw NativeDBError.conflict}},makeViewer:{_,_ in spawned+=1;return PreviewFakeViewer()})
        allowed=false;gated.show(html:"<p>denied</p>",subject:"");RunLoop.current.run(until:Date().addingTimeInterval(0.03));try check(spawned==0 && !gated.isPreparing,"auth failure no renderer")
        var oversized=false
        do {_ = try CampaignTemplatePreviewDocument.make(html:"<p>"+String(repeating:"a",count:NativeMailHTMLDocument.maximumBytes)+"</p>",subject:"")}catch{oversized=error.localizedDescription.contains("8 MiB")}
        try check(oversized,"oversized preview rejected with Japanese explanation")
        try check(try service.campaignTemplate(saved["id"].string).values==saved.values && service.campaignTemplate(saved["id"].string).revision==saved.revision,"size failure no DB changes")
        try check(secrets.calls==0,"no credential accesses")
        print("CampaignTemplatePreview: \(checks) checks passed")
    }
}
