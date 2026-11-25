import Foundation

/// Only installed after InvoiceMailRuntime validates the isolated QA directory.
/// Secrets stay in memory; no QA path reaches Keychain or a real mail server.
final class NativeMailQAServices: NativeMailSecretStore {
    private let lock = NSLock()
    private var values:[String:Data] = [:]
    func load(id:String,interactive:Bool) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(id:String,data:Data) throws { lock.lock(); defer { lock.unlock() }; guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data }
    func remove(id:String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey:id) }
    static var disabled:NativeMailFailure { .invalid("検証モードでは実際のメールサーバーに接続しません。") }
    static func probe(_ settings:NativeMailAccountSettings,_ credential:NativeMailCredential,_ kind:NativeMailConnectionCheck.Kind) async throws -> [String] {
        try settings.validate(); try credential.validate(); try Task.checkCancellation()
        return kind == .inbox ? ["INBOX","送信済み","Sent"] : []
    }
}
