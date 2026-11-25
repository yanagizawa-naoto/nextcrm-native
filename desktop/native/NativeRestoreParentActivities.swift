import Foundation

/// App-owned lifetime for work that can outlive its window's `pending` property.
/// Main-queue entry/registration; cancellation never removes a task early.
final class NativeRestoreParentActivities {
    enum Kind:String {case readOnly, externalRead, acceptedWrite}
    private struct Entry {let kind:Kind,owner:String,task:Task<Void,Never>}
    private var entries:[UUID:Entry]=[:],sealed=false
    #if RESTORE_PARENT_TESTING
    var beforeOperationForTesting:((Kind)async->Void)?
    #endif
    private(set) var accepted=0,completed=0
    var isSealed:Bool {sealed}
    var pendingCount:Int {entries.count}
    var acceptedWriteCount:Int {entries.values.filter{$0.kind == .acceptedWrite}.count}
    func pendingWrites(owner:String)->Int {entries.values.filter{$0.owner==owner && $0.kind == .acceptedWrite}.count}
    var inventory:[String:Int] {Dictionary(grouping:entries.values,by:{$0.kind.rawValue}).mapValues(\.count)}
    @discardableResult func spawn(owner:String,kind:Kind,operation:@escaping ()async->Void)->Task<Void,Never>? {
        dispatchPrecondition(condition:.onQueue(.main));guard !sealed else{return nil}
        let id=UUID();accepted += 1
        #if RESTORE_PARENT_TESTING
        let hook=beforeOperationForTesting
        #endif
        let task=Task.detached(priority:.userInitiated){[self] in
            #if RESTORE_PARENT_TESTING
            await hook?(kind)
            #endif
            await operation()
            await MainActor.run {self.entries.removeValue(forKey:id);self.completed += 1}
        }
        entries[id] = .init(kind:kind,owner:owner,task:task);return task
    }
    /// Caller must first veto accepted writes. This is synchronous with the App
    /// admission fence; it never cancels an accepted write in order to pass.
    func seal()throws {
        dispatchPrecondition(condition:.onQueue(.main));guard acceptedWriteCount==0 else{throw NativeRestoreParentFailure.busy}
        guard !sealed else{return};sealed=true
        for entry in entries.values {entry.task.cancel()}
    }
    /// Terminal App shutdown admits no further operations. Already accepted
    /// writes finish normally; cancellation is only requested for reads.
    /// Restore's stricter seal() still vetoes accepted writes before cutover.
    func sealForShutdown() {
        dispatchPrecondition(condition:.onQueue(.main))
        sealed=true
        for entry in entries.values where entry.kind != .acceptedWrite {entry.task.cancel()}
    }
    @MainActor func drainForShutdown()async {
        sealForShutdown()
        let tasks=entries.values.map(\.task)
        for task in tasks {await task.value}
    }
    @MainActor func drain()async throws->Receipt {
        guard sealed else{throw NativeRestoreParentFailure.notFenced}
        let tasks=entries.values.map(\.task)
        // A cancelled caller still joins every operation. This is not an open
        // SQLite-handle claim; App/readonly dispatch callbacks remain separate.
        for task in tasks {await task.value}
        guard entries.isEmpty else{throw NativeRestoreParentFailure.busy}
        return .init(accepted:accepted,completed:completed,remainingTrackedTasks:0,requiresProcessExitForDatabaseHandles:true)
    }
    struct Receipt:Codable {
        let accepted:Int,completed:Int,remainingTrackedTasks:Int
        let requiresProcessExitForDatabaseHandles:Bool
    }
}

enum NativeRestoreParentFailure:Error,LocalizedError {
    case busy,closeWindows([String]),unownedSheet,notFenced,authority
    var errorDescription:String? {
        switch self {
        case .busy:return "保存・書き出し処理が完了してから、もう一度お試しください。"
        case .closeWindows:return "開いている編集画面を閉じてから、もう一度お試しください。"
        case .unownedSheet:return "開いている確認画面を閉じてから、もう一度お試しください。"
        case .notFenced:return "復元の終了準備が始まっていません。"
        case .authority:return "現在の管理者でログインし直してください。"
        }
    }
}
