import Foundation
import CryptoKit

/// Read-only verification is deliberately separate from an explicit restoration
/// review. This service never constructs a runtime, invokes a provider, or grants
/// permission to claim a job. The existing Host owns that final decision.
final class NativePersonalRuntimePrerequisites {
    typealias Requirement = NativePersonalRuntimeRequirement
    struct Stores {
        let databaseURL:URL
        let mail:NativeMailSecretStore, invoice:InvoiceMailCredentialStore
        let google:GoogleCalendarSecretStore, calendly:CalendlySecretStore
        let campaign:CampaignRelayCredentialStore, ai:NativeAISecretStore, mcp:NativeMCPSecretStore
        let plugins:NativePluginSecretStore, pluginDefinitions:[NativePluginDefinition]
        let environment:NativeAIEnvironment
    }
    enum Choice:String,Codable,CaseIterable {
        case continueReviewed, pauseSources, futureOnly, protectCleanup
        var title:String {
            switch self {
            case .continueReviewed:return "現在の接続先と保存状態を確認して引き継ぐ"
            case .pauseSources:return "復元前の予約・接続を停止した状態で引き継ぐ"
            case .futureOnly:return "復元前の未実行分は保留し、今後の予定から再開する"
            case .protectCleanup:return "復元前の認証情報の整理を保留する"
            }
        }
    }
    struct Prompt:Codable,Equatable {
        let requirement:Requirement,subjectSHA256:String,title:String
        let configured:Int64,oldJobs:Int64,ambiguousJobs:Int64
        let notes:[String],choices:[Choice],validUntil:Date
    }
    struct Receipt:Codable,Equatable {
        let version:Int,requirement:Requirement,bindingSHA256:String
        let configurationSHA256:String,choice:Choice,reviewedAt:Date
        let oldJobs:Int64,archivedStates:Int64
        let oldSourceReviewPending:Bool
    }
    struct Facts {
        var hash=SHA256(),count:Int64=0,notes:[String]=[]
        mutating func add(_ label:String,_ values:[String]) {
            for s in [label]+values { let b=Data(s.utf8);hash.update(data:Data(String(b.count).utf8));hash.update(data:Data([58]));hash.update(data:b) }
            count += 1
        }
        var digest:String {hash.finalize().map{String(format:"%02x",$0)}.joined()}
    }
    let service:CRMService,startup:NativeRestoreApplicationStartup,personal:NativePersonalRestoreAdmission.Record,stores:Stores
    let clock:()->Date
    var db:NativeDatabase {service.db}
    static let prefix="personal.restore.prerequisite.v1."
    init(service:CRMService,startup:NativeRestoreApplicationStartup,personal:NativePersonalRestoreAdmission.Record,stores:Stores,clock:@escaping()->Date) throws {
        self.service=service;self.startup=startup;self.personal=personal;self.stores=stores;self.clock=clock
        guard stores.databaseURL.resolvingSymlinksInPath().standardizedFileURL == service.db.url.resolvingSymlinksInPath().standardizedFileURL else {throw NativeDBError.conflict}
        _ = try authority()
    }
    @discardableResult func authority()throws->String {
        try Task.checkCancellation();try NativePersonalRestoreAdmission.validate(personal,startup:startup)
        guard personal.phase == .bound,!db.isReadOnly,service.identity.id==personal.owner.ownerID else{throw NativeDBError.conflict}
        try service.authenticated()
        let q=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:personal)
        return try NativePersonalRestoreAdmission.hash(q.requireReady())
    }
    func domainAuthority(_ r:Requirement)throws {
        try service.authenticated()
        switch r {
        case .allEnabledPluginsAndSchedules,.campaignRelay,.calendlySubscriptionsAndRelay,.crmAutomationSchedules,.ecbSettings,.mcpCredentialsAndListener,.maintenanceOwnership:
            guard service.identity.role=="admin" else{throw NativeDBError.message("この機能の設定確認には管理者権限が必要です。")}
        case .resendSender:
            guard service.identity.role != "partner" else{throw NativeDBError.message("メール送信の設定を利用する権限がありません。")}
        default:break
        }
    }
    var reportScope:RecordFilter {service.identity.elevated ? .all:.equal("createdBy",.text(service.identity.id))}
    static func title(_ r:Requirement)->String {
        switch r {
        case .imapSMTPAccountsAndCursors:return "メールアカウントと受信位置"
        case .resendSender:return "通知メールの差出人"
        case .reportSchedules:return "定期レポートの予約"
        case .campaignSchedules:return "キャンペーンの予約"
        case .campaignRelay:return "キャンペーンの受信窓口"
        case .googleConnectionsAndCursors:return "Googleカレンダーの接続と同期位置"
        case .calendlySubscriptionsAndRelay:return "Calendlyの通知登録と受信窓口"
        case .openAI:return "OpenAIの接続設定"
        case .e2b:return "AI調査の実行環境"
        case .aiOutstandingWork:return "復元前のAI処理"
        case .credentialCleanupOwnership:return "古いAI認証情報の整理"
        case .allEnabledPluginsAndSchedules:return "プラグインの設定と予約"
        case .crmAutomationSchedules:return "CRM自動処理の日程"
        case .documentPendingWork:return "文書と未完了の処理"
        case .ecbSettings:return "為替レートの更新設定"
        case .mcpCredentialsAndListener:return "MCP接続の設定"
        case .maintenanceOwnership:return "保存途中ファイルの整理"
        }
    }
    func choices(_ r:Requirement)->[Choice] {
        switch r {
        case .reportSchedules:return [.pauseSources,.futureOnly]
        case .campaignSchedules:return [.pauseSources]
        case .crmAutomationSchedules:return [.futureOnly]
        case .credentialCleanupOwnership:return [.protectCleanup]
        case .imapSMTPAccountsAndCursors,.googleConnectionsAndCursors,.allEnabledPluginsAndSchedules,.ecbSettings,.mcpCredentialsAndListener:return [.continueReviewed,.pauseSources]
        default:return [.continueReviewed]
        }
    }
    func inspect(_ requirement:Requirement)throws->Prompt {
        try db.transaction {
            let binding=try authority(),facts=try configuration(requirement,checkCredentials:false),old=try oldJobs(requirement)
            let pendingSource=try sourceReviewPending(requirement)
            let now=clock();guard now.timeIntervalSince1970.isFinite else{throw NativeDBError.conflict}
            let expiry=now.addingTimeInterval(300),options=choices(requirement)
            let subject=try NativePersonalRestoreAdmission.hash(["binding":binding,"requirement":requirement.rawValue,"configuration":facts.digest,"old":String(old.count),"ambiguous":String(old.ambiguous),"pendingSource":String(pendingSource),"validUntil":String(expiry.timeIntervalSince1970)])
            var notes=facts.notes
            notes.append("復元前の処理履歴と送信結果は保持され、自動再送しません。")
            if pendingSource{notes.append("連携先での結果が不明な処理が残っています。設定を停止して保存しても、結果の確認が済むまでは自動処理を再開しません。")}
            if old.ambiguous>0{notes.append("結果が不明な処理があります。未確認の送信・連携は再実行せず、停止対象の連携と処理状況を確認してください。")}
            return Prompt(requirement:requirement,subjectSHA256:subject,title:Self.title(requirement),configured:facts.count,oldJobs:old.count,ambiguousJobs:old.ambiguous,notes:notes,choices:options,validUntil:expiry)
        }
    }
    /// Caller obtains a real UI decision for this exact Prompt. This method does
    /// not infer approval from a settings save or from elapsed time.
    @discardableResult func review(_ prompt:Prompt,choice:Choice,confirmedSubject:String,checkpoint:(String)throws->Void={_ in})throws->Receipt {
        try db.requireRestoredJobQuarantineBoundary()
        return try db.transaction {
            let binding=try authority();guard confirmedSubject==prompt.subjectSHA256,clock()<prompt.validUntil,clock()>=prompt.validUntil.addingTimeInterval(-300),prompt.choices==choices(prompt.requirement),prompt.choices.contains(choice) else{throw NativeDBError.conflict}
            let facts=try configuration(prompt.requirement,checkCredentials:false),old=try oldJobs(prompt.requirement)
            let pendingSource=try sourceReviewPending(prompt.requirement)
            let subject=try NativePersonalRestoreAdmission.hash(["binding":binding,"requirement":prompt.requirement.rawValue,"configuration":facts.digest,"old":String(old.count),"ambiguous":String(old.ambiguous),"pendingSource":String(pendingSource),"validUntil":String(prompt.validUntil.timeIntervalSince1970)])
            guard subject==prompt.subjectSHA256 else{throw NativeDBError.conflict}
            // Holding sources is useful even while remote results remain unknown.
            // It produces a review record, not a successful worker prerequisite.
            if pendingSource,choice != .pauseSources{throw NativeDBError.message("プラグインに復元前の送信待ち・処理権があります。連携の処理状況で結果を確認してください。")}
            let archived=try apply(prompt.requirement,choice:choice);try checkpoint("applied")
            let after=try configuration(prompt.requirement,checkCredentials:choice != .pauseSources)
            let receipt=Receipt(version:1,requirement:prompt.requirement,bindingSHA256:binding,configurationSHA256:after.digest,choice:choice,reviewedAt:clock(),oldJobs:old.count,archivedStates:archived,oldSourceReviewPending:try sourceReviewPending(prompt.requirement))
            try db.setMetadata(Self.prefix+prompt.requirement.rawValue,value:String(decoding:JSONEncoder().encode(receipt),as:UTF8.self))
            try checkpoint("recorded");_ = try authority();return receipt
        }
    }
    func verify(_ requirement:Requirement,_ prior:NativePersonalRuntimeResumption.RequirementEvidence?,_ current:CRMService)throws->NativePersonalRuntimeResumption.RequirementEvidence {
        guard current === service else{throw NativeDBError.conflict}
        return try db.transaction {
            let binding=try authority()
            guard let text=try db.personalPrerequisiteReceipt(requirement.rawValue),let value=try? JSONDecoder().decode(Receipt.self,from:Data(text.utf8)),value.version==1,value.requirement==requirement,value.bindingSHA256==binding,choices(requirement).contains(value.choice) else{throw NativeDBError.message("この機能の接続設定と復元前の処理を確認してください。")}
            // Only quarantined old IDs are checked. New task/cursor progress is
            // never part of the approval digest and cannot invalidate it.
            guard !value.oldSourceReviewPending,try !hasAmbiguous(requirement) else{throw NativeDBError.message("復元前の送信・外部処理の結果が不明です。この機能は確認が終わるまで停止します。")}
            guard try configuration(requirement,checkCredentials:true).digest==value.configurationSHA256 else{throw NativeDBError.message("接続設定が変更されています。復元後の利用設定を再確認してください。")}
            let result=NativePersonalRuntimeResumption.RequirementEvidence(requirement:requirement,referenceSHA256:try NativePersonalRestoreAdmission.hash(value))
            guard prior==nil || prior==result else{throw NativeDBError.conflict};return result
        }
    }
    /// Factory captures no old CRMService/DB. Host commit/cold-open supplies its
    /// current service after draining the old workspace. Stores must be created
    /// for that exact current database namespace, never the source backup root.
    static func verifier(startup:NativeRestoreApplicationStartup,personal:NativePersonalRestoreAdmission.Record,
                         stores:@escaping(CRMService)throws->Stores,clock:@escaping()->Date)->NativePersonalRuntimeResumption.VerifyRequirement {
        { requirement,prior,service in
            let instance=try Self(service:service,startup:startup,personal:personal,stores:stores(service),clock:clock)
            return try instance.verify(requirement,prior,service)
        }
    }
    func rows(_ model:String,fields:[String],filter:RecordFilter = .all,_ visit:(NativeRecord)throws->Void)throws {
        var after:String?
        while true {try Task.checkCancellation();let page=try db.keysetPage(model,fields:fields,after:after,filter:filter)
            for row in page{try visit(row)};if page.count<100{return};after=page.last!["id"].string
        }
    }
    func addRows(_ model:String,fields:[String],filter:RecordFilter = .all,into facts:inout Facts,validate:(NativeRecord)throws->Void={_ in})throws {
        try rows(model,fields:fields,filter:filter){row in try validate(row);facts.add(model,[row["id"].string]+fields.flatMap{[$0,row[$0] == .null ? "null":"value",row[$0].string]})}
    }
}
