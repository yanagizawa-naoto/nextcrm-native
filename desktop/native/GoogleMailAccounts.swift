import Foundation

final class GoogleMailAuthorizationTicket {
    let client:GoogleCalendarClientSettings, expected:NativeRecord?, ownerID:String, ownerRevision:Int64, namespace:String, expires:Date
    fileprivate let lock = NSLock()
    fileprivate var consumed = false
    fileprivate init(client:GoogleCalendarClientSettings,expected:NativeRecord?,ownerID:String,ownerRevision:Int64,namespace:String,expires:Date) {
        self.client=client;self.expected=expected;self.ownerID=ownerID;self.ownerRevision=ownerRevision;self.namespace=namespace;self.expires=expires
    }
}
extension CRMService {
    func beginGoogleMailAuthorization(client:GoogleCalendarClientSettings,expected:NativeRecord? = nil,now:Date = Date()) throws -> GoogleMailAuthorizationTicket {
        try NativeFreshCredentialPublication.requireBoundary(db); _ = try client.validated()
        return try db.transaction {
            try authenticated(); guard let user=try db.get("Users",key:["id":.text(identity.id)]) else{throw NativeDBError.conflict}
            // Lists intentionally omit the credential reference. Capture the
            // complete current row so reconnect can release the old secret.
            let current=try expected.map { expected -> NativeRecord in
                let row=try mailAccount(expected["id"].string)
                guard row.revision==expected.revision else{throw NativeDBError.conflict};return row
            }
            return .init(client:client,expected:current,ownerID:identity.id,ownerRevision:user.revision,namespace:NativeFreshCredentialPublication.namespace(db),expires:now.addingTimeInterval(600))
        }
    }
    @discardableResult func completeGoogleMailAuthorization(_ ticket:GoogleMailAuthorizationTicket,grant:GoogleMailGrant,store:NativeMailSecretStore,now:Date = Date()) throws -> NativeRecord {
        ticket.lock.lock();defer{ticket.lock.unlock()}
        try grant.validate(); guard grant.expiresAt > now else{throw GoogleMailFailure.reconnect}
        func validate() throws {
            try Task.checkCancellation();try authenticated()
            guard !ticket.consumed,ticket.expires>now,ticket.ownerID==identity.id,ticket.namespace==NativeFreshCredentialPublication.namespace(db),
                  try db.get("Users",key:["id":.text(identity.id)])?.revision==ticket.ownerRevision else{throw NativeDBError.conflict}
            if let expected=ticket.expected {
                guard try mailAccount(expected["id"].string).revision==expected.revision,
                      expected["username"].string.lowercased()==grant.email else{throw NativeDBError.message("接続し直すメールアカウントとGoogleで選択したアカウントが一致しません。")}
            } else {
                let existing=try db.page("EmailAccount",fields:["id"],equal:["userId":.text(identity.id),"username":.text(grant.email)],limit:1)
                guard existing.total==0 else{throw NativeDBError.message("このメールアカウントは登録済みです。選択して接続し直してください。")}
            }
        }
        try validate()
        let id=ticket.expected?["id"].string ?? UUID().uuidString.lowercased()
        var settings=GoogleMailStoredGrant.settings(email:grant.email);settings.sentFolder=grant.sentFolder
        if let expected=ticket.expected {settings.label=expected["label"].string}
        let stored=GoogleMailStoredGrant(accountID:id,userID:identity.id,namespace:ticket.namespace,client:ticket.client,grant:grant)
        let credential=NativeMailCredential(version:2,password:"",google:stored);try credential.validate()
        let result=try NativeFreshCredentialPublication.perform(db:db,purpose:.email,ownerID:identity.id,authorize:validate,referenced:freshMailCredentialReferenced,save:{try store.save(id:$0,data:JSONEncoder().encode(credential))},remove:{try store.remove(id:$0)}) { item in
            try validate()
            var fields:[String:SQLValue] = ["label":.text(settings.label),"username":.text(settings.username),"imapHost":.text(settings.imap.host),"imapPort":.integer(993),"imapSsl":.integer(1),"smtpHost":.text(settings.smtp.host),"smtpPort":.integer(465),"smtpSsl":.integer(1),"allowSelfSignedTls":.integer(0),"passwordEncrypted":.text(NativeUserCredentialCleanup.Family.email.prefix+item),"sentFolderName":.text(settings.sentFolder),"isActive":.integer(1)]
            let row:NativeRecord
            if let before=ticket.expected {row=try db.update(before,changes:fields,actor:identity.id,action:"google-mail-connected")}
            else {fields["id"] = .text(id);fields["userId"] = .text(identity.id);row=try db.insert("EmailAccount",values:fields,actor:identity.id)}
            try db.setMetadata("mail.auth."+id,value:"google")
            try db.setMetadata("mail.google.authorization."+id,value:UUID().uuidString.lowercased())
            try db.setMetadata("mail.tls."+id,value:"{\"imap\":2,\"smtp\":2}")
            try db.setMetadata("mail.google.forceRefresh."+id,value:"")
            try db.setMetadata(NativeMailJobs.error(id),value:"")
            return row
        }
        ticket.consumed=true
        if let before=ticket.expected,let old=try? Self.mailCredentialID(before) { cleanupGoogleMailSecret(old,store:store) }
        return result
    }
    private func cleanupGoogleMailSecret(_ id:String,store:NativeMailSecretStore) {
        do { try NativeUserCredentialCleanup.removeUnlessHeld(db:db,family:.email,credentialID:id){try store.remove(id:id)} }
        catch {try? db.setMetadata("mail.orphanCredential."+id,value:"pending")}
    }
    /// Review approval follows a connection authorization, not short-lived token
    /// rotation. Manual reconnect always replaces this non-secret generation.
    func mailCredentialApprovalBinding(_ expected:NativeRecord) throws -> String {
        let current=try mailAccount(expected["id"].string)
        guard current.revision==expected.revision else{throw NativeDBError.conflict}
        let id=try Self.mailCredentialID(current)
        guard try db.metadata("mail.auth."+current["id"].string)=="google" else{return id}
        guard let generation=try db.metadata("mail.google.authorization."+current["id"].string),UUID(uuidString:generation) != nil else{throw GoogleMailFailure.reconnect}
        return "google-mail-v1:"+generation
    }
    /// Refreshes before using a token. A concurrent refresh/settings change loses
    /// the existing revision CAS and is retried by the durable mail worker.
    func readyMailCredential(_ expected:NativeRecord,store:NativeMailSecretStore,request:@escaping GoogleMailOAuth.Request = GoogleMailOAuth.network,now:Date = Date(),validate:()throws->Void = {}) async throws -> (account:NativeRecord,credential:NativeMailCredential) {
        try validate();let credential=try mailCredential(expected,store:store)
        guard let stored=credential.google else{return(expected,credential)}
        let forced=try db.metadata("mail.google.forceRefresh."+expected["id"].string)==Self.mailCredentialID(expected)
        guard forced || stored.grant.expiresAt<=now.addingTimeInterval(120) else{return(expected,credential)}
        try validate();let grant=try await GoogleMailOAuth.refresh(stored,request:request,now:now);try Task.checkCancellation();try validate()
        let next=NativeMailCredential(version:2,password:"",google:.init(accountID:stored.accountID,userID:stored.userID,namespace:stored.namespace,client:stored.client,grant:grant))
        func authority() throws {
            try validate();try authenticated();guard try mailAccount(expected["id"].string).revision==expected.revision else{throw NativeDBError.conflict}
        }
        let row=try NativeFreshCredentialPublication.perform(db:db,purpose:.email,ownerID:identity.id,authorize:authority,referenced:freshMailCredentialReferenced,save:{try store.save(id:$0,data:JSONEncoder().encode(next))},remove:{try store.remove(id:$0)}) { item in
            try authority()
            let row=try db.update(expected,changes:["passwordEncrypted":.text(NativeUserCredentialCleanup.Family.email.prefix+item)],actor:identity.id,action:"google-mail-token-refreshed")
            try db.setMetadata("mail.google.forceRefresh."+expected["id"].string,value:"");return row
        }
        if let old=try? Self.mailCredentialID(expected){cleanupGoogleMailSecret(old,store:store)}
        return(row,next)
    }
    /// SMTP auth rejection happens before upload. A single refreshed credential
    /// is tried on the next leased attempt; arbitrary failures are not exposed.
    func noteGoogleMailAuthenticationFailure(_ account:NativeRecord,error:Error) -> Bool {
        // Supplemental refresh bookkeeping must never bypass failJob / the
        // proven pre-upload SMTP cleanup when the owner was revoked meanwhile.
        guard case NativeMailFailure.transport(let code,let uploaded)=error,code==67,!uploaded else{return false}
        return (try? db.transaction {
            guard try db.metadata("mail.auth."+account["id"].string)=="google",
                  let live=try? mailAccount(account["id"].string),live.revision==account.revision else{return false}
            try db.setMetadata("mail.google.forceRefresh."+account["id"].string,value:Self.mailCredentialID(live));return true
        }) ?? false
    }
}
