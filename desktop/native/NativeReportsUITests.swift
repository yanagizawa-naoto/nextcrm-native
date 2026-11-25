import AppKit

@main enum NativeReportsUITests {
    static var checks=0
    static func check(_ condition: @autoclosure () throws -> Bool,_ name: String) throws {guard try condition() else{throw NativeDBError.message("FAIL: "+name)};checks+=1}
    static func views(_ view: NSView) -> [NSView] {[view]+view.subviews.flatMap(views)}
    static func control<T: NSView>(_ window: NSWindow,_ label: String,_ type: T.Type) throws -> T {
        guard let value=views(window.contentView!).compactMap({$0 as? T}).first(where:{$0.accessibilityLabel()==label}) else {throw NativeDBError.message("Missing "+label)};return value
    }
    static func button(_ window: NSWindow,_ title: String) throws -> NSButton {guard let b=views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else{throw NativeDBError.message("Missing button "+title)};return b}
    static func wait(_ label: String,_ condition: () throws -> Bool) throws {let end=Date().addingTimeInterval(15);while Date()<end{if try condition(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.01))};throw NativeDBError.message("Timeout "+label)}
    static func choose(_ control: NSPopUpButton,_ index: Int) {control.selectItem(at:index);_ = control.sendAction(control.action,to:control.target)}
    static func main() {do {try run()}catch{FileHandle.standardError.write(Data("NativeReportsUITests: \(error)\n".utf8));exit(1)}}
    static func run() throws {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ReportsUI-"+UUID().uuidString)
        defer{NSApp.windows.forEach{$0.orderOut(nil)};try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")),service=CRMService(db:db,identity:identity)
        let now=NativeReportFilters.timestamp(Date()),user=try db.insert("Users",values:["name":.text("担当者"),"email":.text("reports-ui@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        try db.transaction {
            for i in 0..<205 {
                let account=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text(String(format:"取引先%03d",i)),"annual_revenue":.text(String(i*100)),"employees":.text(String(i+1)),"createdBy":.text(identity.id)],actor:identity.id)
                try db.insert("crm_Contacts",values:["last_name":.text("連絡先\(i)"),"created_on":.text(now),"accountsIDs":account["id"],"createdBy":.text(identity.id)],actor:identity.id)
            }
            for (money,budget,status) in [("JPY","100","CLOSED"),("USD","1","ACTIVE")] {try db.insert("crm_Opportunities",values:["name":.text("画面検証"),"created_on":.text(now),"budget":.text(budget),"currency":.text(money),"status":.text(status),"createdBy":.text(identity.id)],actor:identity.id)}
            try db.insert("ExchangeRate",values:["fromCurrency":.text("USD"),"toCurrency":.text("JPY"),"rate":.text("150"),"source":.text("MANUAL"),"effectiveDate":.text(now)],actor:identity.id)
        }
        var exportSection:Int?,dismissExport=false,exportRequests:[NativeReportExportFormat]=[]
        let parent=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1120,height:920),styleMask:[.titled],backing:.buffered,defer:false),controller=try NativeReportsWindow(service:service,exportDialog:{_,snapshot,format,completion in
            exportRequests.append(format)
            guard !dismissExport else{completion(nil);return}
            let sectionID=exportSection.map{snapshot.sections[$0].id} ?? NativeReportExport.standardSection(snapshot.category)!
            completion(.init(sectionID:sectionID,url:root.appendingPathComponent("画面出力."+format.rawValue)))
        }),w=controller.window
        parent.beginSheet(w);controller.start()
        let category=try control(w,"レポートの種類",NSPopUpButton.self),section=try control(w,"集計項目",NSPopUpButton.self),sort=try control(w,"集計結果の並び順",NSPopUpButton.self),currency=try control(w,"レポートの表示通貨",NSPopUpButton.self),preset=try control(w,"集計期間",NSPopUpButton.self),table=try control(w,"レポートの集計結果",NSTableView.self),message=try control(w,"レポートの状態",NSTextField.self)
        let artifacts=resources.appendingPathComponent("../artifacts/native-reports-ui",isDirectory:true);try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        func capture(_ name: String) throws {
            let content=w.contentView!;content.layoutSubtreeIfNeeded()
            let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds)!;content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:artifacts.appendingPathComponent(name+".png"))
            for control in [category,preset,currency] {try check(content.bounds.contains(control.convert(control.bounds,to:content)),"filter remains visible")}
        }
        try wait("overview"){message.stringValue.contains("前期間")}
        try capture("overview")
        try check(w.contentView!.bounds.height<=500 && table.enclosingScrollView!.isHidden,"overview hides empty results")
        try check(try !button(w,"CSV出力…").isEnabled && !button(w,"PDF出力…").isEnabled,"overview exports disabled")
        try check(category.numberOfItems==7,"all report categories")
        try check(views(w.contentView!).compactMap{$0 as? NSButton}.filter{$0.title=="詳細を見る"}.count==10,"all overview links")
        try button(w,"詳細を見る").performClick(nil)
        try wait("drilldown"){category.indexOfSelectedItem==1&&section.numberOfItems==2&&table.numberOfRows>0}
        try capture("sales")
        try check(currency.isEnabled,"sales currency enabled")
        try check(views(w.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="150 JPY"},"converted pipeline displayed")
        try button(w,"条件を保存…").performClick(nil);try wait("save dialog"){w.attachedSheet != nil}
        let saveSheet=w.attachedSheet!
        try control(saveSheet,"保存するレポート名",NSTextField.self).stringValue="検証用の売上"
        try button(saveSheet,"他の利用者と条件を共有").state = .on
        try button(saveSheet,"保存").performClick(nil)
        let loadedName=try control(w,"読み込んだレポート条件",NSTextField.self)
        try wait("saved report"){w.attachedSheet==nil&&loadedName.stringValue.contains("検証用の売上") && !message.stringValue.contains("います…")}
        let savedRows=try NativeReportConfigurations(service:service).list(category:.sales)
        try check(savedRows.total==1 && savedRows.rows[0]["isShared"] == .integer(1),"save and share through actual dialog")
        choose(currency,1)
        try wait("currency change"){views(w.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="1 USD"}&&message.stringValue.contains("換算レート")}
        try check(message.stringValue.contains("換算レート"),"missing exchange warning")
        choose(category,0);try wait("overview currency warning"){message.stringValue.contains("前期間")}
        try check(message.stringValue.contains("換算レート"),"overview missing exchange warning")
        try button(w,"保存した条件…").performClick(nil);try wait("saved list"){w.attachedSheet != nil}
        let savedWindow=w.attachedSheet!,savedTable=try control(savedWindow,"保存したレポートの一覧",NSTableView.self)
        try wait("saved list loaded"){savedTable.numberOfRows==1};savedTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try button(savedWindow,"複製…").performClick(nil);try wait("duplicate dialog"){savedWindow.attachedSheet != nil}
        let duplicateSheet=savedWindow.attachedSheet!
        try control(duplicateSheet,"複製するレポート名",NSTextField.self).stringValue="売上の複製"
        try button(duplicateSheet,"複製").performClick(nil)
        try wait("duplicated"){savedWindow.attachedSheet==nil && savedTable.numberOfRows==2 && savedTable.selectedRow>=0}
        try check(try button(savedWindow,"共有する").isEnabled,"duplicate starts private")
        try button(savedWindow,"共有する").performClick(nil)
        try wait("shared copy"){(try? button(savedWindow,"共有を解除").isEnabled)==true}
        try button(savedWindow,"この条件で集計").performClick(nil)
        try wait("apply saved copy"){w.attachedSheet==nil&&loadedName.stringValue.contains("売上の複製")&&category.indexOfSelectedItem==1&&currency.titleOfSelectedItem=="JPY"&&table.numberOfRows>0}
        try check(views(w.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="150 JPY"},"saved filters restore currency and results")
        try button(w,"保存した条件…").performClick(nil);try wait("reopen configurations"){w.attachedSheet != nil}
        let deleteWindow=w.attachedSheet!,deleteTable=try control(deleteWindow,"保存したレポートの一覧",NSTableView.self)
        try wait("configuration rows"){deleteTable.numberOfRows==2};deleteTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try button(deleteWindow,"削除…").performClick(nil);try wait("delete confirmation"){deleteWindow.attachedSheet != nil}
        try button(deleteWindow.attachedSheet!,"削除").performClick(nil);try wait("deleted configuration"){deleteWindow.attachedSheet==nil&&deleteTable.numberOfRows==1}
        try check(try NativeReportConfigurations(service:service).list(category:.sales).total==1,"configuration delete through confirmation")
        try button(deleteWindow,"閉じる").performClick(nil);try wait("management closes"){w.attachedSheet==nil && !message.stringValue.contains("います…")}
        choose(category,2)
        try wait("leads"){section.numberOfItems==4&&section.titleOfSelectedItem=="月別の新規リード"&&message.stringValue.contains("ありません")}
        try check(!currency.isEnabled,"irrelevant currency disabled")
        choose(section,3)
        try wait("accounts grouping"){table.numberOfRows==100}
        try check(try button(w,"次の100件").isEnabled,"more than first page reachable")
        try button(w,"次の100件").performClick(nil)
        try wait("page two"){views(w.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="101〜200 ／ 205件"}}
        try button(w,"次の100件").performClick(nil)
        try wait("page three"){table.numberOfRows==5}
        try check(try !button(w,"次の100件").isEnabled,"final page bounds")
        choose(sort,3)
        try wait("sort resets page"){table.numberOfRows==100&&views(w.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="1〜100 ／ 205件"}}
        try check(try !button(w,"前の100件").isEnabled,"sort resets previous")
        exportSection=3
        let beforeExportMessage=message.stringValue
        dismissExport=true;try button(w,"CSV出力…").performClick(nil)
        try check(message.stringValue==beforeExportMessage && !FileManager.default.fileExists(atPath:root.appendingPathComponent("画面出力.csv").path),"dismissing export preserves result")
        dismissExport=false;try button(w,"CSV出力…").performClick(nil)
        try check(!category.isEnabled && !section.isEnabled && !currency.isEnabled && (try button(w,"出力を中止").isEnabled),"export locks filters and permits cancellation")
        try wait("CSV export finishes"){message.stringValue.contains("205件を保存しました")}
        let csvBytes=try Data(contentsOf:root.appendingPathComponent("画面出力.csv")),csv=String(data:csvBytes,encoding:.utf8)!
        try check(csvBytes.prefix(3)==Data([0xef,0xbb,0xbf]),"CSV has Japanese spreadsheet BOM")
        try check(csv.contains("\"項目\",\"件数\"") && csv.contains("取引先204"),"CSV exports Japanese labels")
        try check(csv.components(separatedBy:"\r\n").count==207,"CSV exports all 205 rows")
        try check(category.isEnabled && !currency.isEnabled && (try button(w,"CSV出力…").isEnabled),"export restores applicable controls")
        try button(w,"PDF出力…").performClick(nil)
        try wait("PDF export finishes"){message.stringValue.contains("205件を保存しました") && message.stringValue.hasSuffix(".pdf")}
        let pdf=try Data(contentsOf:root.appendingPathComponent("画面出力.pdf"))
        try check(pdf.starts(with:Data("%PDF-".utf8)) && exportRequests==[.csv,.csv,.pdf],"PDF button exports requested format")
        exportSection=nil
        // Exercise every chart type/section and actual AppKit layout/rendering.
        for i in [1,3,4,5,6] {
            choose(category,i)
            try wait("category \(i)"){!message.stringValue.contains("います…")&&section.numberOfItems>0}
            let count=section.numberOfItems
            for j in 0..<count {
                choose(section,j);try wait("section \(i)/\(j)"){!message.stringValue.contains("います…")}
                w.contentView!.layoutSubtreeIfNeeded()
                let chart=views(w.contentView!).compactMap{$0 as? NativeReportChart}.first!
                try check(chart.rows.count<=100,"bounded chart")
                if !chart.isHidden && !chart.rows.isEmpty {
                    let rect=NSRect(x:0,y:0,width:min(1050,chart.bounds.width),height:210)
                    let bitmap=chart.bitmapImageRepForCachingDisplay(in:rect)!;chart.cacheDisplay(in:rect,to:bitmap)
                    let bytes=bitmap.representation(using:.png,properties:[:])!;try bytes.write(to:artifacts.appendingPathComponent("chart-\(i)-\(j).png"));try check(!bytes.isEmpty,"chart renders")
                }
            }
        }
        choose(category,1);choose(category,3);choose(category,6)
        try wait("latest request wins"){section.titleOfSelectedItem=="登録年別の有効な利用者"&&table.numberOfRows>0}
        try check(category.indexOfSelectedItem==6,"stale report suppressed")
        try button(w,"再集計").performClick(nil);try button(w,"集計を中止").performClick(nil)
        RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        try check(message.stringValue=="集計を中止しました。"&&table.numberOfRows==0,"cancellation clears result")
        choose(preset,4);try wait("all time"){table.numberOfRows>0}
        try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("更新")],actor:identity.id)
        NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:w)
        try check(table.numberOfRows==0&&message.stringValue.contains("再集計"),"database update invalidates displayed values")
        choose(category,1);try wait("sales again"){table.numberOfRows>0}
        let from=try control(w,"集計の開始日",NSDatePicker.self),to=try control(w,"集計の終了日",NSDatePicker.self)
        from.dateValue=to.dateValue.addingTimeInterval(86400*3);_ = from.sendAction(from.action,to:from.target)
        try check(message.stringValue.contains("開始日")&&table.numberOfRows==0,"invalid date clears old results")
        try button(w,"閉じる").performClick(nil)
        try wait("sheet closes"){parent.attachedSheet==nil}
        let ordinary=CRMService(db:db,identity:.init(id:user["id"].string,role:"user",partnerAccountID:nil)),other=try NativeReportsWindow(service:ordinary)
        parent.beginSheet(other.window);other.start()
        let ordinaryCategory=try control(other.window,"レポートの種類",NSPopUpButton.self),ordinaryMessage=try control(other.window,"レポートの状態",NSTextField.self)
        try wait("ordinary overview"){ordinaryMessage.stringValue.contains("前期間")}
        try check(ordinaryCategory.numberOfItems==6,"directory category hidden")
        try check(views(other.window.contentView!).compactMap{$0 as? NSButton}.filter{$0.title=="詳細を見る"}.count==9,"directory metric hidden")
        let fresh=try db.get("Users",key:["id":user["id"]])!;try db.update(fresh,changes:["banned":.integer(1)],actor:identity.id)
        NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:other.window)
        try check(ordinaryMessage.stringValue.contains("操作できません"),"revocation clears overview")
        try button(other.window,"閉じる").performClick(nil)
        try check(NativeReportPresentation.label("Unknown",section:"bySize")=="不明"&&NativeReportPresentation.label("User",section:"usersByRole")=="利用者","Japanese labels")
        print("{\"suite\":\"NativeReports AppKit\",\"checks\":\(checks)}")
    }
}
