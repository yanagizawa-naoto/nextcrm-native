import AppKit
#if GOOGLE_MAIL_UI_MODULE
@testable import DistributionLoginCore
#endif

@main enum GoogleMailAccountsUITests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ name:String)throws{guard try value() else{throw NSError(domain:"GoogleMailUI: "+name,code:1)};checks+=1}
    static func all(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(all)}
    static func button(_ title:String,_ w:NSWindow)throws->NSButton{guard let b=all(w.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else{throw NSError(domain:"Missing "+title,code:1)};return b}
    static func click(_ title:String,_ w:NSWindow)throws{let b=try button(title,w);try check(b.isEnabled,title+" enabled");_ = b.sendAction(b.action,to:b.target)}
    static func wait(_ name:String,_ condition:()throws->Bool)throws{let deadline=Date().addingTimeInterval(10);while Date()<deadline{if try condition(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.005))};throw NSError(domain:"Timeout "+name,code:1)}
    static func text(_ w:NSWindow)->String{all(w.contentView!).compactMap{$0 as? NSTextField}.map(\.stringValue).joined(separator:"\n")}
    final class Store:NativeMailSecretStore {
        var values:[String:Data]=[:]
        func load(id:String,interactive:Bool)throws->Data?{values[id]}
        func save(id:String,data:Data)throws{values[id]=data}
        func remove(id:String)throws{values.removeValue(forKey:id)}
    }
    final class Auth {
        var calls=0,held=false,continuation:CheckedContinuation<Void,Never>?
        var grant=GoogleMailGrant(email:"owner@example.test",accessToken:"ui-fake-access",refreshToken:"ui-fake-refresh",expiresAt:Date().addingTimeInterval(3600),scopes:GoogleMailOAuth.scope)
        func run(_ client:GoogleCalendarClientSettings,_ hint:String?)async throws->GoogleMailGrant {
            calls+=1;if held{await withCheckedContinuation{continuation=$0}}
            return grant
        }
    }
    static func run()throws{
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let n=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("NextCRM-GoogleMailUI-"+UUID().uuidString)
        defer{NSApp.windows.forEach{$0.orderOut(nil)};try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"))
        let service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:n.appendingPathComponent("../../prisma"))),store=Store(),auth=Auth()
        let client=GoogleCalendarClientSettings(clientID:"123456-fixture.apps.googleusercontent.com",clientSecret:"")
        var wake=0,currentClient:GoogleCalendarClientSettings?=client
        let ui=try NativeMailAccountsWindow(service:service,store:store,probe:{_,_,_ in throw GoogleMailFailure.invalid},allowsProcessing:false,googleClient:{currentClient},authorize:auth.run)
        ui.onChanged={wake+=1}
        try wait("list"){try button("再読み込み",ui.window).isEnabled}
        ui.window.contentView!.layoutSubtreeIfNeeded()
        for b in all(ui.window.contentView!).compactMap({$0 as? NSButton}).filter({!$0.isHiddenOrHasHiddenAncestor}) {
            let r=b.convert(b.bounds,to:ui.window.contentView),bounds=ui.window.contentView!.bounds
            try check(r.width>0 && r.minX>=0 && r.maxX<=bounds.width+1 && r.minY>=0 && r.maxY<=bounds.height+1,"button fits: "+b.title)
        }
        try click("Googleでログイン…",ui.window)
        try wait("saved"){try service.mailAccounts().total==1 && button("再読み込み",ui.window).isEnabled}
        let row=try service.mailAccounts().rows[0],full=try service.mailAccount(row["id"].string)
        try check(auth.calls==1 && store.values.count==1 && full["imapHost"].string=="imap.gmail.com","real controls publish OAuth account without server/password fields")
        try check(try service.mailSyncJob(full["id"].string)==nil && wake==0 && text(ui.window).contains("確認待ち"),"settings-only never enqueues or wakes worker")
        let table=all(ui.window.contentView!).compactMap{$0 as? NSTableView}.first!
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);ui.tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification,object:table))
        let generation=try service.mailCredentialApprovalBinding(full)
        try click("Googleを接続し直す…",ui.window)
        try wait("reconnect"){try service.mailAccount(full["id"].string).revision>full.revision && button("再読み込み",ui.window).isEnabled}
        try check(try service.mailCredentialApprovalBinding(service.mailAccount(full["id"].string)) != generation,"reconnect rotates approval binding")
        try check(store.values.count==1,"reconnect cleans obsolete immutable secret; retained count=\(store.values.count)")
        auth.held=true
        try click("Googleでログイン…",ui.window)
        try wait("pending"){auth.continuation != nil}
        try check(!ui.confirmDiscard() && !(try button("再読み込み",ui.window)).isEnabled,"pending authorization owns window and vetoes close")
        try click("Googleログインを中止",ui.window)
        try check(!ui.confirmDiscard() && text(ui.window).contains("中止しています"),"cancel request does not pretend completion")
        auth.continuation?.resume();auth.continuation=nil
        try wait("cancel joined"){try button("再読み込み",ui.window).isEnabled}
        try check(try ui.confirmDiscard() && service.mailAccounts().total==1 && store.values.count==1 && text(ui.window).contains("中止しました"),"late ignored-cancel response cannot publish")
        auth.grant=GoogleMailGrant(email:"other@example.test",accessToken:"ui-fake-other-access",refreshToken:"ui-fake-other-refresh",expiresAt:Date().addingTimeInterval(3600),scopes:GoogleMailOAuth.scope)
        try click("Googleでログイン…",ui.window);try wait("resolver pending"){auth.continuation != nil}
        currentClient=nil;auth.continuation?.resume();auth.continuation=nil
        try wait("resolver checked"){try button("再読み込み",ui.window).isEnabled}
        try check(try service.mailAccounts().total==1 && store.values.count==1 && text(ui.window).contains("設定が変更"),"resolver removed while browser pending cannot publish")
        currentClient=client
        let absent=try NativeMailAccountsWindow(service:service,store:store,allowsProcessing:false,googleClient:{nil},authorize:{_,_ in throw NSError(domain:"must not invoke",code:1)})
        try wait("absent list"){try button("再読み込み",absent.window).isEnabled};try click("Googleでログイン…",absent.window)
        try check(text(absent.window).contains("配布元") && !text(absent.window).contains("クライアントID"),"missing distributor config never asks recipient for client ID")
        print("GoogleMailAccountsUITests: \(checks) checks passed; offscreen AppKit, fake auth/store, no external I/O")
    }
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}}
}
