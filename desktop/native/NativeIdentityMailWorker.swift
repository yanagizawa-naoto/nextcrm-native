import Foundation

/// Resolve must re-read the issuing authority's current challenge/user and
/// authorization. nil means superseded/revoked. It must have no external I/O.
/// The caller must never reconstruct an OTP from an untrusted queue payload.
actor NativeIdentityMailWorker {
    static let event = "identity.mail"
    typealias Resolve = (NativeIdentityMailIntent, Date) throws -> NativeIdentityMailContent?
    struct Transport {
        let identity: String
        let send: (Data, String) async throws -> String
    }
    let db: NativeDatabase
    let configuration: NativeIdentityMailConfiguration
    let binding: NativeIdentityMailBinding
    let resolve: Resolve
    let transport: () throws -> Transport
    let clock: () -> Date
    private var active = false
    init(db: NativeDatabase, configuration: NativeIdentityMailConfiguration, binding: NativeIdentityMailBinding,
         resolve: @escaping Resolve, transport: @escaping () throws -> Transport, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.configuration = configuration; self.binding = binding
        self.resolve = resolve; self.transport = transport; self.clock = clock
    }
    private func validate(_ intent: NativeIdentityMailIntent, at date: Date) throws {
        try intent.validate()
        guard intent.workspaceID == configuration.workspace.id, intent.issuer == configuration.workspace.issuer else { throw NativeIdentityMailError.configuration }
        guard intent.valid(at: date) else { throw NativeIdentityMailError.expired }
    }
    @discardableResult func enqueue(_ intent: NativeIdentityMailIntent) throws -> String {
        guard !db.isReadOnly else { throw NativeIdentityMailError.unavailable }
        return try db.transaction {
            try validate(intent, at: clock())
            guard try resolve(intent, clock()) != nil else { throw NativeIdentityMailError.unavailable }
            let encoded = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
            guard encoded.utf8.count <= 8192 else { throw NativeIdentityMailError.invalidIntent }
            if let previous = try db.job(id: intent.id) {
                guard previous.event == Self.event, let raw = previous.payload["intent"],
                      let old = try? JSONDecoder().decode(NativeIdentityMailIntent.self, from: Data(raw.utf8)), old == intent else { throw NativeIdentityMailError.changed }
                return intent.id
            }
            return try db.enqueue(Self.event, payload: ["intent": encoded], id: intent.id, now: clock())
        }
    }
    private func finishAccepted(_ job: NativeJob) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            guard let id = current.result["providerID"], UUID(uuidString: id) != nil else { throw NativeIdentityMailError.invalidIntent }
            try db.finishJob(current, result: current.result.merging(["outcome": "accepted"]) { _, new in new }, now: clock())
        }
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        try Task.checkCancellation()
        guard var job = try db.claimJob(events: [Self.event], now: clock()) else { return false }
        var attempted = false
        var expiry: Date?
        do {
            if job.result["providerID"] != nil { try finishAccepted(job); return true }
            guard let raw = job.payload["intent"], raw.utf8.count <= 8192,
                  let intent = try? JSONDecoder().decode(NativeIdentityMailIntent.self, from: Data(raw.utf8)), intent.id == job.id else { throw NativeIdentityMailError.invalidIntent }
            expiry = intent.expiresAt
            try validate(intent, at: clock())
            guard let material = try resolve(intent, clock()) else { throw NativeIdentityMailError.unavailable }
            let data = try material.data(intent: intent, configuration: configuration)
            let digest = binding.digest(data, intent: intent)
            let delivery = try transport()
            guard !delivery.identity.isEmpty, delivery.identity.utf8.count <= 1024 else { throw NativeIdentityMailError.configuration }
            job = try db.transaction {
                let current = try db.requireJobLease(job)
                try validate(intent, at: clock()); try Task.checkCancellation()
                guard let fresh = try resolve(intent, clock()), binding.digest(try fresh.data(intent: intent, configuration: configuration), intent: intent) == digest else { throw NativeIdentityMailError.unavailable }
                if let start = current.deliveryStartedAt {
                    guard clock() >= start, clock().timeIntervalSince(start) < 23 * 3600,
                          current.result["bodyBinding"] == digest, current.result["transportBinding"] == delivery.identity else { throw NativeIdentityMailError.changed }
                }
                try db.recordJobResult(current, result: ["bodyBinding": digest, "transportBinding": delivery.identity])
                try db.renewJobLease(current, now: clock())
                return try db.markJobDeliveryStarted(current, now: clock())
            }
            try Task.checkCancellation()
            attempted = true
            let providerID = try await delivery.send(data, job.id)
            guard UUID(uuidString: providerID) != nil else { throw MailSendError(message: "送信結果を確認できません。", retryable: true, review: false) }
            let current = try db.requireJobLease(job)
            var result = current.result; result["providerID"] = providerID; result["acceptedAt"] = ISO8601DateFormatter().string(from: clock())
            try db.recordJobResult(current, result: result)
            try finishAccepted(current)
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            let mail = error as? MailSendError
            let policy = error as? NativeIdentityMailError
            let wasAttempted = attempted || current.deliveryStartedAt != nil
            if !wasAttempted, policy == .expired || policy == .unavailable {
                try db.finishJob(current, result: ["outcome": policy == .expired ? "expired" : "superseded"], now: clock())
                return true
            }
            let retryable = mail?.retryable ?? (attempted && policy == nil && !(error is CancellationError))
            let next = clock().addingTimeInterval(max(mail?.retryAfter ?? 0, min(300, 5 * pow(2, Double(min(current.attempts - 1, 6))))))
            let retry = retryable && current.attempts < 8 && mail?.review != true && (expiry.map { next < $0 } ?? true)
            let review = mail?.review == true || (wasAttempted && !retry)
            // Do not persist arbitrary provider/authority error text: it may
            // contain an OTP, cookie, destination, or other credential material.
            let message = policy?.errorDescription ?? (retry ? "認証メールの送信を再試行します。" : review ? "認証メールの送信結果を確認してください。" : "認証メールを送信できませんでした。")
            try db.failJob(current, message: message, retryAt: retry ? next : nil, needsReview: review)
        }
        return true
    }
}
