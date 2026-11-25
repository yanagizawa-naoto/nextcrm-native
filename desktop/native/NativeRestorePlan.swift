import Foundation

struct NativeRestorePlan {
    let db:NativeBackupSQLite;let cancelled:()->Bool
    let emit:(NativeRestorePlanEntry)throws->Void
    func build()throws {
        func row(_ kind:String,_ model:String,_ key:String?=nil,_ field:String?=nil,_ revision:String?=nil,_ state:String?=nil,_ flags:[String]=[],_ count:Int64=1,_ action:String,_ event:String?=nil)throws {
            guard key.map({$0.utf8.count<=4096}) ?? true,field.map({$0.utf8.count<=1024}) ?? true,event.map({$0.utf8.count<=1024}) ?? true else{throw NativeMigrationFailure("restore.plan_limit","再開計画の識別情報が上限を超えています。")}
            try emit(.init(kind:kind,model:model,key:key,field:field,revision:revision,state:state,flags:flags,count:count,action:action,event:event))
        }
        for (model,fields) in [("ApiKeys",["encryptedKey"]),("EmailAccount",["passwordEncrypted"]),("CalendarConnection",["accessTokenEncrypted","refreshTokenEncrypted"]),("InstalledPlugin",["secrets"]),("systemServices",["servicePassword"])] {
            for field in fields {
                let q=NativeBackupSQLite.quote(field)
                let scheme="CASE WHEN \(q) LIKE 'native-ai-keychain:%' OR \(q) LIKE 'native-keychain:%' OR \(q) LIKE 'native-plugin-keychain:%' OR \(q) LIKE 'keychain:v1:%' THEN 'native-reference' ELSE 'opaque-legacy' END"
                try db.rows("SELECT id,_native_revision revision,\(scheme) scheme FROM \(NativeBackupSQLite.quote(model)) WHERE \(q) IS NOT NULL AND length(\(q))>0",cancelled:cancelled){r in
                    try row("credential",model,r["id"] ?? nil,field,r["revision"] ?? nil,r["scheme"] ?? nil,[],1,"最終配置先のKeychain参照または旧暗号形式を確認し、欠けた鍵は復旧・再入力してください。")
                }
            }
        }
        try db.rows("SELECT key,length(value) bytes FROM native_metadata ORDER BY key",cancelled:cancelled){r in
            guard let key=r["key"] ?? nil else{return}
            let kind:String,action:String
            if key.hasPrefix(NativeCredentialArchiveBinding.prefix){kind="credentialArchive";action="暗号化された元の値と保留inventoryを保持し、snapshot・配置先namespace・鍵を確認するまで適用や連携を開始しないでください。"}
            else if key.hasPrefix("mail.sync.cursor.") {kind="mailCursor";action="UIDVALIDITY・mailbox・接続先を照合し、cursorを勝手にリセットしないでください。"}
            else if key.hasPrefix("campaignRelay.") || key.hasPrefix("calendlyRelay."){kind="relayBinding";action="receiverのinstance/client/headと保存cursorを照合してください。"}
            else if key.contains("cleanup") || key.hasPrefix("mail.orphanCredential."){kind="credentialCleanup";action="参照鍵の復旧とnamespace確認が完了するまでcleanupを停止してください。"}
            else if key.hasPrefix("mcp.") || key.hasPrefix("calendar.google.") || key.hasPrefix("calendly."){kind="serviceSetting";action="保存設定・署名鍵・認証中状態を確認し、明示的な再開方針が決まるまでlistenerや連携を起動しないでください。"}
            else{return}
            try row(kind,"native_metadata",key,nil,nil,nil,[],1,action)
        }
        try db.rows("""
        SELECT id,event,status,lease_token IS NOT NULL OR lease_until IS NOT NULL leased,
          delivery_started_at IS NOT NULL begun,
          CASE WHEN json_valid(result) THEN json_extract(result,'$.providerID') IS NOT NULL OR json_extract(result,'$.smtpAccepted')='true' OR json_extract(result,'$.requestOutcome')='confirmed' ELSE 0 END receipt
        FROM native_outbox ORDER BY rowid
        """,cancelled:cancelled){r in
            let state=(r["status"] ?? nil) ?? "unknown",event=(r["event"] ?? nil) ?? "unknown";var flags:[String]=[]
            let terminal=["done","cancelled"].contains(state)
            if (r["leased"] ?? nil) == "1"{flags.append("leaseOwnership")}
            if (r["begun"] ?? nil) == "1"{flags.append((r["receipt"] ?? nil) == "1" ? "receiptRecorded":"deliveryUnknown")}
            if state=="needs_review"{flags.append("existingReview")}
            if !["pending","retry","running","failed","needs_review","done","cancelled"].contains(state){flags.append("unknownState")}
            if event.hasPrefix("plugin/") || event.hasPrefix("plugins/"){flags.append("pluginExternalState")}
            try row(terminal ? "terminalReceipt":"job","native_outbox",r["id"] ?? nil,"event",nil,state,flags,1,terminal ? "完了・取消状態とreceiptを維持してください。再送を生成しません。":"元jobとlease・送信結果を個別に照合し、許可された処理だけを明示的に再開してください。",event)
        }
        for (table,kind,action) in [
            ("native_ai_key_cleanup","credentialCleanup","過去鍵の回収予約を保持し、鍵の復旧前にcleanupを再開しないでください。"),
            ("native_campaign_events","eventReceipts","受信receiptと未処理イベントを保持し、relay履歴の照合後に再開してください。"),
            ("native_campaign_relay_registrations","relayRegistrations","送信IDとreceiver/providerの登録・配信停止を照合してください。"),
            ("native_mail_sends","mailPayloads","保存MIME・Message-ID・SMTP受理結果を維持してください。"),
            ("PluginData","pluginState","外部ID・cursor・claim/TTL・受注状態をproviderと照合し、既存claimを一括削除しないでください。"),
            ("native_document_ai_work","localWork","元job・文書revision・計算結果の対応を確認してから処理を再開してください。")
        ] where try db.exists(table) {
            let count=Int64(try db.first("SELECT COUNT(*) FROM "+NativeBackupSQLite.quote(table)) ?? "0") ?? 0
            if count>0{try row(kind,table,nil,nil,nil,nil,[],count,action)}
        }
        try row("keychainOnlySettings","environment",nil,nil,nil,nil,[],1,"請求書メール・campaign relay等のKeychainのみの設定はDBに含まれません。元環境と最終配置先で別途確認してください。")
    }
}
