import Foundation
import SQLite3

final class FakeNativeMailSecrets: NativeMailSecretStore {
    var values:[String:Data] = [:]
    var removedIDs: [String] = []
    var failSave = false, failRemove = false
    var afterSave: (() throws -> Void)?
    func load(id: String,interactive: Bool) throws -> Data? { values[id] }
    func save(id: String,data: Data) throws { if failSave { throw NativeDBError.conflict }; guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data; try afterSave?() }
    func remove(id: String) throws { removedIDs.append(id); if failRemove { throw NativeDBError.conflict }; values.removeValue(forKey:id) }
}

@main enum CRMEmailTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ name: String) throws { guard try condition() else { throw NativeDBError.message("FAIL: "+name) }; checks += 1 }
    static func rejects(_ name: String,_ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+name) }
    static func main() async {
        do {
            try run(); let resources = URL(fileURLWithPath:CommandLine.arguments[1])
            try relatedLists(resources:resources)
            _ = try await NativeMailSyncTests.run(resources:resources)
            _ = try await NativeMailContentTests.run(resources:resources)
            _ = try await NativeMailSendTests.run(resources:resources)
            _ = try await NativeMailRuntimeTests.run(resources:resources)
            if CommandLine.arguments.contains("--keychain-probe") { try keychainProbe() }
        } catch { FileHandle.standardError.write(Data("CRMEmailTests after \(checks) checks: \(error)\n".utf8)); exit(1) }
    }
    /// Explicit opt-in: only this generated ID and isolated database namespace
    /// are touched. Normal tests never use the real macOS credential store.
    static func keychainProbe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MailKeychainProbe-"+UUID().uuidString)
        let first = KeychainNativeMailSecrets(databaseURL:root.appendingPathComponent("one.sqlite"))
        let other = KeychainNativeMailSecrets(databaseURL:root.appendingPathComponent("two.sqlite"))
        let id = UUID().uuidString.lowercased(), bytes = try JSONEncoder().encode(NativeMailCredential(password:"synthetic-only-"+UUID().uuidString))
        defer { try? first.remove(id:id); try? other.remove(id:id) }
        let before = checks
        try check(try first.load(id:id,interactive:false) == nil,"isolated Keychain item initially absent")
        try first.save(id:id,data:bytes)
        try check(try first.load(id:id,interactive:false) == bytes,"real Keychain saves and reads immutable secret without interaction")
        try check(try other.load(id:id,interactive:false) == nil,"database namespace isolates real Keychain lookup")
        try rejects("real Keychain cannot overwrite immutable ID") { try first.save(id:id,data:bytes) }
        try first.remove(id:id)
        try check(try first.load(id:id,interactive:false) == nil,"real Keychain probe item removed")
        print("NativeMailKeychainProbe: \(checks-before) checks passed; isolated generated item saved/read/deleted, no user credentials accessed")
    }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MailTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(), second = try open(), secrets = FakeNativeMailSecrets()
        let owner = try db.insert("Users",values:["name":.text("メール所有者"),"email":.text("owner@example.test"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"test")
        let other = try db.insert("Users",values:["name":.text("別の管理者"),"email":.text("other@example.test"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"test")
        let service = CRMService(db:db,identity:.init(id:owner["id"].string,role:"user",partnerAccountID:nil)), stranger = CRMService(db:db,identity:.init(id:other["id"].string,role:"admin",partnerAccountID:nil))
        let settings = NativeMailAccountSettings(label:"仕事のメール",username:"owner@example.test",imap:.init(host:"imap.example.test",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.test",port:587,tls:.startTLS),sentFolder:"送信済み")
        var account = try service.createMailAccount(settings,password:"synthetic-only",store:secrets), id = account["id"].string
        try check(try service.mailSettings(account)==settings,"three TLS modes and Japanese folder persist")
        try db.setMetadata("mail.tls."+id,value:"{}")
        try check(try service.mailSettings(account).smtp.tls == .automaticSMTP,"legacy SMTP false keeps Nodemailer automatic STARTTLS behavior")
        try db.setMetadata("mail.tls."+id,value:"{\"imap\":2,\"smtp\":0}")
        try check(try service.mailSettings(account).smtp.tls == .plain,"explicit native plaintext choice is preserved")
        try db.setMetadata("mail.tls."+id,value:"{\"imap\":2,\"smtp\":1}")
        try check(secrets.values.count==1 && account["passwordEncrypted"].string.hasPrefix("native-keychain:"),"only an immutable Keychain reference enters SQLite")
        try check(try service.mailCredential(account,store:secrets).password=="synthetic-only","owner loads credential")
        let summaries = try service.mailAccounts()
        try check(summaries.rows.count==1 && summaries.rows[0].values["passwordEncrypted"]==nil,"account list excludes credential reference")
        try check(try stranger.mailAccounts().total==0,"administrator cannot list another user's mailbox")
        try rejects("administrator cannot open another user's credential") { _ = try stranger.mailCredential(account,store:secrets) }
        try check(try db.page("EmailAccount",fields:[],filter:stranger.scope("EmailAccount")).total==0,"generic CRM scope also protects personal accounts")
        var bad = settings; bad.imap.port = 65536
        try rejects("reject out-of-range port before storing secret") { _ = try service.createMailAccount(bad,password:"synthetic-only",store:secrets) }
        try check(secrets.values.count==1,"invalid account leaves no secret")
        secrets.failSave = true
        try rejects("Keychain failure cannot create account") { _ = try service.createMailAccount(settings,password:"synthetic-only",store:secrets) }
        secrets.failSave = false
        try check(try service.mailAccounts().total==1,"no partial account after Keychain failure")
        let keysBeforeRevocation = Set(secrets.values.keys), removesBeforeRevocation = secrets.removedIDs.count
        secrets.afterSave = {
            let live = try second.get("Users",key:["id":owner["id"]])!
            _ = try second.update(live,changes:["userStatus":.text("INACTIVE")],actor:"test")
        }
        try rejects("revocation between secret and DB write") { _ = try service.createMailAccount(settings,password:"synthetic-only",store:secrets) }
        secrets.afterSave = nil
        let failedKeys = Set(secrets.values.keys).subtracting(keysBeforeRevocation)
        try check(failedKeys.count == 1 && keysBeforeRevocation.isSubset(of:Set(secrets.values.keys)),"revoked create retains live and failed keys")
        try check(secrets.removedIDs.count == removesBeforeRevocation,"revoked actor performs no external deletion")
        let receipts = try NativeFreshCredentialPublication.receipts(db:db,purpose:.email)
        try check(failedKeys.allSatisfy{receipts[$0]?.state == "failed" && receipts[$0]?.ownerID == service.identity.id},"revoked failed publication retains exact durable receipt")
        _ = try second.update(second.get("Users",key:["id":owner["id"]])!,changes:["userStatus":.text("ACTIVE")],actor:"test")
        let reclaimed = try service.cleanupFailedMailCredentials(store:secrets)
        try check(reclaimed.removed == 1 && Set(secrets.values.keys) == keysBeforeRevocation,"reauthorized cleanup removes only failed fresh key")
        try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.email).isEmpty,"successful cleanup consumes receipt")
        func importedHeader(_ uid: UInt32, rfc: String? = nil) throws -> NativeMailIMAPHeader {
            let value = "Message-ID: "+(rfc ?? "<message-\(uid)@example.test>")+"\r\nSubject: 日本語の問い合わせ \(uid)\r\nFrom: Customer <customer@example.test>\r\nTo: owner@example.test\r\nDate: Mon, 15 Jan 2024 19:00:00 +0900\r\n\r\n"
            return .init(uid:uid,seen:false,headers:try NativeMailMIME.headers(Data(value.utf8)))
        }
        var inserted:[String] = []
        for start in stride(from:1,through:300,by:50) { inserted += try service.importMailHeaders(account:account,folder:.inbox,uidValidity:77,headers:try (start..<start+50).map{try importedHeader(UInt32($0))}) }
        let first = try service.mailMessages(accountID:id,folder:.inbox), next = try service.mailMessages(accountID:id,folder:.inbox,offset:50)
        try check(first.total==300 && first.rows.count==50 && next.rows.count==50,"mailbox page stays at 50 headers")
        try check(Set(first.rows.map{$0["id"].string}).isDisjoint(with:next.rows.map{$0["id"].string}),"stable paging across equal dates")
        try check(first.rows.allSatisfy{$0.values["bodyText"]==nil && $0.values["bodyHtml"]==nil},"no body retained in list rows")
        try check(try service.importMailHeaders(account:account,folder:.inbox,uidValidity:77,headers:[importedHeader(1)]).isEmpty,"sync replay is idempotent")
        try check(try service.mailMessages(accountID:id,folder:.inbox,search:"問い合わせ").total==300,"Japanese header search")
        try check(try service.mailMessages(accountID:id,folder:.inbox,search:"%__").total==0,"search wildcards remain literal")
        try check(try service.mailMessages(accountID:id,folder:.inbox,search:"😀名").total==0,"original UTF-16 search length includes a surrogate pair")
        try rejects("mailbox paging limit") { _ = try service.mailMessages(accountID:id,folder:.inbox,offset:10_000) }
        try rejects("cross-owner mail list") { _ = try stranger.mailMessages(accountID:id,folder:.inbox) }
        try rejects("cross-owner mail record") { _ = try stranger.mailMessage(inserted[0]) }
        try check(try db.page("Email",fields:[],filter:stranger.scope("Email")).total==0,"generic scope protects private messages")
        let original = try service.mailMessage(inserted[0]), read = try service.markMailRead(original)
        try check(read["isRead"] == .integer(1),"read status persists")
        let unread = try service.mailMessages(accountID:id,folder:.inbox,unreadOnly:true)
        try check(unread.total == 299 && unread.rows.allSatisfy{$0["isRead"] == .integer(0)},"unread filtering and total cover the complete mailbox")
        try rejects("stale delete") { try service.deleteMailMessage(original) }
        let location = try service.mailLocation(read)!
        try check(location.uid==1 && location.uidValidity==77,"message points to server generation")
        try check(try !service.mailBodyIsLoaded(read),"header-only message needs lazy body")
        let empty = try service.saveMailBody(read,location:location,body:NativeMailBody())
        try check(try service.mailBodyIsLoaded(empty),"empty body is remembered without repeated fetches")
        try rejects("stale body write") { _ = try service.saveMailBody(read,location:location,body:.init(text:"stale")) }
        _ = try service.importMailHeaders(account:account,folder:.inbox,uidValidity:78,headers:[importedHeader(1)])
        try rejects("UIDVALIDITY fence") { _ = try service.saveMailBody(empty,location:location,body:.init(text:"old generation")) }
        try service.deleteMailMessage(try service.mailMessage(inserted[0]))
        _ = try service.importMailHeaders(account:account,folder:.inbox,uidValidity:78,headers:[importedHeader(1)])
        try check(try service.mailMessages(accountID:id,folder:.inbox).total==299,"sync never resurrects locally deleted mail")
        let count = try service.mailMessages(accountID:id,folder:.inbox).total
        try rejects("batch rollback") {
            try db.transaction { _ = try service.importMailHeaders(account:account,folder:.inbox,uidValidity:78,headers:[importedHeader(400)]); throw NativeDBError.conflict }
        }
        try check(try service.mailMessages(accountID:id,folder:.inbox).total==count,"no partial metadata after rollback")
        let missingID = NativeMailIMAPHeader(uid:401,seen:true,headers:try NativeMailMIME.headers(Data("Subject: IDなし\r\n\r\n".utf8)))
        let missing = try service.importMailHeaders(account:account,folder:.inbox,uidValidity:78,headers:[missingID])
        try check(try missing.count==1 && service.mailMessage(missing[0])["isRead"] == .integer(1),"ID-less mail has stable fallback and initial read flag")
        try check(try service.importMailHeaders(account:account,folder:.inbox,uidValidity:78,headers:[missingID]).isEmpty,"fallback ID deduplicates replay")
        let contact = try db.insert("crm_Contacts",values:["first_name":.text("顧客"),"last_name":.text("担当"),"email":.text("CUSTOMER@example.test"),"assigned_to":owner["id"],"createdBy":owner["id"]],actor:owner["id"].string)
        let customer = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("取引先"),"email":.text("customer@example.test"),"assigned_to":owner["id"],"createdBy":owner["id"]],actor:owner["id"].string)
        let hidden = try db.insert("crm_Contacts",values:["first_name":.text("非公開"),"last_name":.text("担当"),"email":.text("customer@example.test"),"assigned_to":other["id"],"createdBy":other["id"]],actor:other["id"].string)
        let bcc = try db.insert("crm_Contacts",values:["first_name":.text("BCC"),"last_name":.text("担当"),"email":.text("private@example.test"),"assigned_to":owner["id"],"createdBy":owner["id"]],actor:owner["id"].string)
        let withBCC = try db.update(service.mailMessage(inserted[1]),changes:["bccRecipients":.text("[{\"email\":\"private@example.test\"}]")],actor:owner["id"].string)
        try check(try service.linkMailToCRM(withBCC)==2,"case-insensitive scoped CRM association")
        try check(try db.get("EmailsToContacts",key:["emailId":withBCC["id"],"contactId":contact["id"]]) != nil,"contact linked")
        try check(try db.get("EmailsToAccounts",key:["emailId":withBCC["id"],"accountId":customer["id"]]) != nil,"account linked")
        try check(try db.get("EmailsToContacts",key:["emailId":withBCC["id"],"contactId":hidden["id"]]) == nil,"inaccessible CRM entity stays unlinked")
        try check(try db.get("EmailsToContacts",key:["emailId":withBCC["id"],"contactId":bcc["id"]]) == nil,"BCC never creates association")
        try check(try service.linkMailToCRM(withBCC)==0,"links are idempotent")
        let searchable = try db.update(withBCC,changes:["subject":.text(String(repeating:"長い件名",count:200)+"末尾の検索語"),"bodyText":.text("本文だけの秘密検索語"),"bccRecipients":.text("[{\"email\":\"bcc-search-private@example.test\"}]")],actor:owner["id"].string)
        try check(try service.mailMessages(accountID:id,folder:.inbox,search:"末尾の検索語").total == 1,"mail search covers complete long subject")
        try check(try service.mailMessages(accountID:id,folder:.inbox,search:"本文だけの秘密検索語").total == 0 && service.mailMessages(accountID:id,folder:.inbox,search:"bcc-search-private").total == 0,"mailbox search uses subject and sender only, as original")
        do {
            var connection:OpaquePointer?
            guard sqlite3_open(db.url.path,&connection) == SQLITE_OK else { throw NativeDBError.conflict }
            defer { sqlite3_close(connection) }
            try check(sqlite3_exec(connection,"BEGIN; UPDATE Email SET _native_search='stale-body-token'; DELETE FROM native_metadata WHERE key='mail.headerSearch.version'; COMMIT",nil,nil,nil) == SQLITE_OK,"prepare prior search-index migration fixture")
        }
        let migrated = try open()
        try check(try service.mailMessages(accountID:id,folder:.inbox,search:"末尾の検索語").total == 1 && service.mailMessages(accountID:id,folder:.inbox,search:"stale-body-token").total == 0 && migrated.get("Email",key:["id":searchable["id"]])?.revision == searchable.revision,"search-index migration preserves email records and repairs all header pages")
        var edited = settings; edited.label = "変更後"; edited.imap.port = 1993; edited.smtp.tls = .automaticSMTP
        try rejects("other owner cannot edit settings") { _ = try stranger.updateMailAccount(account,settings:edited,password:nil,store:secrets) }
        let beforeEdit = account, oldSecret = try CRMService.mailCredentialID(account)
        account = try service.updateMailAccount(account,settings:edited,password:nil,store:secrets)
        try check(try service.mailSettings(account) == edited && CRMService.mailCredentialID(account) == oldSecret && secrets.values.count == 1,"settings and TLS change while preserving password")
        try rejects("stale settings edit") { _ = try service.updateMailAccount(beforeEdit,settings:settings,password:"unused",store:secrets) }
        try check(secrets.values.count == 1,"stale settings edit does not create secret")
        secrets.failSave = true
        try rejects("failed password save cannot partially update settings") { _ = try service.updateMailAccount(account,settings:settings,password:"new",store:secrets) }
        secrets.failSave = false
        try check(try service.mailSettings(account) == edited,"settings unchanged after secret failure")
        secrets.afterSave = {
            _ = try second.update(second.get("EmailAccount",key:["id":account["id"]])!,changes:["label":.text("同時編集")],actor:owner["id"].string)
        }
        try rejects("settings CAS after saving replacement secret") { _ = try service.updateMailAccount(account,settings:settings,password:"unused",store:secrets) }
        secrets.afterSave = nil; account = try service.mailAccount(id)
        try check(try secrets.values.count == 1 && service.mailCredential(account,store:secrets).password == "synthetic-only" && service.mailSettings(account).smtp.tls == .automaticSMTP,"CAS failure cleans replacement and preserves original credential and TLS")
        account = try service.updateMailAccount(account,settings:settings,password:"settings-password",store:secrets)
        try check(try service.mailSettings(account) == settings && service.mailCredential(account,store:secrets).password == "settings-password" && secrets.values.count == 1,"settings and replacement password commit together")
        let updatedPassword = try service.replaceMailPassword(account,password:"synthetic-replacement",store:secrets)
        try check(try secrets.values.count==1 && service.mailCredential(updatedPassword,store:secrets).password=="synthetic-replacement","password rotation publishes new immutable secret")
        try rejects("stale credential snapshot") { _ = try service.mailCredential(account,store:secrets) }
        let disabled = try service.setMailAccountActive(updatedPassword,active:false)
        try rejects("inactive mailbox cannot import") { _ = try service.importMailHeaders(account:disabled,folder:.inbox,uidValidity:78,headers:[importedHeader(500)]) }
        try rejects("stale reactivation") { _ = try service.setMailAccountActive(updatedPassword,active:true) }
        let active = try service.setMailAccountActive(disabled,active:true)
        let oldKey = try CRMService.mailCredentialID(active); secrets.failRemove = true
        try service.deleteMailAccount(active,store:secrets)
        try check(try service.mailAccounts().total==0 && db.page("Email",fields:[]).total==0,"account deletion cascades messages")
        try check(try db.metadata("mail.tls."+id)==nil,"account TLS metadata cleaned atomically")
        try check(try db.metadata("mail.location."+inserted[0])==nil,"deleted message location cleaned without loading message IDs")
        try check(try db.metadata("mail.bodyLoaded."+inserted[0])==nil,"lazy body marker cleaned with account")
        try check(try db.metadata("mail.orphanCredential."+oldKey)=="pending","failed Keychain cleanup is retained for retry")
        let reopened = try open()
        try check(try reopened.page("EmailAccount",fields:[]).total==0,"deletion survives restart")
        print("CRMEmailTests: \(checks) checks passed; ownership, immutable credentials, bounded lists, import replay, UID generation, CRM privacy and rollback")
    }
    static func relatedLists(resources:URL) throws {
        let before = checks, root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-RelatedMail-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), secrets = FakeNativeMailSecrets()
        let owner = try db.insert("Users",values:["email":.text("owner@example.test"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"test")
        let admin = try db.insert("Users",values:["email":.text("admin@example.test"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"test")
        let service = CRMService(db:db,identity:.init(id:owner["id"].string,role:"user",partnerAccountID:nil)), other = CRMService(db:db,identity:.init(id:admin["id"].string,role:"admin",partnerAccountID:nil))
        func account(_ service:CRMService,_ name:String) throws -> NativeRecord {
            try service.createMailAccount(.init(label:name,username:name+"@example.test",imap:.init(host:"imap.example.test",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.test",port:587,tls:.startTLS)),password:"synthetic",store:secrets)
        }
        let first = try account(service,"first"), second = try account(service,"second"), foreign = try account(other,"foreign")
        _ = try service.setMailAccountActive(second,active:false)
        var parent = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("日本語の取引先"),"assigned_to":owner["id"],"createdBy":owner["id"]],actor:service.identity.id)
        let contact = try db.insert("crm_Contacts",values:["first_name":.text("花子"),"last_name":.text("山田"),"assigned_to":owner["id"],"createdBy":owner["id"]],actor:service.identity.id)
        let context = NativeMailListScope.crm(model:parent.model,id:parent["id"].string), contactContext = NativeMailListScope.crm(model:contact.model,id:contact["id"].string)
        var mail:[NativeRecord] = []
        for i in 0..<54 {
            let account = i%2 == 0 ? first : second
            let row = try db.insert("Email",values:["emailAccountId":account["id"],"userId":owner["id"],"rfcMessageId":.text("<related-\(i)@example.test>"),"folder":.text(i == 0 ? "SENT" : "INBOX"),"subject":.text("関連メール \(i)"),"fromEmail":.text("customer@example.test"),"bodyText":.text("本文だけの検索語"),"sentAt":.text(ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1_700_000_000+Double(i)))),"isRead":.integer(i == 0 ? 1 : 0),"isDeleted":.integer(i == 52 ? 1 : 0)],actor:service.identity.id)
            mail.append(row)
            if i < 53 { _ = try db.insert("EmailsToAccounts",values:["emailId":row["id"],"accountId":parent["id"]],actor:service.identity.id) }
            if i < 2 { _ = try db.insert("EmailsToContacts",values:["emailId":row["id"],"contactId":contact["id"]],actor:service.identity.id) }
        }
        let privateMail = try db.insert("Email",values:["emailAccountId":foreign["id"],"userId":admin["id"],"rfcMessageId":.text("<private@example.test>"),"folder":.text("INBOX"),"subject":.text("他人の秘密")],actor:other.identity.id)
        _ = try db.insert("EmailsToAccounts",values:["emailId":privateMail["id"],"accountId":parent["id"]],actor:other.identity.id)
        let page = try service.mailMessages(in:context)
        try check(page.total == 52 && page.rows.count == 50,"CRM mail includes both owned accounts and folders, excluding deleted/unlinked/foreign mail")
        try check(page.rows.allSatisfy{$0.values["bodyText"] == nil && $0.values["bodyHtml"] == nil},"related list reads only bounded headers")
        try check(try service.mailMessages(in:context,offset:50).rows.count == 2,"related list second page")
        try check(try service.mailMessages(in:context,folder:.inbox).total == 51 && service.mailMessages(in:context,folder:.sent).total == 1,"related folder filters")
        try check(try service.mailMessages(in:context,unreadOnly:true).total == 51,"related unread filter")
        try check(try service.mailMessages(in:contactContext).total == 2,"contact-specific associations")
        try check(try service.mailListTitle(context).contains("日本語の取引先") && service.mailListTitle(contactContext).contains("山田"),"localized related headings")
        try check(try service.mailMessages(in:context,search:"関連メール 51").total == 1 && service.mailMessages(in:context,search:"本文だけの検索語").total == 0,"related search excludes message bodies")
        try check(try service.mailMessage(mail[1]["id"].string,in:context)["emailAccountId"] == second["id"],"paused related account remains readable")
        try check(try other.mailMessages(in:context).rows.map{$0["id"]} == [privateMail["id"]],"administrator never inherits another user's private mail")
        try rejects("unlinked body cannot be opened through CRM context") { _ = try service.mailMessage(mail[53]["id"].string,in:context) }
        try rejects("foreign body cannot be opened through CRM context") { _ = try service.mailMessage(privateMail["id"].string,in:context) }
        try rejects("mail from a different account context") { _ = try service.mailMessage(mail[1]["id"].string,in:.account(first["id"].string)) }
        try rejects("unsupported CRM model") { _ = try service.mailMessages(in:.crm(model:"crm_Leads",id:parent["id"].string)) }
        for offset in [-50,1,10_000] { try rejects("invalid related page") { _ = try service.mailMessages(in:context,offset:offset) } }
        let link = try db.get("EmailsToAccounts",key:["emailId":mail[1]["id"],"accountId":parent["id"]])!
        try db.remove(link,actor:service.identity.id)
        try rejects("fresh selection validates association after unlink") { _ = try service.mailMessage(mail[1]["id"].string,in:context) }
        try check(try service.mailMessage(mail[1]["id"].string,in:contactContext)["id"] == mail[1]["id"],"other valid association remains available")
        parent = try db.setDeleted(parent,deleted:true,actor:service.identity.id)
        try rejects("deleted CRM parent blocks list") { _ = try service.mailMessages(in:context) }
        try rejects("deleted CRM parent blocks body even for admin") { _ = try other.mailMessage(privateMail["id"].string,in:context) }
        parent = try db.setDeleted(parent,deleted:false,actor:service.identity.id)
        _ = try db.update(parent,changes:["assigned_to":admin["id"],"createdBy":admin["id"]],actor:other.identity.id)
        try rejects("revoked CRM scope blocks list") { _ = try service.mailMessages(in:context) }
        try rejects("revoked CRM scope blocks body") { _ = try service.mailMessage(mail[0]["id"].string,in:context) }
        _ = try db.update(owner,changes:["banned":.integer(1)],actor:other.identity.id)
        try rejects("revoked session blocks related mail") { _ = try service.mailMessages(in:contactContext) }
        print("NativeMailRelatedServiceTests: \(checks-before) checks passed; bounded cross-account CRM lists, original links, fresh access and mail privacy")
    }
}
