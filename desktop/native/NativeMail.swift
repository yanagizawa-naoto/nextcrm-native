import Foundation
import Darwin

enum NativeMailFailure: LocalizedError, Equatable {
    case invalid(String), malformed, tooLarge, cancelled, mailboxChanged, spoolBusy
    case transport(code: Int, uploaded: Bool)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .malformed: return "メールサーバーから届いた内容を読み取れません。"
        case .tooLarge: return "メールのサイズが上限を超えています。"
        case .cancelled: return "メールの処理を中止しました。"
        case .spoolBusy: return "メールの作業領域を別の処理が使用しています。しばらくしてから再試行します。"
        case .mailboxChanged: return "メールフォルダが更新されました。もう一度同期してください。"
        case .transport(let code,let uploaded):
            if uploaded { return "送信結果を確認できません。送信済みフォルダを確認してから、再送の要否を判断してください。" }
            switch code {
            case -6: return "メールサーバーが国際化メールアドレス（SMTPUTF8）に対応していません。対応する送信サーバーを設定してください。"
            case -2: return "このメールサーバーには接続できません。公開されている接続先を確認してください。"
            case 67: return "メールの利用者名またはパスワードを確認してください。"
            case 51, 60: return "メールサーバーの証明書を確認できません。接続設定を確認してください。"
            case 28: return "メールサーバーへの接続がタイムアウトしました。"
            case 64: return "メールサーバーが要求された暗号化方式に対応していません。"
            default: return "メールサーバーに接続できませんでした。接続設定と通信状況を確認してください。"
            }
        }
    }
}

enum NativeMailTLS: Int, Codable, Sendable { case plain = 0, startTLS = 1, implicitTLS = 2, automaticSMTP = 3 }
struct NativeMailEndpoint: Codable, Equatable, Sendable {
    var host: String
    var port: Int
    var tls: NativeMailTLS
    var allowSelfSigned = false
    func validate(smtp: Bool) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58].contains($0) }),
              (1...65535).contains(port), smtp || tls != .automaticSMTP else {
            throw NativeMailFailure.invalid("メールサーバー名とポート番号を確認してください。")
        }
    }
    func url(smtp: Bool, mailbox: String? = nil) throws -> String {
        var parts = URLComponents(); parts.scheme = (smtp ? "smtp" : "imap") + (tls == .implicitTLS ? "s" : "")
        parts.host = host.contains(":") ? "["+host+"]" : host; parts.port = port
        let folder = try mailbox.map(NativeMailUTF7.encode) ?? ""
        let allowed = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = folder.addingPercentEncoding(withAllowedCharacters:allowed) else { throw NativeMailFailure.malformed }
        parts.percentEncodedPath = "/"+encoded
        guard let result = parts.url?.absoluteString else { throw NativeMailFailure.malformed }; return result
    }
}

final class NativeMailCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
struct NativeMailReply: Sendable {
    let body: Data, protocolHeaders: Data
    let serverCode: Int
    let responseBytes: Int
}
/// Owns a private, temporary response file. Reads and network writes cannot
/// overlap; the descriptor stays alive through cancellation and queued work.
final class NativeMailResponseFile: @unchecked Sendable {
    private let ownership: NativeMailTemporaryFiles.Lease
    private let descriptor: Int32
    private let lock = NSLock()
    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        ownership = try NativeMailTemporaryFiles.create(.response,base:temporaryRoot)
        descriptor = try ownership.openContent()
    }
    deinit { close(descriptor) } // Stored ownership releases only after the fd closes.
    static var fileError: NativeMailFailure { .invalid("メールの作業ファイルを処理できません。空き容量を確認してください。") }
    func withDescriptor<T>(_ operation: (Int32) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try operation(descriptor)
    }
}
struct NativeMailWireRequest: Sendable {
    let endpoint: NativeMailEndpoint
    let username: String, password: String
    var mailbox: String? = nil
    var command: String? = nil
    var sender: String? = nil
    var recipients: [String] = []
    var upload = Data()
    var maximumResponse = 1_048_576
    var responseFile: NativeMailResponseFile? = nil
    var smtpVerifyOnly = false
    var oauthBearer: String? = nil
}
enum NativeMailWire {
    // Serial, releasing temporary Foundation allocations after each operation.
    private static let queue = DispatchQueue(label:"NextCRM.mail.network",qos:.utility,autoreleaseFrequency:.workItem)
    static func perform(_ request: NativeMailWireRequest) async throws -> NativeMailReply {
        let signal = NativeMailCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with:Result { try performBlocking(request,cancellation:signal) }) }
            }
        },onCancel:{ signal.cancel() })
    }
    static func performBlocking(_ request: NativeMailWireRequest,cancellation: NativeMailCancellation = NativeMailCancellation()) throws -> NativeMailReply {
        let smtp = request.sender != nil || request.smtpVerifyOnly
        try request.endpoint.validate(smtp:smtp)
        guard !request.smtpVerifyOnly || (request.sender == nil && request.recipients.isEmpty && request.upload.isEmpty && request.command == nil && request.mailbox == nil && request.responseFile == nil) else { throw NativeMailFailure.malformed }
        let url = try request.endpoint.url(smtp:smtp,mailbox:request.mailbox)
        var pointers:[UnsafeMutablePointer<CChar>] = []
        func string(_ value: String?) throws -> UnsafePointer<CChar>? {
            guard let value else { return nil }
            guard !value.utf8.contains(0), let p = strdup(value) else { throw NativeMailFailure.malformed }
            pointers.append(p); return UnsafePointer(p)
        }
        defer { for p in pointers { free(p) } }
        var q = NativeMailRequest()
        q.url = try string(url); q.username = try string(request.username); q.password = try string(request.password); q.oauth_bearer = try string(request.oauthBearer)
        q.command = try string(request.command); q.sender = try string(request.sender)
        q.recipients = try string(smtp && !request.smtpVerifyOnly ? request.recipients.joined(separator:"\n") : nil)
        q.smtp_verify_only = request.smtpVerifyOnly ? 1 : 0
        q.tls_mode = Int32(request.endpoint.tls.rawValue); q.allow_self_signed = request.endpoint.allowSelfSigned ? 1 : 0
        guard request.maximumResponse > 0 else { throw NativeMailFailure.tooLarge }
        q.maximum_response = request.maximumResponse
        q.context = Unmanaged.passUnretained(cancellation).toOpaque()
        q.cancelled = { p in guard let p else { return 1 }; return Unmanaged<NativeMailCancellation>.fromOpaque(p).takeUnretainedValue().isCancelled ? 1 : 0 }
        func transfer(_ fd: Int32?) -> NativeMailResult {
            q.stream_to_fd = fd == nil ? 0 : 1; q.output_fd = fd ?? -1
            return request.upload.withUnsafeBytes { bytes -> NativeMailResult in
                q.upload = bytes.baseAddress?.assumingMemoryBound(to:UInt8.self); q.upload_length = bytes.count
                return native_mail_perform(&q)
            }
        }
        var result = request.responseFile.map { file in file.withDescriptor { transfer($0) } } ?? transfer(nil)
        defer { native_mail_result_free(&result) }
        if result.code == -4 { throw NativeMailFailure.tooLarge }
        if result.code == -5 && result.uploaded_bytes == 0 { throw NativeMailFailure.cancelled }
        guard result.code == 0 else { throw NativeMailFailure.transport(code:Int(result.code),uploaded:result.uploaded_bytes > 0) }
        // Transfer ownership instead of copying a complete message at the C/
        // Swift boundary. Error paths still free both buffers normally.
        let body = result.body.map { Data(bytesNoCopy:$0,count:result.body_length,deallocator:.free) } ?? Data()
        result.body = nil
        let headers = result.headers.map { Data(bytes:$0,count:result.headers_length) } ?? Data()
        return NativeMailReply(body:body,protocolHeaders:headers,serverCode:Int(result.server_code),responseBytes:result.response_bytes)
    }
}

enum NativeMailUTF7 {
    static func encode(_ text: String) throws -> String {
        guard text.utf8.count <= 2048, !text.unicodeScalars.contains(where:{ $0.value < 32 || $0.value == 127 }) else { throw NativeMailFailure.invalid("メールフォルダ名を確認してください。") }
        var result = "", encoded = Data()
        func flush() { if !encoded.isEmpty { result += "&"+encoded.base64EncodedString().replacingOccurrences(of:"/",with:",").replacingOccurrences(of:"=",with:"")+"-"; encoded.removeAll(keepingCapacity:true) } }
        for unit in text.utf16 {
            if unit >= 32 && unit <= 126 { flush(); result += unit == 38 ? "&-" : String(UnicodeScalar(unit)!) }
            else { encoded.append(UInt8(unit >> 8)); encoded.append(UInt8(unit & 255)) }
        }
        flush(); return result
    }
    static func decode(_ text: String) throws -> String {
        guard text.utf8.count <= 8192, text.utf8.allSatisfy({$0 >= 32 && $0 <= 126}) else { throw NativeMailFailure.malformed }
        var result = "", position = text.startIndex
        while position < text.endIndex {
            guard text[position] == "&" else { result.append(text[position]); position = text.index(after:position); continue }
            let start = text.index(after:position)
            guard let end = text[start...].firstIndex(of:"-") else { throw NativeMailFailure.malformed }
            if start == end { result += "&" }
            else {
                var base = String(text[start..<end]).replacingOccurrences(of:",",with:"/")
                base += String(repeating:"=",count:(4-base.utf8.count%4)%4)
                guard let bytes = Data(base64Encoded:base), bytes.count%2 == 0, let decoded = String(data:bytes,encoding:.utf16BigEndian) else { throw NativeMailFailure.malformed }
                result += decoded
            }
            position = text.index(after:end)
        }
        return result
    }
}
