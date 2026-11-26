import Foundation
import CryptoKit
import Security

private final class MemoryCredentials: NativeChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var value: Data?; private(set) var writes = 0, reads = 0
    init(_ envelope: NativeChatGPTEnvelope? = nil) throws { value = try envelope.map { try JSONEncoder().encode($0) } }
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func replace(_ data: Data, expected: Data?) throws { lock.lock(); defer { lock.unlock() }; guard value == expected else { throw NativeChatGPTError.invalid("CAS") }; value = data; writes += 1 }
    func decoded() throws -> NativeChatGPTEnvelope { try JSONDecoder().decode(NativeChatGPTEnvelope.self, from: load()!) }
}
private actor Flag {
    var allowed = true
    func set(_ value: Bool) { allowed = value }
    func check() throws { if !allowed { throw NativeChatGPTError.invalid("権限なし") } }
}
private actor Gate {
    var entered = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if released { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { released = true; let all = waiters; waiters = []; all.forEach { $0.resume() } }
}
private actor Provider {
    let key = P256.Signing.PrivateKey(); let now: Date
    var nonce = "", client = "oaiapp_one", subject = "subject-one", scopes = NativeChatGPTOAuth.scopes, refreshStatus = 200, revokeStatus = 200
    var requests: [String] = [], refreshes = 0, inferences = 0, authQueries: [[String: String]] = []
    init(now: Date) { self.now = now }
    func configure(client: String? = nil, subject: String? = nil, scopes: String? = nil, refreshStatus: Int? = nil, revokeStatus: Int? = nil) {
        if let client { self.client = client }; if let subject { self.subject = subject }; if let scopes { self.scopes = scopes }; if let refreshStatus { self.refreshStatus = refreshStatus }; if let revokeStatus { self.revokeStatus = revokeStatus }
    }
    func jwt(_ overrides: [String: Any] = [:], nonce: String? = nil) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "kid": "test-ec"]
        var payload: [String: Any] = ["iss": NativeChatGPTOAuth.issuer, "sub": subject, "aud": client, "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(3600).timeIntervalSince1970, "nonce": nonce ?? self.nonce, "email": "person@example.invalid", "email_verified": true]
        payload.merge(overrides) { _, new in new }
        let a = NativeChatGPTOAuth.base64(try JSONSerialization.data(withJSONObject: header)), b = NativeChatGPTOAuth.base64(try JSONSerialization.data(withJSONObject: payload))
        return a+"."+b+"."+NativeChatGPTOAuth.base64(try key.signature(for: Data((a+"."+b).utf8)).rawRepresentation)
    }
    func jwks() throws -> Data {
        let raw = key.publicKey.x963Representation
        return try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "crv": "P-256", "kid": "test-ec", "use": "sig", "alg": "ES256", "x": NativeChatGPTOAuth.base64(Data(raw[1..<33])), "y": NativeChatGPTOAuth.base64(Data(raw[33..<65]))]]])
    }
    func open(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }); authQueries.append(values); nonce = values["nonce"]!
        var callback = URLComponents(string: values["redirect_uri"]!)!
        callback.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: values["state"]!), .init(name: "client_id", value: client)]
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: callback.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NativeChatGPTError.invalid("loopback") }
    }
    func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!; requests.append(url.path)
        var status = 200; var object: [String: Any] = [:]
        switch url {
        case NativeChatGPTOAuth.jwksEndpoint: return (try jwks(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case NativeChatGPTOAuth.discoveryEndpoint: object = ["issuer": NativeChatGPTOAuth.issuer, "revocation_endpoint": NativeChatGPTOAuth.issuer+"/api/accounts/oauth/revoke"]
        case NativeChatGPTOAuth.tokenEndpoint:
            let fields = URLComponents(string: "http://example.invalid/?"+String(decoding: request.httpBody!, as: UTF8.self))!.queryItems!
            let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
            guard values["resource"] == NativeChatGPTOAuth.resource, values["client_secret"] == nil, values["client_id"] != "dynamic_agent_client" else { throw NativeChatGPTError.invalid("request contract") }
            if values["grant_type"] == "refresh_token" {
                refreshes += 1; status = refreshStatus; try await Task.sleep(nanoseconds: 20_000_000)
                object = status == 200 ? ["access_token": "new-access", "refresh_token": "new-refresh", "token_type": "Bearer", "expires_in": 3600, "scope": scopes] : ["error": status == 400 ? "invalid_grant" : "temporarily_unavailable"]
            } else {
                object = ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "id_token": try jwt(), "token_type": "Bearer", "expires_in": 3600, "scope": scopes]
            }
        case NativeChatGPTInference.modelsEndpoint:
            object = ["models": [["slug": "model-hidden", "display_name": "Hidden", "visibility": "hidden"], ["slug": "model-b", "display_name": "モデルB", "visibility": "list"], ["slug": "model-a", "display_name": "モデルA", "visibility": "list"]]]
        default:
            guard url.path == "/api/accounts/oauth/revoke" else { throw NativeChatGPTError.invalid("unexpected endpoint") }; status = revokeStatus
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["x-request-id": "request-test"])!)
    }
    func stream(_ request: URLRequest) throws -> String {
        inferences += 1
        let value = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        guard request.url == NativeChatGPTInference.endpoint, value["store"] as? Bool == false, value["stream"] as? Bool == true,
              value["input"] is [[String: Any]], value["model"] as? String == "model-b", Set(value.keys) == ["model", "instructions", "input", "store", "stream"] else { throw NativeChatGPTError.invalid("inference contract") }
        return "日本語の要約です。"
    }
}

@main enum NativeChatGPTTests {
    static var checks = 0
    static func check(_ value: Bool, _ name: String) throws { guard value else { throw NativeChatGPTError.invalid("FAIL: "+name) }; checks += 1 }
    static func reject(_ name: String, _ action: () async throws -> Void) async throws {
        do { try await action() } catch { checks += 1; return }; throw NativeChatGPTError.invalid("ACCEPTED: "+name)
    }
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), provider = Provider(now: Date(timeIntervalSince1970: 1_800_000_000))
        let redirect = URL(string: "http://127.0.0.1:12345/auth/callback")!
        let attempt = NativeChatGPTOAuth.Attempt(state: String(repeating: "s", count: 43), nonce: String(repeating: "n", count: 43), verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", hostID: "urn:uuid:00000000-0000-0000-0000-000000000001", redirect: redirect, clientID: nil, idTokenHint: nil, loginHint: nil, reconsent: false)
        let query = URLComponents(url: try attempt.authorizationURL(), resolvingAgainstBaseURL: false)!.queryItems!
        try check(query.first { $0.name == "code_challenge" }?.value == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC7636 S256")
        try check(query.contains { $0.name == "client_id" && $0.value == "dynamic_agent_client" }, "dynamic first registration")
        try check(query.contains { $0.name == "resource" && $0.value == NativeChatGPTOAuth.resource }, "public resource")
        func callback(_ tail: String) -> URL { URL(string: redirect.absoluteString+"?state="+attempt.state+tail)! }
        try check(try attempt.callback(callback("&code=abc&client_id=oaiapp_one")).clientID == "oaiapp_one", "issued callback client")
        for tail in ["&code=x", "&code=x&client_id=dynamic_agent_client", "&code=x&code=y&client_id=oaiapp_one", "&state=wrong&code=x&client_id=oaiapp_one", "&error=access_denied", "&code=x&client_id=oaiapp_one&client_id=oaiapp_two"] {
            try await reject("callback rejects "+String(checks)) { _ = try attempt.callback(callback(tail)) }
        }
        let jwks = try await provider.jwks(), jwt = try await provider.jwt(nonce: "expected")
        let identity = try NativeChatGPTIdentity.verify(jwt, jwks: jwks, clientID: "oaiapp_one", nonce: "expected", accessToken: nil, now: now)
        try check(identity.subject == "subject-one" && identity.emailVerified, "actual ES256 signature")
        let rsa = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let exported = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(rsa)!, nil)! as Data
        func contents(_ bytes: [UInt8], _ offset: inout Int) -> Data {
            offset += 1; var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 } }
            let value = Data(bytes[offset..<offset+length]); offset += length; return value
        }
        var offset = 0; let integers = Array(contents(Array(exported), &offset)); offset = 0
        let n = Data(contents(integers, &offset).drop(while: { $0 == 0 })), e = contents(integers, &offset)
        let rsaJWKS = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test-rsa", "alg": "RS256", "n": NativeChatGPTOAuth.base64(n), "e": NativeChatGPTOAuth.base64(e)]]])
        let rsaHeader = NativeChatGPTOAuth.base64(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-rsa"]))
        let rsaMessage = rsaHeader+"."+jwt.split(separator: ".")[1]
        let rsaSignature = SecKeyCreateSignature(rsa, .rsaSignatureMessagePKCS1v15SHA256, Data(rsaMessage.utf8) as CFData, nil)! as Data
        let rsaJWT = rsaMessage+"."+NativeChatGPTOAuth.base64(rsaSignature)
        try check(try NativeChatGPTIdentity.verify(rsaJWT, jwks: rsaJWKS, clientID: "oaiapp_one", nonce: "expected", accessToken: nil, now: now).subject == "subject-one", "actual RS256 2048-bit signature")
        for changes: [String: Any] in [["iss": "https://evil.invalid"], ["aud": "oaiapp_other"], ["exp": now.addingTimeInterval(-30).timeIntervalSince1970], ["iat": now.addingTimeInterval(30).timeIntervalSince1970], ["sub": ""], ["aud": ["oaiapp_one", "oaiapp_two"]], ["exp": true], ["nbf": now.addingTimeInterval(30).timeIntervalSince1970], ["nonce": "bad"], ["at_hash": "wrong"]] {
            let token = try await provider.jwt(changes, nonce: "expected")
            try await reject("signed invalid claims") { _ = try NativeChatGPTIdentity.verify(token, jwks: jwks, clientID: "oaiapp_one", nonce: "expected", accessToken: "synthetic-access", now: now) }
        }
        let bad = String(jwt.dropLast())+((jwt.last == "A") ? "B" : "A")
        try await reject("signature tamper") { _ = try NativeChatGPTIdentity.verify(bad, jwks: jwks, clientID: "oaiapp_one", nonce: "expected", accessToken: nil, now: now) }
        var parser = NativeChatGPTInference.Decoder()
        let events = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"日本語🙂\"}\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\ndata: [DONE]\n\n"
        for byte in events.utf8 { try parser.append(byte) }; try check(try parser.finish() == "日本語🙂", "incremental UTF8/SSE completion")
        for text in ["data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n", "data: invalid\n\n", "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n", "data: {\"type\":\"response.refusal.delta\"}\n\n"] {
            try await reject("incomplete or failed SSE") { var p = NativeChatGPTInference.Decoder(); for b in text.utf8 { try p.append(b) }; _ = try p.finish() }
        }
        let store = try MemoryCredentials(), gate = Flag(), usage = Flag()
        let session = NativeChatGPTSession(store: store, authorize: { try await gate.check() }, authorizeUsage: { try await usage.check() }, request: { try await provider.request($0) }, stream: { try await provider.stream($0) }, clock: { now })
        try check(store.reads == 0, "constructor has no Keychain read")
        try await session.signIn(openBrowser: { try await provider.open($0) })
        var state = try await session.state(); let firstID = state.selected!
        try check(state.accounts.count == 1 && state.accounts[0].signedIn && state.accounts[0].planAllowed && !state.accounts[0].backgroundConsent, "real loopback login binds identity without background consent")
        let catalog = try await session.models(); try check(catalog.map(\.slug) == ["model-b", "model-a"], "catalog filters and server order")
        try await session.selectModel("model-b")
        let result = try await session.generate(instruction: "要約", input: "合成の文章")
        try check(result.text == "日本語の要約です。", "actual session inference routing"); try await session.validate(result.receipt); checks += 1
        try await reject("background requires separate consent") { _ = try await session.generate(instruction: "", input: "text", purpose: .background) }
        try await session.setBackgroundConsent(true)
        _ = try await session.generate(instruction: "", input: "text", purpose: .background); checks += 1
        try await reject("stale result receipt") { try await session.validate(result.receipt) }
        let inferenceBefore = await provider.inferences
        await usage.set(false)
        try await reject("settings permission does not grant inference") { _ = try await session.generate(instruction: "", input: "text") }
        try check(await provider.inferences == inferenceBefore, "usage denial before provider")
        _ = try await session.state(); checks += 1; await usage.set(true)
        await provider.configure(client: "oaiapp_two", subject: "subject-two")
        try await session.signIn(openBrowser: { try await provider.open($0) }); state = try await session.state()
        try check(state.accounts.count == 2 && state.accounts[0].label != state.accounts[1].label && state.selected != firstID, "same email separate registrations")
        try await session.selectAccount(firstID); try check(try await session.state().selected == firstID, "account switch preserves registered client")
        await provider.configure(client: "oaiapp_other")
        try await reject("reauthorization mismatched callback client") { try await session.signIn(registrationID: firstID, openBrowser: { try await provider.open($0) }) }
        try check(try await session.state().selected == firstID, "failed attempt preserves active account")
        await provider.configure(client: "oaiapp_one", subject: "subject-one")
        try await session.signIn(registrationID: firstID, openBrowser: { try await provider.open($0) })
        let requery = await provider.authQueries.last!
        try check(requery["client_id"] == "oaiapp_one" && requery["agent_name_hint"] == nil && requery["id_token_hint"] != nil, "reauthorize reuses client and id hint")
        try check(try await session.state().accounts.first { $0.id == firstID }?.backgroundConsent == false, "reauthorize resets background consent")
        await provider.configure(client: "oaiapp_no_plan", subject: "no-plan", scopes: "openid profile email offline_access")
        try await session.signIn(openBrowser: { try await provider.open($0) }); state = try await session.state()
        try check(state.accounts.count == 3 && state.useChatGPT && state.accounts.last?.planAllowed == false, "identity-only grant retained without silent API billing fallback")
        try await reject("missing direct scope rejects inference") { _ = try await session.generate(instruction: "", input: "text") }
        await provider.configure(scopes: NativeChatGPTOAuth.scopes)
        var expired = try store.decoded(); expired.selected = firstID; expired.useChatGPT = true
        let i = expired.accounts.firstIndex { $0.id == firstID }!, old = expired.accounts[i].tokens!
        expired.accounts[i].model = "model-b"
        expired.accounts[i].tokens = .init(access: old.access, refresh: old.refresh, idToken: old.idToken, scopes: old.scopes, expiresAt: now, earliestRefreshAt: nil)
        let refreshStore = try MemoryCredentials(expired), refreshSession = NativeChatGPTSession(store: refreshStore, authorize: {}, request: { try await provider.request($0) }, stream: { try await provider.stream($0) }, clock: { now })
        async let m1 = refreshSession.models(); async let m2 = refreshSession.models(); _ = try await (m1, m2)
        try check(await provider.refreshes == 1, "concurrent refresh singleflight")
        let refreshed = try refreshStore.decoded().accounts[i].tokens!
        try check(refreshed.access == "new-access" && refreshed.refresh == "new-refresh", "rotating token atomically saved")
        var currentEnvelope = try refreshStore.decoded(); currentEnvelope.accounts[i].model = "model-b"
        let choiceGate = Gate(), raceStore = try MemoryCredentials(currentEnvelope)
        let racing = NativeChatGPTSession(store: raceStore, authorize: {}, authorizeUsage: { await choiceGate.wait() }, request: { try await provider.request($0) }, stream: { try await provider.stream($0) }, clock: { now })
        let beforeRace = await provider.inferences
        let racingRequest = Task { try await racing.generate(instruction: "", input: "text") }
        while !(await choiceGate.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
        try await racing.useAPIKey(); await choiceGate.release()
        try await reject("billing selection changed during admission") { _ = try await racingRequest.value }
        try check(await provider.inferences == beforeRace, "billing race sends zero requests")
        await racing.stopAndDrain()
        let revokeGate = Gate(), revokeRaceStore = try MemoryCredentials(currentEnvelope)
        let revokeRacing = NativeChatGPTSession(store: revokeRaceStore, authorize: {}, request: { request in
            if request.url == NativeChatGPTOAuth.discoveryEndpoint { await revokeGate.wait() }
            return try await provider.request(request)
        }, stream: { try await provider.stream($0) }, clock: { now })
        let signingOut = Task { try await revokeRacing.signOut(firstID) }
        while !(await revokeGate.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
        let beforeSignoutRace = await provider.inferences
        try await reject("signout blocks fresh dispatch before revoke completes") { _ = try await revokeRacing.generate(instruction: "", input: "text") }
        try check(await provider.inferences == beforeSignoutRace, "signout sends zero new inference requests")
        await revokeGate.release(); try check(try await signingOut.value, "revocation acknowledged")
        try check(try revokeRaceStore.decoded().useChatGPT, "signout does not silently select API billing")
        await revokeRacing.stopAndDrain()
        let failureStore = try MemoryCredentials(expired)
        await provider.configure(refreshStatus: 503)
        let failureSession = NativeChatGPTSession(store: failureStore, authorize: {}, request: { try await provider.request($0) }, clock: { now })
        try await reject("refresh temporary failure") { _ = try await failureSession.models() }
        try check(try failureStore.decoded() == expired, "temporary failure preserves tokens")
        await provider.configure(refreshStatus: 400)
        try await reject("terminal refresh") { _ = try await failureSession.models() }
        try check(try failureStore.decoded().accounts[i].tokens == nil && failureStore.decoded().accounts[i].identity == expired.accounts[i].identity, "terminal refresh clears tokens retains mapping")
        await provider.configure(refreshStatus: 200, revokeStatus: 503)
        let remote = try await refreshSession.signOut(firstID)
        try check(!remote && refreshStore.decoded().accounts[i].tokens == nil, "unconfirmed remote revocation clears local tokens honestly")
        let blockedStore = try MemoryCredentials(expired), blocked = NativeChatGPTSession(store: blockedStore, authorize: { throw NativeChatGPTError.invalid("held") })
        try await reject("readonly/authority admission") { _ = try await blocked.state() }
        try check(blockedStore.reads == 0 && blockedStore.writes == 0, "denied store untouched")
        let hold = Gate(), stopStore = try MemoryCredentials(expired)
        let stopping = NativeChatGPTSession(store: stopStore, authorize: {}, request: { try await provider.request($0) }, stream: { _ in await hold.wait(); return "late" }, clock: { now })
        let generating = Task { try await stopping.generate(instruction: "", input: "text") }
        while !(await hold.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
        let stopped = Flag(); await stopped.set(false)
        let draining = Task { await stopping.stopAndDrain(); await stopped.set(true) }
        try await Task.sleep(nanoseconds: 20_000_000); try check(await stopped.allowed == false, "stop waits for noncooperative transport")
        await hold.release(); await draining.value
        try await reject("cancelled old response rejected") { _ = try await generating.value }
        try check(await stopped.allowed, "drain completed")
        await session.stopAndDrain(); await refreshSession.stopAndDrain(); await failureSession.stopAndDrain(); await blocked.stopAndDrain()
        print("NativeChatGPTTests: \(checks) checks passed (synthetic credentials; no external provider or real Keychain)")
    }
}
