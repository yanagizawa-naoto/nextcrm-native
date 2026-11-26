import Foundation
import CryptoKit

extension NativeMailJobs {
    static let embed = "email/embed-email"
    static func bodyPointer(_ id:String) -> String { "mail.body.job."+id }
    static func foreground(_ id:String) -> String { "mail.body.foreground."+id }
    static func absent(_ id:String) -> String { "mail.body.absent."+id }
    static func embedPointer(_ id:String) -> String { "mail.embed.job."+id }
    static func embedHash(_ id:String) -> String { "mail.embed.hash."+id }
}

extension CRMService {
    func mailHasCRMLinks(_ expected: NativeRecord) throws -> Bool {
        let row = try mailMessage(expected["id"].string)
        guard row.revision == expected.revision else { throw NativeDBError.conflict }
        for (table,model,key) in [("EmailsToContacts","crm_Contacts","contactId"),("EmailsToAccounts","crm_Accounts","accountId")] {
            let filter = RecordFilter.relation(model:model,local:key,foreign:"id",matching:.every([scope(model),.equal("deletedAt",.null)]))
            if try !db.page(table,fields:[],equal:["emailId":row["id"]],filter:filter,limit:1).rows.isEmpty { return true }
        }
        return false
    }
    func mailBodyJob(_ emailID: String) throws -> NativeJob? {
        let row = try mailMessage(emailID)
        guard let id = try db.metadata(NativeMailJobs.bodyPointer(emailID)), let job = try db.job(id:id), job.event == NativeMailJobs.body,
              job.payload["actorID"] == identity.id, job.payload["emailID"] == emailID, job.payload["accountID"] == row["emailAccountId"].string else { return nil }
        return job
    }
    @discardableResult func requestMailBody(_ expected: NativeRecord,background: Bool = false,now: Date = Date()) throws -> String? {
        try db.transaction {
            let row = try mailMessage(expected["id"].string)
            guard row.revision == expected.revision else { throw NativeDBError.conflict }
            if try mailBodyIsLoaded(row) { _ = try requestMailEmbedding(row,now:now); return nil }
            if try background && !mailHasCRMLinks(row) { return nil }
            _ = try mailAccount(row["emailAccountId"].string,active:background)
            if let location = try mailLocation(row), let absent = try db.metadata(NativeMailJobs.absent(row["id"].string)),
               (try? JSONDecoder().decode(NativeMailLocation.self,from:Data(absent.utf8))) == location { return nil }
            if let job = try mailBodyJob(row["id"].string), ["pending","running","retry"].contains(job.status) {
                if !background { try db.setMetadata(NativeMailJobs.foreground(row["id"].string),value:job.id) }
                if job.status == "retry" { try db.retryJob(id:job.id,now:now) }; return job.id
            }
            let id = try db.enqueue(NativeMailJobs.body,payload:["actorID":identity.id,"accountID":row["emailAccountId"].string,"emailID":row["id"].string,"background":background ? "true" : "false"],now:now)
            try db.setMetadata(NativeMailJobs.bodyPointer(row["id"].string),value:id)
            if !background { try db.setMetadata(NativeMailJobs.foreground(row["id"].string),value:id) }
            return id
        }
    }
    /// Only the event is prepared here. The native AI worker will revalidate
    /// this owner, association and content hash before calling a provider.
    @discardableResult func requestMailEmbedding(_ expected: NativeRecord,now: Date = Date()) throws -> String? {
        try db.transaction {
            let row = try mailMessage(expected["id"].string)
            guard row.revision == expected.revision else { throw NativeDBError.conflict }
            guard try mailHasCRMLinks(row) else { return nil }
            var hash = SHA256(), any = false
            for key in ["subject","bodyText","fromEmail"] {
                let text = row[key].string; if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { continue }
                if any { hash.update(data:Data([32])) }; hash.update(data:Data(text.utf8)); any = true
            }
            guard any else { return nil }
            let digest = hash.finalize().map{String(format:"%02x",$0)}.joined(), emailID = row["id"].string
            if try db.metadata(NativeMailJobs.embedHash(emailID)) == digest,
               let id = try db.metadata(NativeMailJobs.embedPointer(emailID)), let job = try db.job(id:id), job.event == NativeMailJobs.embed,
               job.payload["actorID"] == identity.id, job.payload["emailID"] == emailID, job.payload["contentHash"] == digest, job.status != "cancelled" { return id }
            let id = try db.enqueue(NativeMailJobs.embed,payload:["actorID":identity.id,"accountID":row["emailAccountId"].string,"emailID":emailID,"contentHash":digest],now:now)
            try db.setMetadata(NativeMailJobs.embedHash(emailID),value:digest); try db.setMetadata(NativeMailJobs.embedPointer(emailID),value:id); return id
        }
    }
}

actor NativeMailContentWorker {
    let db: NativeDatabase, store: NativeMailSecretStore
    let makeClient: NativeMailSyncWorker.Factory, clock: () -> Date
    private var active = false
    let oauthRequest:GoogleMailOAuth.Request
    init(db: NativeDatabase,store: NativeMailSecretStore,makeClient: @escaping NativeMailSyncWorker.Factory = { NativeMailClient(endpoint:$0.imap,username:$0.username,password:$1.password,oauthBearer:$1.oauthBearer) },clock: @escaping () -> Date = Date.init,oauthRequest:@escaping GoogleMailOAuth.Request = GoogleMailOAuth.network) {
        self.db = db; self.store = store; self.makeClient = makeClient; self.clock = clock; self.oauthRequest = oauthRequest
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let job = try db.claimJob(events:[NativeMailJobs.link,NativeMailJobs.body],now:clock()) else { return false }
        var owner: CRMService?, emailID: String?, credentialAccount:NativeRecord?
        do {
            guard let actorID = job.payload["actorID"], let id = job.payload["emailID"], let accountID = job.payload["accountID"], let user = try db.get("Users",key:["id":.text(actorID)]) else { throw NativeDBError.conflict }
            let service = CRMService(db:db,identity:.init(id:actorID,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string)); owner = service; emailID = id
            let row = try service.mailMessage(id)
            guard row["emailAccountId"] == .text(accountID) else { throw NativeDBError.conflict }
            if job.event == NativeMailJobs.link {
                try db.transaction {
                    try Task.checkCancellation(); _ = try db.requireJobLease(job)
                    let linked = try service.linkMailToCRM(row)
                    if try service.mailHasCRMLinks(row) {
                        let bodyJob = try service.requestMailBody(row,background:true,now:clock())
                        if bodyJob == nil { _ = try service.requestMailEmbedding(row,now:clock()) }
                    }
                    try db.finishJob(job,result:["linked":String(linked)],now:clock())
                }
                return true
            }
            // Pausing automatic sync must not disable an explicit open. A
            // queued background request can also be promoted by a user open.
            func requiresActive() throws -> Bool { try job.payload["background"] == "true" && db.metadata(NativeMailJobs.foreground(id)) != job.id }
            var account = try service.mailAccount(accountID,active:requiresActive()); credentialAccount = account
            func validate() throws -> NativeRecord {
                try Task.checkCancellation(); _ = try db.requireJobLease(job)
                let current = try service.mailMessage(id), currentAccount = try service.mailAccount(accountID,active:requiresActive())
                guard currentAccount.revision == account.revision, try db.metadata(NativeMailJobs.bodyPointer(id)) == job.id else { throw NativeDBError.conflict }
                return current
            }
            func heartbeat() throws { try db.transaction { _ = try validate(); try db.renewJobLease(job,now:clock()) } }
            try heartbeat()
            if try service.mailBodyIsLoaded(row) {
                try db.transaction { _ = try validate(); _ = try service.requestMailEmbedding(service.mailMessage(id),now:clock()); try db.finishJob(job,result:["cached":"true"],now:clock()) }; return true
            }
            if job.payload["background"] == "true", try db.metadata(NativeMailJobs.foreground(id)) != job.id, try !service.mailHasCRMLinks(row) {
                try db.finishJob(job,result:["skipped":"unlinked"],now:clock()); return true
            }
            let settings = try service.mailSettings(account)
            guard let location = try service.mailLocation(row), location.source == NativeMailSource(endpoint:settings.imap,username:settings.username,mailbox:location.folder == .inbox ? "INBOX" : settings.sentFolder) else { throw NativeMailFailure.mailboxChanged }
            let prepared = try await service.readyMailCredential(account,store:store,request:oauthRequest,now:clock(),validate:heartbeat)
            account = prepared.account; credentialAccount = account
            let credentials = prepared.credential; try heartbeat()
            let result = try await makeClient(settings,credentials).body(mailbox:location.source!.mailbox,validity:location.uidValidity,uid:location.uid)
            try db.transaction {
                let fresh = try validate()
                guard try service.mailLocation(fresh) == location else { throw NativeDBError.conflict }
                if job.payload["background"] == "true", try db.metadata(NativeMailJobs.foreground(id)) != job.id, try !service.mailHasCRMLinks(fresh) {
                    try db.finishJob(job,result:["skipped":"unlinked"],now:clock()); return
                }
                if let result {
                    let saved = try service.mailBodyIsLoaded(fresh) ? fresh : service.saveMailBody(fresh,location:location,body:result,requiresActive:requiresActive())
                    _ = try service.requestMailEmbedding(saved,now:clock())
                } else {
                    try db.setMetadata(NativeMailJobs.absent(id),value:String(decoding:JSONEncoder().encode(location),as:UTF8.self))
                    _ = try service.requestMailEmbedding(fresh,now:clock())
                }
                try db.finishJob(job,result:["loaded":result == nil ? "false" : "true","missing":result == nil ? "true" : "false"],now:clock())
            }
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            let googleRetry = credentialAccount.map { owner?.noteGoogleMailAuthenticationFailure($0,error:error) ?? false } ?? false
            try db.transaction {
                _ = try db.requireJobLease(job)
                if case NativeMailFailure.mailboxChanged = error, let owner, let emailID,
                   let row = try? owner.mailMessage(emailID), let account = try? owner.mailAccount(row["emailAccountId"].string,active:true) { _ = try owner.requestMailSync(account,now:clock()) }
                // Preserve original subject/from-only embedding on body-fetch
                // failure. Successful retrieval queues the complete text once.
                if job.event == NativeMailJobs.body, let owner, let emailID, let row = try? owner.mailMessage(emailID) { _ = try owner.requestMailEmbedding(row,now:clock()) }
                let retry = (googleRetry || NativeMailJobs.retryable(error)) && current.attempts < 4
                try db.failJob(current,message:googleRetry ? GoogleMailFailure.reconnect.localizedDescription : NativeMailJobs.message(error),retryAt:retry ? clock().addingTimeInterval(min(300,5*pow(2,Double(current.attempts-1)))) : nil)
            }
        }
        return true
    }
}
