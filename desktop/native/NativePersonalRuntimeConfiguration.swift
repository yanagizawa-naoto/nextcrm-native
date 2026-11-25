import Foundation
import Darwin

extension NativePersonalRuntimePrerequisites {
    func configuration(_ requirement:Requirement,checkCredentials:Bool)throws->Facts {
        try domainAuthority(requirement);var f=Facts()
        switch requirement {
        case .imapSMTPAccountsAndCursors:
            let fields=["userId","label","username","imapHost","imapPort","imapSsl","smtpHost","smtpPort","smtpSsl","allowSelfSignedTls","sentFolderName","isActive"]
            try addRows("EmailAccount",fields:fields,into:&f){row in
                guard row["isActive"] == .integer(1) else{return}
                guard row["userId"] == .text(service.identity.id) else{throw NativeDBError.message("別の利用者のメール接続があります。元の利用者の設定を確認してください。")}
                let current=try service.mailAccount(row["id"].string),settings=try service.mailSettings(current);try settings.validate()
                let ref=try CRMService.mailCredentialID(current)
                if checkCredentials{_ = try service.mailCredential(current,store:stores.mail)}
                // Credential identity is added separately; synchronization updates
                // row revisions/UID fields without changing this configuration.
                _ = ref
            }
            try rows("EmailAccount",fields:["passwordEncrypted","isActive"],filter:.equal("isActive",.integer(1))){row in
                f.add("mail-reference",[row["id"].string,try CRMService.mailCredentialID(row)])
            }
            f.notes=["受信位置は保持します。次回同期で既存のUIDVALIDITY・接続先の照合を行い、不一致なら既存処理が再取得を判断します。"]
        case .resendSender:
            if let account=try stores.invoice.load(interactive:false) {
                let sender=try InvoiceMail.mailbox(account.from)
                guard !account.apiKey.isEmpty,!account.apiKey.contains(where:{$0.isWhitespace}) else{throw NativeDBError.message("通知メールの接続キーを保存し直してください。")}
                f.add("resend",[sender])
            }
            f.notes=["未設定の場合は通知メールを送信しません。保存済みの差出人と現在のMacの接続キーを確認します。"]
        case .reportSchedules:
            try addRows("crm_Report_Schedule",fields:["reportConfigId","cronExpression","recipients","format","isActive","createdBy"],filter:reportScope,into:&f){row in
                guard row["isActive"] == .integer(1) else{return}
                _ = try NativeReportSchedules(service:service).load(row["id"].string)
            }
            try rows("crm_Report_Schedule",fields:[],filter:reportScope){row in f.add("report-generation",[row["id"].string,try db.reportScheduleState("generation",id:row["id"].string) ?? "",try db.reportScheduleState("timezone",id:row["id"].string) ?? ""])}
            f.notes=["復元前の未送信分は再送せず、予約を停止するか、現在時刻より後の最初の予定を作り直します。"]
        case .campaignSchedules:
            // status/sent_at are normal worker progress. User-controlled content
            // and run generation identify the approved schedule, not its cursor.
            try addRows("crm_campaigns",fields:["name","from_name","reply_to","template_id","scheduled_at","created_by"],filter:service.scope("crm_campaigns"),into:&f)
            try rows("crm_campaigns",fields:[],filter:service.scope("crm_campaigns")){row in f.add("campaign-run",[row["id"].string,try db.metadata(CampaignWorkflow.runKey(row["id"].string)) ?? ""])}
            f.notes=["予約済み・配信中のキャンペーンは一時停止します。履歴を確認後、キャンペーン画面で必要なものだけ再予約してください。"]
        case .campaignRelay:
            if let binding=try CampaignRelayBinding.load(db:db) {
                f.add("campaign-relay",[binding.publicURL,binding.clientID,binding.instanceID])
                if checkCredentials {
                    guard let secret=try stores.campaign.load(interactive:false),secret.publicURL==binding.publicURL,secret.clientID==binding.clientID,secret.instanceID==binding.instanceID,!secret.authKey.isEmpty else{throw NativeDBError.message("キャンペーンの受信窓口を現在のMacで設定し直してください。")}
                    _ = try secret.configuration()
                }
            }
            f.notes=["受信済みの履歴と接続先を保持します。受信位置の通常の前進でこの確認は失効しません。"]
        case .googleConnectionsAndCursors:
            if let ref=try service.googleCalendarClientReference(){f.add("google-client",[ref.id,ref.clientID])}
            try addRows("CalendarConnection",fields:["provider","userId","accountEmail","scopeLevel","isActive"],filter:.equal("provider",.text("google")),into:&f){row in
                if row["isActive"] == .integer(1){
                    guard row["userId"] == .text(service.identity.id) else{throw NativeDBError.message("別の利用者のGoogle接続があります。接続の所有者を確認してください。")}
                    if checkCredentials{_ = try service.googleCalendarGrant(service.googleCalendarConnection(row["id"].string),store:stores.google)}
                }
            }
            // Token refresh publishes a fresh immutable credential reference.
            // Validate its shape/availability, but bind the stable connection,
            // account, client and granted scope instead of a rotating secret ID.
            try rows("CalendarConnection",fields:["refreshTokenEncrypted"],filter:.every([.equal("provider",.text("google")),.equal("isActive",.integer(1))])){row in
                guard let ref=GoogleCalendarStorage.itemID(row["refreshTokenEncrypted"]) else{throw NativeDBError.message("Google接続を現在のMacで接続し直してください。")};_ = ref
            }
            f.notes=["保存された同期位置を保持します。同期トークンが期限切れの場合は既存の全件再同期経路を使います。書込み結果が不明な予定は先に確認してください。"]
        case .calendlySubscriptionsAndRelay:
            let state=try service.calendlyControl()
            guard state.operation==nil else{throw NativeDBError.message("Calendlyの通知登録が未完了です。通知登録画面で結果を確認してください。")}
            f.add("calendly",[state.revision,state.credentialID ?? "",state.registration?.uri ?? "",state.registration?.organization ?? "",state.registration?.callbackURL ?? ""])
            if let b=try CalendlyRelayBinding.load(db:db){f.add("calendly-relay",[b.publicURL,b.clientID,b.instanceID])}
            if checkCredentials,state.credentialID != nil {
                let value=try service.calendlyCredentials(state,store:stores.calendly)
                _ = try value.relay(db:db,request:{_ in throw NativeDBError.conflict}) // constructor only; no request
            }
            f.notes=["通知登録と受信位置は保持します。登録結果が不明な場合、この機能の再開は保留します。"]
        case .openAI:
            let keys=NativeAIKeys(service:service,store:stores.ai,environment:stores.environment,clock:clock)
            if let key=try keys.resolve(.openai) {
                f.add("openAI",[key.choice.source.rawValue,key.choice.row?.id ?? "",key.choice.row?.credentialID ?? "",key.choice.row.map{String($0.revision)} ?? ""])
            }
        case .e2b:
            let settings=NativeE2BSettings(service:service,store:stores.ai,environment:stores.environment,clock:clock)
            if let value=try settings.resolve(){f.add("e2b",[value.choice.source.rawValue,value.choice.credentialID ?? "",value.template,value.configuration.domain,value.configuration.apiURL.absoluteString,value.configuration.sandboxURL?.absoluteString ?? "",String(value.configuration.debug)])}
        case .aiOutstandingWork:
            // Old outbox and its durable partial chunks stay linked and held.
            f.notes=["復元前のAI処理と途中の結果は保持します。新しい調査・処理は別の処理として開始できます。"]
        case .credentialCleanupOwnership:
            f.notes=["復元前のキー整理予約を削除禁止にします。新しく登録したキーの整理だけを通常どおり続けます。"]
        case .allEnabledPluginsAndSchedules:
            try rows("InstalledPlugin",fields:["status","version","settings","secrets"]){row in
                let id=row["id"].string
                guard row["status"] == .text("ENABLED") else {
                    // An unused connector need not have a currently available
                    // account/key. Enabling it changes this stable identity.
                    f.add("plugin-unused",[id,row["status"].string,row["version"].string,String(row.revision)]);return
                }
                guard let definition=stores.pluginDefinitions.first(where:{$0.id==id}) else{throw NativeDBError.message("このMacに定義がないプラグインがあります。設定を確認してください。")}
                let values=try definition.settings.parse(NativePluginJSON.parse(row["settings"].string))
                let encoded=try NativePluginJSON.text(values)
                let reference=row["secrets"] == .null ? "":row["secrets"].string
                guard reference.isEmpty || NativePluginCredentialVault.valid(reference) else{throw NativeDBError.message("プラグインの接続キーを現在のMacで保存し直してください。")}
                f.add("plugin",[id,row["status"].string,row["version"].string,String(row.revision),encoded,reference])
                if row["status"] == .text("ENABLED"),checkCredentials {
                    let secrets:NativePluginRecord=reference.isEmpty ? [:]:try stores.plugins.read(reference)
                    _ = try definition.secrets.parse(secrets)
                }
            }
            f.notes=["プラグインの外部ID・同期位置は保持します。旧同期・比較の実行予約は保留して記録し、次回の通常日程から再開します。復元前の送信待ちや処理権が残る場合は、連携側の結果確認が必要です。"]
        case .crmAutomationSchedules:
            let settings=try NativeCRMAutomationSettings.load(db)
            f.add("funnel",[try NativePersonalRestoreAdmission.hash(settings)])
            f.notes=["復元前の実行待ちは保留し、次回の通常日程から自動処理を再開します。新しい処理が通知メールを作る場合も、送信には通知メール機能の別の許可が必要です。"]
        case .documentPendingWork:
            f.notes=["復元前の文書処理は保留したまま、元ファイルと途中結果を保持します。必要な文書は文書画面から個別に再処理できます。"]
        case .ecbSettings:
            let s=try NativeCurrencyAdministration(service:service).settings();f.add("ecb",[String(s.enabled),s.revision.map(String.init) ?? "",s.defaultCode ?? ""])
        case .mcpCredentialsAndListener:
            let s=try NativeMCPSettingsStore.read(db:db);f.add("mcp",[String(s.enabled),String(s.port),String(s.maximumConnections),String(s.revision),s.bucket,s.credentialID ?? "",s.configuredBy ?? ""])
            if checkCredentials,s.enabled{_ = try NativeMCPSettingsStore.signingSecret(expected:s,db:db,store:stores.mcp)}
            f.notes=["有効な場合だけ、このMacのループバック接続を開始できます。署名キーは現在のMacの保存先で確認します。"]
        case .maintenanceOwnership:
            try requirePrivateRecoveryRoot()
            f.notes=["現在のデータフォルダの所有記録だけを使用し、復元元の保存先や完成済みバックアップは整理対象にしません。"]
        }
        return f
    }
    func requirePrivateRecoveryRoot()throws {
        let url=db.url.deletingLastPathComponent().appendingPathComponent(".native-maintenance-recovery")
        var s=stat();if lstat(url.path,&s) != 0 {if errno==ENOENT{return};throw NativeDBError.conflict}
        guard s.st_mode&S_IFMT==S_IFDIR,s.st_uid==geteuid(),s.st_mode&0o077==0 else{throw NativeDBError.message("保存途中ファイルの保全フォルダを確認してください。")}
        // The actual registry rechecks marker, parent inode and live leases. This
        // read-only preflight grants no removal authority and opens no registry.
    }
    /// Only explicit inspect/review reads restored connector source state. A
    /// saved pending flag prevents disabled sources from bypassing review, while
    /// normal post-approval claims/cursors do not revoke a valid receipt.
    func sourceReviewPending(_ requirement:Requirement)throws->Bool {
        guard requirement == .allEnabledPluginsAndSchedules else{return false}
        var pending=false
        // Explicitly disabled built-in connectors have no cron/after/action
        // ingress. Bind their status/revision in configuration(), retain every
        // old row, and require a new review before any later enable.
        var held=Set<String>()
        try rows("InstalledPlugin",fields:["status"],filter:.equal("status",.text("DISABLED"))){row in
            if ["odoo-connector","oxo-erp-connector"].contains(row["id"].string){held.insert(row["id"].string)}
        }
        try rows("PluginData",fields:["pluginId","key","value"]){row in
            if held.contains(row["pluginId"].string){return}
            let key=row["key"].string
            if ["sending:","send:","delivery:","address:","claim:","job:order:","intent:"].contains(where:key.hasPrefix) {pending=true;return}
            guard key.hasPrefix("customer:") else{return}
            guard let value=try NativePluginJSON.parse(row["value"].string) as? NativePluginRecord else{pending=true;return}
            if value["until"] != nil {pending=true;return}
            // OXO's durable customer link and Odoo's completed customer report
            // share the prefix used by Odoo's short-lived creation claim.
            if row["pluginId"] == .text("oxo-erp-connector"),
               let id=value["accountId"] as? String,!id.isEmpty {return}
            if row["pluginId"] == .text("odoo-connector"),
               let at=value["at"] as? String,(try? NativePluginJSON.date(at)) != nil,
               value["invoices"] is [Any],value["totals"] is [Any] {return}
            pending=true
        }
        return pending
    }
}
