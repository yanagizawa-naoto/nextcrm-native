import Foundation
import CryptoKit

final class HTTPBodyFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0, discarded = 0, completed = 0, bytes = 0, active = 0, peak = 0
    let release = DispatchSemaphore(value: 0)
    func openedBody() { lock.lock(); defer { lock.unlock() }; opened += 1; active += 1 }
    func appended(_ count: Int) { lock.lock(); defer { lock.unlock() }; bytes += count; peak = max(peak, count) }
    func finished() { lock.lock(); defer { lock.unlock() }; completed += 1 }
    func discardedBody() { lock.lock(); defer { lock.unlock() }; discarded += 1; active -= 1 }
    func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return ["opened": opened, "discarded": discarded, "completed": completed, "bytes": bytes, "active": active, "largestAppend": peak] }
}
@main enum NativeMCPHTTPBodyServerFixture {
    static let block = Data((0..<16384).map { UInt8($0 % 256) })
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func emit(_ object: Any) throws { print(String(decoding: try json(object), as: UTF8.self)); fflush(stdout) }
    static func main() async {
        do { try await run() } catch { try? emit(["fatal": String(describing: error)]); exit(1) }
    }
    static func run() async throws {
        let state = HTTPBodyFixtureState()
        let server = try NativeMCPHTTPServer(configuration: .init(readTimeout: 0.5, requestTimeout: 10, sendTimeout: 0.8, heartbeatInterval: 0.02), bodyReceiver: { request in
            guard request.method == "PUT", request.path == "/upload" else { return nil }
            guard request.headers["x-fixture-allowed"] == "yes" else { throw NativeMCPHTTPParseError(status: 403) }
            state.openedBody(); var hash = SHA256(), bytes = 0, held = false
            return .init(maximumBytes: Int.max, append: { data in
                state.appended(data.count)
                if request.headers["x-fixture-hold"] == "yes", !held { held = true; state.release.wait() }
                try Task.checkCancellation(); hash.update(data: data); bytes += data.count
            }, complete: {
                state.finished()
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                return .init(status: 200, headers: ["content-type": "application/json"], body: try json(["bytes": bytes, "sha256": digest, "target": request.target ?? ""]))
            }, discard: { state.discardedBody() })
        }) { request in
            if request.path == "/stats" { return .init(status: 200, headers: ["content-type": "application/json"], body: try! json(state.snapshot())) }
            if request.path.hasPrefix("/bytes") {
                let count = 9 * 1024 * 1024 + 17, unknown = request.path == "/bytes-chunked", short = request.path == "/bytes-short", extra = request.path == "/bytes-extra"
                let stream = NativeMCPResponseStream { sink in
                    var left = count - (short ? 1 : 0) + (extra ? 1 : 0)
                    while left > 0 {
                        try Task.checkCancellation(); let amount = min(left, block.count); try await sink(Data(block.prefix(amount))); left -= amount
                        if left == count - block.count { try await Task.sleep(nanoseconds: 50_000_000) }
                    }
                }
                return .init(status: 200, headers: ["content-type": "application/octet-stream", "content-disposition": "attachment"], stream: stream, streamFormat: .bytes, contentLength: unknown ? nil : Int64(count))
            }
            return .init(status: 404)
        }
        let url = try await server.start(); try emit(["ready": url.absoluteString])
        while let line = readLine() {
            switch line {
            case "stats":
                let snapshot = await server.snapshot(); try emit(["server": ["retained": snapshot.retainedPeers, "running": snapshot.runningRequests, "peakWrites": snapshot.peakQueuedWrites], "bodies": state.snapshot()])
            case "release": state.release.signal(); try emit(["released": true])
            case "quit": await server.stop(); try emit(["stopped": true]); return
            default: throw NativeMCPHTTPServerError.configuration
            }
        }
        await server.stop()
    }
}
