import Foundation

struct NativeMigrationManifest: Decodable {
    struct Source: Decodable { let kind: String; let snapshotID: String; let consistent: Bool; let completed: Bool; let databaseNamespaceSHA256: String? }
    struct File: Decodable { let path: String; let rows: Int64; let bytes: Int64; let sha256: String }
    struct Model: Decodable { let name: String; let path: String; let rows: Int64; let bytes: Int64; let sha256: String
        var file: File { .init(path:path,rows:rows,bytes:bytes,sha256:sha256) }
    }
    let formatVersion: Int; let schemaSHA256: String; let source: Source; let models: [Model]
    let assets: File; let jobs: File; let secrets: File
}
struct NativeMigrationSchema: Decodable {
    struct Field: Decodable { let name: String; let column: String; let type: String; let optional: Bool; let array: Bool; let attributes: String }
    struct Relation: Decodable { let name: String; let type: String; let attributes: String }
    struct Model: Decodable { let name: String; let fields: [Field]; let relations: [Relation]; let directives: [String]; let primaryKey: [String] }
    let formatVersion: Int; let schemaSHA256: String; let models: [Model]; let enums: [String:[String]]
}
struct NativeMigrationDiagnostic: Codable {
    let severity: String; let code: String; let message: String
    let model: String?; let row: Int64?; let field: String?
}
struct NativeMigrationResult: Codable {
    var formatVersion = 1
    var status = "invalid"
    var migrationPerformed = false
    var checkedModels = 0; var checkedRows: Int64 = 0; var checkedAssets: Int64 = 0; var checkedJobs: Int64 = 0; var checkedSecrets: Int64 = 0
    var errorCount = 0; var incompleteCount = 0; var warningCount = 0; var diagnosticCount = 0
    var diagnostics: [NativeMigrationDiagnostic] = []
    var limitations = [
        "検査は読み取り専用です。移行・復元・データベースへの書込みは行っていません。",
        "snapshot ID・全件性・一貫性はexporterの宣言です。稼働中の元PostgreSQLや旧フォルダとの照合は行っていません。",
        "添付のバイト整合性と参照を検査します。各画面・旧provider形式の読込み互換は別検証です。",
        "Keychainは検査しません（注入された可用性確認を除く）。別パスのnamespace、rotation後の旧鍵、別Macへの秘密の復元は保証しません。",
        "設定JSON・PluginData内の未知の秘密情報や外部参照、ImageUploadの元object keyは専用exporterによる確認が必要です。",
        "job inventoryの完全性と外部送信結果は元サービスと照合していません。worker再開・再送を許可する結果ではありません。"
    ]
}
struct NativeMigrationOptions {
    var maximumLineBytes = 8 * 1024 * 1024
    var maximumMetadataBytes = 4 * 1024 * 1024
    var maximumDiagnostics = 200
}
struct NativeMigrationSecretReference {
    let id: String; let purpose: String; let storage: String; let namespaceSHA256: String?
}
enum NativeMigrationSecretAvailability { case present, missing, unknown }
struct NativeMigrationFailure: Error { let code: String; let message: String
    init(_ code: String, _ message: String) { self.code=code;self.message=message }
}
