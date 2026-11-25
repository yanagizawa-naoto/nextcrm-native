import Foundation

struct CalendlyRelayBinding: Codable,Equatable {
    let publicURL: String, clientID: String, instanceID: String
    var cursor: Int64
    static let clientKey = "calendlyRelay.clientID.v1", metadataKey = "calendlyRelay.binding.v1"
    static func clientID(db: NativeDatabase) throws -> String {
        try db.transaction {
            if let value = try db.metadata(clientKey) { guard UUID(uuidString:value) != nil else { throw NativeDBError.message("予約受信の接続IDが不正です。") }; return value }
            let value = UUID().uuidString.lowercased(); try db.setMetadata(clientKey,value:value); return value
        }
    }
    static func load(db: NativeDatabase) throws -> Self? {
        guard let json = try db.metadata(metadataKey) else { return nil }
        guard let value = try? JSONDecoder().decode(Self.self,from:Data(json.utf8)), UUID(uuidString:value.clientID) != nil, UUID(uuidString:value.instanceID) != nil,
              value.cursor >= 0, value.cursor <= 9_007_199_254_740_991, try db.metadata(clientKey) == value.clientID else { throw NativeDBError.message("予約受信の接続情報が不正です。") }; return value
    }
    func save(db: NativeDatabase) throws { try db.setMetadata(Self.metadataKey,value:String(decoding:try JSONEncoder().encode(self),as:UTF8.self)) }
    static func connect(service: CRMService,client: CalendlyRelayClient,validate: () throws -> Void = {}) async throws -> Self {
        func check() throws { try Task.checkCancellation(); try service.requireCalendlyAdmin(); try validate() }
        try check(); let db = service.db, before = try load(db:service.db)
        guard try clientID(db:db) == client.clientID, before == nil || (before!.publicURL == client.baseURL.absoluteString && before!.clientID == client.clientID) else { throw NativeDBError.message("登録済みの予約受信窓口と接続先が異なります。") }
        let state = try await client.health(); try check()
        guard before == nil || (before!.instanceID == state.instanceId && before!.cursor <= state.head) else { throw NativeDBError.message("予約の受信窓口が変更されたか、履歴が巻き戻っています。") }
        let bound = try await client.expecting(state.instanceId).bind(); try check()
        guard bound.head >= (before?.cursor ?? 0) else { throw NativeDBError.message("予約の受信履歴が接続中に巻き戻りました。") }
        let value = before ?? Self(publicURL:client.baseURL.absoluteString,clientID:client.clientID,instanceID:bound.instanceId,cursor:0)
        return try db.transaction { try check(); guard try load(db:db) == before, try db.metadata(Self.clientKey) == client.clientID else { throw NativeDBError.conflict }; try value.save(db:db); return value }
    }
}
extension CRMService {
    func requireCalendlyAdmin() throws { try authenticated(); guard identity.role == "admin" else { throw NativeDBError.message("予約連携の設定と取込には管理者権限が必要です。") } }
}

actor CalendlyRelaySync {
    let service: CRMService, client: CalendlyRelayClient, binding: CalendlyRelayBinding
    private let validate: () throws -> Void, clock: () -> Date
    private var active = false
    init(service: CRMService,client: CalendlyRelayClient,binding: CalendlyRelayBinding,clock: @escaping () -> Date = Date.init,validate: @escaping () throws -> Void = {}) throws {
        guard client.clientID == binding.clientID, client.baseURL.absoluteString == binding.publicURL else { throw NativeDBError.conflict }
        self.service = service; self.client = try client.expecting(binding.instanceID); self.binding = binding; self.validate = validate; self.clock = clock
    }
    private func current() throws -> CalendlyRelayBinding {
        try Task.checkCancellation(); try service.requireCalendlyAdmin(); try validate()
        guard let value = try CalendlyRelayBinding.load(db:service.db), value.publicURL == binding.publicURL, value.clientID == binding.clientID, value.instanceID == binding.instanceID else { throw NativeDBError.conflict }; return value
    }
    @discardableResult func run() async throws -> Int {
        guard !active else { return 0 }; active = true; defer{active = false}; var applied = 0
        while true {
            let before = try current(), page = try await client.eventBatch(after:before.cursor)
            applied += try service.db.transaction {
                guard try current() == before else { throw NativeDBError.conflict }; var changed = 0
                try page.forEach { event in
                    try Task.checkCancellation()
                    if case let .event(input) = try CalendlyWebhook.normalizeAuthenticatedRelayBody(event.body) {
                        let result = try NativeCalendarImporter(db:service.db).apply(input,authorizedBy:service.identity); if result.action != "skipped" { changed += 1 }
                    }
                }
                var next = before; next.cursor = page.state.cursor!; try next.save(db:service.db)
                if page.state.hasMore == false { try service.db.setMetadata("calendlyRelay.lastSyncedAt.v1",value:try NativeCalendarEvents.stamp(clock())) }
                return changed
            }
            if page.state.hasMore == false { return applied }
        }
    }
}
