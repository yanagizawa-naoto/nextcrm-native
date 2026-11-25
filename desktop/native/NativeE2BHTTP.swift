import Foundation

private final class NativeE2BNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum NativeE2BHTTP {
    typealias Headers = (HTTPURLResponse) throws -> Void
    typealias Chunk = (Data) async throws -> Void
    /// Callbacks are serial and awaited: the reader cannot queue an unbounded
    /// response while SQLite progress/permission checks are running.
    typealias Transport = (URLRequest, Int, @escaping Headers, @escaping Chunk) async throws -> Void
    static func network(_ request: URLRequest, maximumBytes: Int, headers: @escaping Headers, chunk: @escaping Chunk) async throws {
        try await transport(request, maximumBytes: maximumBytes, configuration: .ephemeral, headers: headers, chunk: chunk)
    }
    static func configured(_ options: NativeE2BConfiguration) -> Transport {
        { request, maximumBytes, headers, chunk in
            try await transport(request, maximumBytes: maximumBytes, configuration: .ephemeral, insecureOrigins: options.insecureOrigins, headers: headers, chunk: chunk)
        }
    }
    static func transport(_ request: URLRequest, maximumBytes: Int, configuration: URLSessionConfiguration,
                          insecureOrigins: Set<String> = [],
                          headers: @escaping Headers, chunk: @escaping Chunk) async throws {
        guard let endpoint = request.url, endpoint.scheme == "https" || endpoint.scheme == "http" && insecureOrigins.contains(NativeE2BConfiguration.origin(endpoint)),
              endpoint.user == nil, endpoint.password == nil, maximumBytes > 0 else { throw invalid() }
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(60, request.timeoutInterval); configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: NativeE2BNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, raw) = try await session.bytes(for: request)
            guard let response = raw as? HTTPURLResponse, response.url == endpoint, response.expectedContentLength <= maximumBytes else { throw invalid() }
            try headers(response)
            let framed = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/connect+") == true
            var buffer = Data(), count = 0, envelopeHeader = [UInt8](), payloadRemaining: Int?; buffer.reserveCapacity(16_384)
            for try await byte in bytes {
                guard count < maximumBytes else { throw oversized() }; count += 1; buffer.append(byte)
                var boundary = false
                if framed {
                    if let remaining = payloadRemaining {
                        if remaining == 1 { payloadRemaining = nil; boundary = true } else { payloadRemaining = remaining - 1 }
                    } else {
                        envelopeHeader.append(byte)
                        if envelopeHeader.count == 5 {
                            let length = envelopeHeader.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                            guard length <= NativeE2BStream.maximumFrame else { throw oversized() }
                            payloadRemaining = length == 0 ? nil : length; boundary = length == 0; envelopeHeader.removeAll(keepingCapacity: true)
                        }
                    }
                }
                // Flush even tiny progress frames immediately; waiting for a
                // 16KiB buffer would hide progress until the agent had finished.
                if boundary || buffer.count == 16_384 { try Task.checkCancellation(); try await chunk(buffer); buffer.removeAll(keepingCapacity: true) }
            }
            try Task.checkCancellation(); if !buffer.isEmpty { try await chunk(buffer) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeAIError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // Keep errors from the awaited authority callback intact. Only a
            // URL loading error is converted into a retryable transport failure.
            if error is URLError { throw NativeAIError(message: "企業情報の取得サービスに接続できません。", retryable: true) }
            throw error
        }
    }
    static func invalid() -> NativeAIError { .init(message: "企業情報の取得サービスからの応答を確認できません。") }
    static func oversized() -> NativeAIError { .init(message: "企業情報の取得結果が扱える大きさを超えています。") }
    static func httpError(_ status: Int) -> NativeAIError {
        .init(message: [401,402,403].contains(status) ? "E2Bの接続設定・利用権限・残高を確認してください。" : "企業情報の取得サービスでエラーが発生しました。", retryable: status == 408 || status == 429 || status >= 500, status: status)
    }
    static func frame(_ body: Data, flags: UInt8 = 0) -> Data {
        let count = UInt32(body.count)
        var data = Data([flags, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(body); return data
    }
}

/// Connect's five-byte envelope and the locked SDK's process.Process/Start JSON.
/// Keep UTF-8 as bytes across both HTTP chunks and stdout events.
struct NativeE2BStream {
    static let maximumFrame = 4 * 1024 * 1024, maximumWire = 16 * 1024 * 1024, maximumOutput = 2 * 1024 * 1024
    enum Event { case started(Int), stdout(Data), stderr(Data), ended(Int), finished }
    private var buffer = Data(), received = 0
    private(set) var started = false, ended = false, finished = false
    private struct Message: Decodable {
        struct ProcessEvent: Decodable {
            struct Start: Decodable { let pid: Int }
            struct Output: Decodable { let stdout: String?, stderr: String?, pty: String? }
            struct End: Decodable { var exitCode: Int? }
            let start: Start?, data: Output?, end: End?
        }
        let event: ProcessEvent?
    }
    mutating func append(_ chunk: Data) throws -> [Event] {
        guard received <= Self.maximumWire - chunk.count, !finished || chunk.isEmpty else { throw NativeE2BHTTP.invalid() }
        received += chunk.count; buffer.append(chunk)
        var result: [Event] = [], consumed = 0
        while buffer.count - consumed >= 5 {
            let i = buffer.startIndex + consumed, flags = buffer[i]
            guard flags == 0 || flags == 2 else { throw NativeE2BHTTP.invalid() }
            let length = (1...4).reduce(0) { ($0 << 8) | Int(buffer[i + $1]) }
            guard length <= Self.maximumFrame else { throw NativeE2BHTTP.oversized() }
            guard buffer.count - consumed - 5 >= length else { break }
            let body = buffer.subdata(in: (i + 5)..<(i + 5 + length)); consumed += 5 + length
            if flags == 2 {
                struct EndStream: Decodable { struct Failure: Decodable { let code: String? }; let error: Failure? }
                guard let end = try? JSONDecoder().decode(EndStream.self, from: body) else { throw NativeE2BHTTP.invalid() }
                if let error = end.error {
                    throw NativeAIError(message: "企業情報の取得処理が中断されました。", retryable: ["unavailable", "resource_exhausted", "deadline_exceeded", "canceled"].contains(error.code ?? ""))
                }
                guard started, ended, consumed == buffer.count else { throw NativeE2BHTTP.invalid() }
                finished = true; result.append(.finished); break
            }
            guard !ended, let message = try? JSONDecoder().decode(Message.self, from: body) else { throw NativeE2BHTTP.invalid() }
            guard let event = message.event else { continue } // keepalive/empty event
            guard [event.start != nil, event.data != nil, event.end != nil].filter({ $0 }).count <= 1 else { throw NativeE2BHTTP.invalid() }
            if let start = event.start {
                guard !started, start.pid > 0 else { throw NativeE2BHTTP.invalid() }; started = true; result.append(.started(start.pid))
            } else if let data = event.data {
                guard started, [data.stdout, data.stderr, data.pty].compactMap({ $0 }).count == 1, data.pty == nil else { throw NativeE2BHTTP.invalid() }
                guard let decoded = Data(base64Encoded: data.stdout ?? data.stderr ?? "") else { throw NativeE2BHTTP.invalid() }
                result.append(data.stdout == nil ? .stderr(decoded) : .stdout(decoded))
            } else if let end = event.end {
                guard started else { throw NativeE2BHTTP.invalid() }; ended = true; result.append(.ended(end.exitCode ?? 0))
            }
        }
        if consumed > 0 { buffer = consumed == buffer.count ? Data() : Data(buffer.dropFirst(consumed)) }
        guard buffer.count <= Self.maximumFrame + 5 else { throw NativeE2BHTTP.oversized() }
        return result
    }
    func complete() throws { guard finished, ended, buffer.isEmpty else { throw NativeE2BHTTP.invalid() } }
}

final class NativeE2BCommandResult {
    private var decoder = NativeE2BStream(), stdout = Data(), stderrLine = Data()
    private var stderrBytes = 0, exitCode: Int?, agentStatus: Int?
    private let report: NativeContactEnrichmentWorker.Report
    init(report: @escaping NativeContactEnrichmentWorker.Report) { self.report = report }
    func append(_ chunk: Data) async throws {
        for event in try decoder.append(chunk) {
            switch event {
            case .started: try await report(.init(message: "企業・担当者の情報取得を開始しました。", kind: .agent))
            case let .stdout(data):
                guard stdout.count <= NativeE2BStream.maximumOutput - data.count else { throw NativeE2BHTTP.oversized() }; stdout.append(data)
            case let .stderr(data):
                guard stderrBytes <= 512 * 1024 - data.count else { throw NativeE2BHTTP.oversized() }; stderrBytes += data.count
                for byte in data {
                    if byte == 10 { try await line(); stderrLine.removeAll(keepingCapacity: false) }
                    else { guard stderrLine.count < 32_768 else { throw NativeE2BHTTP.oversized() }; stderrLine.append(byte) }
                }
            case let .ended(code): exitCode = code
            case .finished: break
            }
        }
    }
    private func line() async throws {
        let progressPrefix = Data("@@NEXTCRM_PROGRESS@@".utf8), errorPrefix = Data("@@NEXTCRM_ERROR@@".utf8)
        if stderrLine.starts(with: progressPrefix) {
            struct Progress: Decodable { let message: String; let kind: String?; let sourceURL: String? }
            guard let progress = try? JSONDecoder().decode(Progress.self, from: stderrLine.dropFirst(progressPrefix.count)) else { throw NativeE2BHTTP.invalid() }
            let source = progress.sourceURL.flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme ?? "") && $0.user == nil && $0.password == nil ? $0.absoluteString : nil }
            try await report(.init(message: String(progress.message.prefix(4000)), kind: .init(rawValue: progress.kind ?? "agent") ?? .agent, sourceURL: source))
        } else if stderrLine.starts(with: errorPrefix) {
            struct Failure: Decodable { let status: Int? }
            let status = try? JSONDecoder().decode(Failure.self, from: stderrLine.dropFirst(errorPrefix.count)).status
            if let status, (400...599).contains(status) { agentStatus = status }
        }
        // Other stderr text can contain request URLs or credentials. Discard it.
    }
    func output() async throws -> NativeTargetAgentOutput {
        try decoder.complete(); if !stderrLine.isEmpty { try await line(); stderrLine.removeAll() }
        guard exitCode == 0 else {
            throw NativeAIError(message: agentStatus.map { [401,402,403].contains($0) } == true ? "AnthropicのAPIキー・利用権限・残高を確認してください。" : "企業・担当者の情報を取得できませんでした。", retryable: agentStatus == nil || agentStatus == 429 || (agentStatus ?? 0) >= 500, status: agentStatus)
        }
        guard let result = try? JSONDecoder().decode(NativeTargetAgentOutput.self, from: stdout) else { throw NativeE2BHTTP.invalid() }
        return try result.validated()
    }
}
