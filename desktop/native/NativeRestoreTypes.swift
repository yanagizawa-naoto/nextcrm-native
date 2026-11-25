import Foundation

enum NativeRestoreStatus:String,Codable {case staged,failed,cancelled}
struct NativeRestoreObligation:Codable {
    let kind:String;let resolution:String;let evidence:String
}
struct NativeRestoreActivationGate:Codable {
    let phase:String
    let obligations:[NativeRestoreObligation]
    // This is a handoff to a separate activation transaction, not a permanent ban.
    static let review=NativeRestoreActivationGate(phase:"requiresActivationReview",obligations:[
        .init(kind:"sourceProvenance",resolution:"authorizedSnapshotSelection",evidence:"権限のある利用者が信頼できるsnapshotを指定した記録。署名のないhash一致だけでは作成元を確認できません。"),
        .init(kind:"stopAndSwitch",resolution:"exclusiveApplicationRootSwitch",evidence:"全writer・listener・workerの停止完了、旧/新rootの排他、失敗時の戻し先を記録してください。"),
        .init(kind:"candidateRevalidation",resolution:"recheckAtActivation",evidence:"切替の排他中にsnapshot ID・schema revision・DB/添付/計画のhash・最終保存先の識別情報を再確認してください。"),
        .init(kind:"credentials",resolution:"finalNamespaceCredentialBinding",evidence:"最終DBパスのnamespaceで各参照鍵を確認し、欠けた旧鍵を復旧・再入力してください。Keychainのみの設定も確認し、完了までcleanupを停止してください。"),
        .init(kind:"jobs",resolution:"perJobOutcomeReconciliation",evidence:"queueとreceiptを保持し、未確定の送信結果・lease所有者を外部の証跡と既存の個別確認機能で照合してください。再開を許可するruntime/eventを記録してください。"),
        .init(kind:"relayAndPluginState",resolution:"verifyExternalHistory",evidence:"再開前に受信側のinstance/client/head/cursor、IMAP UIDVALIDITY、連携先ID・TTL claimを実サービスと照合してください。"),
        .init(kind:"pendingAssets",resolution:"resolveBackupPendingScopes",evidence:"backupの未解決項目、外部添付、旧原画像、metadata不足を確認し、復元を認める範囲を記録してください。"),
        .init(kind:"runtimeStartup",resolution:"explicitResumePolicy",evidence:"activation工程で確認済みの起動方針を明示してください。この準備工程はruntimeを起動せず、自動再送も許可しません。")])
}
struct NativeRestoreResult:Codable {
    var formatVersion=1;var status:NativeRestoreStatus = .failed;var candidateCreated=false
    var activated=false;var workersStarted=false;var keychainAccessed=false
    var snapshotID="",sourceNamespaceSHA256="",stagingNamespaceSHA256="",schemaSHA256=""
    var databaseSHA256="",filesManifestSHA256="",tablesManifestSHA256="",backupManifestSHA256="",resumePlanSHA256=""
    var databaseBytes:Int64=0,tableCount:Int64=0,totalRows:Int64=0,fileCount:Int64=0,totalFileBytes:Int64=0,planRows:Int64=0
    var planCounts:[String:Int64]=[:];var inheritedPending:[NativeBackupPending]=[]
    var activationGate=NativeRestoreActivationGate.review
    var diagnostics:[NativeMigrationDiagnostic]=[]
    var limitations=["復元候補の準備です。稼働アプリの切替・送信・worker再開は行っていません。","Keychainや外部サービスを検証していません。最終配置先のnamespace・過去の鍵・送信結果の確認が必要です。","manifestは署名されていません。hash一致は保存内容の整合性を示し、作成元の真正性を保証しません。"]
}
struct NativeRestorePlanEntry:Codable {
    let kind:String;let model:String;let key:String?;let field:String?;let revision:String?
    let state:String?;let flags:[String];let count:Int64;let action:String;var event:String?=nil
}
