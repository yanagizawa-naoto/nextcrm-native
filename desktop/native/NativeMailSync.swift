import Foundation

enum NativeMailJobs {
    static let sync = "native.mail.sync", link = "email/link-crm", body = "native.mail.body"
    static func syncPointer(_ id:String) -> String { "mail.sync.job."+id }
    static func generation(_ id:String) -> String { "mail.sync.generation."+id }
    static func cursor(_ id:String,_ folder:NativeMailFolder) -> String { "mail.sync.cursor."+id+"."+folder.rawValue }
    static func error(_ id:String) -> String { "mail.sync.error."+id }
    static func retryable(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case NativeDBError.conflict = error { return true }
        if let google = error as? GoogleMailFailure { return google == .temporary }
        guard let mail = error as? NativeMailFailure else { return false }
        switch mail {
        case .cancelled,.mailboxChanged,.spoolBusy:return true
        case .transport(let code,let uploaded):return !uploaded && [5,6,7,18,28,35,52,55,56,-3].contains(code)
        default:return false
        }
    }
    static func message(_ error: Error) -> String {
        if let google = error as? GoogleMailFailure { return google.localizedDescription }
        if let mail = error as? NativeMailFailure { return mail.localizedDescription }
        if error is CancellationError { return "メールの同期を中断しました。再開後に再試行します。" }
        if case NativeDBError.conflict = error { return "同期中に設定または処理が更新されました。新しい設定で再試行します。" }
        return "メールを同期できませんでした。アカウント設定と空き容量を確認してください。"
    }
}

struct NativeMailSyncCursor: Codable {
    let endpoint: NativeMailEndpoint
    let username: String, mailbox: String
    let validity: UInt32
    var uid: UInt32
    var initialSince: Date?
}

extension CRMService {
    @discardableResult func requestMailSync(_ expected: NativeRecord,now: Date = Date()) throws -> String {
        try db.transaction {
            let current = try mailAccount(expected["id"].string,active:true)
            guard current.revision == expected.revision else { throw NativeDBError.conflict }
            let id = current["id"].string
            try db.setMetadata(NativeMailJobs.generation(id),value:UUID().uuidString.lowercased())
            if let job = try mailSyncJob(id), ["pending","running","retry"].contains(job.status) {
                if job.status == "retry" { try db.retryJob(id:job.id,now:now) }; return job.id
            }
            let jobID = try db.enqueue(NativeMailJobs.sync,payload:["actorID":identity.id,"accountID":id],now:now)
            try db.setMetadata(NativeMailJobs.syncPointer(id),value:jobID); return jobID
        }
    }
    func mailSyncJob(_ accountID: String) throws -> NativeJob? {
        _ = try mailAccount(accountID)
        guard let id = try db.metadata(NativeMailJobs.syncPointer(accountID)), let job = try db.job(id:id), job.event == NativeMailJobs.sync, job.payload["actorID"] == identity.id, job.payload["accountID"] == accountID else { return nil }; return job
    }
}

actor NativeMailSyncWorker {
    typealias Factory = (NativeMailAccountSettings,NativeMailCredential) throws -> NativeMailReceiving
    let db: NativeDatabase, store: NativeMailSecretStore
    let makeClient: Factory, clock: () -> Date
    let oauthRequest:GoogleMailOAuth.Request
    private var active = false
    init(db: NativeDatabase,store: NativeMailSecretStore,makeClient: @escaping Factory = { NativeMailClient(endpoint:$0.imap,username:$0.username,password:$1.password,oauthBearer:$1.oauthBearer) },clock: @escaping () -> Date = Date.init,oauthRequest:@escaping GoogleMailOAuth.Request = GoogleMailOAuth.network) {
        self.db = db; self.store = store; self.makeClient = makeClient; self.clock = clock; self.oauthRequest = oauthRequest
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let job = try db.claimJob(events:[NativeMailJobs.sync],now:clock()) else { return false }
        var expected: NativeRecord?, owner: CRMService?
        do {
            guard let actorID = job.payload["actorID"], let id = job.payload["accountID"], let user = try db.get("Users",key:["id":.text(actorID)]) else { throw NativeDBError.conflict }
            let service = CRMService(db:db,identity:.init(id:actorID,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string)); owner = service
            var account = try service.mailAccount(id); expected = account
            guard account["isActive"] == .integer(1) else { try db.finishJob(job,result:["skipped":"inactive"],now:clock()); return true }
            let generation = try db.metadata(NativeMailJobs.generation(id))
            func validate() throws {
                try Task.checkCancellation(); _ = try db.requireJobLease(job)
                let current = try service.mailAccount(id,active:true)
                guard current.revision == account.revision, try db.metadata(NativeMailJobs.syncPointer(id)) == job.id else { throw NativeDBError.conflict }
            }
            func heartbeat() throws { try db.transaction { try validate(); try db.renewJobLease(job,now:clock()) } }
            try heartbeat()
            let prepared = try await service.readyMailCredential(account,store:store,request:oauthRequest,now:clock(),validate:heartbeat)
            account = prepared.account; expected = account
            let settings = try service.mailSettings(account), credential = prepared.credential
            try heartbeat(); let client = try makeClient(settings,credential)
            var synced = 0, inserted = 0, finalUIDs:[String:SQLValue] = [:]
            for (folder,mailbox,field) in [(NativeMailFolder.inbox,"INBOX","inboxLastUid"),(.sent,settings.sentFolder,"sentLastUid")] {
                try heartbeat(); let status = try await client.status(mailbox:mailbox); try heartbeat()
                guard status.validity > 0, status.next > 0 else { throw NativeMailFailure.malformed }
                let key = NativeMailJobs.cursor(id,folder), through = status.next-1
                var cursor: NativeMailSyncCursor
                if let saved = try db.metadata(key), let previous = try? JSONDecoder().decode(NativeMailSyncCursor.self,from:Data(saved.utf8)), previous.validity == status.validity, previous.mailbox == mailbox, previous.endpoint == settings.imap, previous.username == settings.username {
                    guard previous.uid <= through else { throw NativeMailFailure.mailboxChanged }; cursor = previous
                } else {
                    cursor = .init(endpoint:settings.imap,username:settings.username,mailbox:mailbox,validity:status.validity,uid:0,initialSince:clock().addingTimeInterval(-180*86400))
                }
                func checkpoint() throws {
                    try validate()
                    try db.setMetadata(key,value:String(decoding:JSONEncoder().encode(cursor),as:UTF8.self))
                }
                try db.transaction { try checkpoint() }
                if through > cursor.uid {
                    let spool = try await client.discover(mailbox:mailbox,validity:cursor.validity,after:cursor.uid,through:through,since:cursor.initialSince); try heartbeat()
                    while true {
                        let uids = try spool.page(after:cursor.uid); if uids.isEmpty { break }
                        try heartbeat(); let headers = try await client.headerBatch(mailbox:mailbox,validity:cursor.validity,uids:uids); try heartbeat()
                        try db.transaction {
                            try validate()
                            var seen:Set<UInt32>=[],batchInserted=0
                            try headers.forEach { header in
                                try validate()
                                guard uids.contains(header.uid),seen.insert(header.uid).inserted else{throw NativeMailFailure.malformed}
                                let ids=try service.importMailHeaders(account:account,folder:folder,uidValidity:cursor.validity,headers:[header])
                                for emailID in ids{_ = try db.enqueue(NativeMailJobs.link,payload:["actorID":actorID,"accountID":id,"emailID":emailID],now:clock())}
                                batchInserted += ids.count
                            }
                            // The full batch, follow-up jobs and checkpoint commit together.
                            cursor.uid = uids.last!; try checkpoint(); try db.renewJobLease(job,now:clock())
                            synced += seen.count; inserted += batchInserted
                        }
                    }
                }
                try db.transaction { cursor.uid = through; cursor.initialSince = nil; try checkpoint() }
                finalUIDs[field] = .integer(Int64(through))
            }
            try db.transaction {
                try validate()
                finalUIDs["lastSyncedAt"] = .text(ISO8601DateFormatter().string(from:clock()))
                let updated = try db.update(account,changes:finalUIDs,actor:actorID,action:"mail-synced"); expected = updated
                try db.setMetadata(NativeMailJobs.error(id),value:"")
                try db.finishJob(job,result:["synced":String(synced),"newMessages":String(inserted)],now:clock())
                if try db.metadata(NativeMailJobs.generation(id)) != generation { _ = try service.requestMailSync(updated,now:clock()) }
            }
        } catch {
            // A stolen lease must not publish an error or overwrite its successor.
            guard let current = try? db.requireJobLease(job) else { return true }
            let googleRetry = expected.map { owner?.noteGoogleMailAuthenticationFailure($0,error:error) ?? false } ?? false
            let message = googleRetry ? GoogleMailFailure.reconnect.localizedDescription : NativeMailJobs.message(error)
            try db.transaction {
                _ = try db.requireJobLease(job)
                if let expected, let owner, let fresh = try? owner.mailAccount(expected["id"].string,active:true), fresh.revision == expected.revision, try db.metadata(NativeMailJobs.syncPointer(fresh["id"].string)) == job.id {
                    try db.setMetadata(NativeMailJobs.error(fresh["id"].string),value:message)
                }
                let retry = (googleRetry || NativeMailJobs.retryable(error)) && current.attempts < 4
                try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(min(300,5*pow(2,Double(current.attempts-1)))) : nil)
            }
        }
        return true
    }
}
