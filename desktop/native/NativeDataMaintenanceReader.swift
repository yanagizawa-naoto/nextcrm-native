import Foundation

enum NativeDataMaintenanceSection:String,CaseIterable {
    case summary,obligations,plan,files,tables
    var title:String{switch self{case .summary:return "検証結果";case .obligations:return "切り替え前の確認";case .plan:return "処理ごとの再開課題";case .files:return "添付ファイル";case .tables:return "保存したデータ"}}
}
struct NativeDataMaintenanceRow {let title:String,value:String,detail:String}
struct NativeDataMaintenancePage {let rows:[NativeDataMaintenanceRow];let offset:Int64,total:Int64;let hasNext:Bool}
final class NativeDataMaintenanceReader {
    let authorize:()throws->Void
    init(authorize:@escaping()throws->Void){self.authorize=authorize}
    static func pending(_ item:NativeBackupPending)->String {
        switch item{case .applicationRestore:return "使用中データへの切り替え";case .credentialRecovery:return "接続鍵・認証情報の確認";case .keychainNamespace:return "最終保存先の鍵の接続";case .rotatedKeys:return "更新済みの過去の鍵の復旧";case .jobReconciliation:return "処理・送信結果の照合";case .externalFiles:return "外部・旧形式の添付の確認";case .sourceMetadata:return "元データの容量・内容の一致を確認";case .fileCopyPause:return "作成時にファイルのコピー待ちが発生";case .avatarOriginal:return "旧プロフィール写真の原画像の確認"}
    }
    static func obligation(_ value:String)->String {
        ["sourceProvenance":"1. 元のバックアップを確認","stopAndSwitch":"2. アプリの処理を停止","candidateRevalidation":"3. 切り替え直前に再検証","credentials":"4. 接続鍵・認証情報を引き継ぐ","jobs":"5. ジョブ・送信結果を照合","relayAndPluginState":"6. 外部の受信履歴・連携状態を照合","pendingAssets":"7. 添付などの未解決項目を確認","runtimeStartup":"8. 再開する処理を決定"][value] ?? "追加の確認事項"
    }
    static func obligationDetail(_ value:String)->String {
        [
            "sourceProvenance":"管理者が作成元と保存日時を確認し、信頼できるバックアップを選んでください。内容が一致するだけでは、誰が作成したものかは確認できません。",
            "stopAndSwitch":"編集中の内容を保存し、通信・自動送信・同期をすべて停止します。切り替え中は旧データと復元候補を開かず、失敗した際に戻す保存先を用意してください。",
            "candidateRevalidation":"他の処理が停止している間に、選んだバックアップ、データの形式、添付と再開計画の内容、最終保存先が正しいことを再確認します。",
            "credentials":"最終保存先で接続設定を確認します。メールや連携サービスの認証情報が使えない場合は復旧・再入力してください。Macに保存した設定も確認し、完了するまで古い認証情報を削除しないでください。",
            "jobs":"処理予定と完了記録を残し、送信済みか不明なメール・通知と途中の処理を、送信先の記録や個別確認機能で照合してください。重複送信を防ぎ、再開する処理を一件ずつ決めます。",
            "relayAndPluginState":"メールの同期位置と受信済み履歴、接続先の識別情報、連携処理の実行中記録を各サービスと照合します。復元前に受信・処理した内容を重複して取り込まない状態にしてから再開します。",
            "pendingAssets":"バックアップに含まれない外部の添付、写真の元画像、不足するファイル情報を確認します。不足分を補うか、保持できる範囲を確認して記録してください。",
            "runtimeStartup":"上の確認を終えてから、再開する送信・同期・自動処理を明示的に決めます。この準備画面では、データの切り替えや自動処理の再開を行いません。"
        ][value] ?? "切り替えを進める前に、管理者が必要な確認を行ってください。"
    }
    func open(_ url:URL)throws->NativeDataMaintenanceArtifact {
        try authorize();let source=try NativeMigrationFiles(root:url)
        let restoreData=try? source.data("restore.json",maximum:4*1024*1024,cancelled:{false})
        let artifact:NativeDataMaintenanceArtifact
        if let data=restoreData {
            _ = try NativeMigrationJSON.parse(data);let value=try JSONDecoder().decode(NativeRestoreResult.self,from:data)
            guard value.formatVersion==1,value.status == .staged,value.candidateCreated,!value.activated,!value.workersStarted,!value.keychainAccessed,value.activationGate.obligations.count==8,Set(value.inheritedPending.map(\.rawValue)).count==value.inheritedPending.count,value.activationGate.phase=="requiresActivationReview",Set(value.activationGate.obligations.map(\.kind))==Set(NativeRestoreActivationGate.review.obligations.map(\.kind)) else{throw NativeMigrationFailure("maintenance.result","対応する復元準備の結果ではありません。")}
            artifact = .init(kind:.restore,url:url,backup:nil,restore:value)
        }else{
            let data=try source.data("snapshot.json",maximum:4*1024*1024,cancelled:{false});_ = try NativeMigrationJSON.parse(data)
            let value=try JSONDecoder().decode(NativeBackupResult.self,from:data)
            guard value.formatVersion==1,value.candidateCreated,!value.applicationRestored,!value.keychainExported,!value.workersStarted,Set(value.pending.map(\.rawValue)).count==value.pending.count,[NativeBackupStatus.prepared,.preparedWithPending].contains(value.status) else{throw NativeMigrationFailure("maintenance.result","完了したバックアップではありません。")}
            artifact = .init(kind:.backup,url:url,backup:value,restore:nil)
        }
        guard UUID(uuidString:artifact.snapshotID)?.uuidString.lowercased()==artifact.snapshotID else{throw NativeMigrationFiles.badPath}
        try authorize();return artifact
    }
    func page(_ artifact:NativeDataMaintenanceArtifact,section:NativeDataMaintenanceSection,offset:Int64,operation:NativeDataMaintenanceOperation)throws->NativeDataMaintenancePage {
        func check()throws{if operation.cancelled || Task.isCancelled{throw CancellationError()};try authorize()}
        try check();guard offset>=0,offset<=Int64.max-100 else{throw NativeMigrationFiles.badPath}
        let fresh=try open(artifact.url)
        func fingerprint(_ value:NativeDataMaintenanceArtifact)throws->String {
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            return NativeMigrationCodec.hash(try value.backup.map{try encoder.encode($0)} ?? encoder.encode(value.restore!))
        }
        guard fresh.snapshotID==artifact.snapshotID,fresh.kind==artifact.kind,try fingerprint(fresh)==fingerprint(artifact) else{throw NativeMigrationFailure("maintenance.changed","保存結果が変更されています。開き直してください。")}
        let tables=fresh.backup?.tableCount ?? fresh.restore!.tableCount,files=fresh.backup?.fileCount ?? fresh.restore!.fileCount,records=fresh.backup?.totalRows ?? fresh.restore!.totalRows
        let pending=fresh.backup?.pending ?? fresh.restore!.inheritedPending
        guard tables>=0,files>=0,records>=0 else{throw NativeMigrationFiles.badPath}
        if section == .summary {
            var rows=[NativeDataMaintenanceRow(title:"結果",value:fresh.kind == .backup ? "バックアップ作成済み":"復元準備済み",detail:fresh.kind == .backup ? "保存時点のデータを保全しました。鍵や外部の履歴は別途確認が必要です。":"使用中のデータは切り替えていません。確認事項を解消してから切り替えます。"),.init(title:"保存先",value:artifact.url.path,detail:"このフォルダを保持してください。"),.init(title:"データ",value:"\(tables) 種類・\(records) 件",detail:"補助データと処理の履歴を含みます。"),.init(title:"添付ファイル",value:"\(files) 件",detail:"管理対象の文書・写真・保存済みメールなど。"),.init(title:"バックアップの注意点",value:"\(pending.count) 分類",detail:pending.map(Self.pending).joined(separator:"\n")),.init(title:"実際の切り替え",value:"未実行",detail:"接続鍵の操作、外部送信、処理の再開は行っていません。")]
            if let restore=fresh.restore{rows.insert(.init(title:"切り替え前の確認",value:"\(restore.activationGate.obligations.count) 件",detail:"各項目の確認はまだ完了していません。「切り替え前の確認」で内容を確認できます。"),at:5)}
            try check();return .init(rows:rows,offset:0,total:Int64(rows.count),hasNext:false)
        }
        if section == .obligations {
            let rows=(fresh.restore?.activationGate.obligations ?? []).map{NativeDataMaintenanceRow(title:Self.obligation($0.kind),value:"確認待ち",detail:Self.obligationDetail($0.kind))}
            try check();return .init(rows:rows,offset:0,total:Int64(rows.count),hasNext:false)
        }
        let path:String,expected:String,total:Int64
        switch section {
        case .files:path="files.ndjson";expected=fresh.backup?.filesManifestSHA256 ?? fresh.restore!.filesManifestSHA256;total=files
        case .tables:path="tables.ndjson";expected=fresh.backup?.tablesManifestSHA256 ?? fresh.restore!.tablesManifestSHA256;total=tables
        case .plan:guard let value=fresh.restore else{throw NativeMigrationFiles.badPath};path="resume-plan.ndjson";expected=value.resumePlanSHA256;total=value.planRows
        default:throw NativeMigrationFiles.badPath
        }
        guard NativeMigrationCodec.validHash(expected),total>=0 else{throw NativeMigrationFiles.badPath}
        operation.report("表示するページの内容を確認しています…")
        let source=try NativeMigrationFiles(root:artifact.url);var pendingLine=Data(),count:Int64=0,rows:[NativeDataMaintenanceRow]=[]
        let measured=try source.read(path,cancelled:{operation.cancelled}){chunk in
            try check();var start=chunk.startIndex
            for i in chunk.indices where chunk[i]==10 {
                guard pendingLine.count+chunk.distance(from:start,to:i)<=65536 else{throw NativeMigrationFailure("maintenance.line","表示データの1行が上限を超えています。")}
                pendingLine.append(chunk[start..<i]);guard !pendingLine.isEmpty else{throw NativeMigrationFiles.badPath}
                if count>=offset && count<offset+100 {
                    try autoreleasepool {
                        _ = try NativeMigrationJSON.parse(pendingLine)
                        if section == .files{let value=try JSONDecoder().decode(NativeBackupFile.self,from:pendingLine);_ = try NativeRestoreWorkspace.path(value.sourcePath);guard value.bytes>=0 else{throw NativeMigrationFiles.badPath};rows.append(.init(title:value.sourcePath,value:ByteCountFormatter.string(fromByteCount:value.bytes,countStyle:.file),detail:"保存された添付ファイルです。"))}
                        else if section == .tables{let value=try JSONDecoder().decode(NativeBackupTable.self,from:pendingLine);guard value.rows>=0,value.name.utf8.count<=1024 else{throw NativeMigrationFiles.badPath};rows.append(.init(title:CRMModule.all.first(where:{$0.model==value.name})?.title ?? value.name,value:"\(value.rows) 件",detail:"保存時点のデータ件数です。"))}
                        else{let value=try JSONDecoder().decode(NativeRestorePlanEntry.self,from:pendingLine);guard value.action.utf8.count<=8192,value.key.map({$0.utf8.count<=4096}) ?? true,value.flags.count<=16 else{throw NativeMigrationFiles.badPath};let kind=["credential":"接続鍵","job":"処理の再開","terminalReceipt":"完了・取消済みの処理","credentialCleanup":"過去の鍵の整理","relayBinding":"外部の受信履歴","mailCursor":"メールの同期位置","pluginState":"プラグインの保存状態","keychainOnlySettings":"Keychainのみの設定","serviceSetting":"接続・認証設定","mailPayloads":"保存済みの送信メール","eventReceipts":"受信したイベント","relayRegistrations":"送信先との登録情報","localWork":"未完了の内部処理"][value.kind] ?? "追加の確認事項";let state=["pending":"待機中","retry":"再試行待ち","running":"以前の実行を要確認","needs_review":"結果確認が必要","done":"完了済み","cancelled":"取消済み","native-reference":"接続先の鍵を確認","opaque-legacy":"旧形式の認証情報を確認"][value.state ?? ""] ?? "確認待ち";rows.append(.init(title:kind,value:state,detail:value.action+(value.key.map{"\n対象ID："+$0} ?? "")))}
                    }
                }
                count+=1;pendingLine.removeAll(keepingCapacity:true);start=chunk.index(after:i)
            }
            pendingLine.append(chunk[start..<chunk.endIndex]);guard pendingLine.count<=65536 else{throw NativeMigrationFailure("maintenance.line","表示データの1行が上限を超えています。")}
        }
        guard pendingLine.isEmpty,count==total,measured.sha256==expected else{throw NativeMigrationFailure("maintenance.digest","一覧の件数・内容が保存結果と一致しません。")}
        try check();return .init(rows:rows,offset:offset,total:total,hasNext:offset+Int64(rows.count)<total)
    }
}
