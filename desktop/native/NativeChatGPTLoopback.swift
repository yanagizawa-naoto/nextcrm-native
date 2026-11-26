import Foundation
import Network

/// Exists only while a user-authorized browser sign-in is in progress.
final class NativeChatGPTLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.nextcrm.chatgpt.callback")
    private let listener: NWListener, state: String, timeout: TimeInterval
    private var redirect: URL?, ready: CheckedContinuation<URL, Error>?, pending: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?, started = false, listenerStopped = false
    private var sockets: [UUID: NWConnection] = [:], drains: [CheckedContinuation<Void, Never>] = []
    private var timer: DispatchWorkItem?
    init(state: String, timeout: TimeInterval = 600) throws {
        self.state = state; self.timeout = timeout
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler(operation: { try await withCheckedThrowingContinuation { c in
            queue.async {
                guard !self.started, self.outcome == nil else { c.resume(throwing: CancellationError()); return }
                self.started = true; self.ready = c
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port, self.outcome == nil else { return }
                        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!; self.redirect = url
                        let c = self.ready; self.ready = nil; c?.resume(returning: url)
                    case .failed: self.finish(.failure(NativeChatGPTError.invalid("認証の受信を開始できません。")))
                    case .cancelled: self.listenerStopped = true; self.checkDrained()
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(NativeChatGPTError.invalid("ChatGPTへの接続がタイムアウトしました。接続し直してください。"))) }
                self.timer = timer; self.queue.asyncAfter(deadline: .now()+self.timeout, execute: timer); self.listener.start(queue: self.queue)
            }
        } }, onCancel: { self.cancel() })
    }
    func callback() async throws -> URL {
        try await withTaskCancellationHandler(operation: { try await withCheckedThrowingContinuation { c in
            queue.async {
                if let result = self.outcome { c.resume(with: result) }
                else if self.pending == nil { self.pending = c }
                else { c.resume(throwing: NativeChatGPTError.invalid("認証の受信が重複しています。")) }
            }
        } }, onCancel: { self.cancel() })
    }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    func cancelAndDrain() async {
        await withCheckedContinuation { c in queue.async { self.drains.append(c); self.finish(.failure(CancellationError())); self.checkDrained() } }
    }
    private func finish(_ result: Result<URL, Error>) {
        guard outcome == nil else { return }; outcome = result; timer?.cancel(); timer = nil
        let c = pending; pending = nil; c?.resume(with: result)
        let r = ready; ready = nil; r?.resume(throwing: CancellationError())
        listener.newConnectionHandler = nil
        if started { listener.cancel() } else { listenerStopped = true }
        sockets.values.forEach { $0.cancel() }; checkDrained()
    }
    private func checkDrained() {
        guard listenerStopped, sockets.isEmpty else { return }; listener.stateUpdateHandler = nil
        let waiters = drains; drains.removeAll(); waiters.forEach { $0.resume() }
    }
    private func accept(_ connection: NWConnection) {
        guard outcome == nil, sockets.count < 4 else { connection.cancel(); return }
        let id = UUID(); sockets[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed: self.sockets.removeValue(forKey: id); connection?.stateUpdateHandler = nil; self.checkDrained()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now()+10) { [weak self, weak connection] in if self?.sockets[id] != nil { connection?.cancel() } }
        receive(connection, buffer: Data())
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.outcome == nil else { connection.cancel(); return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 16_384 else { self.reply(connection, accepted: false, callback: nil); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { self.handle(connection, buffer); return }
            if error != nil || complete { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }
    private func handle(_ connection: NWConnection, _ data: Data) {
        guard let redirect, let text = String(data: data, encoding: .utf8) else { reply(connection, accepted: false, callback: nil); return }
        let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].hasPrefix("/auth/callback?"), !first[1].contains("#"),
              let u = URLComponents(string: "http://127.0.0.1:\(redirect.port!)"+first[1]), u.path == "/auth/callback", u.fragment == nil,
              (u.queryItems ?? []).filter({ $0.name == "state" }).map({ $0.value ?? "" }) == [state], let url = u.url else { reply(connection, accepted: false, callback: nil); return }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard hosts == ["127.0.0.1:\(redirect.port!)"] else { reply(connection, accepted: false, callback: nil); return }
        reply(connection, accepted: true, callback: url)
    }
    private func reply(_ connection: NWConnection, accepted: Bool, callback: URL?) {
        let message = accepted ? "認証の応答を受け取りました。この画面を閉じてNextCRMに戻ってください。" : "認証の確認情報が一致しません。元のChatGPT画面から完了してください。"
        let body = Data("<!doctype html><html lang=\"ja\"><meta charset=\"utf-8\"><title>NextCRM</title><p>\(message)</p></html>".utf8)
        var bytes = Data("HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n".utf8); bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in connection.cancel(); if let callback { self?.finish(.success(callback)) } })
    }
}
