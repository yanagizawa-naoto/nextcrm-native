import Foundation

@main enum NativeMCPHTTPParserTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.assertion(label) }; checks += 1
    }
    static let host = "Host: 127.0.0.1:8123\r\n"
    static func wire(_ headers: String = "", body: String = "", method: String = "POST", target: String = "/api/mcp/mcp") -> Data {
        Data("\(method) \(target) HTTP/1.1\r\n\(host)\(headers)\r\n\(body)".utf8)
    }
    static func parse(_ data: Data, sizes: [Int] = [65536], limits: NativeMCPHTTPParser.Limits = .init()) throws -> NativeMCPHTTPRequest {
        let parser = try NativeMCPHTTPParser(port: 8123, limits: limits)
        var offset = data.startIndex, step = 0, request: NativeMCPHTTPRequest?
        while offset < data.endIndex {
            let end = min(offset + sizes[step % sizes.count], data.endIndex)
            if let value = try parser.append(data.subdata(in: offset..<end)) {
                guard request == nil else { throw Failure.assertion("duplicate emission") }; request = value
            }
            offset = end; step += 1
        }
        let final = try parser.append(Data(), endOfStream: true)
        guard final == nil, parser.bufferedBytes == 0, let request else { throw Failure.assertion("incomplete request or retained body") }
        return request
    }
    static func rejects(_ data: Data, status: Int, label: String, limits: NativeMCPHTTPParser.Limits = .init()) throws {
        do { _ = try parse(data, sizes: [1, 2, 7, 64], limits: limits); throw Failure.assertion("accepted \(label)") }
        catch let error as NativeMCPHTTPParseError { try check(error.status == status, "\(label): expected \(status), got \(error.status)") }
    }
    static func main() {
        do { try run(); print("Native MCP HTTP parser: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let json = "{\"顧客\":\"山田 太郎\"}", bytes = Data("{\"顧客\":\"山田 太郎\"}".utf8)
        let fixed = wire("Content-Type: application/json\r\nContent-Length: \(bytes.count)\r\n", body: json)
        let split = 7
        var chunked = wire("Transfer-Encoding: ChUnKeD\r\nContent-Type: application/json\r\n")
        chunked.append(Data("\(String(split, radix: 16)); name=\"a\\\"b\"\r\n".utf8))
        chunked.append(bytes.prefix(split)); chunked.append(Data("\r\n\(String(bytes.count - split, radix: 16)); unknown\r\n".utf8))
        chunked.append(bytes.dropFirst(split)); chunked.append(Data("\r\n0\r\nX-Checksum: ignored\r\n\r\n".utf8))
        for (label, input) in [("fixed", fixed), ("chunked", chunked)] {
            for size in [1, 2, 3, 7, 31, 4096] {
                let request = try parse(input, sizes: [size])
                try check(request.method == "POST" && request.path == "/api/mcp/mcp" && request.body == bytes, "\(label) fragmentation \(size)")
            }
            // Every possible split of header delimiter, UTF-8, size and chunk
            // delimiters is covered without treating packets as text strings.
            var allSplits = true
            for boundary in 1..<input.count {
                let parser = try NativeMCPHTTPParser(port: 8123)
                let first = try parser.append(input.prefix(boundary))
                let last = try parser.append(input.suffix(input.count - boundary), endOfStream: true)
                allSplits = allSplits && first == nil && last?.body == bytes
            }
            try check(allSplits, "\(label) every two-packet boundary")
        }
        try check(try parse(wire(method: "GET")).body.isEmpty, "GET without body")
        try check(try parse(wire(method: "DELETE")).method == "DELETE", "DELETE without body")
        try check(try parse(wire("Content-Length: 0\r\n")).body.isEmpty, "empty framed POST")
        try check(try parse(wire(method: "GET", target: "/api/mcp/mcp?query=%E6%97%A5")).path == "/api/mcp/mcp", "query excluded from routing path")
        try check(try parse(wire("Origin: http://localhost:8123\r\n", method: "GET")).headers["origin"] == "http://localhost:8123", "local origin accepted")
        let localhost = Data("GET /api/mcp/mcp HTTP/1.1\r\nHoSt: LOCALHOST:8123\r\n\r\n".utf8)
        try check(try parse(localhost).headers["host"] == "LOCALHOST:8123", "case-insensitive field/host")
        for origin in ["null", "https://localhost:8123", "http://localhost:8124", "http://localhost:8123/", "http://localhost:8123.evil.test", "http://user@localhost:8123", "http://evil.test", "http://localhost:8123 http://evil.test"] {
            try rejects(wire("Origin: \(origin)\r\n", method: "GET"), status: 403, label: "untrusted origin \(origin)")
        }
        for value in ["evil.test:8123", "127.0.0.2:8123", "127.0.0.1", "127.0.0.1:8124", "127.0.0.1:8123@evil.test", "localhost.:8123", "0x7f000001:8123"] {
            try rejects(Data("GET / HTTP/1.1\r\nHost: \(value)\r\n\r\n".utf8), status: 403, label: "untrusted Host")
        }
        for field in ["Host: localhost:8123\r\n", "Content-Length: 0\r\nContent-Length: 0\r\n", "Content-Length: 0, 0\r\n", "Content-Length: +0\r\n", "Content-Length: -1\r\n", "Content-Length: 1.0\r\n", "Content-Length: \r\n", "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n", "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n", "Host : localhost:8123\r\n", " Bad: value\r\n", "Bad\r\n", "Bad: value\nInjected: x\r\n", "Bad: value\u{0}\r\n"] {
            try rejects(wire(field), status: 400, label: "ambiguous/malformed header")
        }
        try rejects(Data("GET / HTTP/1.1\r\n\r\n".utf8), status: 400, label: "missing Host")
        for target in ["//evil.test/path", "http://evil.test/path", "/path#fragment", "/path%", "/path%xx", "/path\t", "/a b"] {
            try rejects(wire(method: "GET", target: target), status: 400, label: "invalid request target")
        }
        try rejects(Data("GET / HTTP/1.0\r\n\(host)\r\n".utf8), status: 400, label: "unsupported HTTP version")
        try rejects(Data("GET / HTTP/1.1\nHost: localhost:8123\n\n".utf8), status: 400, label: "bare LF")
        try rejects(wire(), status: 411, label: "unframed POST")
        try rejects(wire("Expect: 100-continue\r\nContent-Length: 100\r\n"), status: 417, label: "unsupported expectation")
        try rejects(wire("Content-Encoding: gzip\r\nContent-Length: 0\r\n"), status: 415, label: "compressed request")
        for coding in ["gzip", "gzip, chunked", "chunked, gzip", "chunked, chunked"] {
            try rejects(wire("Transfer-Encoding: \(coding)\r\n"), status: 501, label: "unsupported coding")
        }
        for content in ["g\r\n", "-1\r\n", "\r\n", "1\na\r\n0\r\n\r\n", "1\rx", "1\r\naXX", "0\r\nHost: evil.test\r\n\r\n", "0\r\nAuthorization: replaced\r\n\r\n", "0\r\nContent-Length: 1\r\n\r\n", "0\r\n Bad: fold\r\n\r\n", "1;\r\n", "1;x=\r\n", "1;x=\"open\r\n", "1;x=\"closed\"oops\r\n", "1 \r\n"] {
            try rejects(wire("Transfer-Encoding: chunked\r\n", body: content), status: 400, label: "malformed chunk/trailer")
        }
        try check(try parse(wire("Transfer-Encoding: chunked\r\n", body: "1 ; name = token; flag\r\na\r\n0\r\n\r\n")).body == Data("a".utf8), "chunk extension whitespace")
        try rejects(wire("Content-Length: 999999999999999999999999\r\n"), status: 413, label: "decimal overflow")
        try rejects(wire("Transfer-Encoding: chunked\r\n", body: "FFFFFFFFFFFFFFFFFFFFFFFF\r\n"), status: 413, label: "hex overflow")
        try rejects(wire("Content-Length: 2\r\n", body: "a"), status: 400, label: "truncated fixed body")
        try rejects(wire("Transfer-Encoding: chunked\r\n", body: "1\r\na\r\n"), status: 400, label: "missing final chunk")
        try rejects(wire("Transfer-Encoding: chunked\r\n", body: "0\r\nX: y\r\n"), status: 400, label: "truncated trailers")
        try rejects(wire("Content-Length: 0\r\n", body: "GET / HTTP/1.1\r\n\r\n"), status: 400, label: "pipelined second request")
        try rejects(wire("Content-Length: 1\r\n", body: "ab"), status: 400, label: "extra body bytes")
        try rejects(wire("Content-Length: 9\r\n"), status: 413, label: "body admission bound", limits: .init(bodyBytes: 8))
        try rejects(wire("Transfer-Encoding: chunked\r\n", body: "5\r\n12345\r\n4\r\n"), status: 413, label: "decoded cumulative bound", limits: .init(bodyBytes: 8))
        try rejects(wire("Transfer-Encoding: chunked\r\n", body: String(repeating: "1\r\na\r\n", count: 20)), status: 413, label: "framing overhead bound", limits: .init(framingBytes: 24))
        try rejects(wire("Transfer-Encoding: chunked\r\n", body: "1;longextension\r\n"), status: 431, label: "chunk line bound", limits: .init(chunkLineBytes: 8))
        try rejects(wire("Transfer-Encoding: chunked\r\n", body: "0\r\nX: 123456\r\n\r\n"), status: 431, label: "trailers bound", limits: .init(trailerBytes: 8))
        try rejects(wire(method: "GET"), status: 431, label: "header bound", limits: .init(headerBytes: 8))
        let bounded = try NativeMCPHTTPParser(port: 8123, limits: .init(bodyBytes: 8))
        _ = try bounded.append(wire("Content-Length: 8\r\n", body: "1234"))
        try check(bounded.bufferedBytes == 4, "only partial body retained")
        let exact = try bounded.append(Data("5678".utf8), endOfStream: true)
        try check(exact?.body == Data("12345678".utf8) && bounded.bufferedBytes == 0, "exact limit accepted and buffer released")
        try check(try bounded.append(Data()) == nil, "no replay of completed request")
        do { _ = try bounded.append(Data("x".utf8)); throw Failure.assertion("trailing input accepted") }
        catch let error as NativeMCPHTTPParseError { try check(error.status == 400 && bounded.bufferedBytes == 0, "terminal failure discards buffers") }
        do { _ = try bounded.append(Data()); throw Failure.assertion("failed parser reused") }
        catch let error as NativeMCPHTTPParseError { try check(error.status == 400, "failed parser cannot restart") }
        // A large body never enters the line accumulator; repeated receives
        // copy into one bounded body, with no cumulative response collection.
        let large = Data(repeating: 120, count: 1024 * 1024)
        let largeParser = try NativeMCPHTTPParser(port: 8123)
        _ = try largeParser.append(wire("Content-Length: \(large.count)\r\n"))
        var largeResult: NativeMCPHTTPRequest?
        for offset in stride(from: 0, to: large.count, by: 4096) {
            largeResult = try largeParser.append(large.subdata(in: offset..<(offset + 4096)))
        }
        try check(largeResult?.body == large && largeParser.bufferedBytes == 0, "1 MiB fragmented request exact reconstruction")
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        for item in reference["cases"] as! [[String: Any]] {
            let input = item["request"] as! [String: Any], method = input["method"] as! String
            var fields = input["headers"] as! [String: String]
            let content = input["body"] as? String ?? ""
            fields["content-length"] = String(content.utf8.count)
            let request = try parse(wire(fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined(), body: content, method: method), sizes: [1, 19, 4096])
            try check(request.method == method && request.body == Data(content.utf8), "installed SDK fixture framing: \(item["label"]!)")
        }
    }
}
