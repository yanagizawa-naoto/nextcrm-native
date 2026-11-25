import Foundation
import CryptoKit
import Darwin

/// Offline URL generation. No network request, credentials file or subprocess
/// is used. App configuration owns the secret and supplies this value to MCP.
struct NativeMCPDocumentStorage {
    static let uploadExtensions = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "application/pdf": "pdf", "application/msword": "doc", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx", "text/plain": "txt"]
    let publicURL: String, bucket: String
    private let signer: (String, String, Int, String) throws -> String
    init(publicURL: String, bucket: String, signer: @escaping (String, String, Int, String) throws -> String) {
        self.publicURL = publicURL; self.bucket = bucket; self.signer = signer
    }
    func presignPut(_ key: String, contentType: String, expiresIn: Int = 600) throws -> String { try signer(key, "PUT", expiresIn, contentType) }
    func presignGet(_ key: String, expiresIn: Int = 300) throws -> String { try signer(key, "GET", expiresIn, "") }
    static func publicEndpoint(_ environment: [String: String]) -> String {
        let value = ["MINIO_PUBLIC_ENDPOINT", "NEXT_PUBLIC_MINIO_ENDPOINT", "MINIO_ENDPOINT"].compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        return value.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    static func local(publicURL: String, bucket: String, appURL: String, secret: String, clock: @escaping () -> Date = Date.init) throws -> NativeMCPDocumentStorage {
        let local = try NativeMCPDocumentLocalSigner(appURL: appURL, secret: secret, clock: clock)
        return .init(publicURL: publicURL, bucket: bucket) { try local.url(key: $0, method: $1, expiresIn: $2, contentType: $3) }
    }
    static func s3(publicURL: String, bucket: String, accessKey: String, secretKey: String, clock: @escaping () -> Date = Date.init) throws -> NativeMCPDocumentStorage {
        let signer = try NativeMCPDocumentS3Signer(endpoint: publicURL, bucket: bucket, accessKey: accessKey, secretKey: secretKey, clock: clock)
        return .init(publicURL: publicURL, bucket: bucket) { try signer.url(key: $0, method: $1, expiresIn: $2, contentType: $3) }
    }
    fileprivate static func encode(_ value: String, form: Bool = false) -> String {
        value.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(byte) || byte == (form ? 42 : 126) { return String(UnicodeScalar(byte)) }
            if form && byte == 32 { return "+" }; return String(format: "%%%02X", byte)
        }.joined()
    }
    fileprivate static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    fileprivate static func hmac(_ data: Data, key: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
    fileprivate static func keyIsValid(_ key: String) -> Bool { !key.isEmpty && key.utf8.count <= 1024 && !key.contains("\0") }
}

struct NativeMCPDocumentLocalSigner {
    private let baseURL: String, secret: Data, clock: () -> Date
    init(appURL: String, secret: String, clock: @escaping () -> Date = Date.init) throws {
        guard var url = URLComponents(string: appURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, !secret.isEmpty else { throw NativeMCPFailure.internalError }
        url.path = "/api/storage/local"; url.query = nil; url.fragment = nil
        guard let base = url.string else { throw NativeMCPFailure.internalError }
        baseURL = base; self.secret = Data(secret.utf8); self.clock = clock
    }
    private func signature(_ key: String, _ method: String, _ expires: String, _ contentType: String) throws -> String {
        let message = try JSONSerialization.data(withJSONObject: ["storage-v1", key, method, expires, contentType], options: [.withoutEscapingSlashes])
        return NativeMCPDocumentStorage.hex(NativeMCPDocumentStorage.hmac(message, key: secret))
    }
    func url(key: String, method: String, expiresIn: Int, contentType: String = "") throws -> String {
        guard NativeMCPDocumentStorage.keyIsValid(key), ["GET", "PUT"].contains(method) else { throw NativeMCPFailure.internalError }
        let expires = String(Int64(floor(clock().timeIntervalSince1970)) + Int64(min(604800, max(1, expiresIn))))
        let values = [("key", key), ("method", method), ("expires", expires), ("contentType", contentType), ("signature", try signature(key, method, expires, contentType))]
        return baseURL + "?" + values.map { NativeMCPDocumentStorage.encode($0.0, form: true) + "=" + NativeMCPDocumentStorage.encode($0.1, form: true) }.joined(separator: "&")
    }
    /// Mirrors URLSearchParams' first-value semantics, including '+' spaces.
    func validate(_ url: URL, method: String, contentType: String = "") throws -> String? {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return nil }
        var params: [String: String] = [:]
        for item in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ value: Substring) -> String? { String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
            guard let key = decode(parts[0]), let value = parts.count == 1 ? "" : decode(parts[1]) else { return nil }
            if params[key] == nil { params[key] = value }
        }
        let key = params["key"] ?? "", expires = params["expires"] ?? "", expectedType = params["contentType"] ?? "", supplied = params["signature"] ?? ""
        guard params["method"] == method, !expires.isEmpty, expires.utf8.allSatisfy({ (48...57).contains($0) }),
              let expiry = Double(expires), expiry > floor(clock().timeIntervalSince1970), supplied.utf8.count == 64,
              supplied.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              method != "PUT" || expectedType == contentType, NativeMCPDocumentStorage.keyIsValid(key) else { return nil }
        let expected = try signature(key, method, expires, expectedType)
        var difference: UInt8 = 0; for (a, b) in zip(supplied.utf8, expected.utf8) { difference |= a ^ b }
        return difference == 0 ? key : nil
    }
}

/// Matches lib/minio.ts with the repository-locked AWS SDK, including its
/// checksum query defaults, path-style bucket and signed Content-Type header.
private struct NativeMCPDocumentS3Signer {
    let endpoint: URLComponents, bucket: String, accessKey: String, secretKey: Data, clock: () -> Date
    init(endpoint: String, bucket: String, accessKey: String, secretKey: String, clock: @escaping () -> Date) throws {
        guard var url = URLComponents(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, !bucket.isEmpty, !accessKey.isEmpty, !secretKey.isEmpty else { throw NativeMCPFailure.internalError }
        url.scheme = url.scheme!.lowercased(); url.host = url.host!.lowercased()
        if url.scheme?.lowercased() == "https" && url.port == 443 || url.scheme?.lowercased() == "http" && url.port == 80 { url.port = nil }
        self.endpoint = url; self.bucket = bucket; self.accessKey = accessKey; self.secretKey = Data(("AWS4" + secretKey).utf8); self.clock = clock
    }
    func url(key: String, method: String, expiresIn: Int, contentType: String) throws -> String {
        guard !key.isEmpty, ["GET", "PUT"].contains(method), (1...604800).contains(expiresIn) else { throw NativeMCPFailure.internalError }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let date = formatter.string(from: clock()), day = String(date.prefix(8)), scope = day + "/us-east-1/s3/aws4_request"
        let encode = NativeMCPDocumentStorage.encode
        var components = endpoint
        let basePath = endpoint.percentEncodedPath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        components.percentEncodedPath = basePath + "/" + encode(bucket, false) + "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0), false) }.joined(separator: "/")
        let host = endpoint.host!.lowercased() + (endpoint.port.map { ":" + String($0) } ?? "")
        let headers = method == "PUT" ? "content-type;host" : "host"
        var query = ["X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Content-Sha256": "UNSIGNED-PAYLOAD", "X-Amz-Credential": accessKey + "/" + scope, "X-Amz-Date": date, "X-Amz-Expires": String(expiresIn), "X-Amz-SignedHeaders": headers, "x-id": method == "PUT" ? "PutObject" : "GetObject"]
        if method == "PUT" { query["x-amz-checksum-crc32"] = "AAAAAA=="; query["x-amz-sdk-checksum-algorithm"] = "CRC32" }
        else { query["x-amz-checksum-mode"] = "ENABLED" }
        func sortedQuery(_ query: [String: String]) -> String { query.keys.sorted().map { encode($0, false) + "=" + encode(query[$0]!, false) }.joined(separator: "&") }
        // The locked S3 serializer supplies this default for an empty header.
        let sourceType = contentType.isEmpty ? "application/octet-stream" : contentType
        let type = sourceType.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let canonicalHeaders = (method == "PUT" ? "content-type:" + type + "\n" : "") + "host:" + host + "\n"
        let request = [method, components.percentEncodedPath, sortedQuery(query), canonicalHeaders, headers, "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", date, scope, NativeMCPDocumentStorage.hex(SHA256.hash(data: Data(request.utf8)))].joined(separator: "\n")
        var signingKey = secretKey
        for value in [day, "us-east-1", "s3", "aws4_request"] { signingKey = NativeMCPDocumentStorage.hmac(Data(value.utf8), key: signingKey) }
        query["X-Amz-Signature"] = NativeMCPDocumentStorage.hex(NativeMCPDocumentStorage.hmac(Data(toSign.utf8), key: signingKey))
        components.percentEncodedQuery = sortedQuery(query); components.fragment = nil
        guard let result = components.string else { throw NativeMCPFailure.internalError }; return result
    }
}

struct NativeMCPDocumentObjectMetadata {
    let fileKey: String, contentType: String, bytes: Int64, sha256: String
}

/// One physical immutable store, shared with native document imports. Mapping
/// from logical bucket/key to this immutable file belongs to the DB transaction.
final class NativeMCPDocumentUpload {
    static let chunkBytes = 256 * 1024
    private let directory: Int32, temporary: String, file: String, contentType: String
    private var descriptor: Int32, bytes: Int64 = 0, hash = SHA256(), metadata: NativeMCPDocumentObjectMetadata?
    private var published = false, retained = false
    init(dataRoot: URL, contentType: String) throws {
        // CRLF forms one Swift grapheme; inspect bytes so both the paired and
        // isolated newline forms match the original /[\r\n]/ rejection.
        guard contentType.utf16.count <= 256, !contentType.utf8.contains(13), !contentType.utf8.contains(10) else { throw NativeMCPFailure.internalError }
        let root = dataRoot.appendingPathComponent("native-documents", isDirectory: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw NativeMCPFailure.internalError }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw NativeMCPFailure.internalError }
        let name = UUID().uuidString.lowercased() + "." + (NativeMCPDocumentStorage.uploadExtensions[contentType] ?? "bin"), temporary = ".stage-" + name
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { close(parent); throw NativeMCPFailure.internalError }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); unlinkat(parent, temporary, 0); close(parent); throw NativeMCPFailure.internalError }
        directory = parent; descriptor = fd; self.temporary = temporary; file = name; self.contentType = contentType
    }
    func append(_ data: Data) throws {
        try Task.checkCancellation()
        guard descriptor >= 0, metadata == nil, !published, !retained, Int64(data.count) <= Int64.max - bytes else { throw NativeMCPFailure.internalError }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let amount = min(Self.chunkBytes, data.count - offset), written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), amount)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw NativeMCPFailure.internalError }; offset += written
            }
        }
        hash.update(data: data); bytes += Int64(data.count)
    }
    func finish() throws -> NativeMCPDocumentObjectMetadata {
        try Task.checkCancellation(); guard descriptor >= 0, !retained else { throw NativeMCPFailure.internalError }
        if let metadata { return metadata }
        guard fsync(descriptor) == 0, fchmod(descriptor, 0o400) == 0 else { throw NativeMCPFailure.internalError }
        let result = NativeMCPDocumentObjectMetadata(fileKey: "native-documents/" + file, contentType: contentType, bytes: bytes, sha256: NativeMCPDocumentStorage.hex(hash.finalize()))
        metadata = result; return result
    }
    func publish() throws {
        try Task.checkCancellation(); guard metadata != nil, !published, !retained, descriptor >= 0 else { throw NativeMCPFailure.internalError }
        guard linkat(directory, temporary, directory, file, 0) == 0 else { throw NativeMCPFailure.internalError }; published = true
        guard unlinkat(directory, temporary, 0) == 0, fsync(directory) == 0 || errno == EINVAL else { throw NativeMCPFailure.internalError }
    }
    func retainAfterCommit() { retained = true; if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    func discard() {
        if !retained { if published { unlinkat(directory, file, 0) }; unlinkat(directory, temporary, 0) }
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }
    deinit { discard(); close(directory) }
}

/// An open inode remains a stable download while another PUT replaces its
/// logical mapping. At most one 256 KiB buffer is retained per read.
final class NativeMCPDocumentObjectReader {
    let metadata: NativeMCPDocumentObjectMetadata
    private var descriptor: Int32, readBytes: Int64 = 0, hash = SHA256(), ended = false
    init(dataRoot: URL, metadata: NativeMCPDocumentObjectMetadata) throws {
        let file = try NativeDocumentFiles.fileName(for: metadata.fileKey)
        let parent = open(dataRoot.appendingPathComponent("native-documents", isDirectory: true).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw NativeMCPFailure.internalError }; defer { Darwin.close(parent) }
        let fd = openat(parent, file, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeMCPFailure.notFound }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == metadata.bytes, metadata.bytes >= 0 else { Darwin.close(fd); throw NativeMCPFailure.internalError }
        descriptor = fd; self.metadata = metadata
    }
    func readChunk() throws -> Data? {
        try Task.checkCancellation(); if ended { return nil }; guard descriptor >= 0 else { throw NativeMCPFailure.internalError }
        var data = Data(count: NativeMCPDocumentUpload.chunkBytes)
        let count: Int = try data.withUnsafeMutableBytes { buffer in
            while true {
                let amount = Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
                if amount < 0 && errno == EINTR { continue }; guard amount >= 0 else { throw NativeMCPFailure.internalError }; return amount
            }
        }
        if count == 0 {
            guard readBytes == metadata.bytes, NativeMCPDocumentStorage.hex(hash.finalize()) == metadata.sha256 else { throw NativeMCPFailure.internalError }
            ended = true; close(); return nil
        }
        guard Int64(count) <= metadata.bytes - readBytes else { throw NativeMCPFailure.internalError }
        data.count = count; readBytes += Int64(count); hash.update(data: data); return data
    }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
