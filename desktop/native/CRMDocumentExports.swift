import Foundation
import Darwin

private final class NativeExportTransactionProbe {var ended=false}

extension CRMService {
    /// A filesystem export cannot be rolled back with an outer SQL transaction.
    /// Refuse it before creating staging, also preventing cancellation cleanup
    /// from joining a fresh DB fence while this thread retains the outer lock.
    func requireDocumentExportTransactionBoundary()throws {
        let probe=NativeExportTransactionProbe()
        db.deferUntilTransactionEnds(onCommit:{probe.ended=true},onRollback:{probe.ended=true})
        guard probe.ended else{throw NativeDBError.message("データベースの更新が確定してから書き出してください。") }
    }
    private func documentExportAuthority()throws {
        guard !db.isReadOnly else{throw NativeDBError.message("閲覧専用のデータから書き出しや一時ファイルの回収は実行できません。")}
        try authenticated()
    }
    func documentExportRegistry(cancelled:@escaping()->Bool={false})throws->NativeExportStagingRegistry {
        try documentExportAuthority();try requireDocumentExportTransactionBoundary()
        return try NativeExportStagingRegistry(url:db.url.deletingLastPathComponent().appendingPathComponent(".native-export-recovery",isDirectory:true),authorize:{try self.documentExportAuthority()},mutationFence:{body in try self.db.transaction{try self.documentExportAuthority();try body()}},cancelled:cancelled)
    }
    func recoverDocumentExports(after:String?=nil,limit:Int=100)throws->NativeDataMaintenanceRecoveryPage {
        try documentExportAuthority()
        let url=db.url.deletingLastPathComponent().appendingPathComponent(".native-export-recovery",isDirectory:true)
        var st=stat();if lstat(url.path,&st) != 0 {if errno==ENOENT{return .init(items:[],nextCursor:nil,hasMore:false)};throw NativeDataMaintenanceRecoveryFailure.io}
        return try documentExportRegistry().recover(after:after,limit:limit)
    }
}

/// Existing documentRecovery Task owns and awaits this actor call. Shutdown
/// cancels and joins that task, so SQLite stays open until this scan has stopped.
actor NativeDocumentExportRecoveryWorker {
    let service:CRMService
    init(service:CRMService){self.service=service}
    func recover()async throws {
        var cursor:String?,pending=0
        repeat {
            try Task.checkCancellation()
            let page=try service.recoverDocumentExports(after:cursor,limit:100)
            pending += page.items.filter{$0.status == .pending || $0.status == .failed}.count
            guard page.hasMore else{break}
            guard let next=page.nextCursor,next != cursor else{throw NativeDataMaintenanceRecoveryFailure.changed};cursor=next
            await Task.yield()
        }while true
        if pending>0{throw NativeDBError.message("以前の書き出しで確認が必要な作業記録が\(pending)件あります。確認できないファイルは保持しています。")}
    }
}
