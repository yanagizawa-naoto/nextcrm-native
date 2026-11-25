import AppKit
import QuartzCore

/// Uses the actual CRM controllers with a disposable synthetic database. This file
/// is deliberately excluded from the application build; no user store is opened.
@main enum DrawingMemoryProbe {
    static var db: NativeDatabase!
    static var service: CRMService!
    static var dashboard: CRMProjectDashboardWindow?
    static var form: CRMEditor?
    static var output: URL!
    static var folder: URL!
    static var mode = "baseline"
    static var samples: [[String:Any]] = []
    static var checks: [String] = []
    static var configured = Set<ObjectIdentifier>()

    static func views(_ root: NSView) -> [NSView] { [root]+root.subviews.flatMap(views) }
    static var windows: [NSWindow] { [dashboard?.window,form?.window].compactMap { $0 } }
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NativeDBError.message("Drawing probe: "+name) }; checks.append(name)
    }
    static func flatten(_ view: NSView) {
        guard configured.insert(ObjectIdentifier(view)).inserted else { return }
        view.wantsLayer = true; view.canDrawSubviewsIntoLayer = true
    }
    static func apply(_ window: NSWindow) {
        guard let root = window.contentView else { return }
        if mode == "static" {
            // Preserve independent native drawing for scrolling, editing, focus,
            // buttons and popups. Only passive labels/container views flatten.
            for view in views(root) {
                if view is NSScrollView || view is NSTextView ||
                    (view is NSControl && !((view as? NSTextField).map { !$0.isEditable && !$0.isSelectable } ?? false)) {
                    view.wantsLayer = true
                }
            }
            flatten(root)
        } else if mode == "rows" {
            // The row and its Core Text display cell share one backing layer.
            // The table/scroll view and native editor remain independent.
            for view in views(root) where view is NSTableRowView { flatten(view) }
        }
    }
    static func show(_ window: NSWindow) {
        if let panel = window as? NSPanel { panel.hidesOnDeactivate = false }
        // A visible, inactive floating window avoids both occlusion differences
        // across runs and stealing keyboard focus from the person using the Mac.
        window.level = .floating
        if let frame = NSScreen.main?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x:frame.midX-size.width/2,y:frame.midY-size.height/2))
        }
        apply(window); window.orderFrontRegardless(); window.displayIfNeeded()
    }
    static func later(_ work: @escaping () throws -> Void) {
        let delay = min(30,max(2,Double(ProcessInfo.processInfo.environment["NEXTCRM_DRAWING_DELAY_SECONDS"] ?? "2") ?? 2))
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) {
            do { try autoreleasepool(invoking:work) }
            catch { fail(error) }
        }
    }
    static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("DrawingMemoryProbe: \(error)\n".utf8))
        db = nil; try? FileManager.default.removeItem(at:folder); exit(1)
    }
    static func windowMetadata() -> [[String:Any]] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
        return info.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowIsOnscreen as String] as? Bool) == true }.map {
            ["number":$0[kCGWindowNumber as String] ?? 0,
             "estimatedWindowBytes":$0[kCGWindowMemoryUsage as String] ?? 0,
             "bounds":$0[kCGWindowBounds as String] ?? [:]]
        }
    }
    static func layerMetadata(_ window: NSWindow) -> [String:Any] {
        guard let root = window.contentView else { return [:] }
        let tree = views(root)
        var layers = Set<ObjectIdentifier>(); var byClass: [String:Int] = [:]; var pixels: Double = 0
        func visit(_ layer: CALayer) {
            guard layers.insert(ObjectIdentifier(layer)).inserted else { return }
            byClass[String(describing:type(of:layer)),default:0] += 1
            if !layer.isHidden { pixels += Double(layer.bounds.width*layer.bounds.height*layer.contentsScale*layer.contentsScale) }
            for child in layer.sublayers ?? [] { visit(child) }
        }
        for view in tree { if let layer = view.layer { visit(layer) } }
        return ["title":window.title,"frame":NSStringFromRect(window.frame),"scale":window.backingScaleFactor,"level":window.level.rawValue,"keyWindow":window.isKeyWindow,
                "viewCount":tree.count,"viewLayers":tree.filter { $0.layer != nil }.count,
                "layers":layers.count,"layerClasses":byClass,"sumLayerPixelAreaNotAllocatedBytes":pixels,
                "flattenedViews":tree.filter { $0.canDrawSubviewsIntoLayer }.count,
                "nativeTextEditors":tree.filter { $0 is NSTextView }.count,
                "tableRows":tree.compactMap { $0 as? NSTableView }.map { $0.numberOfRows }]
    }
    static func sample(_ phase: String) throws {
        let state: [[String:Any]] = windows.map { ["number":$0.windowNumber,"visible":$0.isVisible,"occlusion":$0.occlusionState.rawValue,"frame":NSStringFromRect($0.frame)] }
        try check(windows.allSatisfy { $0.isVisible && $0.occlusionState.contains(.visible) },"AppKit confirms visible windows: "+phase)
        var observer: [String:Any] = [:]
        if ProcessInfo.processInfo.environment["NEXTCRM_DRAWING_OBSERVER"] == "1" {
            let request = output.deletingPathExtension().appendingPathExtension("request.json")
            let response = output.deletingPathExtension().appendingPathExtension("response.json")
            try JSONSerialization.data(withJSONObject:["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"expectedWindowNumbers":windows.map(\.windowNumber)]).write(to:request,options:.atomic)
            // The controller is already settled. Wait only for the external
            // observer, while keeping this exact window state unchanged.
            let deadline = Date().addingTimeInterval(15)
            while observer.isEmpty && Date() < deadline {
                if let data = try? Data(contentsOf:response), let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any], value["phase"] as? String == phase { observer = value }
                else { Thread.sleep(forTimeInterval:0.02) }
            }
            try check(observer["confirmedVisible"] as? Bool == true,"External WindowServer observer confirms window IDs: "+phase)
        }
        let path = output.deletingLastPathComponent().appendingPathComponent(output.deletingPathExtension().lastPathComponent+"-"+phase+"-footprint.json")
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/footprint")
        process.arguments = ["-j",path.path,String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NativeDBError.message("footprint failed") }
        let footprint = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
        let sample: [String:Any] = ["phase":phase,"footprintBytes":footprint["total footprint"]!,
            "ui":windows.map(layerMetadata),"appKitWindows":state,"externalObserver":observer,"windowEstimates":windowMetadata()]
        samples.append(sample)
        try JSONSerialization.data(withJSONObject:report(),options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
        print("\(mode) \(phase): \((footprint["total footprint"] as! NSNumber).doubleValue/1048576) MiB")
        fflush(stdout)
    }
    static func report() -> [String:Any] {
        ["mode":mode,"samples":samples,"checks":checks,"os":ProcessInfo.processInfo.operatingSystemVersionString,
         "screens":NSScreen.screens.map { ["frame":NSStringFromRect($0.frame),"visible":NSStringFromRect($0.visibleFrame),"scale":$0.backingScaleFactor] },
         "limitations":"Synthetic actual CRM controllers, not whole application. App footprint samples are not peaks. CG window memory is an OS estimate, not attributable WindowServer footprint; do not sum it with app footprint. Layer area is geometry, not allocated bytes."]
    }
    static func finish() throws {
        try sample("closed")
        try JSONSerialization.data(withJSONObject:report(),options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
        service = nil; db = nil; try FileManager.default.removeItem(at:folder); exit(0)
    }
    static func openForm() throws {
        var input = try db.initialValues("crm_Accounts")
        input["name"] = .text("日本語の描画比較・保存しない取引先")
        input["description"] = .text(String(repeating:"日本語の商談記録です。提案内容・合意事項・次回の対応を確認します。\n",count:4000))
        form = try CRMEditor(module:CRMModule.find("crm_Accounts")!,record:NativeRecord(model:"crm_Accounts",values:input,revision:0),linkedTo:nil,service:service)
        show(form!.window)
        later {
            try sample("form-top")
            let content = views(form!.window.contentView!).compactMap { $0 as? CRMFormContentView }.first!
            let scroll = content.enclosingScrollView!; scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,content.bounds.height-scroll.contentSize.height))); scroll.reflectScrolledClipView(scroll.contentView)
            apply(form!.window)
            later {
                try sample("form-memo")
                let memo = views(form!.window.contentView!).compactMap { $0 as? DeferredTextInput }.first!
                memo.focusEditor(); let editor = memo.editor!; editor.setSelectedRange(NSRange(location:0,length:0))
                editor.setMarkedText("にほん",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
                try check(editor.hasMarkedText(),"Native marked Japanese text survives drawing mode")
                editor.insertText("日本語",replacementRange:NSRange(location:NSNotFound,length:0)); editor.breakUndoCoalescing()
                try check(!editor.hasMarkedText() && editor.string.hasPrefix("日本語日本語の商談"),"Native composition commits at selection")
                editor.insertText("確認",replacementRange:NSRange(location:NSNotFound,length:0)); editor.breakUndoCoalescing()
                let edited = editor.string; editor.undoManager!.undo(); try check(editor.string != edited,"Native Undo works")
                editor.undoManager!.redo(); try check(editor.string == edited,"Native Redo works")
                apply(form!.window)
                later {
                    try sample("form-editing")
                    form!.window.orderOut(nil); form = nil
                    later { try finish() }
                }
            }
        }
    }
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else { throw NativeDBError.message("usage: resources output.json baseline|static|rows") }
            let resources = URL(fileURLWithPath:CommandLine.arguments[1]); output = URL(fileURLWithPath:CommandLine.arguments[2]); mode = CommandLine.arguments[3]
            guard ["baseline","static","rows"].contains(mode) else { throw NativeDBError.message("unknown mode") }
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-DrawingProbe-"+UUID().uuidString)
            let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.appearance = NSAppearance(named:.darkAqua)
            db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); service = CRMService(db:db,identity:identity)
            try autoreleasepool {
                let board = try service.saveProject(original:nil,input:["title":.text("描画比較プロジェクト"),"description":.text("独立した架空データだけを使用")])
                let section = try service.projectSections(board["id"].string).rows[0]
                let day = Calendar.current.startOfDay(for:Date()); let iso = ISO8601DateFormatter()
                try db.transaction {
                    for i in 0..<200 {
                        _ = try service.saveProjectTask(sectionID:section["id"].string,original:nil,input:["title":.text(String(format:"日本語の担当タスク %03d",i)),"content":.text("保存しない描画比較です。"),"user":.text(identity.id),"priority":.text(i%3 == 0 ? "high" : "normal"),"dueDateAt":.text(iso.string(from:day.addingTimeInterval(i<100 ? 1 : 86401)))])
                    }
                }
            }
            later {
                try sample("no-window")
                dashboard = CRMProjectDashboardWindow(service:service); show(dashboard!.window)
                later {
                    apply(dashboard!.window)
                    later {
                        let tables = views(dashboard!.window.contentView!).compactMap { $0 as? NSTableView }
                        try check(tables.count == 2 && tables.allSatisfy { $0.numberOfRows == 100 },"Both real dashboard lists loaded100rows")
                        try sample("dashboard")
                        for table in tables { table.selectRowIndexes(IndexSet(integer:50),byExtendingSelection:false); table.scrollRowToVisible(50) }
                        later {
                            apply(dashboard!.window)
                            later {
                                try sample("dashboard-scrolled")
                                dashboard!.window.orderOut(nil); dashboard = nil; configured.removeAll()
                                later { try openForm() }
                            }
                        }
                    }
                }
            }
            app.run()
        } catch { fail(error) }
    }
}
