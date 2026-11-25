import Foundation
import CryptoKit

private final class InvoiceMailQACredentials: InvoiceMailCredentialStore {
    private let lock = NSLock()
    private var value: InvoiceMailAccount? = .init(from:"billing@example.invalid",apiKey:"qa-fake-key")
    func load(interactive: Bool) throws -> InvoiceMailAccount? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ account: InvoiceMailAccount) throws { lock.lock(); defer { lock.unlock() }; value = account }
    func remove() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

struct InvoiceMailRuntime {
    let store: InvoiceMailCredentialStore
    let request: ResendMailClient.Request
    let worker: InvoiceJobWorker
    let orderWorker: OrderMailWorker
    let projectWorker: ProjectMailWorker
    let crmTaskWorker: CRMTaskMailWorker
    let leadWorker: NativeMCPLeadsMailWorker
    let isQA: Bool
    init(db: NativeDatabase, service: CRMService? = nil, settingsStore: InvoiceMailCredentialStore? = nil) throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["NEXTCRM_NATIVE_MAIL_TEST_MODE"]
        let legacy: InvoiceMailCredentialStore
        let request: ResendMailClient.Request
        if let mode {
            let root = db.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let normal = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NextCRMNative").resolvingSymlinksInPath().standardizedFileURL
            guard ["success","retry_once","retry_after_restart","reject"].contains(mode), let path = env["NEXTCRM_NATIVE_DATA_DIR"], root == URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL, root != normal,
                  (try? String(contentsOf:root.appendingPathComponent(".native-mail-test"),encoding:.utf8)) == "NextCRM isolated mail QA\n" else { throw NativeDBError.message("メール検証には専用の検証データフォルダが必要です。") }
            legacy = InvoiceMailQACredentials()
            request = { query,file in
                let id = String((query.value(forHTTPHeaderField:"Idempotency-Key") ?? "").split(separator:"/").last ?? "")
                guard UUID(uuidString:id) != nil else { throw NativeDBError.message("検証用送信IDが不正です。") }
                let data = try Data(contentsOf:file); let json = try JSONSerialization.jsonObject(with:data) as! [String:Any]
                let attempts = try db.transaction { () -> Int in
                    let count = (try db.metadata("qaMailSend."+id).flatMap(Int.init) ?? 0)+1
                    try db.setMetadata("qaMailSend."+id,value:String(count))
                    let record: [String:Any] = ["jobID":id,"attempt":count,"to":json["to"] ?? [],"from":json["from"] ?? "","subject":json["subject"] ?? "","bodySHA256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"network":false]
                    try db.setMetadata("qaMailSend.last",value:String(decoding:try JSONSerialization.data(withJSONObject:record,options:.sortedKeys),as:UTF8.self))
                    return count
                }
                let status = mode == "reject" ? 403 : ["retry_once","retry_after_restart"].contains(mode) && attempts == 1 ? 500 : 200
                let response = try JSONSerialization.data(withJSONObject:status == 200 ? ["id":id] : ["name":"qa_simulated_failure"])
                return (response,HTTPURLResponse(url:query.url!,statusCode:status,httpVersion:nil,headerFields:mode == "retry_after_restart" && status == 500 ? ["Retry-After":"120"] : nil)!)
            }
        } else { legacy = KeychainInvoiceMailCredentials(databaseURL:db.url); request = ResendMailClient.request }
        let store: InvoiceMailCredentialStore
        if let settingsStore { store = settingsStore } else if mode != nil {
            // The existing isolated QA store never touches real Keychain or a
            // persisted migration binding; preserve its restart/test semantics.
            store = legacy
        } else {
            guard let service, service.db === db, !db.isReadOnly else { throw NativeDBError.message("メール設定には現在の利用者と書込み可能な保存先が必要です。") }
            store = NativeCredentialMigrationInvoiceBridge(service:service,vault:NativeCredentialMigrationKeychainVault(databaseURL:db.url),legacy:legacy)
        }
        self.store = store; self.request = request; self.isQA = mode != nil
        worker = InvoiceJobWorker(db:db,apiKey:{
            guard let account = try store.load(interactive:false) else { throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。") }
            return account.apiKey
        },request:request)
        orderWorker = OrderMailWorker(db:db,account:{
            guard let account = try store.load(interactive:false) else { throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。") }
            return account
        },request:request)
        crmTaskWorker = CRMTaskMailWorker(db:db,account:{
            guard let account = try store.load(interactive:false) else { throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。") }
            return account
        },request:request)
        leadWorker = NativeMCPLeadsMailWorker(db:db,account:{
            guard let account = try store.load(interactive:false) else { throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。") }
            return account
        },request:request)
        projectWorker = ProjectMailWorker(db:db,account:{
            guard let account = try store.load(interactive:false) else { throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。") }
            return account
        },request:request)
    }
}
