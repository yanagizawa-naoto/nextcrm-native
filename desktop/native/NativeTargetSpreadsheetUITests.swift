import AppKit

@MainActor enum NativeTargetSpreadsheetUITests {
    final class Secrets:NativeAISecretStore {
        func load(id:String,interactive:Bool)throws->Data?{throw NativeDBError.conflict}
        func save(id:String,data:Data)throws{throw NativeDBError.conflict}
        func remove(id:String)throws{throw NativeDBError.conflict}
    }
    static var checks=0
    static func check(_ value:Bool,_ label:String)throws{guard value else{throw NativeTargetSpreadsheetFailure(message:label)};checks += 1}
    static func views(_ root:NSView)->[NSView]{[root]+root.subviews.flatMap{views($0)}}
    static func button(_ owner:NativeTargetSpreadsheetWindow,_ name:String)->NSButton{views(owner.window.contentView!).compactMap{$0 as? NSButton}.first{$0.title==name}!}
    static func wait(_ owner:NativeTargetSpreadsheetWindow)async throws {for _ in 0..<2000{if !owner.busy{return};try await Task.sleep(nanoseconds:5_000_000)};throw NativeTargetSpreadsheetFailure(message:"UI task timed out")}
    static func main()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),native=root.deletingLastPathComponent().deletingLastPathComponent()
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TargetSpreadsheetWindow-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:folder)}
        let db=try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
        let actor=try db.insert("Users",values:["name":.text("担当者"),"email":.text("actor@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"fixture")
        let service=CRMService(db:db,identity:.init(id:actor["id"].string,role:"user",partnerAccountID:nil))
        var keys=NativeAIKeys(service:service,store:Secrets());keys.environment = .init(lookup:{_ in nil})
        let controller=NativeTargetSpreadsheetController(service:service,keys:keys,admission:{})
        controller.request={_ in throw NativeTargetSpreadsheetFailure(message:"network forbidden")}
        let window=NativeTargetSpreadsheetWindow(controller:controller)
        var closed=0;window.onClosed={closed += 1}
        window.window.contentView!.layoutSubtreeIfNeeded()
        let popups=views(window.window.contentView!).compactMap{$0 as? NSComboBox}
        try check(popups.count==21,"all fields map controls")
        for name in ["ファイルを選択…","CSVを書き出す…","Excelを書き出す…"]{try check(button(window,name).isEnabled,"initial action "+name)}
        try check(!button(window,"この内容で取り込む").isEnabled,"no unreviewed import")
        window.load(url:root.appendingPathComponent("source-fixtures/basic.csv"));try await wait(window)
        try check(button(window,"対応を確認").isEnabled,"loaded mapping")
        try check(popups[0].indexOfSelectedItem==1,"source header maps surname")
        button(window,"AIで列を提案").performClick(nil);try await wait(window)
        button(window,"対応を確認").performClick(nil);try await wait(window)
        let table=views(window.window.contentView!).compactMap{$0 as? NSTableView}.first!
        try check(table.numberOfRows==1 && button(window,"この内容で取り込む").isEnabled,"actual preview enables import")
        if CommandLine.arguments.contains("--show") {
            window.window.orderFront(nil);window.window.contentView!.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            let view=window.window.contentView!,rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:rep)
            try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("window-preview.png"))
            try check(!view.hasAmbiguousLayout,"panel layout determined")
            window.window.orderOut(nil)
        }
        button(window,"この内容で取り込む").performClick(nil);try await wait(window)
        try check(window.imported && !button(window,"この内容で取り込む").isEnabled,"actual import becomes result")
        try check(try db.page("crm_Targets",fields:[]).total==1,"UI imported SQLite record")
        let output=folder.appendingPathComponent("export.xlsx")
        window.export(to:output,format:.xlsx,replace:false);try await wait(window)
        try check(FileManager.default.fileExists(atPath:output.path),"UI export workflow")
        if CommandLine.arguments.contains("--show") {window.window.orderFront(nil);try await Task.sleep(nanoseconds:100_000_000);window.window.orderOut(nil);checks += 1}
        let paging=folder.appendingPathComponent("paging.csv")
        let values=(0..<301).map { index in index>=100 && index<200 ? "山田,名":",名だけ" }
        try ("last_name,first_name\n"+values.joined(separator:"\n")).write(to:paging,atomically:true,encoding:.utf8)
        window.load(url:paging);try await wait(window);button(window,"対応を確認").performClick(nil);try await wait(window);button(window,"この内容で取り込む").performClick(nil);try await wait(window)
        try check(table.numberOfRows==100,"result notes first page")
        button(window,"次の100行").performClick(nil);try await wait(window);try check(table.numberOfRows==100,"sparse errors second page")
        button(window,"次の100行").performClick(nil);try await wait(window);try check(table.numberOfRows==1 && !button(window,"次の100行").isEnabled,"sparse errors cursor reaches final page")
        async let a:Void=window.stopAndDrain();async let b:Void=window.stopAndDrain();_ = await(a,b)
        try check(window.closed && closed==1,"concurrent close joins exactly once")
        // A real sheet action starts an accepted provider Task; close cancels
        // and joins that task before reporting the controller as closed.
        keys.environment = .init(lookup:{$0=="OPENAI_API_KEY" ? "synthetic":nil})
        let slow=NativeTargetSpreadsheetController(service:service,keys:keys,admission:{})
        var started=false,exited=false
        slow.request={_ in started=true;defer{exited=true};try await Task.sleep(nanoseconds:2_000_000_000);throw NativeDBError.conflict}
        let closing=NativeTargetSpreadsheetWindow(controller:slow)
        closing.load(url:root.appendingPathComponent("source-fixtures/basic.csv"));try await wait(closing)
        button(closing,"AIで列を提案").performClick(nil)
        for _ in 0..<200 where !started{try await Task.sleep(nanoseconds:5_000_000)}
        try check(started,"actual provider entered")
        await closing.stopAndDrain();try check(exited && closing.closed,"close joins cancelled provider and files")
        let registry=folder.appendingPathComponent(".native-export-recovery")
        let entries=try FileManager.default.contentsOfDirectory(atPath:registry.path)
        try check(!entries.contains{$0.hasSuffix(".json") && $0 != "owner.json"},"no unclosed stage journal")
        try JSONSerialization.data(withJSONObject:["checks":checks,"visible":CommandLine.arguments.contains("--show")],options:.prettyPrinted).write(to:root.appendingPathComponent("window-actual.json"))
        print("Window \(checks) checks")
    }
}
