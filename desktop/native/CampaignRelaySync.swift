import Foundation

/// Authenticated receiver evidence is a review hint, never local acceptance.
struct CampaignRelayReceiptConflict: LocalizedError {
    let sendID: String
    let providerID: String
    let instanceID: String
    var errorDescription: String? { "受信窓口に未確認の送信結果があります。送信サービスの結果を確認してください。" }
}

/// A binding is permanent for this CRM database. Rotating a credential does not
/// reset the cursor or authorize replacing the receiver's event history.
struct CampaignRelayBinding: Codable, Equatable {
    let publicURL: String
    let clientID: String
    let instanceID: String
    var cursor: Int64
    static let metadataKey = "campaignRelay.binding.v1"
    static let clientKey = "campaignRelay.clientID.v1"

    static func clientID(db: NativeDatabase) throws -> String {
        try db.transaction {
            if let id = try db.metadata(clientKey) {
                guard UUID(uuidString:id) != nil else { throw NativeDBError.message("保存したメール受信窓口の接続IDが不正です。") }; return id
            }
            let id = UUID().uuidString.lowercased(); try db.setMetadata(clientKey,value:id); return id
        }
    }
    static func load(db: NativeDatabase) throws -> Self? {
        guard let text = try db.metadata(metadataKey) else { return nil }
        guard let value = try? JSONDecoder().decode(Self.self,from:Data(text.utf8)),
              UUID(uuidString:value.clientID) != nil, UUID(uuidString:value.instanceID) != nil,
              value.cursor >= 0, value.cursor <= 9_007_199_254_740_991,
              try db.metadata(clientKey) == value.clientID else { throw NativeDBError.message("保存したメール受信窓口の接続情報が不正です。") }
        return value
    }
    func save(db: NativeDatabase) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try db.setMetadata(Self.metadataKey,value:String(decoding:try encoder.encode(self),as:UTF8.self))
    }
    /// External requests happen outside SQLite transactions. If the remote bind
    /// succeeds but the local commit fails, the same permanent client ID retries.
    static func connect(db: NativeDatabase, client: CampaignRelayClient, validate: () throws -> Void = {}) async throws -> Self {
        try Task.checkCancellation(); try validate()
        let previous = try load(db:db)
        guard try clientID(db:db) == client.clientID,
              previous == nil || (previous!.clientID == client.clientID && previous!.publicURL == client.baseURL.absoluteString) else {
            throw NativeDBError.message("このCRMに登録済みのメール受信窓口と接続先が異なります。")
        }
        let health = try await client.health()
        guard previous == nil || (health.instanceId == previous!.instanceID && health.head >= previous!.cursor) else {
            throw NativeDBError.message("メール受信窓口が変更されたか、履歴が巻き戻っています。")
        }
        try Task.checkCancellation(); try validate()
        let bound = try await client.expecting(instanceID:health.instanceId).bind()
        guard bound.head >= (previous?.cursor ?? 0) else { throw NativeDBError.message("メール受信窓口の履歴が接続中に巻き戻りました。") }
        try Task.checkCancellation(); try validate()
        try await client.expecting(instanceID:bound.instanceId).checkUnsubscribeRoute()
        let value = previous ?? Self(publicURL:client.baseURL.absoluteString,clientID:client.clientID,instanceID:bound.instanceId,cursor:0)
        return try db.transaction {
            try Task.checkCancellation(); try validate()
            guard try load(db:db) == previous, try db.metadata(clientKey) == client.clientID else { throw NativeDBError.conflict }
            try value.save(db:db); return value
        }
    }
}

/// One bounded page at a time. Event effects and the cursor commit together.
/// Neither syncing nor uploading a receipt can create another outgoing email.
actor CampaignRelaySync {
    let db: NativeDatabase
    let client: CampaignRelayClient
    let binding: CampaignRelayBinding
    let clock: () -> Date
    private var active = false
    init(db: NativeDatabase, client: CampaignRelayClient, binding: CampaignRelayBinding, clock: @escaping () -> Date = Date.init) throws {
        guard client.clientID == binding.clientID, client.baseURL.absoluteString == binding.publicURL else { throw NativeDBError.conflict }
        self.db = db; self.client = try client.expecting(instanceID:binding.instanceID); self.binding = binding; self.clock = clock
    }
    private func current() throws -> CampaignRelayBinding {
        guard let value = try CampaignRelayBinding.load(db:db), value.clientID == binding.clientID,
              value.instanceID == binding.instanceID, value.publicURL == binding.publicURL else {
            throw NativeDBError.message("メール受信窓口の接続設定が変更されています。")
        }
        return value
    }
    private func registration(_ id: String) throws -> CampaignRelayClient.Registration {
        _ = try current()
        guard let send = try db.get("crm_campaign_sends",key:["id":.text(id)]),
              let job = try db.job(id:id), job.event == CampaignWorkflow.sendStepEvent,
              job.payload["sendId"] == id, job.payload["campaignId"] == send["campaign_id"].string,
              job.result["publicURL"] == binding.publicURL,
              UUID(uuidString:send["unsubscribe_token"].string) != nil else {
            throw NativeDBError.message("受信窓口に登録するメールの保存内容が一致しません。")
        }
        let provider = send["resend_message_id"] == .null ? nil : send["resend_message_id"].string
        if let provider {
            guard job.result["providerID"] == provider,
                  job.result["acceptedAt"].flatMap(CampaignRelayClient.date) != nil else {
                throw NativeDBError.message("メールの受付記録と配信結果が一致しません。送信結果を確認してください。")
            }
        }
        return .init(sendId:id,token:send["unsubscribe_token"].string,providerId:provider)
    }
    private func register(_ items: [CampaignRelayClient.Registration]) async throws {
        let response = try await client.register(items)
        let registrations = Dictionary(uniqueKeysWithValues:response.registrations!.map{($0.sendId,$0)})
        try db.transaction {
            _ = try current()
            for item in items {
                let row = registrations[item.sendId]!
                guard try registration(item.sendId) == item else { throw NativeDBError.conflict }
                // A restored local database must never infer a completed send
                // just because the external receiver remembers a provider ID.
                guard row.providerId == item.providerId else {
                    if item.providerId == nil, let provider = row.providerId {
                        throw CampaignRelayReceiptConflict(sendID:item.sendId,providerID:provider,instanceID:binding.instanceID)
                    }
                    throw MailSendError(message:"受信窓口に未確認の送信結果があります。送信サービスの結果を確認してください。",retryable:false,review:true)
                }
                if let date = row.unsubscribedAt.flatMap(CampaignRelayClient.date) {
                    guard date <= clock().addingTimeInterval(300), try db.unsubscribeCampaign(token:item.token,now:date) != nil else { throw NativeDBError.conflict }
                }
                try db.recordCampaignRelayRegistration(instanceID:binding.instanceID,sendID:item.sendId,token:item.token,providerID:item.providerId)
            }
        }
    }
    private func uploadReceipts(heartbeat: () throws -> Void) async throws {
        var after = ""
        while true {
            try Task.checkCancellation(); try heartbeat(); _ = try current()
            let ids = try db.campaignRelayReceiptIDs(instanceID:binding.instanceID,publicURL:binding.publicURL,after:after)
            guard !ids.isEmpty else { return }
            let items = try db.transaction { try ids.map(registration) }
            try await register(items); after = ids.last!
        }
    }
    private func pull(heartbeat: () throws -> Void) async throws -> Int {
        var count = 0
        while true {
            try Task.checkCancellation(); try heartbeat()
            let before = try current(), page = try await client.events(after:before.cursor)
            try db.transaction {
                guard try current() == before else { throw NativeDBError.conflict }
                for event in page.events! {
                    let item = try registration(event.sendId)
                    guard let received = CampaignRelayClient.date(event.receivedAt) else { throw NativeDBError.conflict }
                    if event.kind == "unsubscribe" {
                        guard item.token == event.token, try db.unsubscribeCampaign(token:item.token,now:received) != nil else { throw NativeDBError.conflict }
                    } else {
                        let job = try db.job(id:event.sendId)
                        let retiredHint = item.providerId == nil && job?.status == "done" &&
                            ["notSent","unknown"].contains(job?.result["reviewOutcome"] ?? "") &&
                            job?.result["relayProviderIDHint"] == event.providerId
                        guard item.providerId == event.providerId || retiredHint else {
                            throw NativeDBError.message("配信結果と保存済みのメール受付IDが一致しません。送信結果を確認してください。")
                        }
                        // A terminal unknown/not-sent review does not adopt the
                        // receipt. Retire signed observations against that
                        // exact review so they do not fill the pending inbox.
                        _ = try db.receiveCampaignEvent(id:event.sourceEventId,providerID:event.providerId!,kind:event.kind,bodySHA256:event.bodySHA256!,receivedAt:received,now:clock(),retiredSendID:retiredHint ? event.sendId : nil)
                    }
                }
                var next = before; next.cursor = page.cursor!; try next.save(db:db)
            }
            count += page.events!.count
            if page.hasMore == false { return count }
        }
    }
    /// Called at startup/wake and after locally committing provider receipts.
    /// The runtime schedules retries; this actor starts no timer or subprocess.
    @discardableResult func synchronize(heartbeat: () throws -> Void = {}) async throws -> Int {
        guard !active else { throw CampaignRelayError(message:"配信結果を同期中です。しばらくしてから再試行してください。",retryable:true) }
        active = true; defer { active = false }
        try await uploadReceipts(heartbeat:heartbeat)
        return try await pull(heartbeat:heartbeat)
    }
    /// Required before external mail. Register the actual token and drain all
    /// opt-outs, then let the worker recheck its current authorization and lease.
    func prepareToSend(sendID: String, configuration: CampaignMailConfiguration, heartbeat: () throws -> Void = {}) async throws {
        guard !active else { throw CampaignRelayError(message:"配信結果を同期中です。しばらくしてから再試行してください。",retryable:true) }
        active = true; defer { active = false }
        guard configuration.publicURL.absoluteString == binding.publicURL else { throw NativeDBError.conflict }
        try heartbeat(); try await client.checkUnsubscribeRoute()
        try heartbeat(); let item = try db.transaction { try registration(sendID) }
        try await register([item])
        try await uploadReceipts(heartbeat:heartbeat)
        _ = try await pull(heartbeat:heartbeat)
    }
}
