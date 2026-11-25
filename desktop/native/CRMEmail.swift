import Foundation
import CryptoKit

enum NativeMailFolder: String, Codable { case inbox = "INBOX", sent = "SENT" }
enum NativeMailListScope:Equatable {
    case account(String)
    case crm(model:String,id:String)
    var accountID:String? { if case let .account(id) = self { return id }; return nil }
    var isCRM:Bool { if case .crm = self { return true }; return false }
}
struct NativeMailSource: Codable, Equatable {
    let endpoint: NativeMailEndpoint
    let username: String, mailbox: String
}
struct NativeMailLocation: Codable, Equatable {
    let accountID: String
    let folder: NativeMailFolder
    let uidValidity: UInt32
    let uid: UInt32
    var source: NativeMailSource? = nil
}

extension CRMService {
    func mailMessages(accountID: String,folder: NativeMailFolder,offset: Int = 0,search: String = "",unreadOnly:Bool = false) throws -> (rows:[NativeRecord],total:Int) {
        try mailMessages(in:.account(accountID),folder:folder,offset:offset,search:search,unreadOnly:unreadOnly)
    }
    private func mailListFilter(_ context:NativeMailListScope) throws -> RecordFilter {
        try authenticated()
        switch context {
        case let .account(id):
            _ = try mailAccount(id)
            return .every([scope("Email"),.equal("emailAccountId",.text(id))])
        case let .crm(model,id):
            guard ["crm_Accounts","crm_Contacts"].contains(model) else { throw NativeDBError.message("メールの関連先が不正です。") }
            try assertAccess(model,id:id)
            let account = model == "crm_Accounts"
            return .every([scope("Email"),.relation(model:account ? "EmailsToAccounts" : "EmailsToContacts",local:"id",foreign:"emailId",matching:.equal(account ? "accountId" : "contactId",.text(id)))])
        }
    }
    func mailListTitle(_ context:NativeMailListScope) throws -> String {
        try db.transaction {
            _ = try mailListFilter(context)
            switch context {
            case let .account(id): return "メール — "+(try mailAccount(id))["label"].string
            case let .crm(model,id):
                let fields = model == "crm_Accounts" ? ["name"] : ["first_name","last_name"]
                guard let row = try db.page(model,fields:fields,equal:["id":.text(id)],limit:1).rows.first else { throw NativeDBError.conflict }
                return "関連メール（自分のメール） — "+CRMModule.displayName(row)
            }
        }
    }
    func mailMessages(in context:NativeMailListScope,folder:NativeMailFolder? = nil,offset:Int = 0,search:String = "",unreadOnly:Bool = false) throws -> (rows:[NativeRecord],total:Int) {
        guard offset >= 0, offset < 10_000, offset%50 == 0 else { throw NativeDBError.message("メールのページ番号が不正です。") }
        var matching:[String:SQLValue] = ["userId":.text(identity.id),"isDeleted":.integer(0)]
        if let folder { matching["folder"] = .text(folder.rawValue) }
        if unreadOnly { matching["isRead"] = .integer(0) }
        return try db.transaction {
            let filter = try mailListFilter(context)
            let page = try db.page("Email",fields:["subject","fromName","fromEmail","sentAt","isRead","folder","emailAccountId","userId"],search:search.utf16.count >= 3 ? search : "",equal:matching,offset:offset,filter:filter,sort:"sentAt",descending:true,limit:50)
            return (page.rows,min(10_000,page.total))
        }
    }
    func mailMessage(_ id:String,in context:NativeMailListScope) throws -> NativeRecord {
        try db.transaction {
            let filter = try mailListFilter(context)
            guard try db.page("Email",fields:[],equal:["id":.text(id),"isDeleted":.integer(0)],filter:filter,limit:1).total == 1 else { throw NativeDBError.message("メールが見つからないか、関連先が変更されています。") }
            return try mailMessage(id)
        }
    }
    func mailMessage(_ id: String,includeDeleted: Bool = false) throws -> NativeRecord {
        try authenticated()
        guard let row = try db.get("Email",key:["id":.text(id)]), row["userId"] == .text(identity.id), includeDeleted || row["isDeleted"] != .integer(1) else { throw NativeDBError.message("メールが見つかりません。") }
        _ = try mailAccount(row["emailAccountId"].string); return row
    }
    @discardableResult func markMailRead(_ expected: NativeRecord) throws -> NativeRecord {
        try db.transaction {
            let row = try mailMessage(expected["id"].string); guard row.revision == expected.revision else { throw NativeDBError.conflict }
            return row["isRead"] == .integer(1) ? row : try db.update(row,changes:["isRead":.integer(1)],actor:identity.id)
        }
    }
    func deleteMailMessage(_ expected: NativeRecord) throws {
        try db.transaction {
            let row = try mailMessage(expected["id"].string); guard row.revision == expected.revision else { throw NativeDBError.conflict }
            _ = try db.update(row,changes:["isDeleted":.integer(1)],actor:identity.id,action:"delete-mail")
        }
    }
    func mailLocation(_ expected: NativeRecord) throws -> NativeMailLocation? {
        let row = try mailMessage(expected["id"].string)
        guard row.revision == expected.revision else { throw NativeDBError.conflict }
        guard let value = try db.metadata("mail.location."+row["id"].string) else { return nil }
        guard let location = try? JSONDecoder().decode(NativeMailLocation.self,from:Data(value.utf8)), location.accountID == row["emailAccountId"].string, location.folder.rawValue == row["folder"].string, location.uidValidity > 0, location.uid > 0 else { throw NativeDBError.conflict }
        return location
    }
    /// The caller owns the durable sync cursor; these batches and the cursor
    /// publication can share a surrounding SQLite transaction.
    @discardableResult func importMailHeaders(account expected: NativeRecord,folder: NativeMailFolder,uidValidity: UInt32,headers:[NativeMailIMAPHeader]) throws -> [String] {
        guard uidValidity > 0, headers.count <= 50, Set(headers.map(\.uid)).count == headers.count else { throw NativeMailFailure.malformed }
        return try db.transaction {
            let account = try mailAccount(expected["id"].string,active:true)
            guard account.revision == expected.revision else { throw NativeDBError.conflict }
            let settings = try mailSettings(account)
            var inserted:[String] = []
            for item in headers {
                guard item.uid > 0 else { throw NativeMailFailure.malformed }
                let location = NativeMailLocation(accountID:account["id"].string,folder:folder,uidValidity:uidValidity,uid:item.uid,source:.init(endpoint:settings.imap,username:settings.username,mailbox:folder == .inbox ? "INBOX" : settings.sentFolder))
                let seed = location.accountID+"/"+folder.rawValue+"/"+String(uidValidity)+"/"+String(item.uid)
                let fallback = "<native-"+SHA256.hash(data:Data(seed.utf8)).map{String(format:"%02x",$0)}.joined()+"@nextcrm.local>"
                let rfcID = item.headers.messageID ?? fallback
                let existing = try db.page("Email",fields:["folder"],equal:["emailAccountId":account["id"],"rfcMessageId":.text(rfcID)],limit:1).rows.first
                let row: NativeRecord
                if let existing {
                    row = try mailMessage(existing["id"].string,includeDeleted:true)
                    // The original store has one record per account/Message-ID.
                    // Preserve its chosen folder and local deletion/read state.
                    if row["folder"] != .text(folder.rawValue) { continue }
                    if row["imapUid"] != .integer(Int64(item.uid)) { _ = try db.update(row,changes:["imapUid":.integer(Int64(item.uid))],actor:identity.id,action:"refresh-mail-location") }
                } else {
                    let from = NativeMailMIME.addresses(item.headers["from"]).first
                    func addresses(_ key:String) throws -> SQLValue { .text(String(decoding:try JSONEncoder().encode(NativeMailMIME.addresses(item.headers[key])),as:UTF8.self)) }
                    row = try db.insert("Email",values:["emailAccountId":account["id"],"userId":.text(identity.id),"rfcMessageId":.text(rfcID),"imapUid":.integer(Int64(item.uid)),"folder":.text(folder.rawValue),"subject":.text(item.headers.subject),"fromName":from?.name.map(SQLValue.text) ?? .null,"fromEmail":from.map{.text($0.email)} ?? .null,"toRecipients":try addresses("to"),"ccRecipients":try addresses("cc"),"sentAt":item.headers.sentAt.map{.text(ISO8601DateFormatter().string(from:$0))} ?? .null,"isRead":.integer(item.seen ? 1 : 0)],actor:identity.id)
                    inserted.append(row["id"].string)
                }
                try db.setMetadata("mail.location."+row["id"].string,value:String(decoding:JSONEncoder().encode(location),as:UTF8.self))
            }
            return inserted
        }
    }
    func mailBodyIsLoaded(_ expected: NativeRecord) throws -> Bool {
        let row = try mailMessage(expected["id"].string)
        if row["bodyText"] != .null || row["bodyHtml"] != .null { return true }
        return try db.metadata("mail.bodyLoaded."+row["id"].string) == "1"
    }
    @discardableResult func saveMailBody(_ expected: NativeRecord,location: NativeMailLocation,body: NativeMailBody,requiresActive:Bool = true) throws -> NativeRecord {
        // The derived text can exceed the size of its original HTML (for
        // example horizontal rules). Do not reject previously accepted HTML
        // because of an artificial combined/per-field body budget. The SQLite
        // value/row resource limits still report errors; no field is truncated.
        return try db.transaction {
            let row = try mailMessage(expected["id"].string)
            guard row.revision == expected.revision, try mailLocation(row) == location else { throw NativeDBError.conflict }
            _ = try mailAccount(row["emailAccountId"].string,active:requiresActive)
            let updated = try db.update(row,changes:["bodyText":body.text.map(SQLValue.text) ?? .null,"bodyHtml":body.html.map(SQLValue.text) ?? .null],actor:identity.id,action:"fetch-mail-body")
            try db.setMetadata("mail.bodyLoaded."+row["id"].string,value:"1"); return updated
        }
    }
    @discardableResult func linkMailToCRM(_ expected: NativeRecord) throws -> Int {
        try db.transaction {
            let row = try mailMessage(expected["id"].string)
            guard row.revision == expected.revision else { throw NativeDBError.conflict }
            func recipients(_ key: String) -> [String] { (try? JSONDecoder().decode([NativeMailAddress].self,from:Data(row[key].string.utf8)))?.map(\.email) ?? [] }
            // BCC is deliberately excluded from CRM associations.
            let addresses = Array(Set(([row["fromEmail"].string]+recipients("toRecipients")+recipients("ccRecipients")).filter{!$0.isEmpty}.map{$0.lowercased()})).sorted()
            var linked = 0
            for (model,table,key) in [("crm_Contacts","EmailsToContacts","contactId"),("crm_Accounts","EmailsToAccounts","accountId")] {
                for start in stride(from:0,to:addresses.count,by:50) {
                    let batch = Array(addresses[start..<min(addresses.count,start+50)]); var offset = 0
                    while true {
                        let matches = try db.matchMailAddresses(model,addresses:batch,scope:scope(model),offset:offset)
                        for match in matches {
                            let link:[String:SQLValue] = ["emailId":row["id"],key:match["id"]]
                            if try db.get(table,key:link) == nil { _ = try db.insert(table,values:link,actor:identity.id); linked += 1 }
                        }
                        if matches.count < 100 { break }; offset += matches.count
                    }
                }
            }
            return linked
        }
    }
}
