import AppKit
import Darwin

private final class MaintenanceGate {
    let lock=NSLock(),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    var point:String?,once=false,throwAt:String?
    func checkpoint(_ value:String)throws {
        lock.lock();let waits=value==point && !once;if waits{once=true};let fails=value==throwAt;lock.unlock()
        if waits{entered.signal();guard release.wait(timeout:.now()+15) == .success else{throw NativeMigrationFailure("test.timeout","模擬処理の待機が終了しません。")}}
        if fails{throw NativeMigrationFailure("test.failure","模擬処理に失敗しました。")}
    }
}

@main struct NativeDataMaintenanceTests {
    static var checks=0,last="start"
    static func check(_ value:@autoclosure()throws->Bool,_ name:String)throws{last=name;guard try value()else{throw NativeMigrationFailure("test.assert",name)};checks+=1}
    static func wait(_ label:String,seconds:TimeInterval=25,_ body:()throws->Bool)throws{last=label;let deadline=Date().addingTimeInterval(seconds);while Date()<deadline{if try body(){return};while let event=NSApp.nextEvent(matching:.any,until:Date(),inMode:.default,dequeue:true){NSApp.sendEvent(event)};RunLoop.current.run(until:Date().addingTimeInterval(0.01))};throw NativeMigrationFailure("test.timeout",label)}
    static func views(_ root:NSView)->[NSView]{[root]+root.subviews.flatMap(views)}
    static func button(_ name:String,_ ui:NativeDataMaintenanceWindow)throws->NSButton{guard let b=views(ui.window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==name && !($0 is NSPopUpButton)}) else{throw NativeMigrationFailure("test.control",name)};return b}
    static func field(_ label:String,_ ui:NativeDataMaintenanceWindow)throws->NSTextField{guard let f=views(ui.window.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel()==label}) else{throw NativeMigrationFailure("test.control",label)};return f}
    static func picker(_ label:String,_ ui:NativeDataMaintenanceWindow)throws->NSPopUpButton{guard let p=views(ui.window.contentView!).compactMap({$0 as? NSPopUpButton}).first(where:{$0.accessibilityLabel()==label}) else{throw NativeMigrationFailure("test.control",label)};return p}
    static func table(_ ui:NativeDataMaintenanceWindow)throws->NSTableView{guard let t=views(ui.window.contentView!).compactMap({$0 as? NSTableView}).first else{throw NativeMigrationFiles.io};return t}
    static func click(_ name:String,_ ui:NativeDataMaintenanceWindow)throws{let b=try button(name,ui);try check(b.isEnabled,"enabled "+name);b.sendAction(b.action,to:b.target)}
    static func pick(_ label:String,_ index:Int,_ ui:NativeDataMaintenanceWindow)throws{let p=try picker(label,ui);p.selectItem(at:index);p.sendAction(p.action,to:p.target)}
    static func layout(_ ui:NativeDataMaintenanceWindow)throws {
        ui.window.contentView!.layoutSubtreeIfNeeded();let root=ui.window.contentView!,bounds=root.bounds
        for control in views(root).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor && !($0.superview is NSTableCellView)}) {
            // Recycled table cells live in a scrolling document outside its viewport.
            var parent=control.superview;var inTable=false;while let p=parent{if p is NSTableView{inTable=true};parent=p.superview};if inTable || control is NSTableView{continue}
            let frame=control.convert(control.bounds,to:root)
            try check(frame.width>0 && frame.height>0 && frame.minX >= -1 && frame.maxX <= bounds.maxX+1 && frame.minY >= -1 && frame.maxY<=bounds.maxY+1,"layout "+(control.accessibilityLabel() ?? control.identifier?.rawValue ?? "control"))
        }
    }
    static func main() {
        do{try run()}catch{let value=(error as? NativeMigrationFailure);fputs("Data maintenance QA failed at \(last): \(value?.code ?? "error") / \(value?.message ?? error.localizedDescription)\n",stderr);exit(1)}
    }
    static func run()throws {
        guard CommandLine.arguments.count>=4 else{fatalError("mode resources fixture")}
        let mode=CommandLine.arguments[1],resources=URL(fileURLWithPath:CommandLine.arguments[2]),root=URL(fileURLWithPath:CommandLine.arguments[3])
        if mode=="initialize"{_ = try NativeDatabase(url:root,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"));return}
        _ = NSApplication.shared;NSApp.setActivationPolicy(mode=="visible" ? .regular:.prohibited);if mode=="visible"{NSApp.finishLaunching()}
        let clipboard=NSPasteboard.general.changeCount
        let db=try NativeDatabase(url:root.appendingPathComponent("original/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let id=try String(contentsOf:root.appendingPathComponent("actor.txt"),encoding:.utf8)
        let service=CRMService(db:db,identity:.init(id:id,role:"admin",partnerAccountID:nil))
        func role(_ value:String)throws{guard let user=try db.get("Users",key:["id":.text(id)])else{throw NativeDBError.conflict};_ = try db.update(user,changes:["role":.text(value)],actor:"synthetic-maintenance-test")}
        let output=root.appendingPathComponent("outputs");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var selectedSource:URL?,selectedDestination:URL?,revealed:URL?,reviewed:URL?,prepared:[NativeDataMaintenanceArtifact]=[],closed=0
        let dialogs=NativeDataMaintenanceDialogs(source:{_,done in done(selectedSource)},destination:{_,_,done in done(selectedDestination)},reveal:{revealed=$0})
        let controller=NativeDataMaintenanceController(service:service,resources:resources),ui=NativeDataMaintenanceWindow(controller:controller,onReviewActivation:{reviewed=$0.url},dialogs:dialogs)
        ui.onPrepared={prepared.append($0)};ui.onClosed={closed+=1};ui.start()
        if mode=="visible"{ui.window.center();ui.window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
        defer{ui.window.orderOut(nil);ui.dismissForNavigation()}
        try check(ui.window.title=="バックアップと復元準備","Japanese title");try layout(ui)
        try check(!ui.hasOperation && !button("中止",ui).isEnabled,"idle no operation")
        selectedDestination=output.appendingPathComponent("backup");try click("保存先を選択",ui);try click("バックアップを作成",ui);try wait("backup completed"){!ui.hasOperation}
        guard prepared.count==1 else{throw NativeMigrationFailure("test.backup",try field("データ保全の結果",ui).stringValue)}
        try check(prepared[0].kind == .backup && prepared[0].url==selectedDestination,"published backup callback")
        try check(try field("データ保全の結果",ui).stringValue.contains("保存しました"),"backup success message")
        try check(FileManager.default.fileExists(atPath:selectedDestination!.appendingPathComponent("database.sqlite").path),"backup visible at selected destination")
        try click("保存場所を表示",ui);try check(revealed==selectedDestination,"only published path revealed")
        selectedSource=selectedDestination;try pick("データ保全の操作",1,ui);selectedDestination=output.appendingPathComponent("restore")
        try click("元のバックアップを選択",ui);try click("保存先を選択",ui);try click("復元候補を準備",ui);try wait("restore completed"){!ui.hasOperation}
        try check(prepared.count==2 && prepared[1].kind == .restore,"restore callback")
        let restored=prepared[1],stored=try JSONDecoder().decode(NativeRestoreResult.self,from:Data(contentsOf:restored.url.appendingPathComponent("restore.json")))
        let targetHash=NativeMigrationCodec.hash(Data(restored.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        try check(stored.stagingNamespaceSHA256==targetHash && restored.restore?.stagingNamespaceSHA256==targetHash,"published preparation namespace")
        try check(stored.sourceNamespaceSHA256==prepared[0].backup?.sourceNamespaceSHA256,"source namespace unchanged")
        let summary=try NativeDataMaintenanceReader(authorize:controller.authorize).page(restored,section:.summary,offset:0,operation:.init())
        try check(summary.rows.contains{$0.title=="バックアップの注意点" && $0.value.hasSuffix("分類")},"backup caveat categories separate")
        try check(summary.rows.contains{$0.title=="切り替え前の確認" && $0.value=="8 件"},"actual eight checks shown in summary")
        try check(stored.activationGate.obligations.map(\.evidence)==NativeRestoreActivationGate.review.obligations.map(\.evidence),"machine evidence unchanged by presentation")
        for obligation in stored.activationGate.obligations {
            let text=NativeDataMaintenanceReader.obligationDetail(obligation.kind)
            try check(!["writer","listener","root","namespace","runtime","UIDVALIDITY","hash","cleanup","activation","queue","receipt"].contains(where:text.contains),"plain Japanese obligation "+obligation.kind)
        }

        try check(try field("データ保全の結果",ui).stringValue.contains("切り替えていません"),"preparation is not activation")
        try pick("データ保全の表示内容",1,ui);try wait("obligations page"){!ui.hasOperation};try check(try table(ui).numberOfRows==8,"eight unresolved obligations")
        try table(ui).selectRowIndexes(IndexSet(integer:3),byExtendingSelection:false);try check(try field("選択した確認事項の説明",ui).stringValue.contains("接続設定"),"resolution instructions visible")
        if mode=="visible" {
            ui.window.contentView!.layoutSubtreeIfNeeded();ui.window.displayIfNeeded()
            print("VISUAL_READY "+root.path);fflush(stdout)
            try wait("visual review completed",seconds:300){FileManager.default.fileExists(atPath:root.appendingPathComponent("ui-continue").path)}
            if let bitmap=ui.window.contentView!.bitmapImageRepForCachingDisplay(in:ui.window.contentView!.bounds){ui.window.contentView!.cacheDisplay(in:ui.window.contentView!.bounds,to:bitmap);if let data=bitmap.representation(using:.png,properties:[:]){try data.write(to:resources.appendingPathComponent("build/native-data-maintenance-ui.png"))}}
        }
        try click("切り替え前の確認へ",ui);try check(reviewed==restored.url,"review handoff only")
        try pick("データ保全の表示内容",2,ui);try wait("plan page"){!ui.hasOperation};try check(try table(ui).numberOfRows==100,"paged plan bounded")
        try click("次の100件",ui);try wait("next plan"){!ui.hasOperation};try check(try field("データ保全のページ",ui).stringValue.hasPrefix("101〜"),"second page")
        try click("前の100件",ui);try wait("previous plan"){!ui.hasOperation};try check(try table(ui).numberOfRows==100,"previous page")
        try layout(ui)
        try role("user");try click("次の100件",ui);try wait("revoked page"){!ui.hasOperation};try check(try table(ui).numberOfRows==0 && !button("保存場所を表示",ui).isEnabled,"permission loss clears page")
        try role("admin");try click("権限を再確認",ui);selectedSource=restored.url;try click("保存済みの結果を開く",ui);try wait("reopen result"){!ui.hasOperation};try check(try table(ui).numberOfRows>0,"fresh admin can reopen")
        // A reader revoked while streaming must not return even a partial page.
        var reads=0;let revoked=NativeDataMaintenanceReader(authorize:{reads+=1;if reads==4{try role("user")};try controller.authorize()})
        var readRejected=false;do{_ = try revoked.page(restored,section:.plan,offset:0,operation:.init())}catch{readRejected=true};try check(readRejected && reads>=4,"mid-read authority checked");try role("admin")
        // Current manifest hash is verified before rows are delivered.
        let planURL=restored.url.appendingPathComponent("resume-plan.ndjson"),planData=try Data(contentsOf:planURL);var corrupt=planData;corrupt.append(Data("{}\n".utf8));try corrupt.write(to:planURL)
        var corruptRejected=false;do{_ = try NativeDataMaintenanceReader(authorize:controller.authorize).page(restored,section:.plan,offset:0,operation:.init())}catch{corruptRejected=true};try check(corruptRejected,"corrupt page rejected");try planData.write(to:planURL)
        // Existing targets cannot be overwritten.
        let rejected=controller.perform(kind:.backup,backupURL:nil,destinationURL:prepared[0].url,operation:.init())
        try check(rejected.state == .failed && !rejected.cleanupPending,"existing destination retained")
        // Worker gates make cancellation/publication ordering deterministic.
        func gated(_ name:String,_ point:String,_ action:(NativeDataMaintenanceWindow,NativeDataMaintenanceOperation?)throws->Void)throws {
            let gate=MaintenanceGate();gate.point=point
            let c=NativeDataMaintenanceController(service:service,resources:resources,checkpoint:gate.checkpoint)
            let w=NativeDataMaintenanceWindow(controller:c,dialogs:dialogs);var found:NativeDataMaintenanceArtifact?,didClose=false
            w.onPrepared={found=$0};w.onClosed={didClose=true};w.start();selectedDestination=output.appendingPathComponent(name)
            try click("保存先を選択",w);try click("バックアップを作成",w)
            try wait("gate "+name){gate.entered.wait(timeout:.now()) == .success}
            try action(w,nil);gate.release.signal();try wait("gate finished "+name){!w.hasOperation}
            if name=="commit-wins"{try check(found != nil && FileManager.default.fileExists(atPath:selectedDestination!.path) && didClose,"sealed commit wins close")}
            else{try check(found==nil && !FileManager.default.fileExists(atPath:selectedDestination!.path),"unpublished attempt removed "+name)}
            if name=="close-cancel"{try check(didClose,"close waits for cleanup")}
            w.window.orderOut(nil);w.dismissForNavigation();try role("admin")
        }
        try gated("close-cancel","backend.databasePage"){w,_ in w.dismissForNavigation()}
        try gated("permission-before-commit","beforeCommit"){_,_ in try role("user")}
        try gated("cancel-before-seal","commit"){w,_ in try click("中止",w)}
        try gated("commit-wins","sealed"){w,_ in w.dismissForNavigation()}
        // Failure while exporting also cleans the newly-created hidden sibling.
        let failureGate=MaintenanceGate();failureGate.throwAt="copyChunk"
        let failure=NativeDataMaintenanceController(service:service,resources:resources,checkpoint:failureGate.checkpoint).perform(kind:.backup,backupURL:nil,destinationURL:output.appendingPathComponent("failed-copy"),operation:.init())
        try check(failure.state == .failed && !failure.cleanupPending && !FileManager.default.fileExists(atPath:output.appendingPathComponent("failed-copy").path),"copy failure cleanup")
        let leftovers=try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".nextcrm-pending-")}
        try check(leftovers.isEmpty,"no publication staging remains")
        if mode=="visible" {
            ui.window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            let system=NativeDataMaintenanceDialogs.system(initialDirectory:output)
            var selected:URL?,responded=false
            system.destination(ui.window,.backup){selected=$0;responded=true}
            try wait("actual save sheet"){ui.window.attachedSheet is NSSavePanel}
            let save=ui.window.attachedSheet as! NSSavePanel;save.directoryURL=output;save.nameFieldStringValue="日本語の保存先"
            print("PICKER_SAVE_READY "+output.path);fflush(stdout)
            try wait("actual save response",seconds:300){responded};try check(selected?.lastPathComponent=="日本語の保存先","actual destination picker")
            responded=false;selected=nil
            NativeDataMaintenanceDialogs.system(initialDirectory:prepared[0].url).source(ui.window){selected=$0;responded=true}
            try wait("actual source sheet"){ui.window.attachedSheet is NSOpenPanel}
            let open=ui.window.attachedSheet as! NSOpenPanel;open.directoryURL=prepared[0].url
            print("PICKER_SOURCE_READY "+prepared[0].url.path);fflush(stdout)
            try wait("actual source response",seconds:300){responded};try check(selected?.standardizedFileURL.path==prepared[0].url.standardizedFileURL.path,"actual source picker")
        }
        try check(NSPasteboard.general.changeCount==clipboard,"clipboard unchanged")
        try check(prepared.allSatisfy{$0.restore?.activated != true && $0.restore?.workersStarted != true && $0.restore?.keychainAccessed != true},"no activation keychain or workers")
        try layout(ui);ui.dismissForNavigation();try check(closed==1,"idle close")
        let result:[String:Any]=["ok":true,"checks":checks,"visible":mode=="visible","backupPath":prepared[0].url.path,"restorePath":restored.url.path,"sourceNamespace":stored.sourceNamespaceSHA256,"stagingNamespace":stored.stagingNamespaceSHA256]
        try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:root.appendingPathComponent("ui-results.json"))
        print("NativeDataMaintenanceTests: \(checks) checks passed (\(mode))")
    }
}
