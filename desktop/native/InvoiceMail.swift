import Foundation
import CryptoKit
import Darwin

struct InvoiceMailBody {
    let url: URL; let bytes: Int; let sha256: String
}

enum InvoiceMail {
    static let maximumBytes = 40_000_000 // Local JSON body cap; provider also applies its own message limit.
    static func mailbox(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard result.utf8.count <= 320, result.range(of:#"^[^\s<>@,;]+@[^\s<>@,;]+$"#,options:.regularExpression) != nil else { throw NativeDBError.message("メールアドレスを1件入力してください。") }
        return result
    }
    static func bodyURL(root: URL, id: String) throws -> URL {
        guard UUID(uuidString:id) != nil else { throw NativeDBError.message("送信処理の識別子が不正です。") }
        return root.appendingPathComponent("mail-outbox",isDirectory:true).appendingPathComponent(id.lowercased()+".json")
    }
    /// Plain notifications need no PDF/HTML machinery. Keep only one small encoded
    /// chunk in memory, even when an approval note is long or escape-heavy.
    static func prepareText(root: URL, id: String, from: String, to: String, subject: String, message: String) throws -> InvoiceMailBody {
        let from = try mailbox(from); let to = try mailbox(to)
        guard !subject.isEmpty, !subject.contains("\r"), !subject.contains("\n"), subject.utf8.count <= 998 else { throw NativeDBError.message("件名は改行なし・998バイト以内で入力してください。") }
        guard message.utf8.count <= maximumBytes else { throw NativeDBError.message("メール本文が大きすぎます。") }
        let url = try bodyURL(root:root,id:id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor = Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw NativeDBError.message("送信用ファイルを作成できません。") }
        let output = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true); var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at:url) } }
        var hash = SHA256(); var written = 0
        func write(_ data: Data) throws {
            guard written+data.count <= maximumBytes else { throw NativeDBError.message("メールが40 MBを超えています。") }
            try output.write(contentsOf:data); hash.update(data:data); written += data.count
        }
        var metadata = try JSONSerialization.data(withJSONObject:["from":from,"to":[to],"subject":subject],options:[.sortedKeys,.withoutEscapingSlashes]); metadata.removeLast()
        try write(metadata); try write(Data(",\"text\":\"".utf8))
        var buffer = Data(); buffer.reserveCapacity(64*1024+6); let hex = Array("0123456789abcdef".utf8)
        for byte in message.utf8 {
            switch byte {
            case 34,92: buffer.append(92); buffer.append(byte)
            case 0...31: buffer.append(contentsOf:[92,117,48,48,hex[Int(byte)/16],hex[Int(byte)%16]])
            default: buffer.append(byte)
            }
            if buffer.count >= 64*1024 { try write(buffer); buffer.removeAll(keepingCapacity:true) }
        }
        try write(buffer); try write(Data("\"}".utf8)); try output.synchronize(); complete = true
        return InvoiceMailBody(url:url,bytes:written,sha256:hash.finalize().map { String(format:"%02x",$0) }.joined())
    }
    /// Multi-recipient notifications stream a frozen recipient snapshot.
    static func prepareTextRecipients(root: URL, id: String, from: String, subject: String, message: String, recipients: (_ emit: (String) throws -> Void) throws -> Void) throws -> InvoiceMailBody {
        let from = try mailbox(from)
        guard !subject.isEmpty, !subject.contains("\r"), !subject.contains("\n"), subject.utf8.count <= 998 else { throw NativeDBError.message("件名は改行なし・998バイト以内で入力してください。") }
        guard message.utf8.count <= maximumBytes else { throw NativeDBError.message("メール本文が大きすぎます。") }
        let url = try bodyURL(root:root,id:id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor = Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw NativeDBError.message("送信用ファイルを作成できません。") }
        let output = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true); var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at:url) } }
        var hash = SHA256(); var written = 0
        func write(_ data: Data) throws {
            guard written+data.count <= maximumBytes else { throw NativeDBError.message("メールが40 MBを超えています。") }
            try output.write(contentsOf:data); hash.update(data:data); written += data.count
        }
        var metadata = try JSONSerialization.data(withJSONObject:["from":from,"subject":subject],options:[.sortedKeys,.withoutEscapingSlashes]); metadata.removeLast()
        try write(metadata); try write(Data(",\"to\":[".utf8))
        var count = 0
        try recipients { raw in
            let to = try mailbox(raw)
            if count > 0 { try write(Data(",".utf8)) }
            try write(JSONEncoder().encode(to)); count += 1
        }
        guard count > 0 else { throw NativeDBError.message("通知先がありません。") }
        try write(Data("],\"text\":\"".utf8))
        var buffer = Data(); buffer.reserveCapacity(64*1024+6); let hex = Array("0123456789abcdef".utf8)
        for byte in message.utf8 {
            switch byte {
            case 34,92: buffer.append(92); buffer.append(byte)
            case 0...31: buffer.append(contentsOf:[92,117,48,48,hex[Int(byte)/16],hex[Int(byte)%16]])
            default: buffer.append(byte)
            }
            if buffer.count >= 64*1024 { try write(buffer); buffer.removeAll(keepingCapacity:true) }
        }
        try write(buffer); try write(Data("\"}".utf8)); try output.synchronize(); complete = true
        return InvoiceMailBody(url:url,bytes:written,sha256:hash.finalize().map { String(format:"%02x",$0) }.joined())
    }
    /// Only a multiple-of-three PDF chunk and its Base64 encoding are live at a
    /// time. The immutable JSON file is reused byte-for-byte on every retry.
    static func prepare(root: URL, id: String, from: String, to: String, subject: String, message: String, number: String, pdf: URL) throws -> InvoiceMailBody {
        let from = try mailbox(from); let to = try mailbox(to)
        guard !subject.contains("\r"), !subject.contains("\n"), !subject.isEmpty, subject.utf8.count <= 998 else { throw NativeDBError.message("件名は改行なし・998バイト以内で入力してください。") }
        guard message.utf8.count <= maximumBytes else { throw NativeDBError.message("メール本文が大きすぎます。") }
        let attributes = try pdf.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let size = attributes.fileSize, size > 0, size <= maximumBytes/4*3 else { throw NativeDBError.message("添付PDFが見つからないか、送信可能なサイズを超えています。") }
        var metadata = try JSONSerialization.data(withJSONObject:["from":from,"to":[to],"subject":subject],options:[.sortedKeys,.withoutEscapingSlashes])
        metadata.removeLast()
        let safeNumber = number.replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"\\",with:"_").replacingOccurrences(of:"\r",with:"_").replacingOccurrences(of:"\n",with:"_")
        let filename = String(decoding:try JSONSerialization.data(withJSONObject:"invoice-"+safeNumber+".pdf",options:.fragmentsAllowed),as:UTF8.self)
        let prefix = Data(",\"attachments\":[{\"filename\":\(filename),\"content\":\"".utf8)
        let suffix = Data("\"}]}".utf8)
        let url = try bodyURL(root:root,id:id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor = Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw NativeDBError.message("送信用ファイルを作成できません。") }
        let output = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true); var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at:url) } }
        var hash = SHA256(); var written = 0
        func write(_ bytes: Data) throws { guard written+bytes.count <= maximumBytes else { throw NativeDBError.message("メールが40 MBを超えています。") }; try output.write(contentsOf:bytes); hash.update(data:bytes); written += bytes.count }
        // Encode HTML and JSON together, without building successive copies of
        // a large message. Non-ASCII UTF-8 bytes pass through unchanged.
        func escaped(_ value: String, html: Bool = false, lineBreaks: Bool = false) throws {
            var buffer = Data(); buffer.reserveCapacity(64*1024+16)
            let hex = Array("0123456789abcdef".utf8)
            for byte in value.utf8 {
                switch byte {
                case 38 where html: buffer.append(contentsOf:"&amp;".utf8)
                case 60 where html: buffer.append(contentsOf:"&lt;".utf8)
                case 62 where html: buffer.append(contentsOf:"&gt;".utf8)
                case 39 where html: buffer.append(contentsOf:"&#39;".utf8)
                case 34: buffer.append(contentsOf:(html ? "&quot;" : "\\\"").utf8)
                case 92: buffer.append(contentsOf:"\\\\".utf8)
                case 10: buffer.append(contentsOf:(lineBreaks ? "<br>\\n" : "\\n").utf8)
                case 13: buffer.append(contentsOf:"\\r".utf8)
                case 9: buffer.append(contentsOf:"\\t".utf8)
                case 0...31: buffer.append(contentsOf:[92,117,48,48,hex[Int(byte)/16],hex[Int(byte)%16]])
                default: buffer.append(byte)
                }
                if buffer.count >= 64*1024 { try write(buffer); buffer.removeAll(keepingCapacity:true) }
            }
            if !buffer.isEmpty { try write(buffer) }
        }
        try write(metadata); try write(Data(",\"html\":\"".utf8))
        try escaped("<!doctype html><html lang=\"ja\"><body style=\"font-family:sans-serif\"><h1>請求書 ")
        try escaped(number,html:true); try escaped("</h1><p>")
        try escaped(message,html:true,lineBreaks:true)
        try escaped("</p><hr><p>このメールの送信元：NextCRM</p></body></html>")
        try write(Data("\"".utf8))
        guard written+prefix.count+((size+2)/3*4)+suffix.count <= maximumBytes else { throw NativeDBError.message("添付を含めたメールが40 MBを超えています。") }
        try write(prefix)
        let input = try FileHandle(forReadingFrom:pdf); defer { try? input.close() }
        var carry = Data(); var read = 0
        while let bytes = try input.read(upToCount:48*1024), !bytes.isEmpty {
            try autoreleasepool {
                read += bytes.count; carry.append(bytes)
                let end = carry.count/3*3
                if end > 0 { try write(carry.prefix(end).base64EncodedData()); carry = Data(carry.dropFirst(end)) }
            }
        }
        guard read == size else { throw NativeDBError.message("添付PDFが変更されました。開き直して送信してください。") }
        if !carry.isEmpty { try write(carry.base64EncodedData()) }
        try write(suffix); try output.synchronize(); complete = true
        return InvoiceMailBody(url:url,bytes:written,sha256:hash.finalize().map { String(format:"%02x",$0) }.joined())
    }
    static func verify(_ url: URL, sha256: String, bytes: Int) throws {
        let attrs = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, attrs.fileSize == bytes, bytes > 0, bytes <= maximumBytes else { throw NativeDBError.message("保存したメールが見つからないか、変更されています。") }
        let input = try FileHandle(forReadingFrom:url); defer { try? input.close() }; var hash = SHA256()
        while let chunk = try input.read(upToCount:64*1024), !chunk.isEmpty { hash.update(data:chunk) }
        guard hash.finalize().map({ String(format:"%02x",$0) }).joined() == sha256 else { throw NativeDBError.message("保存したメールが変更されています。") }
    }
}

struct MailSendError: LocalizedError {
    let message: String; let retryable: Bool; let review: Bool; var retryAfter: TimeInterval? = nil
    var errorDescription: String? { message }
}

private final class MailNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ResendMailClient {
    typealias Request = (URLRequest, URL) async throws -> (Data, HTTPURLResponse)
    static func request(_ request: URLRequest, body: URL) async throws -> (Data,HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration:configuration,delegate:MailNoRedirects(),delegateQueue:nil)
        defer { session.finishTasksAndInvalidate() }
        let (data,response) = try await session.upload(for:request,fromFile:body)
        guard let response = response as? HTTPURLResponse else { throw MailSendError(message:"送信サービスの応答を確認できませんでした。",retryable:true,review:false) }
        return (data,response)
    }
    static func envelope(jobID: String, apiKey: String, scope: String) throws -> URLRequest {
        guard ["invoice","order","project","crm-task","campaign","report","lead","plugin","crm-automation","identity"].contains(scope), UUID(uuidString:jobID) != nil else { throw NativeDBError.message("メールの送信IDが不正です。") }
        guard !apiKey.isEmpty, !apiKey.contains("\r"), !apiKey.contains("\n") else { throw MailSendError(message:"送信サービスのAPIキーを設定してください。",retryable:false,review:false) }
        var query = URLRequest(url:URL(string:"https://api.resend.com/emails")!)
        query.httpMethod = "POST"; query.setValue("Bearer "+apiKey,forHTTPHeaderField:"Authorization")
        query.setValue("application/json",forHTTPHeaderField:"Content-Type")
        query.setValue(scope == "campaign" ? "campaign-send/"+jobID : "nextcrm/"+scope+"/"+jobID,forHTTPHeaderField:"Idempotency-Key")
        return query
    }
    static func receipt(data: Data, response: HTTPURLResponse) throws -> String {
        guard data.count <= 64*1024 else { throw MailSendError(message:"送信サービスの応答が不正です。",retryable:true,review:false) }
        let json = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        if (200..<300).contains(response.statusCode) {
            guard let id = json?["id"] as? String, UUID(uuidString:id) != nil else { throw MailSendError(message:"送信結果の識別子を確認できませんでした。",retryable:true,review:false) }
            return id
        }
        let kind = json?["name"] as? String ?? ""
        if response.statusCode == 409 && kind == "invalid_idempotent_request" { throw MailSendError(message:"同じ送信IDで異なる内容が検出されました。送信結果を確認してください。",retryable:false,review:true) }
        let retry = response.statusCode == 429 || response.statusCode == 408 || response.statusCode >= 500 || (response.statusCode == 409 && kind == "concurrent_idempotent_requests")
        let message: String
        switch response.statusCode {
        case 401,403: message = "送信サービスのAPIキー・権限・送信元ドメインの設定を確認してください。"
        case 429: message = "送信サービスの利用制限に達しました。時間をおいて再試行します。"
        case 413: message = "添付を含めたメールが送信可能なサイズを超えています。"
        default: message = retry ? "送信サービスが処理を完了できませんでした。再試行します。" : "送信サービスがメールを受け付けませんでした。宛先・件名・送信元の設定を確認してください。"
        }
        let delay = response.value(forHTTPHeaderField:"Retry-After").flatMap(Double.init).map { min(max($0,1),3600) }
        throw MailSendError(message:message,retryable:retry,review:false,retryAfter:delay)
    }
    static func send(body: URL, jobID: String, apiKey: String, scope: String = "invoice", request: Request = request) async throws -> String {
        let query = try envelope(jobID:jobID,apiKey:apiKey,scope:scope)
        let data: Data; let response: HTTPURLResponse
        do { (data,response) = try await request(query,body) }
        catch let error as MailSendError { throw error }
        catch { throw MailSendError(message:"通信が完了しませんでした。同じ送信内容で再試行します。",retryable:true,review:false) }
        return try receipt(data:data,response:response)
    }
}


extension NativeDatabase {
    /// Only the immutable payload of a committed terminal mail job is eligible.
    /// Register this inside the transaction which changes the job; a nested
    /// savepoint can still be rolled back by its caller. Unknown/non-mail jobs
    /// and delivery-uncertain cancellations retain their files.
    func deferTerminalMailBodyCleanup(id: String) throws {
        guard !isReadOnly else { throw NativeDBError.message("読み取り専用のデータでは送信本文を削除できません。") }
        try transaction {
            let events = ["invoice.email_requested", "orders.approval_requested", "orders.approval_decided",
                          "projects.task_assigned", "projects.task_updated", "projects.task_commented",
                          "crm.task_assigned", "crm.task_watched", "crm.lead_assigned",
                          "campaigns/send-step", "reports.scheduled", "crm.automation.kill.notice", "crm.automation.recycle.notice"]
            guard let expected = try job(id:id), events.contains(expected.event),
                  expected.status == "done" || (expected.status == "cancelled" && expected.deliveryStartedAt == nil),
                  let file = try? InvoiceMail.bodyURL(root:url.deletingLastPathComponent(),id:id) else { return }
            deferUntilTransactionEnds(onCommit: { [self] in
                // BEGIN IMMEDIATE serializes the final row check with writers.
                // A changed/replaced row is not the operation being cleaned up.
                try? transaction {
                    guard let current = try job(id:id), current == expected else { return }
                    try? FileManager.default.removeItem(at:file)
                }
            }, onRollback: {})
        }
    }
}
