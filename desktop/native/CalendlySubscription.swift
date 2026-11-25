import Foundation
import CryptoKit

struct CalendlyControlState: Codable,Equatable {
    struct Registration: Codable,Equatable { let uri: String, organization: String, callbackURL: String, credentialID: String; var actorID: String? = nil }
    struct Operation: Codable,Equatable {
        enum Mode: String,Codable { case subscribe,unsubscribe }
        enum Phase: String,Codable { case prepare,deleteOld,configure,ready,creating }
        let id: String, mode: Mode, callbackURL: String
        var actorID: String, credentialID: String
        var phase: Phase, organization: String?, receiverGeneration: String?
    }
    static let metadataKey = "calendly.control.v1"
    var version = 1, revision = "00000000-0000-0000-0000-000000000000"
    var credentialID: String?, registration: Registration?, operation: Operation?
    static func load(_ db: NativeDatabase) throws -> Self {
        guard let raw = try db.metadata(metadataKey), !raw.isEmpty else { return Self() }
        guard let state = try? JSONDecoder().decode(Self.self,from:Data(raw.utf8)), state.version == 1, UUID(uuidString:state.revision) != nil,
              state.credentialID == nil || UUID(uuidString:state.credentialID!) != nil,
              state.operation == nil || (state.operation!.credentialID == state.credentialID && UUID(uuidString:state.operation!.id) != nil) else { throw NativeDBError.message("Calendlyの通知登録の状態を読み取れません。") }; return state
    }
    mutating func save(_ db: NativeDatabase,expected: Self) throws {
        try db.transaction { guard try Self.load(db) == expected else { throw NativeDBError.conflict }; revision = UUID().uuidString.lowercased(); try db.setMetadata(Self.metadataKey,value:String(decoding:try JSONEncoder().encode(self),as:UTF8.self)) }
    }
}

/// Every external mutation has a durable intent. DELETE and relay configuration
/// are repeatable; an uncertain POST is reconciled by its unique callback URL.
actor CalendlySubscriptionManager {
    let service: CRMService, store: CalendlySecretStore
    private let apiRequest: CalendlyAPIClient.Request, relayRequest: CalendlyRelayClient.Request, allowLoopbackHTTP: Bool
    private let validation: () throws -> Void
    private var running = false
    init(service: CRMService,store: CalendlySecretStore,allowLoopbackHTTP: Bool = false,apiRequest: @escaping CalendlyAPIClient.Request = CalendlyRelayClient.network,relayRequest: @escaping CalendlyRelayClient.Request = CalendlyRelayClient.network,validate: @escaping () throws -> Void = {}) {
        self.service = service; self.store = store; self.allowLoopbackHTTP = allowLoopbackHTTP; self.apiRequest = apiRequest; self.relayRequest = relayRequest
        validation = validate
    }
    private func current(_ expected: CalendlyControlState? = nil) throws -> CalendlyControlState {
        try Task.checkCancellation(); try validation(); let value = try service.calendlyControl()
        guard expected == nil || value == expected!, value.operation == nil || value.operation!.actorID == service.identity.id else { throw NativeDBError.conflict }; return value
    }
    private func change(_ before: CalendlyControlState,_ edit: (inout CalendlyControlState) -> Void) throws -> CalendlyControlState {
        try service.db.transaction { var next = try current(before); edit(&next); try next.save(service.db,expected:before); return next }
    }
    func begin(_ mode: CalendlyControlState.Operation.Mode) throws {
        try service.db.transaction {
            let state = try current(); guard state.operation == nil, let credentialID = state.credentialID else { throw NativeDBError.message("接続設定を保存するか、処理中の通知登録を再開してください。") }
            let secret = try service.calendlyCredentials(state,store:store)
            let relay = try secret.relay(db:service.db,allowLoopbackHTTP:allowLoopbackHTTP,request:relayRequest)
            let id = UUID().uuidString.lowercased(); var callback = URLComponents(url:relay.baseURL.appendingPathComponent("api/crm/calendar/webhooks/calendly"),resolvingAgainstBaseURL:false)!
            callback.queryItems = [.init(name:"subscription",value:id)]
            _ = try change(state){$0.operation = .init(id:id,mode:mode,callbackURL:callback.url!.absoluteString,actorID:service.identity.id,credentialID:credentialID,phase:mode == .subscribe ? .prepare : .deleteOld,organization:nil,receiverGeneration:nil)}
        }
    }
    @discardableResult func resume() async throws -> CalendlyControlState {
        guard !running else { throw NativeDBError.message("Calendlyの通知設定を処理中です。") }; running = true; defer{running = false}
        while true {
            let state = try current(); guard let op = state.operation else { return state }
            let secret = try service.calendlyCredentials(state,store:store), api = try CalendlyAPIClient(token:secret.apiToken,request:apiRequest)
            let relay = try secret.relay(db:service.db,allowLoopbackHTTP:allowLoopbackHTTP,request:relayRequest)
            switch op.phase {
            case .prepare:
                let organization = try await api.organization(); _ = try current(state)
                guard state.registration == nil || state.registration!.organization == organization else { throw NativeDBError.message("現在の通知登録とCalendlyの組織が異なります。元の組織のトークンで通知登録を解除してください。") }
                let health = try await relay.health(); _ = try current(state)
                _ = try change(state){$0.operation!.organization = organization; $0.operation!.receiverGeneration = health.keyGeneration; $0.operation!.phase = .deleteOld}
            case .deleteOld:
                if let old = state.registration {
                    let remote = try await api.get(old.uri); _ = try current(state)
                    if let remote {
                        guard remote.matches(callback:old.callbackURL,organization:old.organization) else { throw NativeDBError.message("削除対象の通知登録が変更されています。Calendly側で確認してください。") }
                        try await api.delete(old.uri); _ = try current(state)
                    }
                }
                _ = try change(state){$0.registration = nil; if op.mode == .unsubscribe { $0.operation = nil } else { $0.operation!.phase = .configure } }
            case .configure:
                let configured = try await relay.configure(signingKey:secret.signingKey,expectedGeneration:op.receiverGeneration); _ = try current(state)
                try await relay.checkCallback(); _ = try current(state)
                _ = try change(state){$0.operation!.receiverGeneration = configured.keyGeneration; $0.operation!.phase = .ready}
            case .ready:
                guard let organization = op.organization else { throw NativeDBError.conflict }
                let receiver = try await relay.health(); _ = try current(state)
                guard receiver.keyGeneration == op.receiverGeneration, receiver.signingKeyFingerprint == SHA256.hash(data:Data(secret.signingKey.utf8)).map({String(format:"%02x",$0)}).joined() else { throw NativeDBError.message("通知登録の準備中に受信窓口の署名キーが変わりました。受信設定を確認してください。") }
                let intent = try change(state){$0.operation!.phase = .creating}
                do {
                    _ = try current(intent)
                    let remote = try await api.create(callback:op.callbackURL,organization:organization,signingKey:secret.signingKey)
                    try publish(remote,state:intent)
                } catch {
                    // Explicit rejection proves this attempt did not create anything.
                    if let error = error as? CalendlyAPIError, error.definiteCreateRejection { _ = try change(intent){$0.operation!.phase = .ready} }
                    throw error
                }
            case .creating:
                guard let organization = op.organization else { throw NativeDBError.conflict }
                let remote = try await api.find(callback:op.callbackURL,organization:organization,validate:{try self.validation(); _ = try self.service.calendlyControlChecked(state)})
                _ = try current(state)
                guard let remote, remote.state == "active" else { throw NativeDBError.message("通知登録の結果を確認中です。再開するとCalendly側の登録を照合します。登録がないことを確認するまでは再作成しません。") }
                try publish(remote,state:state)
            }
        }
    }
    private func publish(_ remote: CalendlyAPIClient.Subscription,state: CalendlyControlState) throws {
        guard let op = state.operation, op.phase == .creating, let organization = op.organization, remote.matches(callback:op.callbackURL,organization:organization), remote.state == "active" else { throw NativeDBError.conflict }
        _ = try change(state){$0.registration = .init(uri:remote.uri,organization:organization,callbackURL:op.callbackURL,credentialID:op.credentialID,actorID:service.identity.id); $0.operation = nil}
    }
    func restartReceiverPreparation(operationID: String) throws {
        guard !running else { throw NativeDBError.conflict }; let state = try current()
        guard let op = state.operation, op.id == operationID, op.mode == .subscribe, [.configure,.ready].contains(op.phase), state.registration == nil else { throw NativeDBError.conflict }
        _ = try change(state){$0.operation!.phase = .prepare}
    }
    func cancelPreparation(operationID: String) throws {
        guard !running else { throw NativeDBError.conflict }; let state = try current()
        guard let op = state.operation, op.id == operationID, op.mode == .subscribe,
              op.phase == .prepare || (state.registration == nil && [.deleteOld,.configure,.ready].contains(op.phase)) else { throw NativeDBError.message("通知登録の作成・削除結果を確認してから中止してください。") }
        _ = try change(state){$0.operation = nil}
    }
    func takeOverOperation(operationID: String) throws {
        guard !running else { throw NativeDBError.conflict }
        try service.db.transaction {
            let state = try service.calendlyControl(); guard state.operation?.id == operationID else { throw NativeDBError.conflict }
            var next = state; next.operation!.actorID = service.identity.id; try next.save(service.db,expected:state)
        }
    }
    /// Called only by an explicit administrator review action, never an automatic retry.
    func confirmCreateNotApplied(operationID: String,note: String) async throws {
        guard !running else { throw NativeDBError.conflict }; running = true; defer{running = false}
        let note = note.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !note.isEmpty, note.utf8.count <= 4000 else { throw NativeDBError.message("Calendly側で登録がないことを確認した内容を入力してください（4,000バイト以内）。") }
        let before = try current(); guard let op = before.operation, op.id == operationID, op.phase == .creating, let organization = op.organization else { throw NativeDBError.conflict }
        let secret = try service.calendlyCredentials(before,store:store), api = try CalendlyAPIClient(token:secret.apiToken,request:apiRequest)
        let remote = try await api.find(callback:op.callbackURL,organization:organization,validate:{try self.validation(); _ = try self.service.calendlyControlChecked(before)})
        guard remote == nil else { throw NativeDBError.message("Calendly側に登録が見つかりました。再開して登録を取り込んでください。") }
        try service.db.transaction {
            _ = try current(before)
            let review = ["operationID":op.id,"actorID":service.identity.id,"note":note,"at":try NativeCalendarEvents.stamp(Date())]
            try service.db.setMetadata("calendly.review."+UUID().uuidString.lowercased(),value:String(decoding:try JSONEncoder().encode(review),as:UTF8.self))
            _ = try change(before){$0.operation!.phase = .ready}
        }
    }
}
extension CRMService {
    fileprivate func calendlyControlChecked(_ expected: CalendlyControlState) throws -> CalendlyControlState {
        try Task.checkCancellation(); let current = try calendlyControl(); guard current == expected else { throw NativeDBError.conflict }; return current
    }
}
