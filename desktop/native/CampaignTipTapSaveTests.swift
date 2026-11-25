import AppKit
private final class CampaignTipTapNoSecrets: NativeAISecretStore {
    var calls = 0
    func load(id: String, interactive: Bool) throws -> Data? { calls += 1; throw NativeDBError.conflict }
    func save(id: String, data: Data) throws { calls += 1; throw NativeDBError.conflict }
    func remove(id: String) throws { calls += 1; throw NativeDBError.conflict }
}
@main enum CampaignTipTapSaveTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func views(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
    static func save(_ editor: CampaignTemplateEditor) throws {
        let button=views(editor.window.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="保存"}!
        button.performClick(nil)
        let deadline=Date().addingTimeInterval(10)
        while editor.isSaving && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
        try check(!editor.isSaving,"save joined")
    }
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}}
    static func run() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let native=URL(fileURLWithPath:CommandLine.arguments[1]), folder=URL(fileURLWithPath:CommandLine.arguments[2])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-TipTap-"+UUID().uuidString)
        defer{NSApp.windows.forEach{$0.orderOut(nil)};try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
        let identity=try CRMService.bootstrap(db,resources:native.appendingPathComponent("../../prisma")),service=CRMService(db:db,identity:identity)
        let secrets=CampaignTipTapNoSecrets(), ai=CampaignAIService(keys:NativeAIKeys(service:service,store:secrets),generate:{_,_ in throw NativeDBError.conflict})
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("results.json"))) as! [String:Any]
        let rows=(fixture["oracle"] as! [String:Any])["rows"] as! [[String:Any]], inputs=fixture["fixtures"] as! [[String:Any]]
        var persisted: [[String:Any]]=[];var reopen: [(String,String,String)]=[]
        for input in inputs {
            try autoreleasepool {
                let name=input["id"] as! String,html=input["html"] as! String,row=rows.first{$0["id"] as? String==name}!
                let source=row["source"] as! [String:Any]
                let json=String(decoding:try JSONSerialization.data(withJSONObject:source["json"]!,options:.sortedKeys),as:UTF8.self)
                let original=try service.saveCampaignTemplate(nil,input:["name":.text(name),"subject_default":.text("件名"),"content_html":.text(html),"content_json":.text(json)])
                let meta=try CampaignTemplateEditor(service:service,record:original,ai:ai);meta.window.setFrameOrigin(NSPoint(x:-10000,y:-10000));meta.name.stringValue=name+"更新"
                try save(meta);meta.window.close()
                let updated=try service.campaignTemplate(original["id"].string)
                try check(updated.revision>original.revision && updated["content_html"]==original["content_html"] && updated["content_json"]==original["content_json"],"metadata exact "+name)
                let rich=try CampaignTemplateEditor(service:service,record:updated,ai:ai);rich.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
                rich.body.textStorage!.append(NSAttributedString(string:"追記\n",attributes:CampaignRichText.attributes(CampaignTextBlock())))
                rich.body.didChangeText();let expected=try CampaignRichText.serialize(rich.body.attributedString())
                try save(rich);rich.window.close();let saved=try service.campaignTemplate(updated["id"].string)
                try check(saved.revision>updated.revision && saved["content_html"].string==expected.html && saved["content_json"].string==expected.json,"actual rich UI save "+name)
                if input["expectEditable"] as? Bool == true {
                    try check(try CampaignRichText.load(saved["content_html"].string).protectedBlocks == 0, "ordinary marks stay rich-editable after save "+name)
                }
                persisted.append(["id":name,"html":(row["edited"] as! [String:Any])["html"]!,"nativeHTML":saved["content_html"].string,"nativeJSON":saved["content_json"].string,"protectedBlocks":input["protectedBlocks"]!, "knownURLNormalization": input["knownURLNormalization"] ?? false])
                let raw=try CampaignTemplateEditor(service:service,record:saved,ai:ai);raw.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
                let mode=views(raw.window.contentView!).compactMap{$0 as? NSSegmentedControl}.first!;mode.selectedSegment=1;_ = mode.sendAction(mode.action,to:mode.target)
                let literal=html+"<p>HTMLで追記</p>";raw.htmlEditor.string=literal;raw.htmlEditor.didChangeText();try save(raw);raw.window.close()
                let final=try service.campaignTemplate(saved["id"].string)
                try check(final.revision>saved.revision && final["content_html"].string==literal,"HTML mode exact "+name)
                var campaign=try service.createCampaign(input:["name":.text("キャンペーン "+name)])
                var payload:[String:SQLValue]=[:];for key in ["name","description","subject_default","content_html","content_json"]{payload[key]=final[key]}
                let step=try service.saveCampaignStepDraft(campaign:campaign,original:nil,sourceTemplate:final,templateInput:payload,stepInput:.init(order:0,templateID:"",subject:"件名"));campaign=step.campaign
                try check(step.step["template_id"]==final["id"] && campaign["template_id"]==final["id"],"campaign reuses exact body "+name)
                payload["content_html"] = .text(literal+"<p>キャンペーン専用</p>")
                let copied=try service.saveCampaignStepDraft(campaign:campaign,original:step.step,sourceTemplate:final,templateInput:payload,stepInput:.init(order:0,templateID:"",subject:"件名"))
                let template=try service.campaignTemplate(copied.step["template_id"].string)
                try check(template["id"] != final["id"] && template["content_html"]==payload["content_html"] && template["content_json"]==payload["content_json"],"campaign clone exact fields "+name)
                try check(try service.campaignTemplate(final["id"].string)["content_html"].string==literal,"shared template unchanged "+name)
                reopen.append((final["id"].string,literal,final["content_json"].string))
            }
        }
        let opened=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql")), again=CRMService(db:opened,identity:identity)
        for (id,html,json) in reopen {let value=try again.campaignTemplate(id);try check(value["content_html"].string==html && value["content_json"].string==json,"reopen exact")}
        // Actual selection formatting must remain editable after reopening.
        let selectionRecord = try service.saveCampaignTemplate(nil, input: ["name": .text("選択範囲の太字"), "subject_default": .text("件名"), "content_html": .text("<p>先頭 太字の範囲 後尾</p>")])
        let selection = try CampaignTemplateEditor(service: service, record: selectionRecord, ai: ai)
        selection.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        selection.window.makeFirstResponder(selection.body)
        selection.body.setSelectedRange((selection.body.string as NSString).range(of: "太字の範囲 "))
        views(selection.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "太字" }!.performClick(nil)
        let selectedHTML = try CampaignRichText.serialize(selection.body.attributedString()).html
        try check(selectedHTML.contains("<strong>"), "actual selection became bold: " + selectedHTML)
        try save(selection); selection.window.close()
        let formatted = try service.campaignTemplate(selectionRecord["id"].string)
        let selectedRoundTrip = try CampaignRichText.load(formatted["content_html"].string)
        let markedRange = (selectedRoundTrip.text.string as NSString).range(of: "太字の範囲 ")
        try check(markedRange.location != NSNotFound && (markedRange.location..<NSMaxRange(markedRange)).allSatisfy {
            selectedRoundTrip.text.attribute(CampaignRichText.boldKey, at: $0, effectiveRange: nil) as? Bool == true
        }, "selection toolbar preserves trailing marked space")
        // AppKit may split adjacent identical mark runs. The actual upstream
        // schema, not HTML byte equality, checks their meaning after persistence.
        persisted.append(["id": "actual_selection_bold", "html": "<p>先頭 <strong>太字の範囲 </strong>後尾</p>", "nativeHTML": formatted["content_html"].string, "nativeJSON": formatted["content_json"].string, "protectedBlocks": 0])
        let reopenedSelection = try CampaignTemplateEditor(service: service, record: formatted, ai: ai)
        reopenedSelection.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        try check(reopenedSelection.body.isEditable && !reopenedSelection.body.string.contains(CampaignRichText.rawLabel), "reopened selected bold body is rich editable")
        let replaced = (reopenedSelection.body.string as NSString).range(of: "後尾")
        reopenedSelection.window.makeFirstResponder(reopenedSelection.body)
        reopenedSelection.body.setSelectedRange(replaced)
        reopenedSelection.body.insertText("再編集", replacementRange: replaced)
        try save(reopenedSelection); reopenedSelection.window.close()
        let editedAgain = try service.campaignTemplate(formatted["id"].string)
        try check(editedAgain.revision > formatted.revision && editedAgain["content_html"].string.contains("再編集") && !editedAgain["content_html"].string.contains("後尾"), "reopened rich body edits and saves")
        persisted.append(["id": "actual_selection_reedit", "html": "<p>先頭 <strong>太字の範囲 </strong>再編集</p>", "nativeHTML": editedAgain["content_html"].string, "nativeJSON": editedAgain["content_json"].string, "protectedBlocks": 0])
        let invalidList = NSMutableAttributedString(attributedString: try CampaignRichText.load("<ul><li><p>段落</p></li></ul>").text)
        var invalidBlock = CampaignTextBlock.read(invalidList.attribute(CampaignTextBlock.key, at: 0, effectiveRange: nil)); invalidBlock.tag = "h1"
        invalidList.addAttribute(CampaignTextBlock.key, value: invalidBlock.encoded, range: NSRange(location: 0, length: invalidList.length))
        do { _ = try CampaignRichText.serialize(invalidList); throw NativeDBError.message("invalid list JSON accepted") }
        catch NativeDBError.message(let message) where message.contains("箇条書きの先頭") { checks += 1 }
        try check(secrets.calls==0,"no Keychain/provider access")
        try JSONSerialization.data(withJSONObject:["fixtures":persisted,"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("saved-results.json"))
        print("CampaignTipTapSaveTests: \(inputs.count) fixtures / \(checks) AppKit + SQLite checks passed")
    }
}
