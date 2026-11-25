import Foundation

/// The same listener serves MCP and its short-lived local object capabilities.
/// Host/Origin/framing are checked by HTTPParser before this adapter is called.
final class NativeMCPDocumentHTTP {
    let store: NativeMCPDocumentObjectStore
    init(store: NativeMCPDocumentObjectStore) { self.store = store }
    private func url(_ request: NativeMCPHTTPRequest) -> URL? {
        guard let host = request.headers["host"], let target = request.target,
              target.hasPrefix("/"), !target.hasPrefix("//") else { return nil }
        return URL(string: "http://" + host + target)
    }
    private static func text(_ status: Int, _ message: String) -> NativeMCPHTTPResponse {
        .init(status: status, headers: ["content-type": "text/plain;charset=UTF-8"], body: Data(message.utf8))
    }
    func bodyReceiver(_ request: NativeMCPHTTPRequest) throws -> NativeMCPHTTPBodyReceiver? {
        guard request.path == "/api/storage/local", request.method == "PUT" else { return nil }
        let type = request.headers["content-type"] ?? ""
        guard let url = url(request), let key = try store.authorize(url, method: "PUT", contentType: type) else {
            throw NativeMCPHTTPParseError(status: 403, message: "アクセスできません")
        }
        let upload: NativeMCPDocumentObjectStore.Upload
        do { upload = try store.beginUpload(key: key, contentType: type) }
        catch { throw NativeMCPHTTPParseError(status: 500) }
        return .init(maximumBytes: Int.max, append: { try upload.append($0) }, complete: {
            let etag = try upload.finish()
            return .init(status: 200, headers: ["etag": etag])
        }, discard: { upload.discard() })
    }
    func handle(_ request: NativeMCPHTTPRequest) -> NativeMCPHTTPResponse? {
        guard request.path == "/api/storage/local" else { return nil }
        if request.method == "OPTIONS" { return .init(status: 204, headers: ["allow": "GET, HEAD, OPTIONS, PUT"]) }
        guard ["GET", "HEAD"].contains(request.method) else {
            // Successful PUT is dispatched through its streamed receiver.
            return .init(status: 405, headers: ["allow": "GET, HEAD, OPTIONS, PUT"])
        }
        do {
            guard let url = url(request), let key = try store.authorize(url, method: "GET") else { return Self.text(403, "アクセスできません") }
            let reader = try store.open(key: key), metadata = reader.metadata
            let inline = ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(metadata.contentType)
            // encodeURIComponent retains these ASCII characters and encodes
            // UTF-8 bytes. The logical key is never used as a filesystem path.
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
            let filename = (key.components(separatedBy: "/").last ?? "").utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
            let stream = NativeMCPResponseStream { sink in
                defer { reader.close() }
                while let data = try reader.readChunk() { try Task.checkCancellation(); try await sink(data) }
            }
            return .init(status: 200, headers: ["content-type": metadata.contentType,
                "content-disposition": "\(inline ? "inline" : "attachment"); filename*=UTF-8''\(filename)",
                "cache-control": "private, no-store", "x-content-type-options": "nosniff",
                "content-security-policy": "default-src 'none'; sandbox"], stream: stream, streamFormat: .bytes, contentLength: metadata.bytes)
        } catch NativeMCPFailure.notFound { return Self.text(404, "ファイルが見つかりません") }
        catch { return .init(status: 500) }
    }
}
