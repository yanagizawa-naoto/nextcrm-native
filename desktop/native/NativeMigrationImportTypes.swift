import Foundation

enum NativeMigrationImportStatus:String,Codable {case prepared,preparedWithGaps,rejected,failed,cancelled}
enum NativeMigrationImportPending:String,Codable {
    case sourceSnapshotAuthenticity,applicationRestore,credentials,jobRecovery,nativeAuxiliaryTables,externalAssets,assetReaderIntegration,imageObjectInventory
}
struct NativeMigrationImportModelProof:Codable {let model:String;let rows:Int64;let readBackRows:Int64;let sourceSHA256:String}
struct NativeMigrationImportResult:Codable {
    var formatVersion=1
    var status:NativeMigrationImportStatus = .rejected
    var candidateCreated=false;var applicationRestored=false;var workersStarted=false;var keychainWritten=false
    var normalizedUUIDValues:Int64=0;var importedRows:Int64=0;var copiedAssets:Int64=0;var copiedAssetBytes:Int64=0
    var modelProofs:[NativeMigrationImportModelProof]=[]
    var pending:[NativeMigrationImportPending]=[.sourceSnapshotAuthenticity,.applicationRestore]
    var preflight:NativeMigrationResult?
    var diagnostics:[NativeMigrationDiagnostic]=[]
    var schemaSHA256:String?;var sqlSHA256:String?
    var limitations=["候補の作成だけを行いました。既存アプリへの移行・復元・置換は実行していません。","元の本番snapshotの真正性・完全性は証明していません。入力bundleは変更していません。","秘密情報とjob inventoryは保全のみです。Keychainの移送・復号・ジョブ再開・外部送信は行っていません。"]
}
enum NativeMigrationImportValue:Equatable {case null,integer(Int64),real(Double),text(Data),blob(Data)}
