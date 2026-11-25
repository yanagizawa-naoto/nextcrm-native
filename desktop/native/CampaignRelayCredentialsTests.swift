import Foundation

enum CampaignRelayCredentialsTests {
    static var checks = 0
    final class Store: CampaignRelayCredentialStore {
        var value: CampaignRelayCredentials?
        var reads = 0, saves = 0, removes = 0
        var failSave = false
        func load(interactive: Bool) throws -> CampaignRelayCredentials? { reads += 1; return value }
        func save(_ settings: CampaignRelayCredentials) throws { if failSave { throw NativeDBError.message("test credential storage failure") }; saves += 1; value = settings }
        func remove() throws { removes += 1; value = nil }
    }
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL relay credentials: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () async throws -> Void) async throws { do { try await body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL relay credentials accepted: "+label) }
    static func run(_ resources: URL) async throws {
        let f = try await CampaignMailTests.Fixture.make(resources), server = try CampaignRelaySyncTests.Server(f); defer { server.stop() }
        let store = Store(), user = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!
        try f.change(user,["role":.text("user")])
        let ordinary = CRMService(db:f.db,identity:.init(id:f.service.identity.id,role:"user",partnerAccountID:nil))
        try await rejects("nonadmin settings read"){_ = try ordinary.campaignRelayPreferences(store:store)}
        try await rejects("nonadmin settings save"){try await ordinary.saveCampaignRelaySettings(publicURL:server.url.absoluteString,appName:"CRM",authKey:CampaignRelaySyncTests.key,store:store,allowLoopbackHTTP:true)}
        try await rejects("nonadmin settings remove"){try ordinary.removeCampaignRelaySettings(store:store)}
        try check(store.reads == 0 && store.saves == 0 && store.removes == 0,"denied operations never touch secret store")
        try f.change(user,["role":.text("admin")])
        func save(name: String = "日本語CRM", key: String = CampaignRelaySyncTests.key, request: @escaping CampaignRelayClient.Request = CampaignRelayClient.network) async throws {
            try await f.service.saveCampaignRelaySettings(publicURL:server.url.absoluteString+"/",appName:name,authKey:key,store:store,allowLoopbackHTTP:true,request:request,clock:{f.now})
        }
        try await rejects("missing initial key"){try await save(key:"")}
        try await rejects("blank app name"){try await save(name:" \n ")}
        try await rejects("app name controls"){try await save(name:"CRM\u{0000}")}
        try await rejects("invalid authentication key"){try await save(key:"invalid")}
        try check(store.value == nil,"invalid settings are not persisted")
        store.failSave = true
        try await rejects("keychain failure after remote/local bind"){try await save()}
        let connected = try CampaignRelayBinding.load(db:f.db)!
        try check(store.value == nil && connected.cursor == 0,"credential failure preserves recoverable binding")
        store.failSave = false; try await save()
        try check(store.value?.publicURL == server.url.absoluteString && store.value?.appName == "日本語CRM" && store.value?.instanceID == connected.instanceID,"canonical public URL and identity stored with key")
        let summary = try f.service.campaignRelayPreferences(store:store)
        try check(summary.configured && summary.appName == "日本語CRM","settings summary exposes configuration status")
        try check(try CampaignEventTests.scalar(f,"SELECT instr(group_concat(value),'\(CampaignRelaySyncTests.key)') FROM native_metadata") == "0","shared authentication key absent from SQLite metadata")
        f.config = try store.value!.configuration(allowLoopbackHTTP:true)
        let client = try store.value!.client(db:f.db,allowLoopbackHTTP:true,clock:{f.now})
        let sync = try CampaignRelaySync(db:f.db,client:client,binding:connected,clock:{f.now})
        _ = try await f.worker(ready:{config in try await sync.prepareToSend(sendID:f.sendID,configuration:config)}).runNext()
        try await server.unsubscribe(f.send()["unsubscribe_token"].string)
        _ = try await sync.synchronize()
        let cursor = try CampaignRelayBinding.load(db:f.db)!.cursor
        try check(cursor == 1,"fixture has applied remote opt-out")
        try await save(name:"名称変更",key:"")
        try check(store.value?.authKey == CampaignRelaySyncTests.key && store.value?.appName == "名称変更","blank key retains secret during metadata edit")
        try check(try CampaignRelayBinding.load(db:f.db)?.cursor == cursor,"settings update preserves cursor")
        // Revocation at either network boundary prevents the final local save.
        for endpoint in ["health","bind","unsubscribe"] {
            let previousSaves = store.saves
            try await rejects("permissions revoked during "+endpoint){
                try await save(name:"保存不可",key:"",request:{ request in
                    let response = try await CampaignRelayClient.network(request)
                    if request.url!.path.hasSuffix("/"+endpoint) { try f.change(user,["role":.text("user")]) }
                    return response
                })
            }
            try check(store.saves == previousSaves && store.value?.appName == "名称変更","revocation does not change credential item")
            try f.change(user,["role":.text("admin")])
        }
        try await rejects("wrong replacement key"){try await save(key:Data(repeating:8,count:32).base64EncodedString().replacingOccurrences(of:"=",with:""))}
        try check(store.value?.authKey == CampaignRelaySyncTests.key,"failed key validation preserves original")
        let other = try await CampaignMailTests.Fixture.make(resources)
        try await rejects("credential cannot be used with another CRM"){_ = try store.value!.client(db:other.db,allowLoopbackHTTP:true)}
        try f.service.removeCampaignRelaySettings(store:store)
        try check(store.value == nil && store.removes == 1,"admin removes credential")
        try check(try CampaignRelayBinding.load(db:f.db)?.cursor == cursor,"deleting key keeps stop history and binding")
        try await rejects("removed key is not recoverable as blank"){try await save(key:"")}
        try await save()
        try check(try CampaignRelayBinding.load(db:f.db)?.cursor == cursor && f.bodies.count == 1,"reconnect preserves cursor and cannot send additional mail")
        print("CampaignRelayCredentialsTests: \(checks) checks passed; fake credential store, loopback receiver only")
    }
    static func keychainProbe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-RelayKeychainProbe-"+UUID().uuidString)
        let store = KeychainCampaignRelayCredentials(databaseURL:root.appendingPathComponent("crm.sqlite"))
        guard try store.load(interactive:false) == nil else { throw NativeDBError.message("Keychain probe destination already exists") }
        defer { try? store.remove() }
        let first = CampaignRelayCredentials(publicURL:"https://probe.example.invalid",appName:"検証",clientID:UUID().uuidString.lowercased(),instanceID:UUID().uuidString.lowercased(),authKey:CampaignRelaySyncTests.key)
        try store.save(first)
        try check(try store.load(interactive:false) == first,"real Keychain read/save scoped fake credential")
        let second = CampaignRelayCredentials(publicURL:first.publicURL,appName:"更新",clientID:first.clientID,instanceID:first.instanceID,authKey:first.authKey)
        try store.save(second)
        try check(try store.load(interactive:false) == second,"real Keychain update is one item")
        try check(try KeychainCampaignRelayCredentials(databaseURL:root.appendingPathComponent("other.sqlite")).load(interactive:false) == nil,"real Keychain database isolation")
        try store.remove(); try store.remove()
        try check(try store.load(interactive:false) == nil,"real Keychain fake credential removed")
        print("CampaignRelayKeychainProbe: \(checks) checks passed; temporary fake credential removed")
    }
}
