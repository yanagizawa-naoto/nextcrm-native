import Foundation

/// Business identity binding for the explicitly chosen personal/this-Mac mode.
/// It is not a login provider. The host owns macOS/root/control/lease authority.
/// Read APIs also work against an immutable, sealed review database; only bind
/// changes metadata, after the host has committed and opened the writable root.
enum NativePersonalWorkspace {
    enum State {
        case existing(CRMIdentity)
        case pristine
        case needsSelection(invalidBinding: Bool)
        case blocked
    }
    struct Owner {
        let id: String, name: String, email: String, role: String
    }
    struct Page { let rows: [Owner]; let total: Int; let offset: Int }
    /// Persist only inside the host's authenticated root/control approval.
    /// This serializable snapshot contains no credential and grants no authority.
    struct BindingDescriptor: Codable, Equatable {
        let version: Int
        let ownerID: String
        let ownerRevision: Int64
        let expectedLocalActor: String?
        let schemaSHA256: String
        let role: String
        let partnerAccountID: String?
    }
    struct Selection {
        let identity: CRMIdentity
        let ownerRevision: Int64
        fileprivate let expectedLocalActor: String?
        fileprivate let schemaSHA256: String
        var descriptor: BindingDescriptor {
            BindingDescriptor(version: 1, ownerID: identity.id, ownerRevision: ownerRevision,
                expectedLocalActor: expectedLocalActor, schemaSHA256: schemaSHA256,
                role: identity.role, partnerAccountID: identity.partnerAccountID)
        }
    }
    private static let identityFields = ["role", "userStatus", "banned", "partnerAccountId"]
    private static let eligible: RecordFilter = .every([
        .equal("userStatus", .text("ACTIVE")),
        .any([.equal("banned", .null), .not(.equal("banned", .integer(1)))]),
        .any(["admin", "manager", "user", "partner"].map { .equal("role", .text($0)) })
    ])
    private static func identity(_ record: NativeRecord, db: NativeDatabase) throws -> CRMIdentity {
        let result = CRMIdentity(id: record["id"].string, role: record["role"].string,
                                 partnerAccountID: record["partnerAccountId"] == .null ? nil : record["partnerAccountId"].string)
        // Use the existing authorization contract, including current role,
        // ACTIVE, banned and partner account checks; do not invent a new role.
        try CRMService(db: db, identity: result).authenticated()
        return result
    }
    private static func owner(_ id: String, db: NativeDatabase) throws -> NativeRecord {
        guard !id.isEmpty, id.utf8.count <= 256,
              let row = try db.page("Users", fields: identityFields, equal: ["id": .text(id)], limit: 1).rows.first else {
            throw NativeDBError.message("このデータの利用者を確認できません。利用者を選び直してください。")
        }
        return row
    }
    /// Invalid/dangling/banned bindings throw. They never fall back to admin.
    static func reuseExisting(_ db: NativeDatabase) throws -> CRMIdentity? {
        try db.transaction {
            guard let id = try db.metadata("localActor") else { return nil }
            return try identity(owner(id, db: db), db: db)
        }
    }
    static func inspect(_ db: NativeDatabase) throws -> State {
        try db.transaction {
            let binding = try db.metadata("localActor")
            if binding != nil, let current = try? reuseExisting(db) { return .existing(current) }
            if binding == nil, try db.isPristinePersonalWorkspace(), !hasImportMarker(db) { return .pristine }
            let count = try db.page("Users", fields: [], filter: eligible, limit: 1).total
            return count == 0 ? .blocked : .needsSelection(invalidBinding: binding != nil)
        }
    }
    /// A bounded, non-secret projection. Search is bounded before SQLite work;
    /// no password/token/photo/session payload is fetched for the picker.
    static func owners(_ db: NativeDatabase, search: String = "", offset: Int = 0) throws -> Page {
        guard search.utf8.count <= 512, offset >= 0, offset <= Int(Int32.max) - 100, offset % 100 == 0 else {
            throw NativeDBError.message("検索文字またはページ指定が長すぎます。")
        }
        let page = try db.page("Users", fields: ["name", "email", "role"], search: search,
                               offset: offset, filter: eligible, sort: "name", limit: 100)
        return Page(rows: page.rows.map { Owner(id: $0["id"].string,
            name: String($0["name"].string.prefix(256)), email: String($0["email"].string.prefix(320)), role: $0["role"].string) }, total: page.total, offset: offset)
    }
    /// No writes, including on a sealed read-only candidate. The host must
    /// retain this value together with the reviewed root/seal/control evidence.
    static func select(_ db: NativeDatabase, userID: String) throws -> Selection {
        try db.transaction {
            if let current = try? reuseExisting(db), current.id != userID { throw NativeDBError.conflict }
            let row = try owner(userID, db: db)
            return Selection(identity: try identity(row, db: db), ownerRevision: row.revision,
                             expectedLocalActor: try db.metadata("localActor"), schemaSHA256: db.schema.schemaSHA256)
        }
    }
    /// Call only for the root whose committed host authorization accompanies
    /// this selection. Never call while reviewing a sealed candidate.
    /// A surrounding transaction is allowed: metadata publication rolls back
    /// with it. The caller must not activate runtimes before that commit.
    static func bind(_ selection: Selection, to db: NativeDatabase, authorize: () throws -> Void) throws -> CRMIdentity {
        guard !db.isReadOnly else { throw NativeDBError.message("復元内容の確認中は利用者を確定できません。") }
        return try db.transaction {
            try Task.checkCancellation()
            try authorize()
            guard db.schema.schemaSHA256 == selection.schemaSHA256,
                  try db.metadata("localActor") == selection.expectedLocalActor else { throw NativeDBError.conflict }
            if let bound = try? reuseExisting(db), bound.id != selection.identity.id { throw NativeDBError.conflict }
            let row = try owner(selection.identity.id, db: db)
            let current = try identity(row, db: db)
            guard row.revision == selection.ownerRevision, current.role == selection.identity.role,
                  current.partnerAccountID == selection.identity.partnerAccountID else { throw NativeDBError.conflict }
            try Task.checkCancellation()
            // Authorization may validate OS/root/control evidence but must not
            // grant a new role or mutate the selected Users record.
            try db.setMetadata("localActor", value: current.id)
            return current
        }
    }
    /// Recovery only after the host has authenticated the durable pending
    /// record and opened that committed writable root. Same-owner completion is
    /// idempotent and respects its current role/status, even after profile edits.
    static func resumeBinding(_ descriptor: BindingDescriptor, to db: NativeDatabase, authorize: () throws -> Void) throws -> CRMIdentity {
        guard !db.isReadOnly else { throw NativeDBError.message("復元内容の確認中は利用者を確定できません。") }
        guard descriptor.version == 1, descriptor.ownerRevision > 0,
              UUID(uuidString: descriptor.ownerID) != nil, descriptor.ownerID.utf8.count == 36,
              descriptor.expectedLocalActor == nil || descriptor.expectedLocalActor!.utf8.count <= 256,
              descriptor.schemaSHA256 == db.schema.schemaSHA256,
              ["admin", "manager", "user", "partner"].contains(descriptor.role),
              descriptor.partnerAccountID == nil || (descriptor.partnerAccountID!.utf8.count == 36 && UUID(uuidString: descriptor.partnerAccountID!) != nil) else { throw NativeDBError.conflict }
        return try db.transaction {
            try Task.checkCancellation()
            try authorize()
            if try db.metadata("localActor") == descriptor.ownerID {
                guard let current = try reuseExisting(db) else { throw NativeDBError.conflict }
                return current
            }
            let selection = Selection(identity: CRMIdentity(id: descriptor.ownerID, role: descriptor.role, partnerAccountID: descriptor.partnerAccountID),
                ownerRevision: descriptor.ownerRevision, expectedLocalActor: descriptor.expectedLocalActor, schemaSHA256: descriptor.schemaSHA256)
            // The first authorize ran inside this same transaction. The second
            // current-authority check is intentional, not a default-success path.
            return try bind(selection, to: db, authorize: authorize)
        }
    }
    static func requirePristineSetup(_ db: NativeDatabase) throws {
        guard !db.isReadOnly, !hasImportMarker(db), try db.isPristinePersonalWorkspace() else {
            throw NativeDBError.message("既存データには管理者を自動作成しません。このMacで使う利用者を選んでください。")
        }
    }
    private static func hasImportMarker(_ db: NativeDatabase) -> Bool {
        // The root host additionally verifies fresh-root admission and restore
        // control. This marker check prevents empty offline imports from being
        // accidentally treated as an ordinary brand-new installation.
        let marker = db.url.deletingLastPathComponent().appendingPathComponent(".native-migration-candidate")
        return FileManager.default.fileExists(atPath: marker.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: marker.path)) != nil
    }
}
