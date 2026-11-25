import Foundation
import Network

enum NativeMCPHTTPServerError: Error { case configuration, alreadyStarted, closed, invalidResponse }

/// Network.framework owns TCP; the incremental parser owns HTTP framing.
/// All mutable socket/lifecycle state lives on queue. Handler tasks only use
/// the async writer, which acknowledges each bounded write before the next.
final class NativeMCPHTTPServer: @unchecked Sendable {
    typealias Handler = (NativeMCPHTTPRequest) async -> NativeMCPHTTPResponse
    struct Configuration {
        var port: UInt16 = 0
        var maximumConnections = 4
        var readTimeout: TimeInterval = 10
        var requestTimeout: TimeInterval = 600
        var sendTimeout: TimeInterval = 15
        var heartbeatInterval: TimeInterval = 10
        var parserLimits = NativeMCPHTTPParser.Limits()
    }
    struct Snapshot {
        var connections: Int, runningRequests: Int, retainedPeers: Int
        var peakConnections: Int, peakQueuedWrites: Int, accepted: Int, rejected: Int
    }
    private enum State { case stopped, starting, running, stopping }
    private let queue = DispatchQueue(label: "local.nextcrm.native.mcp-http")
    private let configuration: Configuration, handler: Handler
    private let bodyReceiver: NativeMCPHTTPBodyReceiver.Factory?
    private var state = State.stopped, generation = UUID()
    private var listener: NWListener?, timer: DispatchSourceTimer?
    private var starting: CheckedContinuation<URL, Error>?
    private var stopping: [CheckedContinuation<Void, Never>] = []
    private var peers: [UUID: Peer] = [:]
    private var port: UInt16 = 0, startDeadline = 0.0
    private var peakConnections = 0, peakQueuedWrites = 0, accepted = 0, rejected = 0
    private static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    init(configuration: Configuration = .init(), bodyReceiver: NativeMCPHTTPBodyReceiver.Factory? = nil, handler: @escaping Handler) throws {
        let times = [configuration.readTimeout, configuration.requestTimeout, configuration.sendTimeout, configuration.heartbeatInterval]
        guard (1...32).contains(configuration.maximumConnections), times.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 86400 }) else { throw NativeMCPHTTPServerError.configuration }
        _ = try NativeMCPHTTPParser(port: 1, limits: configuration.parserLimits)
        self.configuration = configuration; self.handler = handler; self.bodyReceiver = bodyReceiver
    }

    func start() async throws -> URL {
        let ticket = UUID(), cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard self.state == .stopped else { continuation.resume(throwing: NativeMCPHTTPServerError.alreadyStarted); return }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: self.configuration.port)!)
                        let listener = try NWListener(using: parameters)
                        self.generation = ticket; self.listener = listener; self.state = .starting; self.starting = continuation
                        self.startDeadline = Self.now + self.configuration.readTimeout
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self, self.generation == ticket else { return }
                            switch state {
                            case .ready:
                                guard self.state == .starting, let bound = self.listener?.port else { return }
                                self.port = bound.rawValue; self.state = .running
                                let pending = self.starting; self.starting = nil
                                pending?.resume(returning: URL(string: "http://127.0.0.1:\(bound.rawValue)/api/mcp/mcp")!)
                            case .failed(let error): self.stopOnQueue(error: error)
                            case .cancelled:
                                self.listener?.stateUpdateHandler = nil; self.listener?.newConnectionHandler = nil; self.listener = nil
                                self.completeStopIfReady()
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, self.generation == ticket else { connection.cancel(); return }
                            self.accept(connection)
                        }
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        let interval = min(0.25, self.configuration.readTimeout / 4, self.configuration.sendTimeout / 4, self.configuration.requestTimeout / 4)
                        timer.schedule(deadline: .now() + interval, repeating: interval)
                        timer.setEventHandler { [weak self] in self?.tick() }
                        self.timer = timer; timer.resume(); listener.start(queue: self.queue)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: {
            cancellation.cancel()
            self.queue.async { if self.generation == ticket { self.stopOnQueue(error: CancellationError()) } }
        })
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.state == .stopped { continuation.resume(); return }
                self.stopping.append(continuation); self.stopOnQueue(error: CancellationError())
            }
        }
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Snapshot(connections: self.peers.values.filter { !$0.closed }.count,
                    runningRequests: self.peers.values.filter { $0.task != nil || $0.parseTask != nil }.count, retainedPeers: self.peers.count,
                    peakConnections: self.peakConnections, peakQueuedWrites: self.peakQueuedWrites, accepted: self.accepted, rejected: self.rejected))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard state == .running, peers.count < configuration.maximumConnections else { rejected += 1; connection.cancel(); return }
        do {
            let peer = try Peer(server: self, connection: connection, port: port)
            peers[peer.id] = peer; accepted += 1; peakConnections = max(peakConnections, peers.count)
            connection.stateUpdateHandler = { [weak peer] state in
                if case .failed = state { peer?.closeOnQueue() }
                if case .cancelled = state { peer?.closeOnQueue() }
            }
            connection.start(queue: queue); peer.receive()
        } catch { connection.cancel() }
    }

    private func tick() {
        let now = Self.now
        if state == .starting, now >= startDeadline { stopOnQueue(error: NativeMCPHTTPServerError.closed); return }
        for peer in Array(peers.values) { peer.checkDeadline(now) }
    }
    private func stopOnQueue(error: Error) {
        guard state != .stopped else { return }
        state = .stopping
        let pending = starting; starting = nil; pending?.resume(throwing: error)
        for peer in Array(peers.values) { peer.closeOnQueue() }
        listener?.cancel(); completeStopIfReady()
    }
    private func completeStopIfReady() {
        guard state == .stopping, listener == nil, peers.isEmpty else { return }
        timer?.setEventHandler {}; timer?.cancel(); timer = nil; state = .stopped; port = 0
        let pending = stopping; stopping = []; pending.forEach { $0.resume() }
    }
    private func release(_ peer: Peer) {
        // Canceled but still-running handlers retain their admission slot.
        // Uncooperative application code cannot create unbounded orphan tasks.
        guard peer.closed, peer.task == nil, peer.parseTask == nil else { return }
        peers.removeValue(forKey: peer.id); completeStopIfReady()
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    private final class Peer: @unchecked Sendable {
        // Parser ownership passes from the append task back to the network
        // queue only after append has returned. This immutable envelope is
        // that handoff; the consumer is never invoked by both concurrently.
        struct ParsedBody: @unchecked Sendable {
            let result: Result<NativeMCPHTTPRequest?, Error>, streaming: Bool
        }
        struct Write {
            let id = UUID(), pieces: [Data], continuation: CheckedContinuation<Void, Error>
            var offset = 0
        }
        let id = UUID(), connection: NWConnection
        // Server outlives every admitted task and owns lifecycle until stop.
        unowned let server: NativeMCPHTTPServer
        var parser: NativeMCPHTTPParser?, task: Task<Void, Never>?, parseTask: Task<Void, Never>?
        var closed = false, requestStarted = false, receiveEOF = false
        var deadline: Double, sendDeadline: Double?, uploadDeadline: Double?
        var writes: [Write] = []

        init(server: NativeMCPHTTPServer, connection: NWConnection, port: UInt16) throws {
            self.server = server; self.connection = connection
            parser = try NativeMCPHTTPParser(port: port, limits: server.configuration.parserLimits, bodyReceiver: server.bodyReceiver)
            deadline = NativeMCPHTTPServer.now + server.configuration.readTimeout
        }
        func checkDeadline(_ now: Double) {
            guard !closed else { return }
            if now >= deadline || sendDeadline.map({ now >= $0 }) == true || uploadDeadline.map({ now >= $0 }) == true { closeOnQueue() }
        }
        func receive() {
            guard !closed, !receiveEOF else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { return }
                if error != nil { self.closeOnQueue(); return }
                self.receiveEOF = complete
                if self.requestStarted {
                    // EOF is a TCP write-half-close; the peer may still be
                    // reading a valid response. Failed sends/heartbeat detect
                    // full disconnects without canceling half-closed clients.
                    if let data, !data.isEmpty { self.closeOnQueue(); return }
                    if !complete { self.receive() }
                    return
                }
                guard let parser = self.parser, self.parseTask == nil else { self.closeOnQueue(); return }
                // A file consumer may perform disk I/O. Keep it off the shared
                // network queue, with only one 16 KiB receive/append in flight.
                // Cancelled appends retain their admission slot until done.
                self.parseTask = Task { [self, parser] in
                    let parsed: Result<NativeMCPHTTPRequest?, Error>
                    do { try Task.checkCancellation(); let request = try parser.append(data ?? Data(), endOfStream: complete); try Task.checkCancellation(); parsed = .success(request) }
                    catch { parsed = .failure(error) }
                    let outcome = ParsedBody(result: parsed, streaming: parser.isReceivingStream)
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        self.server.queue.async {
                            self.parseTask = nil
                            defer { continuation.resume() }
                            guard !self.closed else { self.server.release(self); return }
                            switch outcome.result {
                            case .success(let request):
                                if let request {
                                    self.parser = nil; self.requestStarted = true; self.uploadDeadline = nil
                                    self.deadline = NativeMCPHTTPServer.now + self.server.configuration.requestTimeout
                                    self.respond(request: request)
                                } else if outcome.streaming {
                                    if self.uploadDeadline == nil { self.uploadDeadline = NativeMCPHTTPServer.now + self.server.configuration.requestTimeout }
                                    self.deadline = NativeMCPHTTPServer.now + self.server.configuration.readTimeout
                                }
                            case .failure(let error as NativeMCPHTTPParseError):
                                self.parser = nil; self.requestStarted = true; self.uploadDeadline = nil
                                self.respond(response: .init(status: error.status, headers: error.message == nil ? [:] : ["content-type": "text/plain;charset=UTF-8"], body: Data((error.message ?? "").utf8)))
                            case .failure: self.closeOnQueue()
                            }
                            if !complete, !self.closed { self.receive() }
                        }
                    }
                }
            }
        }
        func respond(request: NativeMCPHTTPRequest? = nil, response: NativeMCPHTTPResponse? = nil) {
            task = Task { [self, server] in
                var heartbeat: Task<Void, Never>?
                do {
                    try Task.checkCancellation()
                    let reply: NativeMCPHTTPResponse
                    if let response { reply = response }
                    else if let body = request?.bodyReceiver {
                        do { reply = try await body.finish() }
                        catch is CancellationError { throw CancellationError() }
                        catch let failure as NativeMCPHTTPParseError { reply = .init(status: failure.status) }
                        catch { reply = .init(status: 500) }
                    } else { reply = await server.handler(request!) }
                    try Task.checkCancellation()
                    let streamed = reply.stream != nil || reply.keepOpen
                    let events = streamed && reply.streamFormat == .events
                    let chunked = streamed && (events || reply.contentLength == nil)
                    let headOnly = request?.method == "HEAD"
                    try await send(Self.responseHead(reply, streamed: streamed, chunked: chunked))
                    if headOnly {
                        // HTTP HEAD exposes the representation's headers but
                        // must never execute a stream or send body framing.
                    } else if events {
                        try await send(Data(": connected\n\n".utf8), chunked: true)
                        let beating = Task { [self] in
                            do {
                                while true {
                                    try await Task.sleep(nanoseconds: UInt64(server.configuration.heartbeatInterval * 1_000_000_000))
                                    try Task.checkCancellation()
                                    try await send(Data(": keepalive\n\n".utf8), chunked: true)
                                }
                            } catch { if !Task.isCancelled { await close() } }
                        }
                        heartbeat = beating
                        try await reply.writeBody { [self] data in try await send(data, chunked: true) }
                        if reply.keepOpen {
                            await withTaskCancellationHandler(operation: { await beating.value }, onCancel: { beating.cancel() })
                            throw CancellationError()
                        }
                        beating.cancel(); await beating.value; heartbeat = nil
                        try Task.checkCancellation(); try await send(Data("0\r\n\r\n".utf8))
                    } else {
                        let counter = ResponseLength(expected: streamed ? reply.contentLength : Int64(reply.body.count))
                        try await reply.writeBody { [self] data in try counter.consume(data.count); try await send(data, chunked: chunked) }
                        try counter.finish()
                        if chunked { try Task.checkCancellation(); try await send(Data("0\r\n\r\n".utf8)) }
                    }
                    await close()
                } catch { heartbeat?.cancel(); await close(); await heartbeat?.value }
                await withCheckedContinuation { continuation in
                    server.queue.async { self.task = nil; server.release(self); continuation.resume() }
                }
            }
        }
        private final class ResponseLength {
            private let lock = NSLock(), expected: Int64?
            private var count: Int64 = 0
            init(expected: Int64?) { self.expected = expected }
            func consume(_ bytes: Int) throws {
                lock.lock(); defer { lock.unlock() }
                guard bytes >= 0, Int64(bytes) <= Int64.max - count else { throw NativeMCPHTTPServerError.invalidResponse }
                let next = count + Int64(bytes)
                guard expected.map({ next <= $0 }) ?? true else { throw NativeMCPHTTPServerError.invalidResponse }
                count = next
            }
            func finish() throws {
                lock.lock(); defer { lock.unlock() }
                guard expected.map({ count == $0 }) ?? true else { throw NativeMCPHTTPServerError.invalidResponse }
            }
        }
        private static func responseHead(_ response: NativeMCPHTTPResponse, streamed: Bool, chunked: Bool) throws -> Data {
            let reasons = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type", 417: "Expectation Failed", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable"]
            guard let reason = reasons[response.status] else { throw NativeMCPHTTPServerError.invalidResponse }
            guard !response.keepOpen || response.streamFormat == .events,
                  (response.contentLength.map({ $0 >= 0 }) ?? true),
                  !streamed || response.streamFormat == .bytes || response.contentLength == nil,
                  streamed || (response.contentLength.map({ $0 == Int64(response.body.count) }) ?? true) else { throw NativeMCPHTTPServerError.invalidResponse }
            var headers = ["connection": "close", "cache-control": "no-store", "x-content-type-options": "nosniff"]
            for (name, value) in response.headers {
                let name = name.lowercased()
                guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                      value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { throw NativeMCPHTTPServerError.invalidResponse }
                if !["content-length", "transfer-encoding", "connection"].contains(name) { headers[name] = value }
            }
            if chunked { headers["transfer-encoding"] = "chunked" }
            else { headers["content-length"] = String(streamed ? response.contentLength! : Int64(response.body.count)) }
            return Data(("HTTP/1.1 \(response.status) \(reason)\r\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        }
        func send(_ data: Data, chunked: Bool = false) async throws {
            try Task.checkCancellation()
            if data.isEmpty { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                server.queue.async {
                    guard !self.closed else { continuation.resume(throwing: NativeMCPHTTPServerError.closed); return }
                    // One producer plus one heartbeat; disallow any accidental
                    // unbounded producer fanout. Payload is not copied to frame.
                    guard self.writes.count < 2 else { continuation.resume(throwing: NativeMCPHTTPServerError.invalidResponse); self.closeOnQueue(); return }
                    let pieces = chunked ? [Data("\(String(data.count, radix: 16))\r\n".utf8), data, Data("\r\n".utf8)] : [data]
                    self.writes.append(Write(pieces: pieces, continuation: continuation))
                    self.server.peakQueuedWrites = max(self.server.peakQueuedWrites, self.writes.count)
                    if self.writes.count == 1 { self.startWrite() }
                }
            }
        }
        func startWrite() {
            guard !closed, let first = writes.first else { return }
            if first.offset == 0 { sendDeadline = NativeMCPHTTPServer.now + server.configuration.sendTimeout }
            let writeID = first.id
            connection.send(content: first.pieces[first.offset], completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed, self.writes.first?.id == writeID else { return }
                if error != nil { self.closeOnQueue(); return }
                self.writes[0].offset += 1
                if self.writes[0].offset == self.writes[0].pieces.count {
                    let finished = self.writes.removeFirst(); self.sendDeadline = nil; finished.continuation.resume()
                }
                self.startWrite()
            })
        }
        func close() async {
            await withCheckedContinuation { continuation in
                server.queue.async { self.closeOnQueue(); continuation.resume() }
            }
        }
        func closeOnQueue() {
            guard !closed else { return }; closed = true; parser = nil
            connection.stateUpdateHandler = nil; connection.cancel(); task?.cancel(); parseTask?.cancel()
            let pending = writes; writes = []; sendDeadline = nil
            pending.forEach { $0.continuation.resume(throwing: NativeMCPHTTPServerError.closed) }
            server.release(self)
        }
    }
}
