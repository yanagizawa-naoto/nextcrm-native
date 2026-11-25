import AppKit

@main enum NativeAdminAuditUITests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
    static func views(_ root:NSView)->[NSView]{[root]+root.subviews.flatMap(views)}
    static func button(_ title:String,_ window:NSWindow)throws->NSButton{guard let b=views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else{throw NativeDBError.message("button "+title)};return b}
    static func field(_ label:String,_ window:NSWindow)throws->NSTextField{guard let f=views(window.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel()==label}) else{throw NativeDBError.message("field "+label)};return f}
    static func popup(_ label:String,_ window:NSWindow)throws->NSPopUpButton{guard let f=views(window.contentView!).compactMap({$0 as? NSPopUpButton}).first(where:{$0.accessibilityLabel()==label}) else{throw NativeDBError.message("popup "+label)};return f}
    static func table(_ window:NSWindow)->NSTableView{views(window.contentView!).compactMap{$0 as? NSTableView}.first!}
    static func text(_ window:NSWindow)->String{views(window.contentView!).compactMap{$0 as? NSTextView}.first!.string}
    static func click(_ title:String,_ window:NSWindow)throws{let b=try button(title,window);try check(b.isEnabled,title+" enabled");b.sendAction(b.action,to:b.target)}
    static func wait(_ label:String,_ condition:()throws->Bool)throws{let end=Date().addingTimeInterval(10);while Date()<end{if try condition(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.01))};throw NativeDBError.message("UI timeout "+label)}
    static func ready(_ window:NSWindow)throws{try wait("ready"){try button("再読み込み",window).isEnabled}}
    static func detailReady(_ window:NSWindow)throws{try wait("detail ready"){try button("閉じる",window).isEnabled}}
    static func select(_ window:NSWindow,_ row:Int=0)throws{try check(table(window).numberOfRows>row,"row available");table(window).selectRowIndexes(.init(integer:row),byExtendingSelection:false)}
    static func choose(_ label:String,_ index:Int,_ window:NSWindow)throws{let p=try popup(label,window);p.selectItem(at:index);p.sendAction(p.action,to:p.target);try ready(window)}
    static func child(_ window:NSWindow)throws->NSWindow{try wait("child"){window.attachedSheet != nil};return window.attachedSheet!}
    static func closeChild(_ window:NSWindow,_ child:NSWindow)throws{try click("閉じる",child);try wait("child closed"){window.attachedSheet == nil};try ready(window)}
    static func snapshot(_ window:NSWindow,_ url:URL)throws{
        window.appearance=NSAppearance(named:.aqua);let view=window.contentView!;view.layoutSubtreeIfNeeded();window.displayIfNeeded()
        for control in views(view).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor}){let frame=control.convert(control is NSTableView ? control.visibleRect:control.bounds,to:view);try check(frame.width>0 && frame.height>0 && frame.minX>=(-1) && frame.maxX<=view.bounds.width+1 && frame.minY>=(-1) && frame.maxY<=view.bounds.height+1,"bounds \(type(of:control)) \(frame)")}
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw NativeDBError.message("bitmap")};window.effectiveAppearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
        guard let ctx=CGContext(data:nil,width:bitmap.pixelsWide,height:bitmap.pixelsHigh,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let image=bitmap.cgImage else{throw NativeDBError.message("snapshot")};ctx.setFillColor(CGColor(gray:0.94,alpha:1));ctx.fill(CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh));ctx.draw(image,in:CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh));guard let result=ctx.makeImage(),let data=NSBitmapImageRep(cgImage:result).representation(using:.png,properties:[:]) else{throw NativeDBError.message("png")};try data.write(to:url)
    }
    static func main(){do{try run();print("{\"checks\":\(checks),\"exit\":0}")}catch{fputs("After \(checks) checks: \(error.localizedDescription)\n",stderr);exit(1)}}
    static func run()throws{
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let n=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AuditUI-"+UUID().uuidString);defer{NSApp.windows.forEach{$0.orderOut(nil)};try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"))
        var admin=try db.insert("Users",values:["name":.text("履歴管理者"),"email":.text("audit-admin@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"fixture")
        let colleague=try db.insert("Users",values:["name":.text("営業担当者"),"email":.text("audit-user@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"fixture")
        let service=CRMService(db:db,identity:.init(id:admin["id"].string,role:"admin",partnerAccountID:nil));var account=try db.insert("crm_Accounts",values:["v":.integer(1),"name":.text("履歴の取引先")],actor:admin["id"].string)
        let f=ISO8601DateFormatter();f.formatOptions.insert(.withFractionalSeconds);let base=f.date(from:"2026-11-20T17:00:00.000Z")!
        for i in 0..<110{account=try db.update(account,changes:["description":.text("変更\(i)")],actor:admin["id"].string);_ = try db.insert("crm_AuditLog",values:["entityType":.text("account"),"entityId":account["id"],"action":.text("updated"),"userId":i%2==0 ? admin["id"]:colleague["id"],"createdAt":.text(f.string(from:base.addingTimeInterval(Double(i)))),"changes":.text("[{\"field\":\"description\",\"old\":\"旧\",\"new\":\"新\"}]")],actor:admin["id"].string)}
        var allowRestore=false,confirmations=0,restores=0
        let controller=try NativeAdminAuditWindow(service:service,confirmRestore:{_ in confirmations+=1;return allowRestore});controller.onChanged={restores+=1};let window=controller.window;controller.start();try ready(window)
        try check(try popup("履歴の保存元",window).indexOfSelectedItem==0 && table(window).numberOfRows==50,"Mac mutation journal is initial bounded page")
        try snapshot(window,n.appendingPathComponent("build/admin-audit-main.png"))
        try click("次の50件",window);try ready(window);try check(table(window).numberOfRows==50,"native second page")
        try choose("履歴の保存元",1,window);try choose("履歴の種別",1,window);try choose("履歴の操作",2,window);try click("次の50件",window);try ready(window)
        try check(try popup("履歴の種別",window).indexOfSelectedItem==1 && popup("履歴の操作",window).indexOfSelectedItem==2 && table(window).numberOfRows==50,"filters preserved by paging")
        try field("履歴の開始日時",window).stringValue="2026-11-20 17:00:10";try field("履歴の終了日時",window).stringValue="2026-11-20 17:00:11";try click("日時を適用",window);try ready(window);try check(table(window).numberOfRows==2,"inclusive datetime controls")
        try field("履歴の開始日時",window).stringValue="invalid";try click("日時を適用",window);try check(try field("履歴の操作結果",window).stringValue.contains("形式"),"invalid date shown without query")
        try click("条件を解除",window);try ready(window);try click("利用者を選択…",window);var sheet=try child(window);try wait("users ready"){try button("キャンセル",sheet).isEnabled};let search=try field("履歴利用者の検索",sheet);search.stringValue="営業";search.sendAction(search.action,to:search.target);try wait("filtered users"){try table(sheet).numberOfRows==1 && button("キャンセル",sheet).isEnabled};try select(sheet);try click("選択",sheet);try wait("picker closed"){window.attachedSheet==nil};try ready(window);try check(try field("履歴の利用者条件",window).stringValue=="営業担当者" && table(window).numberOfRows==50,"user filter bound to selected actor")
        try click("次の50件",window);try ready(window);try check(table(window).numberOfRows==5,"user-filtered final page");try click("利用者条件を解除",window);try ready(window)
        account=try db.setDeleted(account,deleted:true,actor:admin["id"].string)
        let long=String(repeating:"長い変更内容です。",count:1200)+"末尾の確認",changes:[[String:Any]]=[["field":"description","old":"前の説明","new":long],["field":"name","old":"旧名称","new":"新名称"],["field":"password","old":"old-secret","new":"hidden-secret"]]
        let payload=String(decoding:try JSONSerialization.data(withJSONObject:changes),as:UTF8.self)
        _ = try db.insert("crm_AuditLog",values:["entityType":.text("account"),"entityId":account["id"],"action":.text("deleted"),"userId":admin["id"],"createdAt":.text("2026-11-20T18:00:00.000Z"),"changes":.text(payload)],actor:admin["id"].string)
        try click("再読み込み",window);try ready(window);try select(window);try click("詳細…",window);sheet=try child(window);try detailReady(sheet);try select(sheet);try detailReady(sheet);try check(text(sheet).count==4096,"detail reads only first value chunk")
        try snapshot(sheet,n.appendingPathComponent("build/admin-audit-detail.png"))
        while try button("次の4,096文字",sheet).isEnabled{try click("次の4,096文字",sheet);try detailReady(sheet)};try check(text(sheet).hasSuffix("末尾の確認"),"long detail fully reachable")
        try select(sheet,2);try detailReady(sheet);try check(text(sheet)=="非公開の値" && !text(sheet).contains("hidden-secret"),"copyable text contains no credential value")
        try click("このデータを復元…",sheet);try check(confirmations==1 && (try db.get("crm_Accounts",key:["id":account["id"]])?["deletedAt"] != .null),"restore confirmation can cancel")
        allowRestore=true;account=try db.update(account,changes:["name":.text("別の更新")],actor:admin["id"].string);try click("このデータを復元…",sheet);try detailReady(sheet);try check(try field("変更内容の操作結果",sheet).stringValue.contains("別の操作"),"stale restore fails with explanation");try closeChild(window,sheet)
        try select(window);try click("詳細…",window);sheet=try child(window);try detailReady(sheet);try click("このデータを復元…",sheet);try detailReady(sheet);try check(try db.get("crm_Accounts",key:["id":account["id"]])?["deletedAt"] == .null && restores==1 && !button("このデータを復元…",sheet).isEnabled,"fresh restore succeeds once and reloads capability")
        try select(sheet);try detailReady(sheet);admin=try db.update(admin,changes:["banned":.integer(1)],actor:"fixture");let side=try popup("変更内容の前後",sheet);side.selectItem(at:0);side.sendAction(side.action,to:side.target);try detailReady(sheet);try check(text(sheet).isEmpty && (try field("変更内容の操作結果",sheet).stringValue.contains("この利用者")),"authority loss clears detail before presentation")
        try closeChild(window,sheet);try check(table(window).numberOfRows==0 && !(try button("利用者を選択…",window).isEnabled),"revoked global directory cleared");try check(controller.confirmDiscard(),"retained child released")
    }
}
