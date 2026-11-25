import Foundation
import CoreFoundation

struct NativeMCPHTTPRequest {
    var method: String, path: String, headers: [String: String], body: Data
    // Preserve the original query for signed object URLs. MCP dispatch still
    // matches the path without a query string.
    var target: String? = nil
    var bodyReceiver: NativeMCPHTTPBodyReceiver? = nil
}
enum NativeMCPHTTPStreamFormat { case events, bytes }
struct NativeMCPHTTPResponse {
    var status: Int, headers: [String: String] = [:], body = Data(), keepOpen = false
    var stream: NativeMCPResponseStream?
    var streamFormat: NativeMCPHTTPStreamFormat = .events
    var contentLength: Int64? = nil
    func writeBody(to sink: @escaping NativeMCPResponseStream.Sink) async throws {
        if let stream { try await stream.write(to: sink) }
        else if !body.isEmpty { try Task.checkCancellation(); try await sink(body) }
    }
}

/// A request-specific consumer selected after validating its HTTP headers.
/// The transport serializes append calls and applies backpressure before
/// receiving another chunk. Cleanup also runs for incomplete/disconnected
/// requests; a committed upload's cleanup must preserve the published object.
final class NativeMCPHTTPBodyReceiver {
    typealias Factory = (NativeMCPHTTPRequest) throws -> NativeMCPHTTPBodyReceiver?
    let maximumBytes: Int
    private let consume: (Data) throws -> Void
    private let complete: () async throws -> NativeMCPHTTPResponse
    private let discard: () -> Void
    init(maximumBytes: Int, append: @escaping (Data) throws -> Void,
         complete: @escaping () async throws -> NativeMCPHTTPResponse, discard: @escaping () -> Void) {
        self.maximumBytes = maximumBytes; consume = append; self.complete = complete; self.discard = discard
    }
    deinit { discard() }
    func append(_ data: Data) throws { try Task.checkCancellation(); try consume(data); try Task.checkCancellation() }
    func finish() async throws -> NativeMCPHTTPResponse { try Task.checkCancellation(); return try await complete() }
}

/// The producer cannot run ahead of the socket. One event is retained until
/// its send completes, and a disconnected consumer stops subsequent effects.
/// Copies of the HTTP response share this single-use producer.
final class NativeMCPResponseStream {
    typealias Sink = (Data) async throws -> Void
    private let produce: (@escaping Sink) async throws -> Void
    private let lock = NSLock()
    private var consumed = false
    init(_ produce: @escaping (@escaping Sink) async throws -> Void) { self.produce = produce }
    private func claim() throws {
        lock.lock(); defer { lock.unlock() }
        guard !consumed else { throw NativeMCPProtocolError.streamAlreadyConsumed }
        consumed = true
    }
    func write(to sink: @escaping Sink) async throws {
        try claim(); try Task.checkCancellation(); try await produce(sink)
    }
}

/// Stateless Streamable HTTP/JSON-RPC envelope. Tool authorization, schema
/// validation and CRM effects are supplied by the dispatcher, never inferred
/// from discovery metadata. This layer does not open any listening socket.
final class NativeMCPProtocol {
    typealias Call = (_ name: String, _ arguments: [String: Any], _ id: Any) async throws -> [String: Any]
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]
    private let tools: [[String: Any]], names: Set<String>, name: String, version: String, call: Call
    private let maximumBodyBytes: Int, maximumBatchSize: Int
    init(tools: [[String: Any]], name: String = "NextCRM Native", version: String = "0.6", maximumBodyBytes: Int = 8 * 1024 * 1024, maximumBatchSize: Int = 100, call: @escaping Call) throws {
        let names = tools.compactMap { $0["name"] as? String }
        guard names.count == tools.count, Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty }), maximumBodyBytes > 0, maximumBatchSize > 0,
              JSONSerialization.isValidJSONObject(tools) else { throw NativeMCPProtocolError.invalidCatalog }
        self.tools = tools; self.names = Set(names); self.name = name; self.version = version
        self.maximumBodyBytes = maximumBodyBytes; self.maximumBatchSize = maximumBatchSize; self.call = call
    }
    private static func encode(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data() }
    private static func validID(_ value: Any?) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite
    }
    private static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func validParams(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let params = object(value) else { return false }
        if let meta = params["_meta"] {
            guard let fields = object(meta) else { return false }
            if let progress = fields["progressToken"], !validID(progress) { return false }
        }
        return true
    }
    private static func validMessage(_ value: Any) -> Bool {
        guard let object = object(value), object["jsonrpc"] as? String == "2.0" else { return false }
        if object["method"] is String { return (object["id"] == nil || validID(object["id"])) && validParams(object["params"]) }
        guard validID(object["id"]) else { return false }
        if let error = self.object(object["error"]) { return validID(error["code"]) && !(error["code"] is String) && error["message"] is String }
        return self.object(object["result"]) != nil
    }
    private static func error(id: Any = NSNull(), code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    private static func failure(_ status: Int, _ code: Int, _ message: String) -> NativeMCPHTTPResponse {
        .init(status: status, headers: ["content-type": "application/json"], body: encode(error(code: code, message: message)))
    }
    static func toolError(_ message: String) -> [String: Any] { ["content": [["type": "text", "text": message]], "isError": true] }

    func handle(_ request: NativeMCPHTTPRequest, dispatch: Call? = nil) async -> NativeMCPHTTPResponse {
        // A request-specific closure carries only that request's credentials;
        // never mutate a shared dispatcher when concurrent clients connect.
        let call = dispatch ?? self.call
        guard request.path == "/api/mcp/mcp" else {
            if ["/api/mcp/sse", "/api/mcp/message"].contains(request.path) {
                return .init(status: 501, headers: ["content-type": "application/json"], body: Self.encode(["error": "SSE transport is not available. Use the Streamable HTTP endpoint /api/mcp/mcp."]))
            }
            return .init(status: 404)
        }
        // The network layer also enforces this bound before reading the body.
        guard request.body.count <= maximumBodyBytes else { return Self.failure(413, -32000, "Request body too large") }
        let headers = request.headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        if let supplied = headers["mcp-protocol-version"], !Self.supportedVersions.contains(supplied) {
            return Self.failure(400, -32000, "Bad Request: Unsupported protocol version: \(supplied) (supported versions: \(Self.supportedVersions.joined(separator: ", ")))")
        }
        let accept = (headers["accept"] ?? "").lowercased()
        if request.method == "GET" {
            guard accept.contains("text/event-stream") else { return Self.failure(406, -32000, "Not Acceptable: Client must accept text/event-stream") }
            return .init(status: 200, headers: ["content-type": "text/event-stream", "cache-control": "no-cache", "connection": "keep-alive"], keepOpen: true)
        }
        if request.method == "DELETE" { return .init(status: 200) }
        guard request.method == "POST" else { return .init(status: 405, headers: ["allow": "GET, POST, DELETE"]) }
        guard accept.contains("application/json"), accept.contains("text/event-stream") else {
            return Self.failure(406, -32000, "Not Acceptable: Client must accept both application/json and text/event-stream")
        }
        guard (headers["content-type"] ?? "").lowercased().contains("application/json") else {
            return Self.failure(415, -32000, "Unsupported Media Type: Content-Type must be application/json")
        }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed]) }
        catch { return Self.failure(400, -32700, "Parse error: Invalid JSON") }
        let messages = (decoded as? [Any]) ?? [decoded]
        guard messages.count <= maximumBatchSize else { return Self.failure(413, -32000, "Too many messages in one request") }
        guard messages.allSatisfy(Self.validMessage) else { return Self.failure(400, -32700, "Parse error: Invalid JSON-RPC message") }
        // Validate the entire batch before any action runs. Responses and
        // notifications have no event to produce.
        let requests = messages.compactMap { $0 as? [String: Any] }.filter { $0["id"] != nil && $0["method"] is String }
        guard !requests.isEmpty else { return .init(status: 202) }
        let stream = NativeMCPResponseStream { [self] sink in
        for message in requests {
            try Task.checkCancellation()
            let id = message["id"]!, method = message["method"] as! String
            let params = Self.object(message["params"]) ?? [:]
            let response: [String: Any]
                switch method {
                case "initialize":
                    guard let requested = params["protocolVersion"] as? String,
                          Self.object(params["capabilities"]) != nil, let client = Self.object(params["clientInfo"]),
                          client["name"] is String, client["version"] is String else {
                        try await sink(Self.event(Self.error(id: id, code: -32602, message: "Invalid initialize parameters"))); continue
                    }
                    let selected = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
                    response = ["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": selected, "capabilities": ["tools": ["listChanged": true]], "serverInfo": ["name": name, "version": version]]]
                case "ping": response = ["jsonrpc": "2.0", "id": id, "result": [:]]
                case "tools/list": response = ["jsonrpc": "2.0", "id": id, "result": ["tools": tools]]
                case "tools/call":
                    let result: [String: Any]
                    if let tool = params["name"] as? String {
                        if names.contains(tool) {
                            if params["arguments"] != nil && Self.object(params["arguments"]) == nil {
                                result = Self.toolError("MCP error -32602: Invalid tool arguments")
                            } else {
                                do { result = try await call(tool, Self.object(params["arguments"]) ?? [:], id) }
                                catch is CancellationError { throw CancellationError() }
                                catch { result = Self.toolError("Internal tool error") }
                            }
                        } else { result = Self.toolError("MCP error -32602: Tool \(tool) not found") }
                    } else { result = Self.toolError("MCP error -32602: Tool name is required") }
                    guard JSONSerialization.isValidJSONObject(result) else {
                        try await sink(Self.event(Self.error(id: id, code: -32603, message: "Invalid tool result"))); continue
                    }
                    response = ["jsonrpc": "2.0", "id": id, "result": result]
                default: response = Self.error(id: id, code: -32601, message: "Method not found")
                }
            try Task.checkCancellation()
            try await sink(Self.event(response))
        }
        }
        return .init(status: 200, headers: ["content-type": "text/event-stream", "cache-control": "no-cache"], stream: stream)
    }
    private static func event(_ message: [String: Any]) -> Data {
        var data = Data("event: message\ndata: ".utf8); data.append(encode(message)); data.append(Data("\n\n".utf8)); return data
    }
}
enum NativeMCPProtocolError: Error { case invalidCatalog, streamAlreadyConsumed }
