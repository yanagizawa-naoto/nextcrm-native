import Foundation
import CryptoKit

/// Loss-prevention only: deleting a user must not erase the last pointer to an
/// immutable personal credential. These records grant no permission to erase it.
/// Restore already classifies metadata containing "cleanup" as requiring review.
enum NativeUserCredentialCleanup {
    enum Family: String, Codable {
        case ai, email, google
        var prefix: String { switch self { case .ai: return "native-ai-keychain:"; case .email: return "native-keychain:"; case .google: return "keychain:v1:" } }
        var service: String { switch self { case .ai: return "local.nextcrm.native.ai.v1"; case .email: return "local.nextcrm.native.email.v1"; case .google: return "local.nextcrm.native.google-calendar.v1" } }
        var model: String { switch self { case .ai: return "ApiKeys"; case .email: return "EmailAccount"; case .google: return "CalendarConnection" } }
        var fields: [String] { switch self { case .ai: return ["encryptedKey"]; case .email: return ["passwordEncrypted"]; case .google: return ["refreshTokenEncrypted", "accessTokenEncrypted"] } }
    }
    // v1 AI keys are kept for compatibility with the original held-intent slice.
    static let holdPrefix = "user.credentials.cleanup.ai.hold.v1."
    static let intentPrefix = "user.credentials.cleanup.ai.intent.v1."
    struct Hold: Codable { let version: Int; let state: String; let credentialID: String }
    struct Intent: Codable {
        let version: Int; let state: String; let service: String
        let credentialID: String; let sourceNamespaceSHA256: String
        let userID: String; let recordID: String; let provider: String; let scope: String
        let requestedBy: String; let requestedAt: String
        var sourceModel: String? = nil; var sourceField: String? = nil
    }
    static func namespace(_ db: NativeDatabase) -> String {
        SHA256.hash(data: Data(db.url.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func intentKey(namespace: String, recordID: String, credentialID: String) -> String { intentPrefix + namespace + "." + recordID + "." + credentialID }
    /// Mere existence fences cleanup, even if a restored marker is malformed or
    /// belongs to another source namespace. Parsing failure is not erase authority.
    static func isHeld(db: NativeDatabase, credentialID: String) throws -> Bool {
        try db.metadata(holdPrefix + credentialID) != nil
    }
    static func markerKey(_ family: Family, _ credentialID: String) -> String { "user.credentials.cleanup." + family.rawValue + ".hold.v1." + credentialID }
    static func referenceIntentKey(_ family: Family, namespace: String, recordID: String, field: String, credentialID: String) -> String {
        if family == .ai { return intentKey(namespace: namespace, recordID: recordID, credentialID: credentialID) }
        return "user.credentials.cleanup." + family.rawValue + ".intent.v1." + namespace + "." + recordID + "." + field + "." + credentialID
    }
    static func isHeld(db: NativeDatabase, family: Family, credentialID: String) throws -> Bool {
        try db.metadata(markerKey(family, credentialID)) != nil
    }
    /// Existing explicit/rotation cleanup calls this at their existing removal
    /// point. User deletion's hold publication and this check share the writer
    /// fence. No new queue or permission to erase any additional key is created.
    @discardableResult static func removeUnlessHeld(db: NativeDatabase, family: Family, credentialID: String, remove: () throws -> Void) throws -> Bool {
        guard !db.isReadOnly else {throw NativeDBError.message("このデータベースは閲覧専用です。")}
        return try db.transaction {
            guard try !isHeld(db: db, family: family, credentialID: credentialID) else { return false }
            try remove(); return true
        }
    }
    @discardableResult static func holdPersonalReferences(db: NativeDatabase, userID: String, actorID: String, now: Date) throws -> Int {
        try db.transaction {
            var count = 0
            for family in [Family.ai, .email, .google] { count += try capture(family, db: db, userID: userID, actorID: actorID, now: now) }
            return count
        }
    }
    /// Internal deletion hook. The administrator gate belongs to the enclosing
    /// user action; the same transaction also owns its FK cascades and rollback.
    /// Per-row intents preserve aliases and namespaces without growing one JSON.
    @discardableResult static func holdPersonalAIReferences(db: NativeDatabase, userID: String, actorID: String, now: Date) throws -> Int {
        try capture(.ai, db: db, userID: userID, actorID: actorID, now: now)
    }
    private static func capture(_ family: Family, db: NativeDatabase, userID: String, actorID: String, now: Date) throws -> Int {
        try db.transaction {
            guard UUID(uuidString: userID) != nil, UUID(uuidString: actorID) != nil, now.timeIntervalSince1970.isFinite else { throw NativeDBError.conflict }
            let sourceNamespace = namespace(db), encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var after: String?, recorded = 0
            var scope: [RecordFilter] = [.equal("userId", .text(userID))]
            if family == .ai { scope.append(.equal("scope", .text("USER"))) }
            // Only this native Google integration owns keychain:v1 references.
            if family == .google { scope.append(.equal("provider", .text("google"))) }
            let descriptors = family == .ai ? ["provider", "scope"] : family == .google ? ["provider", "scopeLevel"] : []
            while true {
                try Task.checkCancellation()
                let rows = try db.keysetPage(family.model, fields: family.fields + descriptors, after: after, filter: .every(scope),
                    maximumTextCharacters: Dictionary(uniqueKeysWithValues: family.fields.map { ($0, family.prefix.utf8.count + 37) }))
                for row in rows { for field in family.fields {
                    let reference = row[field].string
                    guard reference.hasPrefix(family.prefix) else { continue }
                    let id = String(reference.dropFirst(family.prefix.count))
                    // Keep exact Keychain account case; the extra read character
                    // prevents an oversized/legacy value becoming a valid UUID.
                    guard id.utf8.count == 36, UUID(uuidString: id) != nil else { continue }
                    let key = referenceIntentKey(family, namespace: sourceNamespace, recordID: row["id"].string, field: field, credentialID: id)
                    if try db.metadata(key) == nil {
                        let intent = Intent(version: 1, state: "reviewHeld", service: family.service, credentialID: id,
                            sourceNamespaceSHA256: sourceNamespace, userID: userID, recordID: row["id"].string,
                            provider: family == .email ? "IMAP_SMTP" : row["provider"].string,
                            scope: family == .ai ? row["scope"].string : family == .google ? row["scopeLevel"].string : "USER",
                            requestedBy: actorID, requestedAt: ISO8601DateFormatter().string(from: now), sourceModel: family.model, sourceField: field)
                        try db.setMetadata(key, value: String(decoding: encoder.encode(intent), as: UTF8.self)); recorded += 1
                    }
                    let marker = markerKey(family, id)
                    if try db.metadata(marker) == nil {
                        try db.setMetadata(marker, value: String(decoding: encoder.encode(Hold(version: 1, state: "reviewHeld", credentialID: id)), as: UTF8.self))
                    }
                } }
                if rows.count < 100 { return recorded }; after = rows.last!["id"].string
            }
        }
    }
}
