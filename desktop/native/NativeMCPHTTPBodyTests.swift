import Foundation
import CryptoKit

@main enum NativeMCPHTTPBodyTests {
    enum Failure: Error { case assertion(String), injected }
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure.assertion(message) }; checks += 1 }
    final class Probe {
        var bytes = 0, pieces = 0, discarded = 0, completed = 0, largestPiece = 0
        var hash = SHA256(), target: String?
        func receiver(maximum: Int = Int.max, failing: Bool = false) -> NativeMCPHTTPBodyReceiver {
            .init(maximumBytes: maximum, append: { [self] data in
                if failing { throw Failure.injected }; bytes += data.count; pieces += 1; largestPiece = max(largestPiece, data.count); hash.update(data: data)
            }, complete: { [self] in completed += 1; return .init(status: 200) }, discard: { [self] in discarded += 1 })
        }
    }
    static func head(_ headers: String, host: String = "127.0.0.1:8123", target: String = "/api/storage/local?key=a%2Fb%2B%26&signature=fixture") -> Data {
        Data("PUT \(target) HTTP/1.1\r\nHost: \(host)\r\n\(headers)\r\n".utf8)
    }
    static func main() async {
        do { try await run(); print("Native MCP HTTP streamed bodies: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let probe = Probe(), block = Data(repeating: 0xA7, count: 16 * 1024), count = 641
        let parser = try NativeMCPHTTPParser(port: 8123, bodyReceiver: { head in probe.target = head.target; return probe.receiver() })
        try check(try parser.append(head("Content-Length: \(block.count * count)\r\n")) == nil, "stream begins after validated headers")
        var request: NativeMCPHTTPRequest?, expected = SHA256(), peak = 0
        for _ in 0..<count { request = try parser.append(block); expected.update(data: block); peak = max(peak, parser.bufferedBytes) }
        try check(request?.body.isEmpty == true && request?.bodyReceiver != nil, "large body is streamed, never returned as a Data buffer")
        try check(probe.bytes == block.count * count && peak == 0 && probe.largestPiece == block.count, "over 10 MiB body retains no decoded bytes in parser")
        try check(probe.hash.finalize() == expected.finalize(), "every streamed byte reaches consumer")
        try check(probe.target == request?.target && request?.path == "/api/storage/local" && request?.target?.contains("a%2Fb%2B%26") == true, "signed raw query preserved separately from routing path")
        try check(probe.completed == 0, "parser does not publish before request dispatch")
        _ = try await request!.bodyReceiver!.finish(); request = nil
        try check(probe.completed == 1 && probe.discarded == 1, "body ownership transfers to response and cleanup occurs once")
        let chunkedProbe = Probe(), chunked = try NativeMCPHTTPParser(port: 8123, bodyReceiver: { _ in chunkedProbe.receiver() })
        _ = try chunked.append(head("Transfer-Encoding: chunked\r\n"))
        for _ in 0..<14000 { _ = try chunked.append(Data("1\r\nx\r\n".utf8)) }
        var ended = try chunked.append(Data("0\r\nX-Trace: ignored\r\n\r\n".utf8))
        try check(ended?.body.isEmpty == true && chunkedProbe.bytes == 14000 && chunked.bufferedBytes == 0, "streaming framing budget is per line/trailer, not total file size")
        ended = nil; try check(chunkedProbe.discarded == 1, "unpublished complete upload is discarded")
        for (label, input, expectedStatus, maximum) in [
            ("declared size", head("Content-Length: 11\r\n"), 413, 10),
            ("chunked size", head("Transfer-Encoding: chunked\r\n") + Data("4\r\ntest\r\n7\r\nignored\r\n0\r\n\r\n".utf8), 413, 10),
            ("forbidden trailer", head("Transfer-Encoding: chunked\r\n") + Data("1\r\nx\r\n0\r\nAuthorization: injected\r\n\r\n".utf8), 400, 100),
            ("incomplete body", head("Content-Length: 4\r\n") + Data("abc".utf8), 400, 100),
            ("pipelined body", head("Content-Length: 1\r\n") + Data("xGET / HTTP/1.1\r\n\r\n".utf8), 400, 100)
        ] {
            let p = Probe(), parser = try NativeMCPHTTPParser(port: 8123, bodyReceiver: { _ in p.receiver(maximum: maximum) })
            do { _ = try parser.append(input, endOfStream: true); throw Failure.assertion("accepted " + label) }
            catch let error as NativeMCPHTTPParseError { try check(error.status == expectedStatus, "reject " + label) }
            try check(p.completed == 0 && p.discarded == 1 && parser.bufferedBytes == 0, "discard without publishing " + label)
        }
        var opened = 0
        let badHost = try NativeMCPHTTPParser(port: 8123, bodyReceiver: { _ in opened += 1; return Probe().receiver() })
        do { _ = try badHost.append(head("Content-Length: 1\r\n", host: "attacker.invalid:8123")); throw Failure.assertion("host accepted") }
        catch let error as NativeMCPHTTPParseError { try check(error.status == 403 && opened == 0, "host validation precedes opening consumer") }
        let refused = try NativeMCPHTTPParser(port: 8123, bodyReceiver: { _ in throw NativeMCPHTTPParseError(status: 403) })
        do { _ = try refused.append(head("Content-Length: 50000000\r\n")); throw Failure.assertion("unauthorized upload accepted") }
        catch let error as NativeMCPHTTPParseError { try check(error.status == 403 && refused.bufferedBytes == 0, "receiver authorization precedes body size and reception") }
        let failedProbe = Probe(), failed = try NativeMCPHTTPParser(port: 8123, bodyReceiver: { _ in failedProbe.receiver(failing: true) })
        do { _ = try failed.append(head("Content-Length: 1\r\n") + Data([1])); throw Failure.assertion("consumer failure accepted") }
        catch Failure.injected { try check(failedProbe.discarded == 1 && failedProbe.completed == 0, "I/O failure discards unpublished body") }
        let zeroProbe = Probe(), zero = try NativeMCPHTTPParser(port: 8123, bodyReceiver: { _ in zeroProbe.receiver(maximum: 0) })
        var empty = try zero.append(head("Content-Length: 0\r\n"))
        try check(empty?.bodyReceiver != nil && zeroProbe.pieces == 0, "empty PUT still owns a publishable consumer")
        _ = try await empty!.bodyReceiver!.finish(); empty = nil
        try check(zeroProbe.completed == 1 && zeroProbe.discarded == 1, "empty object follows normal lifecycle")
    }
}
