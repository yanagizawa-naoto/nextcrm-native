import AppKit

@main enum NativeReportSchedulesUITests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ name:String)throws {guard try value()else{throw NativeDBError.message("FAIL schedule UI: "+name)};checks+=1}
    static func views(_ root:NSView)->[NSView]{[root]+root.subviews.flatMap(views)}
    static func control<T:NSView>(_ window:NSWindow,_ label:String,_ type:T.Type)throws->T {guard let value=views(window.contentView!).compactMap({$0 as? T}).first(where:{$0.accessibilityLabel()==label}) else{throw NativeDBError.message("Missing control: "+label)};return value}
    static func button(_ window:NSWindow,_ title:String)throws->NSButton {guard let value=views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else{throw NativeDBError.message("Missing button: "+title)};return value}
    static func wait(_ label:String,_ condition:()throws->Bool)throws {let deadline=Date().addingTimeInterval(20);while Date()<deadline {if try condition(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.01))};throw NativeDBError.message("Timeout: "+label)}
    static func choose(_ control:NSPopUpButton,_ index:Int){control.selectItem(at:index);_ = control.sendAction(control.action,to:control.target)}
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("Report schedule UI: \(error)\n".utf8));exit(1)}}
    static func run()throws {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ScheduleUI-"+UUID().uuidString)
        defer{NSApp.windows.forEach{$0.orderOut(nil)};try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")),service=CRMService(db:db,identity:identity),store=NativeReportSchedules(service:service)
        let config=try NativeReportConfigurations(service:service).save(name:"日本語の月次営業レポート",category:.sales,filters:.init(json:"{}"),shared:false)
        let output=resources.appendingPathComponent("../artifacts/native-report-schedule-ui");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func capture(_ window:NSWindow,_ name:String)throws {
            let content=window.contentView!;content.layoutSubtreeIfNeeded();let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds)!;content.cacheDisplay(in:content.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
            for control in views(content).compactMap({$0 as? NSControl}) where !control.isHiddenOrHasHiddenAncestor && !(control is NSTableView) {
                if control.bounds.width>0 && control.bounds.height>0 {try check(content.bounds.contains(control.convert(control.bounds,to:content)),"visible control within panel: "+(control.accessibilityLabel() ?? ""))}
            }
        }
        let parent=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1200,height:900),styleMask:[.titled],backing:.buffered,defer:false),reports=try NativeReportsWindow(service:service)
        var reviewed:String?
        reports.onReviewReport={job,_,completion in reviewed=job.id;completion()}
        parent.beginSheet(reports.window);reports.start()
        try button(reports.window,"定期送信…").performClick(nil);try wait("schedule entry point"){reports.window.attachedSheet != nil}
        let window=reports.window.attachedSheet!,table=try control(window,"定期送信と履歴の一覧",NSTableView.self),status=try control(window,"定期送信の一覧状態",NSTextField.self)
        try wait("empty list ready"){try status.stringValue.isEmpty && button(window,"新規…").isEnabled}
        try check(table.numberOfRows==0,"empty schedule list")
        try button(window,"新規…").performClick(nil);try wait("configuration picker"){window.attachedSheet != nil}
        let chooser=window.attachedSheet!,configs=try control(chooser,"保存したレポートの一覧",NSTableView.self)
        try wait("configuration choice loaded"){configs.numberOfRows==1};configs.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try button(chooser,"このレポートを定期送信").performClick(nil)
        try wait("editor opened"){window.attachedSheet?.title=="レポートの定期送信を作成"}
        let editor=window.attachedSheet!,addresses=try control(editor,"定期送信の宛先",NSTextView.self),zone=try control(editor,"定期送信のタイムゾーン",NSTextField.self),frequency=try control(editor,"定期送信の頻度",NSPopUpButton.self),format=try control(editor,"定期送信の添付形式",NSPopUpButton.self),inputStatus=try control(editor,"定期送信の入力状態",NSTextField.self)
        try check(frequency.numberOfItems==5 && format.numberOfItems==3,"original frequency and attachment choices")
        addresses.string="invalid";try button(editor,"保存").performClick(nil)
        try wait("bad email rejected"){try inputStatus.stringValue.contains("メールアドレス") && button(editor,"保存").isEnabled}
        try check(try store.list().total==0 && window.attachedSheet===editor,"invalid input preserves editor without creating schedule")
        addresses.string="one@example.invalid\ntwo@example.invalid、one@example.invalid";zone.stringValue="Asia/Tokyo";choose(frequency,2);choose(format,2)
        try button(editor,"次回日時を確認").performClick(nil);try check(inputStatus.stringValue.contains("Asia/Tokyo") && inputStatus.stringValue.contains("金"),"preview uses selected weekday and named time zone")
        try capture(editor,"editor")
        try check(frequency.superview!.bounds.height<=30,"hiding advanced cron keeps frequency row compact")
        try button(editor,"保存").performClick(nil);try wait("schedule saved"){window.attachedSheet==nil && table.numberOfRows==1 && !status.stringValue.contains("います")}
        var saved=try store.load(store.list().rows[0]["id"].string)
        try check(saved.settings.cron.expression=="0 9 * * 5" && saved.settings.format == .both && saved.settings.recipients.count==2,"UI settings persisted exactly")
        try check(try db.reportScheduleState("job",id:saved.id) != nil,"UI creation reserves durable occurrence")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);try button(window,"停止").performClick(nil)
        try wait("paused"){try !store.load(saved.id).isActive && !status.stringValue.contains("います")};table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try check(try button(window,"再開").isEnabled,"pause offers resume")
        try button(window,"再開").performClick(nil);try wait("resumed"){try store.load(saved.id).isActive && !status.stringValue.contains("います")}
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);try button(window,"編集…").performClick(nil);try wait("editor reopens"){window.attachedSheet != nil}
        let edit=window.attachedSheet!,editedFormat=try control(edit,"定期送信の添付形式",NSPopUpButton.self)
        try check(try control(edit,"定期送信の宛先",NSTextView.self).string=="one@example.invalid\ntwo@example.invalid","editor restores recipient list")
        choose(editedFormat,0);try button(edit,"保存").performClick(nil);try wait("edit saved"){window.attachedSheet==nil && !status.stringValue.contains("います")}
        saved=try store.load(saved.id);try check(saved.settings.format == .csv,"format change persisted")
        try capture(window,"reservations")
        let mode=try control(window,"定期送信の表示内容",NSPopUpButton.self);choose(mode,1)
        try wait("history loaded"){try table.numberOfRows==store.history().total && !status.stringValue.contains("います")}
        let firstID=try db.reportScheduleState("job",id:saved.id)!,firstIndex=try store.history().rows.firstIndex(where:{$0.id==firstID})!
        table.selectRowIndexes(IndexSet(integer:firstIndex),byExtendingSelection:false);try button(window,"予約を取り消す…").performClick(nil);try wait("cancel confirmation"){window.attachedSheet != nil}
        try button(window.attachedSheet!,"取り消す").performClick(nil);try wait("single occurrence cancelled"){try db.reportScheduleState("job",id:saved.id) != firstID && !status.stringValue.contains("います")}
        try check(try db.job(id:firstID)?.status=="cancelled" && store.load(saved.id).isActive,"one-off cancel preserves active schedule")
        let nextID=try db.reportScheduleState("job",id:saved.id)!,due=try ISO8601DateFormatter().date(from:db.job(id:nextID)!.payload["occurrence"]!)!
        var held=try db.claimReportJob(now:due)!;_ = try NativeReportQueue.advance(held,db:db,now:due);held=try db.markJobDeliveryStarted(held,now:due);try db.failJob(held,message:"検証：送信サービスの結果を確認してください。",needsReview:true)
        try button(window,"更新").performClick(nil);try wait("review row loaded"){try table.numberOfRows==store.history().total && !status.stringValue.contains("います")}
        let index=try store.history().rows.firstIndex(where:{$0.id==held.id})!;table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
        try check(try button(window,"送信結果を記録…").isEnabled && !button(window,"予約を取り消す…").isEnabled && !button(window,"再試行").isEnabled,"ambiguous receipt requires review rather than resend/cancel")
        try capture(window,"review-history")
        try button(window,"送信結果を記録…").performClick(nil);try check(reviewed==held.id,"review routes exact selected immutable job")
        try wait("review callback refreshed"){!status.stringValue.contains("います")}
        choose(mode,0);try wait("reservations again"){table.numberOfRows==1 && !status.stringValue.contains("います")}
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);try button(window,"削除…").performClick(nil);try wait("delete confirmation"){window.attachedSheet != nil};try button(window.attachedSheet!,"削除").performClick(nil)
        try wait("deleted"){table.numberOfRows==0 && !status.stringValue.contains("います")}
        try check(try store.list().total==0 && store.history(scheduleID:saved.id).total>0,"deletion retains receipt history")
        try button(window,"閉じる").performClick(nil);try wait("manager closes"){reports.window.attachedSheet==nil}
        // Pagination uses bounded rows even with more than one hundred schedules.
        let settings=try NativeReportScheduleSettings(expression:"0 9 * * *",recipients:["paging@example.invalid"],format:"csv",timeZone:"Asia/Tokyo")
        try db.transaction {for _ in 0..<105 {_ = try store.create(configID:config.id,settings:settings)}}
        try button(reports.window,"定期送信…").performClick(nil);try wait("reopened manager"){reports.window.attachedSheet != nil}
        let paged=reports.window.attachedSheet!,pagedTable=try control(paged,"定期送信と履歴の一覧",NSTableView.self),pagedStatus=try control(paged,"定期送信の一覧状態",NSTextField.self)
        try wait("first hundred"){pagedTable.numberOfRows==100 && !pagedStatus.stringValue.contains("います")};try check(try button(paged,"次の100件").isEnabled,"second page reachable")
        try button(paged,"次の100件").performClick(nil);try wait("last five"){pagedTable.numberOfRows==5 && !pagedStatus.stringValue.contains("います")};try check(try !button(paged,"次の100件").isEnabled && button(paged,"前の100件").isEnabled,"bounded final page controls")
        let reopened=try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try check(try NativeReportSchedules(service:.init(db:reopened,identity:identity)).list().total==105,"schedule settings survive database reopen")
        let legacy=try store.list(offset:100).rows[0];try db.clearReportScheduleMetadata(legacy["id"].string)
        pagedTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);try button(paged,"停止").performClick(nil)
        try wait("unconfirmed migration opens editor"){paged.attachedSheet?.title=="レポートの定期送信を編集"}
        try check(try db.reportScheduleTimeZone(legacy["id"].string)==nil,"pause/resume cannot silently confirm migrated timezone")
        try button(paged.attachedSheet!,"キャンセル").performClick(nil);try wait("timezone confirmation dismissed"){paged.attachedSheet==nil}
        print("{\"suite\":\"NativeReportSchedulesUI\",\"checks\":\(checks),\"network\":false}")
    }
}
