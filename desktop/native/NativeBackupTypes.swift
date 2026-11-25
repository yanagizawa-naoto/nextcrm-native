import Foundation

enum NativeBackupStatus:String,Codable {case prepared,preparedWithPending,failed,cancelled}
enum NativeBackupPending:String,Codable {case applicationRestore,credentialRecovery,keychainNamespace,rotatedKeys,jobReconciliation,externalFiles,sourceMetadata,fileCopyPause,avatarOriginal}
struct NativeBackupResult:Codable {
    var formatVersion=1;var status:NativeBackupStatus = .failed;var candidateCreated=false
    var applicationRestored=false;var keychainExported=false;var workersStarted=false
    var snapshotID=UUID().uuidString.lowercased();var sourceNamespaceSHA256=""
    var tableCount:Int64=0;var totalRows:Int64=0;var fileCount:Int64=0;var totalFileBytes:Int64=0
    var databaseBytes:Int64=0;var databaseSHA256="";var filesManifestSHA256="";var tablesManifestSHA256=""
    var pinnedByLink:Int64=0;var pinnedByClone:Int64=0;var copiedUnderFence:Int64=0;var writeFenceSeconds:Double=0;var sourceJournalMode=""
    var pending:[NativeBackupPending]=[.applicationRestore,.credentialRecovery,.keychainNamespace,.rotatedKeys,.jobReconciliation]
    var diagnostics:[NativeMigrationDiagnostic]=[]
    var limitations=["ローカルsnapshot候補です。既存アプリの置換・復元は行っていません。","Keychain参照はDBに保持されますが、秘密の書出し・旧鍵回復・別パス/別Mac移送は行っていません。","復元後のworkerは停止し、外部送信receipt・lease・relay cursor・plugin処理を確認する必要があります。","未publish staging・参照されない一時ファイル・plugin通知の一時bodyは対象外です。","整合性は現行native writerがDB transaction内で参照を公開し、公開後のファイルを不変として扱う契約に依存します。"]
}
struct NativeBackupFile:Codable {
    let sourcePath:String;let archivePath:String;let bytes:Int64;let sha256:String
}
struct NativeBackupTable:Codable {let name:String;let rows:Int64;let schemaSHA256:String}
