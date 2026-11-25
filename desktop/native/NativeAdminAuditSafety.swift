import Foundation

/// The writer already removes credential fields and limits seven auth models
/// to their primary keys. Imported business history has no such guarantee, so
/// presentation independently applies an allowlist and never returns raw JSON.
enum NativeAdminAuditSafety {
    static let hiddenModels: Set<String> = ["ApiKeys","ApiToken","Account","Session","Verification","EmailAccount","CalendarConnection","PluginInstallation","InstalledPlugin","PluginLog","PluginData","PluginSecret","crm_SystemSettings","crm_AuditLog"]
    static func sensitive(_ key: String) -> Bool { let k = key.lowercased(); return ["password","token","secret","credential","encrypted","apikey","api_key","authorization","cookie","privatekey","private_key","keychain"].contains { k.contains($0) } }
    static func permits(field: String, model: String, schema: NativeSchema) -> Bool {
        guard !hiddenModels.contains(model), !sensitive(field) else { return false }
        let synthetic: [String:Set<String>] = ["crm_Orders":["lines","decision","plugin"],"crm_Products":["count","plugin"],"crm_Leads":["web_form"]]
        if synthetic[model]?.contains(field) == true { return true }
        guard let value = try? schema.model(model).field(field), !["Json","Bytes"].contains(value.type) else { return false }
        return true
    }
    static func fieldTitle(_ field: String) -> String {
        ["lines":"明細数","decision":"承認結果","plugin":"連携元","count":"取込件数","web_form":"登録フォーム","id":"識別子","name":"名称","first_name":"名","last_name":"姓","firstName":"名","lastName":"姓","email":"メールアドレス","phone":"電話番号","role":"権限","userStatus":"利用状態","banned":"利用停止","isActive":"有効状態","createdAt":"作成日時","updatedAt":"更新日時","createdBy":"作成者","updatedBy":"更新者","deletedAt":"削除日時","deletedBy":"削除者","description":"説明","content":"内容","body":"本文","notes":"メモ","v":"版","code":"コード","symbol":"記号","isDefault":"既定","isEnabled":"有効","stage_kind":"受注時の段階"][field] ?? "その他の項目"
    }
    // A whole scalar is withheld before slicing if it contains common secret
    // carriers. This also catches serialized JSON and cross-chunk credentials.
    static let markers = ["password","token=","token:","secret:","sessionid=","\"token\"","\"secret\"","sk-proj-","sk-ant-","sk_live_","ghp_","github_pat_","xoxb-","access_token","refresh_token","api_key","apikey","client_secret","authorization","bearer ","keychain","credential","private key","session_token","secret=","secret\""]
}
