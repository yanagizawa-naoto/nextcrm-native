import AppKit

/// Isolated rendering benchmark. Synthetic data only; never opens the normal user database.
@main enum FormMemoryProbe {
    static var form: CRMEditor?
    static var database: NativeDatabase?
    static var folder: URL!
    static var output: URL!
    static var results: [[String:Any]] = []
    static func views(_ root: NSView) -> [NSView] { [root]+root.subviews.flatMap(views) }
    static func sample(_ phase: String) throws {
        let path = folder.appendingPathComponent("footprint.json")
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/footprint")
        process.arguments = ["-j",path.path,String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NativeDBError.message("footprint failed") }
        let data = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
        let tree = form.map { views($0.window.contentView!) } ?? []
        results.append(["phase":phase,"footprintBytes":data["total footprint"]!,"textFields":tree.filter { $0 is NSTextField }.count,"multilineEngines":tree.filter { ($0 as? NSTextView)?.isFieldEditor == false }.count])
    }
    static func later(_ body: @escaping () throws -> Void) {
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            do { try autoreleasepool(invoking:body) }
            catch { FileHandle.standardError.write(Data("FormMemoryProbe: \(error)\n".utf8)); exit(1) }
        }
    }
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); output = URL(fileURLWithPath:CommandLine.arguments[2])
        let repeats = Int(CommandLine.arguments[3])!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-FormMemoryProbe-"+UUID().uuidString)
        database = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let db = database!; let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity)
        try autoreleasepool {
            var values = try db.initialValues("crm_Accounts")
            values["name"] = .text("長文描画の検証用・保存しない取引先")
            values["description"] = .text(String(repeating:"日本語の商談記録です。提案内容・合意事項・次回の対応を確認します。\n",count:repeats))
            let record = NativeRecord(model:"crm_Accounts",values:values,revision:0)
            form = try CRMEditor(module:CRMModule.find("crm_Accounts")!,record:record,linkedTo:nil,service:service)
            form!.window.center(); form!.window.makeKeyAndOrderFront(nil)
        }
        later {
            try sample("opened-top")
            let content = views(form!.window.contentView!).compactMap { $0 as? CRMFormContentView }.first!
            let scroll = content.enclosingScrollView!; scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,content.bounds.height-scroll.contentSize.height))); scroll.reflectScrolledClipView(scroll.contentView)
            later {
                try sample("visible-memo")
                let long = views(form!.window.contentView!).compactMap { $0 as? DeferredTextInput }.first!
                long.focusEditor()
                later {
                    try sample("editing-memo")
                    form!.window.orderOut(nil); form = nil
                    later {
                        try sample("closed")
                        let report: [String:Any] = ["mode":ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_FORM_MODE"] ?? "virtual","repeats":repeats,"samples":results,"scenario":"isolated synthetic Japanese memo; app-only snapshots, not whole CRM or peak"]
                        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
                        database = nil; try FileManager.default.removeItem(at:folder); exit(0)
                    }
                }
            }
        }
        app.run()
    }
}
