import Foundation

struct NativeMCPHTTPParseError: Error {
    let status: Int
    var message: String? = nil
}

/// One HTTP/1.1 request per connection. Header/framing bytes are bounded
/// independently of decoded body bytes. No trailer can replace authentication
/// or routing headers, and no request is emitted twice.
final class NativeMCPHTTPParser {
    struct Limits {
        var headerBytes = 16 * 1024
        var bodyBytes = 8 * 1024 * 1024
        var framingBytes = 64 * 1024
        var chunkLineBytes = 1024
        var trailerBytes = 16 * 1024
    }
    private enum State { case head, fixed(Int), chunkLine, chunkData(Int), chunkEnd(Int), trailers, complete, failed }
    private var state = State.head
    private var line: [UInt8] = [], body = Data()
    private var method = "", path = "", target = "", headers: [String: String] = [:]
    private var framing = 0, trailers = 0, emitted = false
    private var bodyBytes = 0, maximumBodyBytes: Int
    private var bodyReceiver: NativeMCPHTTPBodyReceiver?
    private let receiverFactory: NativeMCPHTTPBodyReceiver.Factory?
    private let limits: Limits, hosts: Set<String>, origins: Set<String>
    var bufferedBytes: Int { line.count + body.count }
    var isReceivingStream: Bool { bodyReceiver != nil }

    init(port: UInt16, limits: Limits = Limits(), bodyReceiver: NativeMCPHTTPBodyReceiver.Factory? = nil) throws {
        guard port > 0, limits.headerBytes > 0, limits.bodyBytes > 0,
              limits.framingBytes > 0, limits.chunkLineBytes > 0, limits.trailerBytes > 0 else {
            throw NativeMCPHTTPParseError(status: 500)
        }
        self.limits = limits; maximumBodyBytes = limits.bodyBytes; receiverFactory = bodyReceiver
        hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        origins = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
    }

    func append(_ data: Data, endOfStream: Bool = false) throws -> NativeMCPHTTPRequest? {
        do { return try consume(data, endOfStream: endOfStream) }
        catch {
            state = .failed; line = []; body = Data(); headers = [:]; bodyReceiver = nil
            throw error
        }
    }

    private func consume(_ data: Data, endOfStream: Bool) throws -> NativeMCPHTTPRequest? {
        if case .failed = state { throw NativeMCPHTTPParseError(status: 400) }
        var cursor = data.startIndex
        while cursor < data.endIndex {
            switch state {
            case .head:
                line.append(data[cursor]); cursor += 1
                guard line.count <= limits.headerBytes else { throw NativeMCPHTTPParseError(status: 431) }
                if line.count >= 4, line.suffix(4).elementsEqual([13, 10, 13, 10]) {
                    try parseHead(); line = []
                }
            case .fixed(let remaining), .chunkData(let remaining):
                let amount = min(remaining, data.endIndex - cursor)
                guard amount <= maximumBodyBytes - bodyBytes else { throw NativeMCPHTTPParseError(status: 413) }
                if let bodyReceiver { try bodyReceiver.append(Data(data[cursor..<(cursor + amount)])) }
                else { body.append(contentsOf: data[cursor..<(cursor + amount)]) }
                bodyBytes += amount; cursor += amount
                switch state {
                case .fixed: state = amount == remaining ? .complete : .fixed(remaining - amount)
                default: state = amount == remaining ? .chunkEnd(0) : .chunkData(remaining - amount)
                }
            case .chunkLine, .trailers:
                let byte = data[cursor]; cursor += 1
                if bodyReceiver == nil {
                    framing += 1
                    guard framing <= limits.framingBytes else { throw NativeMCPHTTPParseError(status: 413) }
                }
                let isTrailer: Bool
                if case .trailers = state { isTrailer = true; trailers += 1 } else { isTrailer = false }
                guard trailers <= limits.trailerBytes else { throw NativeMCPHTTPParseError(status: 431) }
                if line.last == 13 && byte != 10 || byte == 10 && line.last != 13 { throw NativeMCPHTTPParseError(status: 400) }
                line.append(byte)
                guard line.count <= (isTrailer ? limits.headerBytes : limits.chunkLineBytes) else { throw NativeMCPHTTPParseError(status: 431) }
                if byte == 10 {
                    line.removeLast(2)
                    if isTrailer {
                        if line.isEmpty { state = .complete }
                        else {
                            let field = try Self.field(String(decoding: line, as: UTF8.self))
                            guard !Self.forbiddenTrailers.contains(field.0) else { throw NativeMCPHTTPParseError(status: 400) }
                        }
                    } else {
                        let length = try Self.chunkLength(line)
                        guard length <= maximumBodyBytes - bodyBytes else { throw NativeMCPHTTPParseError(status: 413) }
                        state = length == 0 ? .trailers : .chunkData(length)
                    }
                    line = []
                }
            case .chunkEnd(let offset):
                if bodyReceiver == nil {
                    framing += 1
                    guard framing <= limits.framingBytes else { throw NativeMCPHTTPParseError(status: 413) }
                }
                guard data[cursor] == (offset == 0 ? 13 : 10) else { throw NativeMCPHTTPParseError(status: 400) }
                cursor += 1; state = offset == 0 ? .chunkEnd(1) : .chunkLine
            case .complete, .failed:
                // Pipelining is deliberately unsupported; every response closes
                // the connection (except the bounded standalone SSE stream).
                throw NativeMCPHTTPParseError(status: 400)
            }
        }
        if case .complete = state {
            guard !emitted else { return nil }
            emitted = true
            let request = NativeMCPHTTPRequest(method: method, path: path, headers: headers, body: body, target: target, bodyReceiver: bodyReceiver)
            body = Data(); headers = [:]; bodyReceiver = nil
            return request
        }
        if endOfStream { throw NativeMCPHTTPParseError(status: 400) }
        return nil
    }

    private func parseHead() throws {
        guard line.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { throw NativeMCPHTTPParseError(status: 400) }
        let lines = String(decoding: line.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", !first[0].isEmpty,
              first[0].utf8.allSatisfy(Self.token) else { throw NativeMCPHTTPParseError(status: 400) }
        target = String(first[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#"),
              target.utf8.allSatisfy({ (33...126).contains($0) }), Self.validEscapes(target) else { throw NativeMCPHTTPParseError(status: 400) }
        method = String(first[0]); path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        for value in lines.dropFirst() {
            let (name, value) = try Self.field(value)
            // Reject ambiguous repeated fields instead of merging them. The
            // installed SDK uses one field for each name, including Accept.
            guard headers[name] == nil else { throw NativeMCPHTTPParseError(status: 400) }
            headers[name] = value
        }
        guard let host = headers["host"] else { throw NativeMCPHTTPParseError(status: 400) }
        guard hosts.contains(host.lowercased()) else { throw NativeMCPHTTPParseError(status: 403) }
        if let origin = headers["origin"], !origins.contains(origin.lowercased()) { throw NativeMCPHTTPParseError(status: 403) }
        if headers["expect"] != nil { throw NativeMCPHTTPParseError(status: 417) }
        if let coding = headers["content-encoding"], coding.lowercased() != "identity" { throw NativeMCPHTTPParseError(status: 415) }
        var declaredLength: Int?
        if let encoding = headers["transfer-encoding"] {
            guard headers["content-length"] == nil else { throw NativeMCPHTTPParseError(status: 400) }
            guard encoding.lowercased() == "chunked" else { throw NativeMCPHTTPParseError(status: 501) }
            state = .chunkLine
        } else if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }) else { throw NativeMCPHTTPParseError(status: 400) }
            guard let count = Int(length) else { throw NativeMCPHTTPParseError(status: 413) }
            declaredLength = count
            state = count == 0 ? .complete : .fixed(count)
        } else {
            guard method != "POST" else { throw NativeMCPHTTPParseError(status: 411) }
            state = .complete
        }
        bodyReceiver = try receiverFactory?(.init(method: method, path: path, headers: headers, body: Data(), target: target))
        if let bodyReceiver {
            guard bodyReceiver.maximumBytes >= 0 else { throw NativeMCPHTTPParseError(status: 500) }
            maximumBodyBytes = bodyReceiver.maximumBytes
        }
        if let declaredLength, declaredLength > maximumBodyBytes { throw NativeMCPHTTPParseError(status: 413) }
    }

    private static let forbiddenTrailers: Set<String> = ["host", "origin", "authorization", "proxy-authorization", "cookie", "content-length", "transfer-encoding", "trailer", "content-type", "content-encoding", "connection", "expect", "mcp-protocol-version", "mcp-session-id"]
    private static func token(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
    private static func field(_ value: String) throws -> (String, String) {
        guard let colon = value.firstIndex(of: ":"), colon != value.startIndex else { throw NativeMCPHTTPParseError(status: 400) }
        let name = value[..<colon], raw = value[value.index(after: colon)...]
        guard name.utf8.allSatisfy(token), raw.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { throw NativeMCPHTTPParseError(status: 400) }
        return (name.lowercased(), raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
    }
    private static func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
    private static func validEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8); var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
    private static func chunkLength(_ bytes: [UInt8]) throws -> Int {
        var index = 0
        while index < bytes.count, hex(bytes[index]) { index += 1 }
        guard index > 0 else { throw NativeMCPHTTPParseError(status: 400) }
        guard let length = Int(String(decoding: bytes[..<index], as: UTF8.self), radix: 16) else { throw NativeMCPHTTPParseError(status: 413) }
        func whitespace() { while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 { index += 1 } }
        while index < bytes.count {
            whitespace()
            guard index < bytes.count, bytes[index] == 59 else { throw NativeMCPHTTPParseError(status: 400) }
            index += 1; whitespace()
            let start = index
            while index < bytes.count, token(bytes[index]) { index += 1 }
            guard index > start else { throw NativeMCPHTTPParseError(status: 400) }
            whitespace()
            if index < bytes.count, bytes[index] == 61 {
                index += 1; whitespace()
                if index < bytes.count, bytes[index] == 34 {
                    index += 1; var closed = false
                    while index < bytes.count {
                        let byte = bytes[index]; index += 1
                        if byte == 34 { closed = true; break }
                        if byte == 92 {
                            guard index < bytes.count, bytes[index] == 9 || (32...126).contains(bytes[index]) else { throw NativeMCPHTTPParseError(status: 400) }
                            index += 1
                        } else if byte != 9 && !(32...126).contains(byte) { throw NativeMCPHTTPParseError(status: 400) }
                    }
                    guard closed else { throw NativeMCPHTTPParseError(status: 400) }
                } else {
                    let start = index
                    while index < bytes.count, token(bytes[index]) { index += 1 }
                    guard index > start else { throw NativeMCPHTTPParseError(status: 400) }
                }
            }
        }
        return length
    }
}
