import Foundation

/// Isolated QA only: persists public fixture settings across app restarts. It
/// accepts one fixed fake key and never writes an entered secret to SQLite.
final class CampaignRelayQACredentials: CampaignRelayCredentialStore {
    private let db: NativeDatabase
    static let key = Data(repeating:7,count:32).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    private static let metadataKey = "qa.campaignRelaySettings.v1"
    init(db: NativeDatabase) throws {
        let env = ProcessInfo.processInfo.environment, root = db.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let normal = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NextCRMNative").resolvingSymlinksInPath().standardizedFileURL
        guard let mode = env["NEXTCRM_NATIVE_MAIL_TEST_MODE"], ["success","retry_once","retry_after_restart","reject"].contains(mode),
              let directory = env["NEXTCRM_NATIVE_DATA_DIR"], root == URL(fileURLWithPath:directory).resolvingSymlinksInPath().standardizedFileURL, root != normal,
              (try? String(contentsOf:root.appendingPathComponent(".native-mail-test"),encoding:.utf8)) == "NextCRM isolated mail QA\n" else {
            throw NativeDBError.message("受信窓口の検証には専用の検証データフォルダが必要です。")
        }
        self.db = db
    }
    private static func isLocal(_ url: URL?) -> Bool {
        guard let url else { return false }; return url.scheme == "http" && ["127.0.0.1","localhost","::1","[::1]"].contains(url.host ?? "")
    }
    static func request(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard isLocal(request.url) else { throw NativeDBError.message("検証モードではMac内の受信窓口だけを利用できます。") }
        return try await CampaignRelayClient.network(request)
    }
    func load(interactive: Bool) throws -> CampaignRelayCredentials? {
        guard let text = try db.metadata(Self.metadataKey), !text.isEmpty else { return nil }
        guard let value = try? JSONDecoder().decode([String:String].self,from:Data(text.utf8)), let url = value["publicURL"], Self.isLocal(URL(string:url)),
              let name = value["appName"], let client = value["clientID"], let instance = value["instanceID"] else { throw NativeDBError.message("検証用の受信窓口設定が不正です。") }
        return .init(publicURL:url,appName:name,clientID:client,instanceID:instance,authKey:Self.key)
    }
    func save(_ settings: CampaignRelayCredentials) throws {
        guard settings.authKey == Self.key, Self.isLocal(URL(string:settings.publicURL)) else { throw NativeDBError.message("検証専用の接続キーとMac内の受信窓口を使用してください。") }
        let publicFields = ["publicURL":settings.publicURL,"appName":settings.appName,"clientID":settings.clientID,"instanceID":settings.instanceID]
        try db.setMetadata(Self.metadataKey,value:String(decoding:try JSONEncoder().encode(publicFields),as:UTF8.self))
    }
    func remove() throws { try db.setMetadata(Self.metadataKey,value:"") }
}
