import Foundation

/// One actor per live workspace/CRM owner. Constructing it does not access Keychain or network.
actor NativeChatGPTSession {
    typealias Authorize = () async throws -> Void
    typealias OpenBrowser = (URL) async throws -> Void
    enum Purpose: Sendable { case userRequested, background }
    struct Account: Sendable {
        let id: String, label: String
        let signedIn: Bool, planAllowed: Bool, backgroundConsent: Bool, welcomed: Bool
        let model: String?
    }
    struct State: Sendable {
        let accounts: [Account], selected: String?, useChatGPT: Bool, closed: Bool
    }
    struct Receipt: Equatable, Sendable { let accountID: String, revision: UUID, model: String }
    struct Generated: Sendable { let text: String, receipt: Receipt }
    private let store: NativeChatGPTCredentialStore, authorize: Authorize, authorizeUsage: Authorize
    private let request: NativeChatGPTOAuth.Request, stream: NativeChatGPTInference.Stream, clock: () -> Date
    private var envelope: NativeChatGPTEnvelope?, stored: Data?, revision = UUID(), selectionGeneration = UUID(), closed = false
    private var login: Task<(NativeChatGPTIdentity, NativeChatGPTTokens), Error>?
    private var refresh: (id: UUID, task: Task<NativeChatGPTTokens, Error>)?
    private var requests: [UUID: Task<String, Error>] = [:]
    private var httpRequests: [UUID: Task<(Data, HTTPURLResponse), Error>] = [:]
    private var catalog: [NativeChatGPTInference.Model] = [], catalogAccount: String?
    private var revoking = Set<String>(), blocked = Set<String>()
    init(store: NativeChatGPTCredentialStore, authorize: @escaping Authorize,
         authorizeUsage: Authorize? = nil,
         request: @escaping NativeChatGPTOAuth.Request = NativeChatGPTOAuth.network,
         stream: @escaping NativeChatGPTInference.Stream = NativeChatGPTInference.network,
         clock: @escaping () -> Date = Date.init) {
        self.store = store; self.authorize = authorize; self.authorizeUsage = authorizeUsage ?? authorize
        self.request = request; self.stream = stream; self.clock = clock
    }
    private func check(_ expected: UUID? = nil, usage: Bool = false) async throws {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
        try await authorize(); if usage { try await authorizeUsage() }
        try Task.checkCancellation(); guard !closed, expected == nil || expected == revision else { throw NativeChatGPTError.invalid("接続先や権限が変更されました。もう一度実行してください。") }
    }
    private func load() async throws {
        try await check(); if envelope != nil { return }
        let data = try store.load()
        if let data {
            guard data.count <= 1_048_576, let value = try? JSONDecoder().decode(NativeChatGPTEnvelope.self, from: data) else { throw NativeChatGPTError.invalid("保存したChatGPT接続を読み取れません。") }
            envelope = try value.validated()
        } else { envelope = .init() }
        stored = data
    }
    private func save(_ next: NativeChatGPTEnvelope, expected: UUID, selectionChange: Bool = true) async throws {
        _ = try next.validated(); try await check(expected)
        let data = try JSONEncoder().encode(next); try store.replace(data, expected: stored)
        stored = data; envelope = next; revision = UUID(); if selectionChange { selectionGeneration = UUID() }
    }
    func state() async throws -> State {
        try await load(); let value = envelope!
        return .init(accounts: value.accounts.enumerated().map { index, account in
            .init(id: account.id, label: (account.identity.email ?? "ChatGPTアカウント") + " · " + String(index+1), signedIn: account.tokens != nil, planAllowed: account.tokens?.permitsInference == true, backgroundConsent: account.backgroundConsent, welcomed: account.welcomed, model: account.model)
        }, selected: value.selected, useChatGPT: value.useChatGPT, closed: closed)
    }
    func isSelectedForText() async throws -> Bool { try await load(); return envelope!.useChatGPT }
    private func account(_ id: String? = nil) throws -> NativeChatGPTRegistration {
        guard let value = envelope, let id = id ?? value.selected, let account = value.accounts.first(where: { $0.id == id }) else { throw NativeChatGPTError.invalid("ChatGPTアカウントを選択してください。") }; return account
    }
    private func noLogin() throws { guard login == nil, revoking.isEmpty else { throw NativeChatGPTError.invalid("接続の変更中です。完了または取り消しを待ってください。") } }
    private func settleRefresh() async throws {
        if let pending = refresh {
            _ = try? await pending.task.value
            while refresh?.id == pending.id { try await check(); try await Task.sleep(nanoseconds: 1_000_000) }
        }
        try await check()
    }
    private func send(_ value: URLRequest, expected: UUID) async throws -> (Data, HTTPURLResponse) {
        try await check(expected)
        let id = UUID(), request = request, task = Task { try await request(value) }; httpRequests[id] = task
        defer { httpRequests.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try await check(expected); return result
    }
    private func cancelInference() { requests.values.forEach { $0.cancel() } }
    func selectAccount(_ id: String) async throws {
        try await load(); try noLogin(); try await settleRefresh(); let selected = try account(id); guard selected.tokens != nil else { throw NativeChatGPTError.invalid("このアカウントで接続し直してください。") }
        cancelInference(); var next = envelope!; next.selected = id; next.useChatGPT = true
        try await save(next, expected: revision); catalog = []; catalogAccount = nil
    }
    func useAPIKey() async throws {
        try await load(); try noLogin(); try await settleRefresh(); cancelInference(); var next = envelope!; next.useChatGPT = false; try await save(next, expected: revision)
    }
    func useChatGPTPlan() async throws {
        try await load(); try noLogin(); try await settleRefresh(); guard try account().tokens?.permitsInference == true else { throw NativeChatGPTError.invalid("ChatGPTプランの利用を許可してから選択してください。") }
        cancelInference(); var next = envelope!; next.useChatGPT = true; try await save(next, expected: revision)
    }
    func setBackgroundConsent(_ allowed: Bool) async throws {
        try await load(); try noLogin(); try await settleRefresh(); let selected = try account()
        guard !allowed || selected.tokens?.permitsInference == true else { throw NativeChatGPTError.invalid("ChatGPTプランの利用が許可されていません。") }
        cancelInference(); var next = envelope!; let index = next.accounts.firstIndex { $0.id == selected.id }!
        next.accounts[index].backgroundConsent = allowed; try await save(next, expected: revision)
        // Deliberately no AIKeys.didChange / worker wake notification.
    }
    func acknowledgeWelcome() async throws {
        try await load(); try await settleRefresh(); let selected = try account(); var next = envelope!
        next.accounts[next.accounts.firstIndex { $0.id == selected.id }!].welcomed = true
        try await save(next, expected: revision)
    }
    func signIn(registrationID: String? = nil, reconsent: Bool = false, openBrowser: @escaping OpenBrowser) async throws {
        try await load(); try noLogin(); try await settleRefresh()
        let selected = try registrationID.map { try account($0) }
        guard selected != nil || envelope!.accounts.count < 16 else { throw NativeChatGPTError.invalid("保存できるChatGPT登録は16件までです。") }
        if stored == nil { try await save(envelope!, expected: revision) } // Stable host ID precedes first browser navigation.
        let expected = revision, hostID = envelope!.hostID, clock = clock
        try noLogin() // Recheck after every asynchronous admission before owning the task.
        let task = Task { () throws -> (NativeChatGPTIdentity, NativeChatGPTTokens) in
            var issuedClient = selected?.identity.clientID
            for pass in 0..<2 {
            let state = try NativeChatGPTOAuth.random(), receiver = try NativeChatGPTLoopback(state: state)
            do {
                let redirect = try await receiver.start()
                let attempt = NativeChatGPTOAuth.Attempt(state: state, nonce: try NativeChatGPTOAuth.random(), verifier: try NativeChatGPTOAuth.random(), hostID: hostID, redirect: redirect, clientID: issuedClient, idTokenHint: selected?.tokens?.idToken, loginHint: selected?.identity.email, reconsent: reconsent)
                try await self.check(expected); try await openBrowser(attempt.authorizationURL())
                let callback = try await receiver.callback(); await receiver.cancelAndDrain()
                let result = try attempt.callback(callback)
                let fields = ["grant_type": "authorization_code", "client_id": result.clientID, "code": result.code, "code_verifier": attempt.verifier, "redirect_uri": redirect.absoluteString, "resource": NativeChatGPTOAuth.resource]
                try await self.check(expected)
                let (data, response) = try await self.send(NativeChatGPTOAuth.post(fields), expected: expected)
                let json: [String: Any]
                do { json = try NativeChatGPTOAuth.json(data, response, expected: NativeChatGPTOAuth.tokenEndpoint) }
                catch let error as NativeChatGPTError where error.code == "invalid_grant" && pass == 0 {
                    // The code is one-use. Restart OAuth once with fresh PKCE/nonce, retaining the issued registration.
                    issuedClient = result.clientID; continue
                }
                let tokens = try NativeChatGPTTokens.parse(json, now: clock())
                try await self.check(expected)
                let (jwks, jwksResponse) = try await self.send(URLRequest(url: NativeChatGPTOAuth.jwksEndpoint), expected: expected)
                _ = try NativeChatGPTOAuth.json(jwks, jwksResponse, expected: NativeChatGPTOAuth.jwksEndpoint)
                let identity = try NativeChatGPTIdentity.verify(tokens.idToken, jwks: jwks, clientID: result.clientID, nonce: attempt.nonce, accessToken: tokens.access, now: clock())
                if let selected { guard identity.issuer == selected.identity.issuer, NativeChatGPTOAuth.exact(identity.subject, selected.identity.subject), NativeChatGPTOAuth.exact(identity.clientID, selected.identity.clientID) else { throw NativeChatGPTError.invalid("選択したChatGPTアカウントと本人確認が一致しません。") } }
                try await self.check(expected); return (identity, tokens)
            } catch { await receiver.cancelAndDrain(); throw error }
            }
            throw NativeChatGPTError.invalid("認証を完了できません。接続し直してください。")
        }
        login = task
        defer { login = nil }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try await check(expected)
        var next = envelope!
        let existing = next.accounts.firstIndex { NativeChatGPTOAuth.exact($0.identity.clientID, result.0.clientID) && NativeChatGPTOAuth.exact($0.identity.subject, result.0.subject) }
        let id = existing.map { next.accounts[$0].id } ?? UUID().uuidString.lowercased()
        let record = NativeChatGPTRegistration(id: id, identity: result.0, tokens: result.1, model: existing.flatMap { next.accounts[$0].model }, backgroundConsent: false, welcomed: existing.map { next.accounts[$0].welcomed } ?? false)
        if let existing { next.accounts[existing] = record } else { next.accounts.append(record) }
        next.selected = id; next.useChatGPT = true
        cancelInference(); try await save(next, expected: expected); blocked.remove(id); catalog = []; catalogAccount = nil
    }
    private func credentials() async throws -> (NativeChatGPTRegistration, UUID) {
        try await load(); let current = try account()
        guard !blocked.contains(current.id), !revoking.contains(current.id) else { throw NativeChatGPTError.invalid("サインアウト中、またはサインアウトした接続です。接続し直してください。") }
        guard let tokens = current.tokens, tokens.permitsInference else { throw NativeChatGPTError.invalid("ChatGPTプランの利用は未許可です。接続し直して許可するか、APIキー方式を選んでください。") }
        if tokens.expiresAt.timeIntervalSince(clock()) > 60 { return (current, revision) }
        if let earliest = tokens.earliestRefreshAt, earliest > clock() {
            guard tokens.expiresAt > clock() else { throw NativeChatGPTError.invalid("認証の更新可能時刻を待ってから再実行してください。") }; return (current, revision)
        }
        guard let refreshToken = tokens.refresh else { throw NativeChatGPTError.invalid("継続利用の認証がありません。ChatGPTに接続し直してください。") }
        let expected = revision
        if let refreshing = refresh {
            _ = try await refreshing.task.value
            try Task.checkCancellation()
            return try await credentials()
        }
        let clock = clock, refreshID = UUID()
        let task = Task { () throws -> NativeChatGPTTokens in
            try await self.check(expected)
            let (data, response) = try await self.send(NativeChatGPTOAuth.post(["grant_type": "refresh_token", "client_id": current.identity.clientID, "refresh_token": refreshToken, "resource": NativeChatGPTOAuth.resource]), expected: expected)
            let json = try NativeChatGPTOAuth.json(data, response, expected: NativeChatGPTOAuth.tokenEndpoint)
            let updated = try NativeChatGPTTokens.parse(json, now: clock(), prior: tokens)
            if json["id_token"] != nil {
                try await self.check(expected)
                let (jwks, response) = try await self.send(URLRequest(url: NativeChatGPTOAuth.jwksEndpoint), expected: expected); _ = try NativeChatGPTOAuth.json(jwks, response, expected: NativeChatGPTOAuth.jwksEndpoint)
                let identity = try NativeChatGPTIdentity.verify(updated.idToken, jwks: jwks, clientID: current.identity.clientID, nonce: nil, accessToken: updated.access, now: clock())
                guard NativeChatGPTOAuth.exact(identity.subject, current.identity.subject) else { throw NativeChatGPTError.invalid("更新した認証のアカウントが一致しません。") }
            }
            try await self.commitRefresh(updated, accountID: current.id, expected: expected)
            return updated
        }
        refresh = (refreshID, task)
        defer { if refresh?.id == refreshID { refresh = nil } }
        do {
            _ = try await task.value; try await check()
            guard envelope?.selected == current.id else { throw NativeChatGPTError.invalid("接続先が変更されました。") }
            guard try account().tokens?.permitsInference == true else { throw NativeChatGPTError.invalid("更新後の認証ではChatGPTプランの利用が許可されていません。利用方式を確認してください。") }
            return (try account(), revision)
        } catch {
            if let error = error as? NativeChatGPTError, error.terminalRefresh, revision == expected, !closed {
                var next = envelope!; let index = next.accounts.firstIndex { $0.id == current.id }!
                next.accounts[index].tokens = nil; next.accounts[index].backgroundConsent = false
                try await save(next, expected: expected)
            }
            throw error
        }
    }
    private func commitRefresh(_ tokens: NativeChatGPTTokens, accountID: String, expected: UUID) async throws {
        try await check(expected); var next = envelope!
        guard let index = next.accounts.firstIndex(where: { $0.id == accountID }) else { throw NativeChatGPTError.invalid("接続先が変更されました。") }
        next.accounts[index].tokens = tokens; try await save(next, expected: expected, selectionChange: false)
    }
    func models() async throws -> [NativeChatGPTInference.Model] {
        let (account, expected) = try await credentials(); try await check(expected)
        var req = URLRequest(url: NativeChatGPTInference.modelsEndpoint); req.setValue("Bearer "+account.tokens!.access, forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(req, expected: expected); let models = try NativeChatGPTInference.models(data, response)
        try await check(expected); catalog = models; catalogAccount = account.id; return models
    }
    func selectModel(_ slug: String) async throws {
        try await load(); try noLogin(); try await settleRefresh(); let selected = try account()
        guard catalogAccount == selected.id, catalog.contains(where: { $0.slug == slug }) else { throw NativeChatGPTError.invalid("現在のアカウントで利用できるモデルを選択してください。") }
        cancelInference(); var next = envelope!; next.accounts[next.accounts.firstIndex { $0.id == selected.id }!].model = slug; try await save(next, expected: revision)
    }
    func generate(instruction: String, input: String, purpose: Purpose = .userRequested) async throws -> Generated {
        try await load(); guard envelope!.useChatGPT else { throw NativeChatGPTError.invalid("文章生成でChatGPTプランを使用する設定を選んでください。") }
        var selected = try account(); let selection = selectionGeneration, accountID = selected.id
        guard purpose != .background || selected.backgroundConsent else { throw NativeChatGPTError.invalid("ChatGPTによる自動処理は許可されていません。") }
        try await checkSelection(selection, accountID: accountID, purpose: purpose)
        if catalogAccount != selected.id || catalog.isEmpty { _ = try await models() }
        try await checkSelection(selection, accountID: accountID, purpose: purpose)
        let (current, expected) = try await credentials(); selected = current
        guard let model = selected.model, catalogAccount == selected.id, catalog.contains(where: { $0.slug == model }), purpose != .background || selected.backgroundConsent else { throw NativeChatGPTError.invalid("モデルを選択するか、自動処理の許可を確認してください。") }
        try await checkSelection(selection, accountID: accountID, purpose: purpose, expected: expected)
        let req = try NativeChatGPTInference.request(accessToken: selected.tokens!.access, model: model, instruction: instruction, input: input)
        let id = UUID(), stream = stream, task = Task { try await stream(req) }; requests[id] = task
        defer { requests.removeValue(forKey: id) }
        let text = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try await checkSelection(selection, accountID: accountID, purpose: purpose, expected: expected)
        return .init(text: text, receipt: .init(accountID: selected.id, revision: expected, model: model))
    }
    private func checkSelection(_ generation: UUID, accountID: String, purpose: Purpose, expected: UUID? = nil) async throws {
        try await check(expected, usage: true)
        let selected = try account()
        guard selectionGeneration == generation, envelope?.useChatGPT == true, envelope?.selected == accountID,
              !blocked.contains(accountID), !revoking.contains(accountID),
              purpose != .background || selected.backgroundConsent else { throw NativeChatGPTError.invalid("利用方式・アカウント・自動処理の許可が変更されたため、送信を中止しました。") }
    }
    func validate(_ receipt: Receipt) async throws {
        try await check(receipt.revision, usage: true)
        guard !blocked.contains(receipt.accountID), !revoking.contains(receipt.accountID), let value = envelope, value.useChatGPT, value.selected == receipt.accountID, try account().model == receipt.model else { throw NativeChatGPTError.invalid("文章生成の接続先が変更されました。作成し直してください。") }
    }
    /// Returns false when remote revocation was not confirmed; local tokens are still removed.
    func signOut(_ id: String) async throws -> Bool {
        try await load(); try noLogin(); _ = try account(id)
        revoking.insert(id); blocked.insert(id); selectionGeneration = UUID()
        defer { revoking.remove(id) }
        cancelInference(); let running = Array(requests.values)
        for task in running { _ = try? await task.value }
        try await settleRefresh()
        let selected = try account(id), expected = revision
        try await check(expected)
        var revoked = selected.tokens?.refresh == nil
        if let token = selected.tokens?.refresh {
            do {
                let (data, response) = try await send(URLRequest(url: NativeChatGPTOAuth.discoveryEndpoint), expected: expected)
                let discovery = try NativeChatGPTOAuth.json(data, response, expected: NativeChatGPTOAuth.discoveryEndpoint)
                guard discovery["issuer"] as? String == NativeChatGPTOAuth.issuer, let value = discovery["revocation_endpoint"] as? String, let url = URL(string: value), NativeChatGPTOAuth.allowed(url), url.host == "auth.openai.com" else { throw NativeChatGPTError.invalid("失効先を確認できません。") }
                for attempt in 0..<2 {
                    try await check(expected)
                    let (_, response) = try await send(NativeChatGPTOAuth.post(["token": token, "token_type_hint": "refresh_token", "client_id": selected.identity.clientID], to: url), expected: expected)
                    if response.url == url && response.statusCode == 200 { revoked = true; break }
                    if response.statusCode < 500 || attempt == 1 { break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { revoked = false }
        }
        try await check(expected); var next = envelope!; let index = next.accounts.firstIndex { $0.id == id }!
        next.accounts[index].tokens = nil; next.accounts[index].backgroundConsent = false
        try await save(next, expected: expected)
        catalog = []; catalogAccount = nil; return revoked
    }
    func stopAndDrain() async {
        closed = true; revision = UUID(); login?.cancel(); refresh?.task.cancel(); cancelInference(); httpRequests.values.forEach { $0.cancel() }
        let login = login, refresh = refresh?.task, tasks = Array(requests.values), http = Array(httpRequests.values)
        if let login { _ = try? await login.value }; if let refresh { _ = try? await refresh.value }
        for task in tasks { _ = try? await task.value }
        for task in http { _ = try? await task.value }
        self.login = nil; self.refresh = nil; requests.removeAll(); httpRequests.removeAll(); catalog.removeAll(); envelope = nil; stored = nil
    }
}
