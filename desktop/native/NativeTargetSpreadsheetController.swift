import Foundation

final class NativeTargetSpreadsheetOperation {
    private let lock = NSLock()
    private var stopped = false, sealed = false, text = "準備しています…"
    var cancelled: Bool { lock.lock();defer{lock.unlock()};return stopped }
    var message: String { lock.lock();defer{lock.unlock()};return text }
    func cancel() { lock.lock();defer{lock.unlock()};if !sealed {stopped=true;text="中止して作業用ファイルを回収しています…"} }
    func check() throws { if cancelled {throw CancellationError()} }
    func report(_ value:String) {lock.lock();defer{lock.unlock()};if !stopped && !sealed{text=value}}
    func seal() throws {lock.lock();defer{lock.unlock()};guard !stopped else{throw CancellationError()};sealed=true;text="保存内容を確定しています…"}
}

/// Owned by a sheet until its tasks have joined. Closing never drops this
/// reference while parsing/AI/commit/publication is still in progress.
final class NativeTargetSpreadsheetSession {
    let staging: NativeExportStaging, draft: NativeTargetSpreadsheetDraft, fileName: String
    init(staging:NativeExportStaging,draft:NativeTargetSpreadsheetDraft,fileName:String){self.staging=staging;self.draft=draft;self.fileName=fileName}
    func finish() throws { draft.closeDatabase();try staging.finish() }
}

final class NativeTargetSpreadsheetController {
    struct ExportResult { let rows:Int64;let url:URL;let cleanupPending:Bool }
    let service:CRMService
    let keys:NativeAIKeys?
    var allowsAI:Bool {keys != nil}
    let admission:()throws->Void
    var request:NativeEmbeddingClient.Request = {try await NativeEmbeddingClient.providerTransport($0,endpoint:NativeTargetSpreadsheetAI.endpoint)}
    private let queue = DispatchQueue(label:"local.nextcrm.target-spreadsheet",qos:.userInitiated)
    init(service:CRMService,keys:NativeAIKeys?=nil,admission:@escaping()throws->Void){self.service=service;self.keys=keys;self.admission=admission}
    private func current()throws {
        try service.authenticated()
        guard !service.db.isReadOnly else{throw NativeTargetSpreadsheetFailure(message:"閲覧専用では取り込み・書き出しを実行できません。")}
    }
    func revalidate() throws { try current();try admission() }
    private func registry(_ op:NativeTargetSpreadsheetOperation)throws->NativeExportStagingRegistry {
        try current();try admission();try op.check()
        // Same private registry as existing app recovery. Cleanup verifies the
        // current session/readonly state but does not reopen new-work admission.
        return try NativeExportStagingRegistry(url:service.db.url.deletingLastPathComponent().appendingPathComponent(".native-export-recovery"),authorize:current,mutationFence:{body in try self.service.db.transaction{try self.current();try body()}},cancelled:{op.cancelled})
    }
    private func worker<T>(_ op:NativeTargetSpreadsheetOperation,_ body:@escaping()throws->T)async throws->T {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with:Result{try op.check();return try body()}) }
            }
        },onCancel:{op.cancel()})
    }
    func load(_ url:URL,operation op:NativeTargetSpreadsheetOperation)async throws->NativeTargetSpreadsheetSession {
        try await worker(op) {
            let staging=try self.registry(op).begin(parent:FileManager.default.temporaryDirectory)
            do {
                let draft=try NativeTargetSpreadsheetDraft(directory:staging.directoryURL)
                do {
                    let check={try op.check();try self.admission();try self.current()}
                    op.report("ファイルを安全な作業場所へ読み込んでいます…")
                    let source=try draft.copySource(url,checkpoint:check)
                    op.report("列と行を読み込んでいます…")
                    if source.pathExtension == "xlsx" {
                        try NativeTargetSpreadsheetXLSXReader.parse(url:source,draft:draft,numberText:NativePluginJSON.numberString,checkpoint:check)
                    } else {
                        try draft.execute("BEGIN")
                        do {
                            try NativeTargetSpreadsheetCSVReader.parse(url:source,checkpoint:check,headers:{try draft.setHeaders($0)},row:{try draft.append($0)})
                            try check();try draft.execute("COMMIT")
                        }catch{try? draft.execute("ROLLBACK");throw error}
                    }
                    try check();return .init(staging:staging,draft:draft,fileName:url.lastPathComponent)
                }catch{draft.closeDatabase();throw error}
            }catch{try? staging.finish();throw error}
        }
    }
    func headers(_ session:NativeTargetSpreadsheetSession,operation op:NativeTargetSpreadsheetOperation)async throws->[String] {
        try await worker(op){try self.current();try self.admission();return try session.draft.allHeaders()}
    }
    func suggest(_ session:NativeTargetSpreadsheetSession,operation op:NativeTargetSpreadsheetOperation)async throws->NativeTargetSpreadsheetAI.Result {
        try op.check()
        guard let keys else{throw NativeTargetSpreadsheetFailure(message:"AIによる列の提案は停止しています。列を選んで取り込む操作は引き続き使えます。")}
        let headers=try await worker(op){try self.current();try self.admission();return try session.draft.allHeaders()}
        var ai=NativeTargetSpreadsheetAI(keys:keys,admission:{try self.admission();try self.current();try op.check()});ai.request=request
        return try await withTaskCancellationHandler(operation:{try await ai.suggest(headers)},onCancel:{op.cancel()})
    }
    func preview(_ session:NativeTargetSpreadsheetSession,mapping:NativeTargetSpreadsheetMapping,after:Int64,operation op:NativeTargetSpreadsheetOperation)async throws->[(position:Int64,values:[String:String],valid:Bool)] {
        try await worker(op){try NativeTargetSpreadsheetService(service:self.service,admission:self.admission).preview(session.draft,mapping:mapping,after:after,checkpoint:op.check)}
    }
    func importRows(_ session:NativeTargetSpreadsheetSession,mapping:NativeTargetSpreadsheetMapping,operation op:NativeTargetSpreadsheetOperation)async throws->NativeTargetSpreadsheetService.ImportResult {
        try await worker(op){try NativeTargetSpreadsheetService(service:self.service,admission:self.admission).importRows(session.draft,mapping:mapping,checkpoint:op.check,progress:{op.report("\($0) / \(session.draft.rowCount) 行を確認しています…")},willCommit:op.seal)}
    }
    func notes(_ session:NativeTargetSpreadsheetSession,after:Int64,operation op:NativeTargetSpreadsheetOperation)async throws->[(Int64,String)] {
        try await worker(op){try self.current();try self.admission();var result:[(Int64,String)]=[];try session.draft.each("SELECT position,message FROM notes WHERE position>? ORDER BY position LIMIT 100",[.integer(after)]){try op.check();result.append((Int64($0[0]!)!,$0[1]!))};return result}
    }
    func export(_ selection:NativeTargetSpreadsheetService.ExportSelection,to destination:URL,format:NativeTargetSpreadsheetExport.Format,replace:Bool,operation op:NativeTargetSpreadsheetOperation)async throws->ExportResult {
        try await worker(op) {
            let staging=try self.registry(op).begin(parent:destination.deletingLastPathComponent())
            do {
                let draft=try NativeTargetSpreadsheetDraft(directory:staging.directoryURL)
                let count:Int64
                do {
                    let api=NativeTargetSpreadsheetService(service:self.service,admission:self.admission)
                    count=try api.exportSnapshot(selection,into:draft,checkpoint:op.check,progress:{op.report("\($0)件の書き出し内容を確認しています…")})
                    let name=format == .csv ? "targets.csv":"targets.xlsx",output=try staging.unusedContentURL(named:name)
                    let writer=try NativeTargetSpreadsheetExport(stagedOutput:output,format:format,headers:NativeTargetSpreadsheetFields.all.map(\.title),cancelled:{op.cancelled})
                    do {
                        var after:Int64 = -1
                        while after<draft.rowCount-1 {
                            try draft.rows(after:after){position,row in
                                try op.check();try self.admission();try self.current()
                                try writer.append(NativeTargetSpreadsheetFields.keys.map{row.value($0)?.text ?? ""});after=position
                                op.report("\(position+1) / \(draft.rowCount)件を書き出しています…")
                            }
                        }
                        _ = try writer.finish()
                    }catch{writer.cancel();throw error}
                    try staging.publish(content:name,to:destination,replace:replace){publish in
                        try self.service.db.transaction{try self.current();try self.admission();try op.seal();try publish()}
                    }
                    draft.closeDatabase()
                }catch{draft.closeDatabase();throw error}
                do {try staging.finish();return .init(rows:count,url:destination,cleanupPending:false)}
                catch {return .init(rows:count,url:destination,cleanupPending:true)}
            }catch{try? staging.finish();throw error}
        }
    }
    /// Always joins cleanup, including after the caller's Task was cancelled.
    /// A denied cleanup remains in the recovery journal; no success is invented.
    func close(_ session:NativeTargetSpreadsheetSession)async throws {
        try await withCheckedThrowingContinuation { continuation in queue.async{continuation.resume(with:Result{try session.finish()})} }
    }
}
