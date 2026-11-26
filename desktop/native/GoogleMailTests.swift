import Foundation

@main enum GoogleMailTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ name:String)throws{guard try value() else{throw NativeDBError.message("GoogleMailTests: "+name)};checks+=1}
    static func rejects(_ name:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("Accepted: "+name)}
    static func rejectsAsync(_ name:String,_ body:()async throws->Void)async throws{do{try await body()}catch{checks+=1;return};throw NativeDBError.message("Accepted: "+name)}
    final class Store:NativeMailSecretStore {
        var values:[String:Data]=[:],fail=false,saveHook:(()throws->Void)?
        func load(id:String,interactive:Bool)throws->Data?{values[id]}
        func save(id:String,data:Data)throws{if fail{throw NativeDBError.message("synthetic keychain unavailable")};values[id]=data;try saveHook?()}
        func remove(id:String)throws{values.removeValue(forKey:id)}
    }
    static let client=GoogleCalendarClientSettings(clientID:"123456-test.apps.googleusercontent.com",clientSecret:"")
    static let now=Date(timeIntervalSince1970:1_900_000_000)
    static func grant(_ email:String="owner@example.test",expired:Bool=false)->GoogleMailGrant {
        .init(email:email,accessToken:"synthetic-google-access",refreshToken:"synthetic-google-refresh",expiresAt:now.addingTimeInterval(expired ? -60:3600),scopes:GoogleMailOAuth.scope)
    }
    static func response(_ request:URLRequest,_ value:[String:Any],status:Int=200)throws->(Data,HTTPURLResponse){(try JSONSerialization.data(withJSONObject:value),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)}
    static func run(_ resources:URL)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-GoogleMail-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))),store=Store()
        let ticket=try service.beginGoogleMailAuthorization(client:client,now:now)
        let account=try service.completeGoogleMailAuthorization(ticket,grant:grant(),store:store,now:now)
        try check(try service.mailAccounts().total==1 && store.values.count==1,"account and one immutable secret")
        let binding=try service.mailCredentialApprovalBinding(account)
        let credential=try service.mailCredential(account,store:store)
        try check(credential.version==2 && credential.password.isEmpty && credential.oauthBearer==grant().accessToken,"bearer is not a password")
        try check(try service.mailSettings(account).smtp==GoogleMailStoredGrant.settings(email:grant().email).smtp,"fixed SSL SMTP")
        try rejects("ticket replay"){_ = try service.completeGoogleMailAuthorization(ticket,grant:grant(),store:store,now:now)}
        try rejects("duplicate address"){_ = try service.completeGoogleMailAuthorization(service.beginGoogleMailAuthorization(client:client,now:now),grant:grant(),store:store,now:now)}
        try rejects("wrong reconnect account"){_ = try service.completeGoogleMailAuthorization(service.beginGoogleMailAuthorization(client:client,expected:account,now:now),grant:grant("different@example.test"),store:store,now:now)}
        var unsafe=try service.mailSettings(account);unsafe.smtp = .init(host:"evil.example.test",port:465,tls:.implicitTLS)
        try rejects("redirect bearer via settings"){_ = try service.updateMailAccount(account,settings:unsafe,password:nil,store:store)}
        try rejects("password downgrade"){_ = try service.replaceMailPassword(account,password:"synthetic",store:store)}
        try check(try service.mailAccount(account["id"].string).revision==account.revision,"rejections preserve row")
        var freshCalls=0
        let same=try await service.readyMailCredential(account,store:store,request:{_ in freshCalls+=1;throw GoogleMailFailure.invalid},now:now)
        try check(same.account.revision==account.revision && freshCalls==0,"valid token requires no network")
        let forced=try service.noteGoogleMailAuthenticationFailure(account,error:NativeMailFailure.transport(code:67,uploaded:false))
        try check(forced,"pre-upload auth failure requests refresh")
        let updated=try await service.readyMailCredential(account,store:store,request:{r in
            freshCalls+=1;let form=String(decoding:r.httpBody!,as:UTF8.self)
            try check(r.url?.query==nil && form.contains("grant_type=refresh_token") && !form.contains("client_secret"),"public client refresh POST only")
            return try response(r,["access_token":"synthetic-refreshed-access","expires_in":3600,"token_type":"Bearer"])
        },now:now)
        try check(freshCalls==1 && updated.account.revision>account.revision && updated.credential.google?.grant.refreshToken==grant().refreshToken,"refresh keeps omitted refresh token/scope")
        try check(store.values.count==1 && updated.credential.oauthBearer=="synthetic-refreshed-access","fresh reference published and obsolete released")
        try rejects("old snapshot"){_ = try service.mailCredential(account,store:store)}
        try check(try service.mailCredentialApprovalBinding(updated.account)==binding,"token rotation preserves approval binding")
        let projected=try service.mailAccounts().rows.first{$0["id"]==updated.account["id"]}!
        try check(projected["passwordEncrypted"] == .null,"account list deliberately omits secret reference")
        let reconnectTicket=try service.beginGoogleMailAuthorization(client:client,expected:projected,now:now)
        try check(reconnectTicket.expected?["passwordEncrypted"]==updated.account["passwordEncrypted"],"authorization ticket revalidates and retains full account reference")
        let reconnected=try service.completeGoogleMailAuthorization(reconnectTicket,grant:grant(),store:store,now:now)
        try check(store.values.count==1,"projected UI reconnect releases obsolete immutable credential")
        try check(try service.mailCredentialApprovalBinding(reconnected) != binding,"manual reconnect invalidates approval binding")
        let current=reconnected
        try rejects("outer TX publication"){try db.transaction{_ = try service.completeGoogleMailAuthorization(service.beginGoogleMailAuthorization(client:client,expected:current,now:now),grant:grant(),store:store,now:now)}}
        let stale=try service.beginGoogleMailAuthorization(client:client,expected:current,now:now)
        let changed=try service.setMailAccountActive(current,active:false)
        try rejects("concurrent edit"){_ = try service.completeGoogleMailAuthorization(stale,grant:grant(),store:store,now:now)}
        store.fail=true
        let failure=try service.beginGoogleMailAuthorization(client:client,expected:changed,now:now)
        try rejects("Keychain failure"){_ = try service.completeGoogleMailAuthorization(failure,grant:grant(),store:store,now:now)}
        store.fail=false
        try check(try service.mailAccount(changed["id"].string).revision==changed.revision && store.values.count==1,"failed save retains current secret")
        let cancel=try service.beginGoogleMailAuthorization(client:client,expected:changed,now:now)
        store.saveHook={let user=try db.get("Users",key:["id":.text(service.identity.id)])!;_ = try db.update(user,changes:["userStatus":.text("INACTIVE")],actor:service.identity.id)}
        try rejects("authority revoked during secret save"){_ = try service.completeGoogleMailAuthorization(cancel,grant:grant(),store:store,now:now)}
        store.saveHook=nil
        let user=try db.get("Users",key:["id":.text(service.identity.id)])!;_ = try db.update(user,changes:["userStatus":.text("ACTIVE")],actor:service.identity.id)
        _ = try service.cleanupFailedMailCredentials(store:store)
        try check(try service.mailAccount(changed["id"].string).revision==changed.revision && store.values.count==1,"revoked publication rolls back and cleanup is recoverable")
        for path in [db.url,URL(fileURLWithPath:db.url.path+"-wal")] where FileManager.default.fileExists(atPath:path.path) {
            let data=try Data(contentsOf:path)
            for secret in [grant().accessToken,grant().refreshToken,"synthetic-refreshed-access"]{try check(data.range(of:Data(secret.utf8))==nil,"no OAuth plaintext in DB/WAL")}
        }
        try await oauth()
        try await workers(resources)
        checks += try await NativeMailSyncTests.run(resources:resources)
        checks += try await NativeMailContentTests.run(resources:resources)
        checks += try await NativeMailSendTests.run(resources:resources)
        checks += try await NativeMailRuntimeTests.run(resources:resources)
    }
    actor Gate {
        var entered=false
        var continuation:CheckedContinuation<Void,Never>?
        func wait()async{entered=true;await withCheckedContinuation{continuation=$0}}
        func release(){continuation?.resume();continuation=nil}
    }
    static func workers(_ resources:URL)async throws {
        func setup()throws->MailSyncFixture {
            let f=try MailSyncFixture(resources:resources)
            var value=GoogleMailGrant(email:"owner@example.test",accessToken:"synthetic-access-before",refreshToken:"synthetic-refresh-before",expiresAt:f.now.addingTimeInterval(30),scopes:GoogleMailOAuth.scope)
            value.sentFolder="送信済み"
            _ = try f.service.completeGoogleMailAuthorization(f.service.beginGoogleMailAuthorization(client:client,expected:f.account(),now:f.now),grant:value,store:f.secrets,now:f.now)
            return f
        }
        do {
            let f=try setup(),id=try f.start();var factories=0,refreshes=0
            let worker=NativeMailSyncWorker(db:f.db,store:f.secrets,makeClient:{settings,credential in
                factories+=1;try check(settings.imap.host=="imap.gmail.com" && credential.password.isEmpty && credential.oauthBearer=="synthetic-after-refresh","sync receives XOAUTH2 snapshot");return f.receiver
            },clock:{f.now},oauthRequest:{r in refreshes+=1;return try response(r,["access_token":"synthetic-after-refresh","expires_in":3600,"token_type":"Bearer"])})
            _ = try await worker.runNext()
            try check(try refreshes==1 && factories==1 && f.db.job(id:id)?.status=="done" && f.rows()==122,"refresh own revision does not break sync heartbeat/publication")
        }
        do {
            let f=try setup(),id=try f.start(),before=try f.account();var stolen:NativeJob?,factories=0
            let worker=NativeMailSyncWorker(db:f.db,store:f.secrets,makeClient:{_,_ in factories+=1;return f.receiver},clock:{f.now},oauthRequest:{r in
                stolen=try f.second.claimJob(events:[NativeMailJobs.sync],now:f.now.addingTimeInterval(301))
                return try response(r,["access_token":"must-not-publish","expires_in":3600,"token_type":"Bearer"])
            })
            _ = try await worker.runNext()
            try check(try factories==0 && f.account().revision==before.revision && f.secrets.values.count==1 && f.db.job(id:id)?.leaseToken==stolen?.leaseToken,"stolen refresh lease preserves row/secret/successor and sends no IMAP")
        }
        do {
            let f=try setup(),id=try f.start(),before=try f.account(),gate=Gate();var factories=0
            let worker=NativeMailSyncWorker(db:f.db,store:f.secrets,makeClient:{_,_ in factories+=1;return f.receiver},clock:{f.now},oauthRequest:{r in
                await gate.wait();return try response(r,["access_token":"cancelled-token","expires_in":3600,"token_type":"Bearer"])
            })
            let task=Task{try await worker.runNext()}
            while !(await gate.entered){try await Task.sleep(nanoseconds:1_000_000)}
            task.cancel();try await Task.sleep(nanoseconds:20_000_000)
            try check(try f.db.job(id:id)?.status=="running" && factories==0,"cancel waits for accepted refresh transport")
            await gate.release();_ = try await task.value
            try check(try f.account().revision==before.revision && f.secrets.values.count==1 && f.db.job(id:id)?.status=="retry","cancelled refresh joins and never publishes token")
        }
        do {
            let f=try setup(),id=try f.start()
            let worker=NativeMailSyncWorker(db:f.db,store:f.secrets,makeClient:{_,_ in throw NativeDBError.conflict},clock:{f.now},oauthRequest:{r in try response(r,["error":"invalid_grant","message":"secret-do-not-log"],status:400)})
            _ = try await worker.runNext()
            try check(try f.db.job(id:id)?.status=="failed" && f.db.job(id:id)?.lastError?.contains("接続し直す")==true && f.db.job(id:id)?.lastError?.contains("secret-do-not-log")==false,"revoked grant ends with safe reconnect instruction")
        }
        do {
            let f=try setup(),account=try f.account(),draft=NativeMailDraft(to:["customer@example.test"],cc:[],bcc:[],subject:"Google fixture",body:"synthetic only")
            let id=try f.service.queueMailSend(account:account,draft:draft,now:f.now)
            var sent:[NativeMailWireRequest]=[],refreshes=0
            let worker=NativeMailSendWorker(db:f.db,store:f.secrets,send:{q in sent.append(q);if sent.count==1{throw NativeMailFailure.transport(code:67,uploaded:false)}},clock:{f.now},oauthRequest:{r in
                refreshes+=1;return try response(r,["access_token":"synthetic-send-\(refreshes)","expires_in":3600,"token_type":"Bearer"])
            })
            _ = try await worker.runNext()
            try check(try f.db.job(id:id)?.status=="retry" && f.db.job(id:id)?.deliveryStartedAt==nil,"auth refusal is proven pre-upload and retryable")
            f.now.addTimeInterval(10);_ = try await worker.runNext()
            try check(try sent.count==2 && sent.allSatisfy{$0.password.isEmpty && $0.oauthBearer != nil} && sent[0].upload==sent[1].upload && refreshes==2 && f.db.job(id:id)?.status=="done","SMTP uses refreshed bearer, immutable MIME and existing accepted receipt")
        }
        do {
            let f=try setup(),account=try f.account(),draft=NativeMailDraft(to:["customer@example.test"],cc:[],bcc:[],subject:"Revoked owner",body:"synthetic only")
            let id=try f.service.queueMailSend(account:account,draft:draft,now:f.now)
            let worker=NativeMailSendWorker(db:f.db,store:f.secrets,send:{_ in
                let user=try f.db.get("Users",key:["id":.text(f.service.identity.id)])!
                _ = try f.db.update(user,changes:["userStatus":.text("INACTIVE")],actor:f.service.identity.id)
                throw NativeMailFailure.transport(code:67,uploaded:false)
            },clock:{f.now},oauthRequest:{r in try response(r,["access_token":"synthetic-before-ban","expires_in":3600,"token_type":"Bearer"])})
            _ = try await worker.runNext()
            try check(try f.db.job(id:id)?.status=="failed" && f.db.job(id:id)?.deliveryStartedAt==nil,"auxiliary refresh bookkeeping cannot skip proven no-upload cleanup after owner revocation")
        }
    }
    static func oauth()async throws {
        let redirect=URL(string:"http://127.0.0.1:54321/")!,verifier=String(repeating:"v",count:43),state=String(repeating:"s",count:43)
        let url=try GoogleMailOAuth.authorizationURL(client:client,redirect:redirect,state:state,verifier:verifier,loginHint:nil)
        let query=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
        try check(query.first{$0.name=="scope"}?.value==GoogleMailOAuth.scope && query.first{$0.name=="code_challenge_method"}?.value=="S256","Gmail scope and PKCE")
        try rejects("non-loopback redirect"){_ = try GoogleMailOAuth.authorizationURL(client:client,redirect:URL(string:"http://localhost:1/")!,state:state,verifier:verifier,loginHint:nil)}
        var calls=0
        let grant=try await GoogleMailOAuth.exchange(client:client,code:"synthetic-code",verifier:verifier,redirect:redirect,request:{r in
            calls+=1
            if calls==1{return try response(r,["access_token":"synthetic-token","refresh_token":"synthetic-refresh","expires_in":3600,"token_type":"Bearer","scope":GoogleMailOAuth.scope])}
            try check(r.value(forHTTPHeaderField:"Authorization")=="Bearer synthetic-token" && r.url?.path=="/gmail/v1/users/me/profile","account email comes from Gmail profile")
            return try response(r,["emailAddress":"OWNER@example.test"])
        },now:now)
        try check(grant.email=="owner@example.test" && calls==2,"verified profile normalized")
        for payload:[String:Any] in [ ["access_token":"x","expires_in":3600,"token_type":"Bearer"], ["access_token":"x","refresh_token":"y","expires_in":true,"token_type":"Bearer"], ["access_token":"x\r\nsecret","refresh_token":"y","expires_in":3600,"token_type":"Bearer"], ["access_token":"x","refresh_token":"y","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/gmail.send"] ] {
            try await rejectsAsync("malformed/partial token"){_ = try await GoogleMailOAuth.exchange(client:client,code:"synthetic",verifier:verifier,redirect:redirect,request:{try response($0,payload)},now:now)}
        }
        do{_ = try await GoogleMailOAuth.exchange(client:client,code:"synthetic",verifier:verifier,redirect:redirect,request:{try response($0,["error":"invalid_grant","secret":"do-not-display"],status:400)},now:now);throw NativeDBError.conflict}catch let e as GoogleMailFailure{try check(e == .reconnect && !e.localizedDescription.contains("do-not-display"),"revoked token sanitized")}
        let encoded=try NativeMailUTF7.encode("[Gmail]/送信済みメール")
        try check(try GoogleMailOAuth.sentFolder(Data("* LIST (\\HasNoChildren \\Sent) \"/\" \"\(encoded)\"\r\n".utf8))=="[Gmail]/送信済みメール","localized special-use Sent folder")
        try rejects("missing sent special-use"){_ = try GoogleMailOAuth.sentFolder(Data("* LIST () \"/\" \"Sent\"\r\n".utf8))}
    }
    static func main()async{do{try await run(URL(fileURLWithPath:CommandLine.arguments[1]));print("GoogleMailTests: \(checks) checks passed")}catch{FileHandle.standardError.write(Data("GoogleMailTests: \(error)\n".utf8));exit(1)}}
}
