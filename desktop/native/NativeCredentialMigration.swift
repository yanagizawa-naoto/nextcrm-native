import Foundation
import CryptoKit

enum NativeCredentialMigrationFamily: String, Codable, CaseIterable {
    case ai, email, plugin, google, invoice, calendly
    var prefix:String {switch self {case .ai:return "native-ai-keychain:";case .email:return "native-keychain:";case .plugin:return "native-plugin-keychain:";case .google:return "keychain:v1:";case .invoice:return "native-invoice-keychain:";case .calendly:return "native-calendly-keychain:"}}
}
struct NativeCredentialMigrationLease: Codable, Equatable {
    let id:String,namespace:String,payloadSHA256:String,creationToken:String
    let family:NativeCredentialMigrationFamily
}
/// The implementation must use insert-only immutable IDs. removeCreated may
/// remove only the exact namespace/family/id/payload digest and creation token
/// in its receipt. A failed/ambiguous insert remains recoverable in the journal.
protocol NativeCredentialMigrationVault {
    var namespace:String {get}
    func insert(_ lease:NativeCredentialMigrationLease,data:Data)throws
    func load(_ family:NativeCredentialMigrationFamily,id:String)throws->Data?
    func removeCreated(_ lease:NativeCredentialMigrationLease)throws
}
struct NativeCredentialMigrationOptions {
    struct Google {let clientID:String,clientSecret:String}
    struct Calendly {let publicURL:String,clientID:String,instanceID:String,authKey:String}
    var google:Google?
    var calendly:Calendly?
    var resendSender:String?
    var resendServiceID:String?
    // The caller must explicitly establish that legacy singleton settings are
    // absent; migration never overwrites the old singleton.
    var legacyInvoiceConfigured:()->Bool = {true}
}
enum NativeCredentialMigrationResult: Equatable {case applied(String),alreadyApplied(String),held(String)}

final class NativeCredentialMigration {
    static let pendingKey="migration.credentials.pending.v1", invoiceKey="migration.invoice.credential.v1"
    let service:CRMService,vault:NativeCredentialMigrationVault
    private let namespace:String
    static func namespace(_ db:NativeDatabase)->String {NativeCredentialMigrationEnvelope.hash(Data(db.url.resolvingSymlinksInPath().standardizedFileURL.path.utf8))}
    init(service:CRMService,vault:NativeCredentialMigrationVault)throws {
        self.service=service;self.vault=vault;namespace=Self.namespace(service.db);try authority()
    }
    private func authority()throws {
        guard !service.db.isReadOnly,service.identity.role=="admin",vault.namespace==namespace,namespace==Self.namespace(service.db) else{throw NativeCredentialMigrationFailure.authority}
        do{try service.authenticated()}catch{throw NativeCredentialMigrationFailure.authority}
    }
    private final class Boundary {var ended=false}
    private func boundary()throws {let p=Boundary();service.db.deferUntilTransactionEnds(onCommit:{p.ended=true},onRollback:{p.ended=true});guard p.ended else{throw NativeCredentialMigrationFailure.conflict}}
    private func pending()throws->[String:NativeCredentialMigrationLease] {
        guard let text=try service.db.metadata(Self.pendingKey),!text.isEmpty else{return [:]}
        guard text.utf8.count<=524_288,let values=try? JSONDecoder().decode([String:NativeCredentialMigrationLease].self,from:Data(text.utf8)),values.count<=1024,values.allSatisfy({$0.key==$0.value.id&&UUID(uuidString:$0.key) != nil&&UUID(uuidString:$0.value.creationToken) != nil&&$0.value.namespace==namespace}) else{throw NativeCredentialMigrationFailure.integrity};return values
    }
    private func put(_ value:[String:NativeCredentialMigrationLease])throws {try service.db.setMetadata(Self.pendingKey,value:String(decoding:JSONEncoder().encode(value),as:UTF8.self))}
    private func row(_ expected:NativeRecord)throws->NativeRecord {
        guard let model=service.db.schema.models.first(where:{$0.name==expected.model}) else{throw NativeCredentialMigrationFailure.format}
        let key=Dictionary(uniqueKeysWithValues:model.primaryKey.map{($0,expected[$0])})
        guard let current=try service.db.get(expected.model,key:key),current.revision==expected.revision,current.values==expected.values else{throw NativeCredentialMigrationFailure.conflict};return current
    }
    private func source(_ entry:NativeCredentialMigrationEnvelope.Entry,_ bytes:Data,_ expected:NativeRecord)throws {
        guard let model=service.db.schema.models.first(where:{$0.name==expected.model}),Set(entry.owner.key.keys)==Set(model.primaryKey),entry.owner.model==expected.model,entry.valueSHA256==NativeCredentialMigrationEnvelope.hash(bytes),entry.owner.key.allSatisfy({expected[$0.key] == .text($0.value)}) else{throw NativeCredentialMigrationFailure.integrity}
    }
    private static func text(_ bytes:Data)throws->String {guard let s=String(data:bytes,encoding:.utf8) else{throw NativeCredentialMigrationFailure.unsupported};return s}
    private static func json(_ value:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    private static func validSecret(_ value:String)->Bool {!value.isEmpty&&value.utf8.count<=16_384&&value.unicodeScalars.allSatisfy{(33...126).contains($0.value)}}
    private static func isHeld(_ value:SQLValue)->Bool {value == .null || value == .text("") || value.string.hasPrefix("m07-held:")}
    private func encrypted(_ raw:Data,key:Data)throws->String {try Self.text(NativeCredentialMigrationEnvelope.decryptServer(Self.text(raw),key:key))}
    private func referenceIsUsed(_ lease:NativeCredentialMigrationLease)throws->Bool {
        let ref=lease.family.prefix+lease.id
        let locations:[(String,String)]=[("ApiKeys","encryptedKey"),("EmailAccount","passwordEncrypted"),("InstalledPlugin","secrets"),("CalendarConnection","refreshTokenEncrypted"),("CalendarConnection","accessTokenEncrypted"),("systemServices","serviceKey"),("crm_SystemSettings","value")]
        for (model,field) in locations {if try service.db.page(model,fields:[],equal:[field:.text(ref)],includeDeleted:true,limit:1).total>0{return true}}
        if let raw=try service.db.metadata(Self.invoiceKey),raw.contains(lease.id){return true}
        if let raw=try service.db.metadata("calendly.control.v1"),raw.contains(lease.id){return true}
        return false
    }
    private func cleanup(_ lease:NativeCredentialMigrationLease)throws {
        try service.db.transaction {
            try authority();var queue=try pending();guard queue[lease.id]==lease else{return}
            if try referenceIsUsed(lease){queue.removeValue(forKey:lease.id);try put(queue);return}
            try vault.removeCreated(lease);queue.removeValue(forKey:lease.id);try put(queue)
        }
    }
    /// Retry only this migration's newly created, unpublished IDs. Never scans
    /// prefixes in a vault or queues/removes any previous source/backup key.
    func retryPendingCleanup()throws->Int {
        try boundary();try authority();let items=try service.db.transaction{try pending().values.sorted{$0.id<$1.id}}
        var removed=0
        for lease in items {try Task.checkCancellation();do{try cleanup(lease);removed+=1}catch NativeCredentialMigrationFailure.authority{throw NativeCredentialMigrationFailure.authority}catch{}}
        return removed
    }
    private func publish(_ expected:NativeRecord,family:NativeCredentialMigrationFamily,field:String,data:Data,
                         additional:[String:SQLValue]=[:],invoice:Bool=false,allowSourceReference:String?=nil,
                         pairedRows:[(NativeRecord,String)]=[],metadataBefore:[String:String?]=[:],metadataAfter:((String)throws->[String:String])?=nil,allowExistingInvoice:Bool=false,validateSource:()throws->Void = {})throws->NativeCredentialMigrationResult {
        try boundary();try Task.checkCancellation();guard data.count<=([NativeCredentialMigrationFamily.plugin,.invoice].contains(family) ? NativeCredentialMigrationEnvelope.maximumValueBytes:65_536) else{return .held("native-value-limit")}
        let already=try service.db.transaction { ()throws->String? in
            try authority();let current=try row(expected),ref=current[field].string
            guard ref.hasPrefix(family.prefix),UUID(uuidString:String(ref.dropFirst(family.prefix.count))) != nil else{return nil}
            let id=String(ref.dropFirst(family.prefix.count));guard try vault.load(family,id:id)==data else{return nil}
            if invoice {guard let binding=try service.db.metadata(Self.invoiceKey),let value=try JSONSerialization.jsonObject(with:Data(binding.utf8)) as? [String:Any],value["id"] as? String==id,value["namespace"] as? String==namespace else{return nil}}
            for (other,key) in pairedRows {guard try row(other)[key] == .text(ref) else{return nil}}
            for (key,before) in metadataBefore {guard try service.db.metadata(key)==before else{throw NativeCredentialMigrationFailure.conflict}}
            return ref
        }
        if let already{return .alreadyApplied(already)}
        let lease=NativeCredentialMigrationLease(id:UUID().uuidString.lowercased(),namespace:namespace,payloadSHA256:NativeCredentialMigrationEnvelope.hash(data),creationToken:UUID().uuidString.lowercased(),family:family)
        let previousInvoice=try service.db.transaction { ()throws->String? in
            try authority();let current=try row(expected)
            if !Self.isHeld(current[field]),current[field].string != allowSourceReference {throw NativeCredentialMigrationFailure.conflict}
            for (other,key) in pairedRows {let value=try row(other)[key];guard Self.isHeld(value) || value.string == allowSourceReference else{throw NativeCredentialMigrationFailure.conflict}}
            for (key,before) in metadataBefore {guard try service.db.metadata(key)==before else{throw NativeCredentialMigrationFailure.conflict}}
            let active=try service.db.metadata(Self.invoiceKey);if invoice,!allowExistingInvoice,let active,!active.isEmpty {throw NativeCredentialMigrationFailure.conflict}
            var queue=try pending();guard queue.count<1024 else{throw NativeCredentialMigrationFailure.cleanup};queue[lease.id]=lease;try put(queue);return active
        }
        do {
            try vault.insert(lease,data:data);try Task.checkCancellation();try validateSource()
            try service.db.transaction {
                try authority();let current=try row(expected);guard try pending()[lease.id]==lease,try vault.load(family,id:lease.id)==data else{throw NativeCredentialMigrationFailure.integrity}
                var changes=additional;changes[field] = .text(family.prefix+lease.id)
                _ = try NativeRecordMutationScope.$bypassHooks.withValue(true) {try service.db.update(current,changes:changes,actor:service.identity.id)}
                for (other,key) in pairedRows {_ = try NativeRecordMutationScope.$bypassHooks.withValue(true) {try service.db.update(row(other),changes:[key:.text(family.prefix+lease.id)],actor:service.identity.id)}}
                for (key,before) in metadataBefore {guard try service.db.metadata(key)==before else{throw NativeCredentialMigrationFailure.conflict}}
                if let metadataAfter {for (key,value) in try metadataAfter(lease.id){try service.db.setMetadata(key,value:value)}}
                if invoice {
                    guard try service.db.metadata(Self.invoiceKey)==previousInvoice else{throw NativeCredentialMigrationFailure.conflict}
                    let binding=try Self.json(["version":1,"id":lease.id,"namespace":namespace,"recordID":current["id"].string,"payloadSHA256":lease.payloadSHA256])
                    try service.db.setMetadata(Self.invoiceKey,value:String(decoding:binding,as:UTF8.self))
                }
                var queue=try pending();queue.removeValue(forKey:lease.id);try put(queue)
            }
            return .applied(family.prefix+lease.id)
        } catch {
            try? cleanup(lease)
            throw NativeCredentialMigrationFailure.conflict
        }
    }
    func migrateGoogle(_ expected:NativeRecord,refresh:(NativeCredentialMigrationEnvelope.Entry,Data),access:(NativeCredentialMigrationEnvelope.Entry,Data)?,serverKey:Data,options:NativeCredentialMigrationOptions)throws->NativeCredentialMigrationResult {
        try boundary();try authority();try source(refresh.0,refresh.1,expected)
        guard expected.model=="CalendarConnection",refresh.0.owner.field=="refreshTokenEncrypted",let access,access.0.owner.field=="accessTokenEncrypted",let client=options.google else{return .held("google-related-token-and-client-required")}
        try source(access.0,access.1,expected)
        guard client.clientID.utf8.count<=512,client.clientID.range(of:#"^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#,options:.regularExpression) != nil,!client.clientID.contains("\n"),client.clientSecret.utf8.count<=4096,!client.clientSecret.unicodeScalars.contains(where:{$0.value<=32||$0.value==127}),["readonly","readwrite"].contains(expected["scopeLevel"].string),UUID(uuidString:expected["userId"].string) != nil else{return .held("google-client-or-owner-binding")}
        let refreshToken:String,accessToken:String
        do{refreshToken=try encrypted(refresh.1,key:serverKey);accessToken=try encrypted(access.1,key:serverKey)}catch{return .held("source-decryption-or-binding")}
        guard Self.validSecret(refreshToken),Self.validSecret(accessToken) else{return .held("google-value")}
        let scope=expected["scopeLevel"].string,email=expected["accountEmail"].string
        guard email.utf8.count<=320,email.split(separator:"@",omittingEmptySubsequences:false).count==2,email.split(separator:"@",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty}),!email.unicodeScalars.contains(where:{$0.value<=32||$0.value==127}) else{return .held("google-account-binding")}
        var grant:[String:Any]=["accountEmail":email,"accessToken":accessToken,"refreshToken":refreshToken,"grantedScopes":scope=="readwrite" ? "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events":"https://www.googleapis.com/auth/calendar.readonly"]
        if expected["tokenExpiresAt"] != .null {let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];let plain=ISO8601DateFormatter();guard let date=f.date(from:expected["tokenExpiresAt"].string) ?? plain.date(from:expected["tokenExpiresAt"].string) else{return .held("google-expiry")};grant["expiresAt"]=date.timeIntervalSinceReferenceDate}
        let payload=try Self.json(["version":1,"connectionID":expected["id"].string,"userID":expected["userId"].string,"client":["clientID":client.clientID,"clientSecret":client.clientSecret],"grant":grant])
        return try publish(expected,family:.google,field:"refreshTokenEncrypted",data:payload,additional:["accessTokenEncrypted":.null])
    }
    func migrateCalendly(token:(NativeRecord,NativeCredentialMigrationEnvelope.Entry,Data),signing:(NativeRecord,NativeCredentialMigrationEnvelope.Entry,Data),serverKey:Data,options:NativeCredentialMigrationOptions)throws->NativeCredentialMigrationResult {
        try boundary();try authority();try source(token.1,token.2,token.0);try source(signing.1,signing.2,signing.0)
        guard token.0.model=="crm_SystemSettings",signing.0.model=="crm_SystemSettings",token.0["key"] == .text("calendly_api_token"),signing.0["key"] == .text("calendly_signing_key"),token.1.owner.field=="value",signing.1.owner.field=="value",let context=options.calendly else{return .held("calendly-pair-and-relay-required")}
        let bindingKey="calendlyRelay.binding.v1",clientKey="calendlyRelay.clientID.v1",controlKey="calendly.control.v1"
        let before=try service.db.transaction {try authority();return [bindingKey:try service.db.metadata(bindingKey),clientKey:try service.db.metadata(clientKey),controlKey:try service.db.metadata(controlKey)]}
        guard let raw=before[bindingKey] ?? nil,let binding=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],binding["publicURL"] as? String==context.publicURL,binding["clientID"] as? String==context.clientID,binding["instanceID"] as? String==context.instanceID,before[clientKey] ?? nil==context.clientID,UUID(uuidString:context.clientID) != nil,UUID(uuidString:context.instanceID) != nil,context.authKey.utf8.count==43,context.authKey.utf8.allSatisfy({(65...90).contains($0)||(97...122).contains($0)||(48...57).contains($0)||$0==45||$0==95}),let url=URLComponents(string:context.publicURL),url.scheme=="https",url.host != nil,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil else{return .held("calendly-receiver-not-bound")}
        if let control=before[controlKey] ?? nil,!control.isEmpty {
            guard let value=try JSONSerialization.jsonObject(with:Data(control.utf8)) as? [String:Any],value["operation"]==nil,value["registration"]==nil else{return .held("calendly-destination-in-use")}
            if let id=value["credentialID"] as? String {guard UUID(uuidString:id) != nil,token.0["value"] == .text(NativeCredentialMigrationFamily.calendly.prefix+id),signing.0["value"]==token.0["value"] else{return .held("calendly-destination-in-use")}}
            else if value["credentialID"] != nil{return .held("calendly-destination-in-use")}
        }
        let apiToken:String,signingKey:String
        do{apiToken=try encrypted(token.2,key:serverKey);signingKey=try encrypted(signing.2,key:serverKey)}catch{return .held("source-decryption-or-binding")}
        guard Self.validSecret(apiToken),!signingKey.isEmpty,signingKey.utf8.count<=16_384,!signingKey.unicodeScalars.contains(where:{$0.value<32||$0.value==127}) else{return .held("calendly-value")}
        let payload=try Self.json(["version":1,"publicURL":context.publicURL,"clientID":context.clientID,"instanceID":context.instanceID,"authKey":context.authKey,"apiToken":apiToken,"signingKey":signingKey])
        return try publish(token.0,family:.calendly,field:"value",data:payload,pairedRows:[(signing.0,"value")],metadataBefore:before,metadataAfter:{id in [controlKey:String(decoding:try Self.json(["version":1,"revision":UUID().uuidString.lowercased(),"credentialID":id]),as:UTF8.self)]})
    }
    func migrate(_ entry:NativeCredentialMigrationEnvelope.Entry,original:Data,expected:NativeRecord,serverKey:Data,options:NativeCredentialMigrationOptions = .init())throws->NativeCredentialMigrationResult {
        try boundary();try authority();try source(entry,original,expected)
        guard entry.kind=="credential" else{return .held("opaque-original-preserved")}
        let field=entry.owner.field
        do {
            switch (expected.model,field) {
            case ("ApiKeys","encryptedKey"):
                let secret=try encrypted(original,key:serverKey),provider=expected["provider"].string,scope=expected["scope"].string
                guard Self.validSecret(secret),["OPENAI","FIRECRAWL","ANTHROPIC","GROQ"].contains(provider),["SYSTEM","USER"].contains(scope),scope != "USER" || UUID(uuidString:expected["userId"].string) != nil else{return .held("ai-binding-or-value")}
                var payload:[String:Any]=["version":1,"recordID":expected["id"].string,"provider":provider,"scope":scope,"key":secret]
                if scope=="USER"{payload["ownerID"]=expected["userId"].string}
                return try publish(expected,family:.ai,field:field,data:Self.json(payload))
            case ("EmailAccount","passwordEncrypted"):
                let secret=try encrypted(original,key:serverKey)
                guard !secret.isEmpty,secret.utf8.count<=16_384,!secret.unicodeScalars.contains(where:{$0.value<32||$0.value==127}) else{return .held("email-value")}
                return try publish(expected,family:.email,field:field,data:Self.json(["version":1,"password":secret]))
            case ("InstalledPlugin","secrets"):
                let plaintext=try NativeCredentialMigrationEnvelope.decryptServer(Self.text(original),key:serverKey)
                guard (try? JSONSerialization.jsonObject(with:plaintext)) is [String:Any] else{return .held("plugin-object")}
                // Preserve unknown keys and exact source JSON bytes; no schema fallback.
                return try publish(expected,family:.plugin,field:field,data:plaintext)
            case ("systemServices","serviceKey") where expected["name"] == .text("resend_smtp"):
                guard options.resendServiceID==expected["id"].string,let from=options.resendSender,from.utf8.count<=320,from.contains("@"),!from.unicodeScalars.contains(where:{$0.value<32||$0.value==127}),!options.legacyInvoiceConfigured() else{return .held("invoice-destination-binding")}
                let stored=try Self.text(original),secret=try stored.hasPrefix("enc:") ? Self.text(NativeCredentialMigrationEnvelope.decryptServer(String(stored.dropFirst(4)),key:serverKey)):stored
                guard !secret.isEmpty,!secret.contains(where:{$0.isWhitespace}) else{return .held("invoice-value")}
                return try publish(expected,family:.invoice,field:field,data:Self.json(["from":from,"apiKey":secret]),invoice:true)
            case ("CalendarConnection",_):return .held("google-related-token-and-client-required")
            case ("crm_SystemSettings",_) where ["calendly_api_token","calendly_signing_key"].contains(expected["key"].string):return .held("calendly-pair-and-relay-required")
            default:return .held("purpose-not-activated")
            }
        } catch NativeCredentialMigrationFailure.key {return .held("server-key-unavailable")}
          catch NativeCredentialMigrationFailure.integrity {return .held("source-decryption-or-binding")}
    }
    /// A native backup contains namespace-specific immutable references. Copy a
    /// verified source payload into a fresh destination ID; never remove source.
    /// Invoice metadata and Calendly pairs use their additional binding methods.
    func rebindNativeBackup(_ expected:NativeRecord,field:String,family:NativeCredentialMigrationFamily,
                            sourceNamespace:String,sourceVault:NativeCredentialMigrationVault,authorizeSource:()throws->Void)throws->NativeCredentialMigrationResult {
        try boundary();try authority();try authorizeSource();guard sourceVault.namespace==sourceNamespace else{throw NativeCredentialMigrationFailure.authority}
        let reference=expected[field].string
        guard reference.hasPrefix(family.prefix),UUID(uuidString:String(reference.dropFirst(family.prefix.count))) != nil else{throw NativeCredentialMigrationFailure.format}
        // Preserve the exact account case for references created by older native stores.
        let id=String(reference.dropFirst(family.prefix.count))
        guard let payload=try sourceVault.load(family,id:id),let object=try JSONSerialization.jsonObject(with:payload) as? [String:Any] else{throw NativeCredentialMigrationFailure.unavailable}
        switch family {
        case .ai:guard expected.model=="ApiKeys",field=="encryptedKey",object["version"] as? Int==1,object["recordID"] as? String==expected["id"].string,object["provider"] as? String==expected["provider"].string,object["scope"] as? String==expected["scope"].string,(object["ownerID"] as? String)==(expected["scope"] == .text("USER") ? expected["userId"].string:nil),let key=object["key"] as? String,Self.validSecret(key) else{throw NativeCredentialMigrationFailure.integrity}
        case .email:guard expected.model=="EmailAccount",field=="passwordEncrypted",object["version"] as? Int==1,let key=object["password"] as? String,!key.isEmpty,key.utf8.count<=16_384,!key.unicodeScalars.contains(where:{$0.value<32||$0.value==127}) else{throw NativeCredentialMigrationFailure.integrity}
        case .plugin:guard expected.model=="InstalledPlugin",field=="secrets" else{throw NativeCredentialMigrationFailure.integrity}
        case .google:
            guard expected.model=="CalendarConnection",field=="refreshTokenEncrypted",expected["provider"] == .text("google"),expected["accessTokenEncrypted"] == .null,object["version"] as? Int==1,object["connectionID"] as? String==expected["id"].string,object["userID"] as? String==expected["userId"].string,let grant=object["grant"] as? [String:Any],grant["accountEmail"] as? String==expected["accountEmail"].string,let access=grant["accessToken"] as? String,let refresh=grant["refreshToken"] as? String,Self.validSecret(access),Self.validSecret(refresh),let client=object["client"] as? [String:Any],client["clientID"] is String,client["clientSecret"] is String else{throw NativeCredentialMigrationFailure.integrity}
            let write=(grant["grantedScopes"] as? String)?.split(separator:" ").contains("https://www.googleapis.com/auth/calendar.events")==true
            guard expected["scopeLevel"] == .text(write ? "readwrite":"readonly") else{throw NativeCredentialMigrationFailure.integrity}
        case .invoice:guard expected.model=="systemServices",field=="serviceKey",expected["name"] == .text("resend_smtp"),object["from"] is String,let key=object["apiKey"] as? String,!key.isEmpty,!key.contains(where:{$0.isWhitespace}) else{throw NativeCredentialMigrationFailure.integrity}
        case .calendly:return .held("native-backup-related-binding-required")
        }
        try authorizeSource();return try publish(expected,family:family,field:field,data:payload,allowSourceReference:reference,validateSource:authorizeSource)
    }
    /// Never activates an old remote registration/unfinished operation. The caller
    /// must bind the destination receiver first; unsupported state remains intact.
    func rebindCalendlyBackup(token:NativeRecord,signing:NativeRecord,sourceNamespace:String,sourceVault:NativeCredentialMigrationVault,authorizeSource:()throws->Void)throws->NativeCredentialMigrationResult {
        try boundary();try authority();try authorizeSource()
        guard sourceVault.namespace==sourceNamespace,token.model=="crm_SystemSettings",signing.model=="crm_SystemSettings",token["key"] == .text("calendly_api_token"),signing["key"] == .text("calendly_signing_key"),token["value"]==signing["value"] else{throw NativeCredentialMigrationFailure.integrity}
        let ref=token["value"].string,prefix=NativeCredentialMigrationFamily.calendly.prefix
        guard ref.hasPrefix(prefix),UUID(uuidString:String(ref.dropFirst(prefix.count))) != nil else{throw NativeCredentialMigrationFailure.format}
        let id=String(ref.dropFirst(prefix.count)),bindingKey="calendlyRelay.binding.v1",controlKey="calendly.control.v1",clientKey="calendlyRelay.clientID.v1"
        guard let data=try sourceVault.load(.calendly,id:id),let payload=try JSONSerialization.jsonObject(with:data) as? [String:Any],payload["version"] as? Int==1 else{throw NativeCredentialMigrationFailure.integrity}
        let before=try service.db.transaction {try authority();_ = try row(token);_ = try row(signing);return [bindingKey:try service.db.metadata(bindingKey),controlKey:try service.db.metadata(controlKey),clientKey:try service.db.metadata(clientKey)]}
        guard let raw=before[bindingKey] ?? nil,let binding=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],let controlRaw=before[controlKey] ?? nil,var control=try JSONSerialization.jsonObject(with:Data(controlRaw.utf8)) as? [String:Any],control["version"] as? Int==1,control["credentialID"] as? String==id,control["operation"]==nil,control["registration"]==nil,
              ["publicURL","clientID","instanceID"].allSatisfy({(binding[$0] as? String) != nil && (binding[$0] as? String)==(payload[$0] as? String)}),before[clientKey] ?? nil==payload["clientID"] as? String else{return .held("calendly-destination-receiver-review")}
        return try publish(token,family:.calendly,field:"value",data:data,allowSourceReference:ref,pairedRows:[(signing,"value")],metadataBefore:before,metadataAfter:{newID in control["credentialID"]=newID;control["revision"]=UUID().uuidString.lowercased();return [controlKey:String(decoding:try Self.json(control),as:UTF8.self)]},validateSource:authorizeSource)
    }
    /// No mutation or fallback on malformed/foreign bindings. Disabled is a
    /// tombstone: the legacy singleton must not silently become active again.
    static func readInvoice(service:CRMService,vault:NativeCredentialMigrationVault)throws->(configured:Bool,data:Data?) {
        try service.authenticated();guard service.identity.role != "partner",vault.namespace==namespace(service.db) else{throw NativeCredentialMigrationFailure.authority}
        guard let text=try service.db.metadata(invoiceKey),!text.isEmpty else{return (false,nil)}
        guard let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],object["version"] as? Int==1,object["namespace"] as? String==vault.namespace else{throw NativeCredentialMigrationFailure.integrity}
        if object["disabled"] as? Bool==true{return (true,nil)}
        guard let id=object["id"] as? String,UUID(uuidString:id) != nil,let payload=try vault.load(.invoice,id:id),NativeCredentialMigrationEnvelope.hash(payload)==object["payloadSHA256"] as? String else{throw NativeCredentialMigrationFailure.integrity}
        return (true,payload)
    }
    func invoicePayload()throws->Data? {try Self.readInvoice(service:service,vault:vault).data}
    /// Immutable settings rotation. Old items (including the legacy singleton)
    /// remain available to old backups; deletion needs a separate retention policy.
    func replaceInvoice(_ data:Data?,expectedBinding:String?,validateSource:()throws->Void = {})throws->String? {
        try boundary();try authority();try Task.checkCancellation()
        guard let data else {
            try service.db.transaction {try authority();guard try service.db.metadata(Self.invoiceKey)==expectedBinding else{throw NativeCredentialMigrationFailure.conflict};try service.db.setMetadata(Self.invoiceKey,value:String(decoding:Self.json(["version":1,"namespace":namespace,"disabled":true]),as:UTF8.self))};return nil
        }
        guard data.count<=65_536,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let from=object["from"] as? String,from.utf8.count<=320,from.range(of:#"^[^\s<>@,;]+@[^\s<>@,;]+$"#,options:.regularExpression) != nil,!from.unicodeScalars.contains(where:{$0.value<32||$0.value==127}),let key=object["apiKey"] as? String,!key.isEmpty,!key.contains(where:{$0.isWhitespace}) else{throw NativeCredentialMigrationFailure.format}
        let lease=NativeCredentialMigrationLease(id:UUID().uuidString.lowercased(),namespace:namespace,payloadSHA256:NativeCredentialMigrationEnvelope.hash(data),creationToken:UUID().uuidString.lowercased(),family:.invoice)
        try service.db.transaction {try authority();guard try service.db.metadata(Self.invoiceKey)==expectedBinding else{throw NativeCredentialMigrationFailure.conflict};var values=try pending();guard values.count<1024 else{throw NativeCredentialMigrationFailure.cleanup};values[lease.id]=lease;try put(values)}
        do {
            try vault.insert(lease,data:data);try Task.checkCancellation();try validateSource()
            try service.db.transaction {try authority();guard try service.db.metadata(Self.invoiceKey)==expectedBinding,try pending()[lease.id]==lease,try vault.load(.invoice,id:lease.id)==data else{throw NativeCredentialMigrationFailure.conflict};try service.db.setMetadata(Self.invoiceKey,value:String(decoding:Self.json(["version":1,"namespace":namespace,"id":lease.id,"payloadSHA256":lease.payloadSHA256]),as:UTF8.self));var values=try pending();values.removeValue(forKey:lease.id);try put(values)}
            return lease.id
        }catch{try? cleanup(lease);throw NativeCredentialMigrationFailure.conflict}
    }
    func rebindInvoiceBackup(sourceNamespace:String,sourceVault:NativeCredentialMigrationVault,authorizeSource:()throws->Void)throws->String? {
        try boundary();try authority();try authorizeSource();guard sourceVault.namespace==sourceNamespace else{throw NativeCredentialMigrationFailure.authority}
        guard let raw=try service.db.metadata(Self.invoiceKey),let binding=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],binding["version"] as? Int==1,binding["namespace"] as? String==sourceNamespace else{throw NativeCredentialMigrationFailure.integrity}
        if binding["disabled"] as? Bool==true{return try replaceInvoice(nil,expectedBinding:raw)}
        guard let id=binding["id"] as? String,UUID(uuidString:id) != nil,let payload=try sourceVault.load(.invoice,id:id),NativeCredentialMigrationEnvelope.hash(payload)==binding["payloadSHA256"] as? String else{throw NativeCredentialMigrationFailure.integrity}
        return try replaceInvoice(payload,expectedBinding:raw,validateSource:authorizeSource)
    }
}
