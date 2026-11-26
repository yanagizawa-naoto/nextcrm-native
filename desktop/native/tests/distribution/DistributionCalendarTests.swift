@testable import NextCRMDistribution
import AppKit

@main enum DistributionCalendarTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws { guard try value() else{throw NativeDBError.message("DistributionCalendar: "+label)}; checks += 1 }
    static func rejects(_ label:String,_ body:()throws->Void)throws { do{try body()}catch{checks += 1;return};throw NativeDBError.message("Expected rejection: "+label) }
    final class Store:GoogleCalendarSecretStore {
        var values:[String:Data]=[:], loads=0
        func load(id:String,interactive:Bool)throws->Data?{loads += 1;return values[id]}
        func save(id:String,data:Data)throws{guard values[id]==nil else{throw NativeDBError.conflict};values[id]=data}
        func remove(id:String)throws{values.removeValue(forKey:id)}
    }
    final class Configuration {
        var client:NativeDistributionConfiguration.GoogleClient?
        init(_ id:String?)throws{client=try id.map{try .init(clientID:$0)}}
        func load()throws->NativeDistributionConfiguration.GoogleClient?{client}
    }
    final class Fixture {
        let db:NativeDatabase, service:CRMService, store=Store()
        init(_ resources:URL,_ root:URL)throws {
            db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
        }
    }
    static let firstID="1234567890-first.apps.googleusercontent.com", secondID="1234567890-second.apps.googleusercontent.com"
    static func grant(_ email:String="calendar@example.invalid")->GoogleCalendarGrant {.init(accountEmail:email,accessToken:"synthetic-access",refreshToken:"synthetic-refresh",expiresAt:Date(timeIntervalSince1970:1_900_000_000),grantedScopes:GoogleCalendarScope.read)}
    static func wait(_ label:String,_ ready:()throws->Bool)throws {
        let limit=Date().addingTimeInterval(10)
        while Date()<limit {if try ready(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        throw NativeDBError.message("Timed out: "+label)
    }
    static func views(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(views)}
    static func button(_ title:String,_ panel:NSWindow)throws->NSButton{guard let b=views(panel.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title && !$0.isHiddenOrHasHiddenAncestor})else{throw NativeDBError.message("Missing button: "+title)};return b}
    static func ready(_ panel:NSWindow)throws{try wait("panel load"){try button("再読み込み",panel).isEnabled}}
    static func click(_ title:String,_ panel:NSWindow)throws{let b=try button(title,panel);try check(b.isEnabled,"enabled action "+title);_ = b.sendAction(b.action,to:b.target)}
    static func texts(_ panel:NSWindow)->[NSTextField]{views(panel.contentView!).compactMap{$0 as? NSTextField}}
    static func fit(_ panel:NSWindow)throws{
        panel.contentView!.layoutSubtreeIfNeeded()
        for view in views(panel.contentView!).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor && !($0 is NSTableView)}) {
            let box=view.convert(view.bounds,to:panel.contentView), area=panel.contentView!.bounds
            try check(box.minX>=(-1) && box.minY>=(-1) && box.maxX<=area.width+1 && box.maxY<=area.height+1,"visible control inside panel")
        }
    }
    static func serviceTests(_ resources:URL,_ root:URL)throws {
        let f=try Fixture(resources,root.appendingPathComponent("services")), s=f.service, c=try Configuration(nil)
        try rejects("missing public app identity"){_ = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:f.store,distributionClient:c.load)}
        try check(try s.googleCalendarClientReference()==nil && f.store.values.isEmpty,"opening / missing configuration writes no shared settings or Keychain")
        c.client=try .init(clientID:firstID)
        let changing=try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:f.store,distributionClient:c.load)
        try check(changing.client.clientID==firstID && changing.client.clientSecret.isEmpty && changing.reference==nil,"public client ticket without secret")
        c.client=try .init(clientID:secondID)
        try rejects("bundle identity changes while browser open"){_ = try s.completeGoogleCalendarAuthorization(changing,grant:grant(),store:f.store)}
        try check(try s.googleCalendarConnections().total==0 && f.store.values.isEmpty,"changed config publishes no grant")
        try s.cancelGoogleCalendarAuthorization(changing)
        c.client=try .init(clientID:firstID)
        let ticket=try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:f.store,distributionClient:c.load)
        let row=try s.completeGoogleCalendarAuthorization(ticket,grant:grant(),store:f.store)
        try check(row["scopeLevel"] == .text("readonly"),"actual granted scope preserved")
        try check(try s.googleCalendarClientReference()==nil && f.store.values.count==1,"only grant stored; no admin-global client setup")
        c.client=try .init(clientID:secondID)
        let stored=try s.googleCalendarGrant(row,store:f.store)
        try check(stored.client.clientID==firstID,"app update does not replace prior grant client")
        var refreshed:Result<GoogleCalendarStoredGrant,Error>?, capturedClient=false
        Task { @MainActor in
            do {
                let value=try await GoogleCalendarOAuth.refresh(stored,request:{request in
                    let body=String(decoding:request.httpBody ?? Data(),as:UTF8.self)
                    capturedClient=body.contains("client_id="+firstID) && !body.contains("client_secret") && !body.contains(secondID)
                    return (try JSONSerialization.data(withJSONObject:["access_token":"synthetic-refreshed","expires_in":3600,"token_type":"Bearer"]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
                });refreshed = .success(value)
            }catch{refreshed = .failure(error)}
        }
        try wait("fake token refresh"){refreshed != nil}
        try check(try refreshed!.get().client==stored.client && capturedClient,"actual refresh uses original client and no embedded secret")
        let cancelled=try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:f.store,distributionClient:c.load)
        try s.cancelGoogleCalendarAuthorization(cancelled)
        try rejects("cancelled bundled login"){_ = try s.completeGoogleCalendarAuthorization(cancelled,grant:grant("cancel@example.invalid"),store:f.store)}
        try s.saveGoogleCalendarClient(clientID:"manual.apps.googleusercontent.com",clientSecret:"synthetic-manual-secret",store:f.store)
        let manual=try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:f.store,distributionClient:{throw NativeDistributionConfiguration.Failure.invalid})
        try check(manual.client.clientID=="manual.apps.googleusercontent.com" && manual.client.clientSecret=="synthetic-manual-secret" && manual.reference != nil,"manual override remains usable even if bundle unavailable")
        try s.cancelGoogleCalendarAuthorization(manual)
        try check(try s.googleCalendarGrant(row,store:f.store).client.clientID==firstID,"changing manual setup leaves existing grant untouched")
        let pending=try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:f.store,distributionClient:c.load)
        try s.saveGoogleCalendarClient(clientID:"manual.apps.googleusercontent.com",clientSecret:"",store:f.store)
        try rejects("manual setting CAS unchanged"){_ = try s.completeGoogleCalendarAuthorization(pending,grant:grant(),store:f.store)}
        for path in [f.db.url,URL(fileURLWithPath:f.db.url.path+"-wal")] where FileManager.default.fileExists(atPath:path.path) {
            let data=try Data(contentsOf:path)
            for secret in ["synthetic-access","synthetic-refresh","synthetic-manual-secret"] {try check(data.range(of:Data(secret.utf8))==nil,"secrets absent from SQLite and WAL")}
        }
        let g=try Fixture(resources,root.appendingPathComponent("ordinary"))
        let actor=try g.db.insert("Users",values:["email":.text("ordinary@example.invalid"),"name":.text("利用者"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:g.service.identity.id)
        let ordinary=CRMService(db:g.db,identity:.init(id:actor["id"].string,role:"user",partnerAccountID:nil))
        let own=try ordinary.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:g.store,distributionClient:c.load)
        let ownRow=try ordinary.completeGoogleCalendarAuthorization(own,grant:grant(),store:g.store)
        try check(ownRow["userId"]==actor["id"],"recipient connects without admin configuration")
        try rejects("ordinary cannot override global manual settings"){try ordinary.saveGoogleCalendarClient(clientID:"manual.apps.googleusercontent.com",clientSecret:"",store:g.store)}
        let revoked=try ordinary.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:g.store,distributionClient:c.load)
        _ = try g.db.update(try g.db.get("Users",key:["id":actor["id"]])!,changes:["banned":.integer(1)],actor:g.service.identity.id)
        try rejects("fresh actor authority before grant publication"){_ = try ordinary.completeGoogleCalendarAuthorization(revoked,grant:grant(),store:g.store)}
    }
    static func uiTests(_ resources:URL,_ root:URL)throws {
        let f=try Fixture(resources,root.appendingPathComponent("ui")), c=try Configuration(firstID)
        var calls=0,connected=0
        let panel=try GoogleCalendarSettingsWindow(service:f.service,store:f.store,authorize:{client,scope,_ in
            calls += 1;try check(client.clientID==firstID && scope == .readonly,"normal login uses bundled identity/read scope");return grant()
        },allowsProcessing:false,distributionClient:c.load)
        panel.onConnected={connected += 1};try ready(panel.window)
        try check(texts(panel.window).filter{!$0.isHiddenOrHasHiddenAncestor}.allSatisfy{!($0.accessibilityLabel() ?? "").contains("クライアント")},"developer fields hidden in normal recipient flow")
        try check(f.store.loads==0 && f.store.values.isEmpty,"opening configured screen reads no Keychain")
        try fit(panel.window)
        try click("Google にログイン…",panel.window);try ready(panel.window)
        try check(calls==1 && connected==1 && (try f.service.googleCalendarConnections().total)==1,"actual UI -> service -> stored connection")
        try check(!(try button("選択した接続を同期",panel.window)).isEnabled,"settings-only login does not bypass processing hold")
        try check(texts(panel.window).allSatisfy{!$0.stringValue.contains("synthetic-")},"tokens not rendered")
        try click("詳細設定（開発者向け）…",panel.window)
        try check(texts(panel.window).contains{!$0.isHiddenOrHasHiddenAncestor && $0.accessibilityLabel()=="GoogleクライアントID"},"manual developer controls remain reachable")
        try fit(panel.window)
        try click("詳細設定を閉じる",panel.window)
        let missing=try Fixture(resources,root.appendingPathComponent("missing"));var missingCalls=0
        let unavailable=try GoogleCalendarSettingsWindow(service:missing.service,store:missing.store,authorize:{_,_,_ in missingCalls += 1;return grant()},distributionClient:{nil})
        try ready(unavailable.window)
        try check(!(try button("Google にログイン…",unavailable.window)).isEnabled,"unconfigured build never appears ready")
        _ = unavailable.perform(NSSelectorFromString("connectRead"))
        try check(missingCalls==0 && (try missing.service.googleCalendarConnections().total)==0,"direct selector also rejects missing client")
        let invalid=try GoogleCalendarSettingsWindow(service:missing.service,store:missing.store,authorize:{_,_,_ in throw NativeDBError.conflict},distributionClient:{throw NativeDistributionConfiguration.Failure.invalid})
        try ready(invalid.window)
        try check(!(try button("Google にログイン…",invalid.window)).isEnabled && texts(invalid.window).contains{$0.stringValue.contains("不正")},"invalid bundled metadata produces actionable error")
    }
    static func main() {
        do {
            try check(Thread.isMainThread,"AppKit main thread");_ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
            let resources=URL(fileURLWithPath:CommandLine.arguments[1]), root=URL(fileURLWithPath:CommandLine.arguments[2])
            defer{NSApp.windows.forEach{$0.orderOut(nil)}}
            try serviceTests(resources,root);try uiTests(resources,root)
            print("DistributionCalendarTests: \(checks) checks passed")
        }catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}
    }
}
