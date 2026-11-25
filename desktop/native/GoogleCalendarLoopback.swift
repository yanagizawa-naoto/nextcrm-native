import Foundation
import Network

/// A short-lived, loopback-only HTTP receiver. It exists only during browser
/// authorization; state and PKCE verifier are never written to disk.
final class GoogleCalendarLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label:"local.nextcrm.native.google-authorization")
    private let listener: NWListener
    private let state: String
    private let timeout: TimeInterval
    private var timer: DispatchWorkItem?
    private var ready: CheckedContinuation<URL,Error>?
    private var pending: CheckedContinuation<String,Error>?
    private var outcome: Result<String,Error>?
    private var started = false
    private var sockets: [UUID:NWConnection] = [:]
    init(state: String, timeout: TimeInterval = 600) throws {
        self.state = state; self.timeout = timeout
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        listener = try NWListener(using:parameters)
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler(operation:{ try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.started, self.outcome == nil else { continuation.resume(throwing:CancellationError()); return }
                self.started = true; self.ready = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else { self.finish(.failure(NativeDBError.message("Google認証の受信を開始できません。"))); return }
                        let c = self.ready; self.ready = nil; c?.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)/")!)
                    case .failed:self.finish(.failure(NativeDBError.message("Google認証の受信を開始できません。")))
                    case .cancelled:if self.outcome == nil { self.finish(.failure(CancellationError())) }
                    default:break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                let work = DispatchWorkItem { [weak self] in self?.finish(.failure(NativeDBError.message("Googleの認証がタイムアウトしました。接続し直してください。"))) }; self.timer = work
                self.queue.asyncAfter(deadline:.now()+self.timeout,execute:work); self.listener.start(queue:self.queue)
            }
        } },onCancel:{self.stop()})
    }
    func code() async throws -> String {
        try await withTaskCancellationHandler(operation:{ try await withCheckedThrowingContinuation { continuation in
            queue.async { if let result = self.outcome { continuation.resume(with:result) } else if self.pending == nil { self.pending = continuation } else { continuation.resume(throwing:NativeDBError.message("Google認証の受信が重複しています。")) } }
        } },onCancel:{self.stop()})
    }
    func stop() { queue.async { self.finish(.failure(CancellationError())) } }
    private func finish(_ result: Result<String,Error>) {
        guard outcome == nil else { return }; outcome = result; timer?.cancel(); timer = nil; listener.cancel()
        let starting = ready; ready = nil; starting?.resume(throwing:result.failure ?? CancellationError())
        let c = pending; pending = nil; c?.resume(with:result)
        sockets.values.forEach{$0.cancel()}; sockets.removeAll()
        listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
    }
    private func accept(_ connection: NWConnection) {
        guard outcome == nil, sockets.count < 4 else { connection.cancel(); return }
        let id = UUID(); sockets[id] = connection; connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+10) { [weak self,weak connection] in guard let self, self.sockets[id] != nil else { return }; connection?.cancel(); self.sockets.removeValue(forKey:id) }
        receive(connection,id:id,buffer:Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] data,_,complete,error in
            guard let self, self.outcome == nil, self.sockets[id] != nil else { connection.cancel(); return }
            var bytes = buffer; if let data { bytes.append(data) }
            guard bytes.count <= 16_384 else { self.reply(connection,id:id,status:431,message:"認証の応答が大きすぎます。",result:nil); return }
            if bytes.range(of:Data("\r\n\r\n".utf8)) != nil { self.handle(connection,id:id,data:bytes); return }
            if error != nil || complete { connection.cancel(); self.sockets.removeValue(forKey:id); return }
            self.receive(connection,id:id,buffer:bytes)
        }
    }
    private func handle(_ connection: NWConnection, id: UUID, data: Data) {
        guard let text = String(data:data,encoding:.utf8), let first = text.components(separatedBy:"\r\n").first else { reply(connection,id:id,status:400,message:"認証の応答が不正です。",result:nil); return }
        let parts = first.split(separator:" ",omittingEmptySubsequences:false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"), let url = URLComponents(string:"http://127.0.0.1"+parts[1]), url.path == "/", url.fragment == nil else { reply(connection,id:id,status:400,message:"認証の応答が不正です。",result:nil); return }
        let items = url.queryItems ?? []
        func values(_ key: String) -> [String] { items.filter{$0.name == key}.map{$0.value ?? ""} }
        guard values("state") == [state] else { reply(connection,id:id,status:400,message:"認証の確認情報が一致しません。元のGoogle画面から接続を完了してください。",result:nil); return }
        if values("error") == ["access_denied"] { reply(connection,id:id,status:200,message:"Googleの接続を中止しました。この画面を閉じてNextCRMに戻ってください。",result:.failure(NativeDBError.message("Googleへのアクセスが許可されませんでした。"))); return }
        guard values("error").isEmpty, values("code").count == 1, let code = values("code").first, !code.isEmpty, code.utf8.count <= 8192 else { reply(connection,id:id,status:400,message:"認証の応答が不正です。",result:.failure(NativeDBError.message("Googleの認証応答が不正です。接続し直してください。"))); return }
        reply(connection,id:id,status:200,message:"認証の応答を受け取りました。この画面を閉じてNextCRMに戻ってください。",result:.success(code))
    }
    private func reply(_ connection: NWConnection, id: UUID, status: Int, message: String, result: Result<String,Error>?) {
        let body = Data("<!doctype html><html lang=\"ja\"><meta charset=\"utf-8\"><title>NextCRM</title><p>\(message)</p></html>".utf8)
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n".utf8); response.append(body)
        connection.send(content:response,completion:.contentProcessed { [weak self] _ in guard let self else { return }; connection.cancel(); self.sockets.removeValue(forKey:id); if let result { self.finish(result) } })
    }
}
private extension Result {
    var failure: Failure? { if case let .failure(error) = self { return error }; return nil }
}

enum GoogleCalendarBrowserAuthorization {
    typealias Open = (URL) async throws -> Void
    static func run(client: GoogleCalendarClientSettings, scope: GoogleCalendarScope, loginHint: String?, open: @escaping Open, request: @escaping GoogleCalendarOAuth.Request = GoogleCalendarOAuth.network) async throws -> GoogleCalendarGrant {
        let state = try GoogleCalendarOAuth.random(), verifier = try GoogleCalendarOAuth.random(), receiver = try GoogleCalendarLoopback(state:state)
        defer { receiver.stop() }
        let redirect = try await receiver.start()
        let url = try GoogleCalendarOAuth.authorizationURL(client:client,scope:scope,redirect:redirect,state:state,verifier:verifier,loginHint:loginHint)
        try Task.checkCancellation(); try await open(url)
        let code = try await receiver.code(); try Task.checkCancellation()
        return try await GoogleCalendarOAuth.exchange(client:client,code:code,verifier:verifier,redirect:redirect,request:request)
    }
}
