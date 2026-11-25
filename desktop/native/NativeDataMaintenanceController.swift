import Foundation
import Darwin

final class NativeDataMaintenanceController {
    let service:CRMService;let resources:URL
    private let sessionCheck:()->Bool,checkpoint:((String)throws->Void)?
    init(service:CRMService,resources:URL,sessionCheck:@escaping()->Bool={true},checkpoint:((String)throws->Void)?=nil){self.service=service;self.resources=resources;self.sessionCheck=sessionCheck;self.checkpoint=checkpoint}
    func authorize()throws {
        try service.authenticated()
        guard service.identity.role=="admin",sessionCheck() else{throw NativeMigrationFailure("maintenance.forbidden","バックアップと復元準備を操作できるのは、現在ログイン中の管理者のみです。")}
    }
    private func recoveryRegistry(operation:NativeDataMaintenanceOperation?)throws->NativeDataMaintenanceRecovery {
        try NativeDataMaintenanceRecovery(url:service.db.url.deletingLastPathComponent().appendingPathComponent(".native-maintenance-recovery",isDirectory:true),authorize:authorize,mutationFence:{body in try self.service.db.transaction{try self.authorize();try body()}},cancelled:{operation?.cancelled==true || Task.isCancelled},checkpoint:{point in
            operation?.report("以前の作業用フォルダを確認・回収しています…")
            try self.checkpoint?("recovery."+point)
        })
    }
    /// Call off the UI thread; at most 100 outcomes are retained. Neither a
    /// pending nor a failed item is reported as a successful directory removal.
    func recoverStaging(after:String?=nil,limit:Int=100,operation:NativeDataMaintenanceOperation?=nil)throws->NativeDataMaintenanceRecoveryPage {
        try authorize();return try recoveryRegistry(operation:operation).recover(after:after,limit:limit)
    }
    private func fence(_ point:String,_ operation:NativeDataMaintenanceOperation)throws {
        if operation.cancelled || Task.isCancelled{throw CancellationError()};try authorize();try checkpoint?(point);if operation.cancelled || Task.isCancelled{throw CancellationError()};try authorize()
    }
    func perform(kind:NativeDataMaintenanceKind,backupURL:URL?,destinationURL:URL,operation:NativeDataMaintenanceOperation)->NativeDataMaintenanceOutcome {
        var temporary:NativeDataMaintenanceDirectory?,publication:NativeDataMaintenanceDirectory?,committed=false,cleanupOK=true
        var lease:NativeDataMaintenanceRecoveryLease?,temporaryPlanned=false,publicationPlanned=false
        func clean(_ role:NativeDataMaintenanceRecoveryRole,_ directory:NativeDataMaintenanceDirectory?,planned:Bool){
            guard planned else{return}
            if directory?.didPublish==true {
                guard directory!.rollbackPublished(at:destinationURL) else{cleanupOK=false;return}
            }
            do{try lease!.cleanup(role:role)}catch{
                // Compensating cleanup of an object this in-process attempt just
                // created remains valid after cancellation. It does not discover
                // arbitrary roots or authorize registry updates after revocation.
                if let directory,!directory.didPublish{cleanupOK=directory.cleanup() && cleanupOK}
                do{try lease!.cleanup(role:role)}catch{cleanupOK=false}
            }
        }
        func finishJournal(){do{try lease?.finish()}catch{cleanupOK=false}}
        func cleanup(){clean(.publication,publication,planned:publicationPlanned);clean(.temporary,temporary,planned:temporaryPlanned);finishJournal()}
        do {
            try fence("start",operation)
            guard destinationURL.isFileURL else{throw NativeMigrationFiles.badPath}
            let parent=destinationURL.deletingLastPathComponent(),name=destinationURL.lastPathComponent
            let databaseRoot=service.db.url.deletingLastPathComponent().standardizedFileURL.path
            guard destinationURL.path != databaseRoot,!destinationURL.path.hasPrefix(databaseRoot+"/"),backupURL.map({destinationURL.path != $0.path && !destinationURL.path.hasPrefix($0.path+"/")}) ?? true else{throw NativeMigrationFailure("maintenance.overlap","使用中のデータや元backupと重ならない新しい保存先を指定してください。")}
            var existing=stat();guard lstat(destinationURL.path,&existing) != 0,errno==ENOENT else{throw NativeMigrationFailure("maintenance.exists","保存先が既に存在します。新しいフォルダ名を指定してください。") }
            lease=try recoveryRegistry(operation:operation).begin()
            let temporaryRoot=try NativeMigrationImportWorkspace.resolvedTemporaryDirectory(),temporaryName="NextCRMMaintenance-"+UUID().uuidString.lowercased()
            try lease!.plan(role:.temporary,parentURL:temporaryRoot,name:temporaryName);temporaryPlanned=true
            temporary=try NativeDataMaintenanceDirectory(parentURL:temporaryRoot,name:temporaryName)
            try lease!.attach(role:.temporary)
            let working=temporary!.url.appendingPathComponent("candidate",isDirectory:true)
            var backup:NativeBackupResult?,restore:NativeRestoreResult?,authorityError:Error?,nextAuthorityCheck:UInt64=0
            func stopped()->Bool {
                if operation.cancelled || Task.isCancelled{return true}
                let now=DispatchTime.now().uptimeNanoseconds
                if now<nextAuthorityCheck{return false}
                do{try authorize();nextAuthorityCheck=now+100_000_000;return false}catch{authorityError=error;return true}
            }
            func progress(_ point:String)throws {
                let label:String
                switch point {
                case "snapshotEstablished","pinsComplete","table","beforeReferences","reference":label="保存内容の整合性を確認しています…"
                case "databasePage","databaseChunk","beforeDatabase":label="データベースをコピーしています…"
                case "fileChunk","pinFile","asset","assetChunk":label="添付ファイルを確認・コピーしています…"
                case "beforePlan","planRow":label="切り替え後に必要な確認事項を整理しています…"
                case "beforePublish","afterResult":label="準備結果を検証しています…"
                default:label=kind == .backup ? "バックアップを準備しています…":"復元候補を準備しています…"
                }
                operation.report(label);try fence("backend."+point,operation)
            }
            if kind == .backup {
                let value=NativeBackup(cancelled:stopped,checkpoint:progress).prepare(source:service.db,destinationURL:working)
                guard value.candidateCreated else{if let authorityError{throw authorityError};if value.status == .cancelled{throw CancellationError()};throw value.diagnostics.first.map{NativeMigrationFailure($0.code,$0.message)} ?? NativeMigrationFiles.io};backup=value
            }else{
                guard let backupURL else{throw NativeMigrationFailure("maintenance.source","元のバックアップフォルダを選択してください。")}
                var value=NativeRestore(cancelled:stopped,checkpoint:progress).prepare(backupURL:backupURL,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:working)
                guard value.candidateCreated else{if let authorityError{throw authorityError};if value.status == .cancelled{throw CancellationError()};throw value.diagnostics.first.map{NativeMigrationFailure($0.code,$0.message)} ?? NativeMigrationFiles.io}
                try fence("namespace",operation)
                let canonicalParent=parent.resolvingSymlinksInPath().standardizedFileURL.path
                let publishedPath=URL(fileURLWithPath:canonicalParent,isDirectory:true).appendingPathComponent(name,isDirectory:true).appendingPathComponent("crm.sqlite").path
                value.stagingNamespaceSHA256=NativeMigrationCodec.hash(Data(publishedPath.utf8))
                let root=try NativeBackupWorkspace.openDirectory(working);defer{close(root)}
                let fd=openat(root,"restore.json",O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw NativeMigrationFiles.io};defer{close(fd)}
                try NativeMigrationImportWorkspace.write(JSONEncoder().encode(value),to:fd);guard fsync(fd)==0 else{throw NativeMigrationFiles.io};restore=value
            }
            try fence("beforeCopy",operation);operation.report("選択した保存先へコピーしています…")
            let publicationName=".nextcrm-pending-"+UUID().uuidString.lowercased()
            try lease!.plan(role:.publication,parentURL:parent,name:publicationName);publicationPlanned=true
            publication=try NativeDataMaintenanceDirectory(parentURL:parent,name:publicationName)
            try lease!.attach(role:.publication)
            try NativeDataMaintenancePublication(source:working,kind:kind,destination:publication!,check:{try self.fence("copyChunk",operation)}).copy()
            try fence("beforeCommit",operation)
            try lease!.beginPublication(destinationName:name)
            // Authorization and publication are linearized against user changes.
            try service.db.transaction {
                try authorize();if operation.cancelled{throw CancellationError()};try checkpoint?("commit");try authorize();try operation.seal();try checkpoint?("sealed")
                try publication!.commit(to:parent.appendingPathComponent(name))
                if let restore {
                    let actual=NativeMigrationCodec.hash(Data(destinationURL.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL.path.utf8))
                    guard actual==restore.stagingNamespaceSHA256 else{throw NativeMigrationFailure("maintenance.namespace","保存後の場所の識別情報が一致しません。作成した候補を回収します。")}
                }
            }
            committed=true;operation.finish(success:true)
            // Once publication committed, ledger failure must never turn it into
            // rollback. Restart recovery recognizes the final inode and preserves it.
            do{try lease!.didPublish()}catch{cleanupOK=false}
            clean(.temporary,temporary,planned:temporaryPlanned);finishJournal()
            let artifact=NativeDataMaintenanceArtifact(kind:kind,url:destinationURL,backup:backup,restore:restore)
            return .init(state:.completed,artifact:artifact,message:kind == .backup ? "バックアップを保存しました。":"復元候補を準備しました。使用中のデータは切り替えていません。",cleanupPending:!cleanupOK)
        } catch {
            if !committed{cleanup()};operation.finish(success:false)
            if error is CancellationError{return .init(state:.cancelled,artifact:nil,message:"処理を中止しました。",cleanupPending:!cleanupOK)}
            let text=(error as? NativeMigrationFailure)?.message ?? (error as? NativeDBError)?.localizedDescription ?? "処理を完了できませんでした。元のデータは変更していません。"
            return .init(state:.failed,artifact:nil,message:text,cleanupPending:!cleanupOK)
        }
    }
}
