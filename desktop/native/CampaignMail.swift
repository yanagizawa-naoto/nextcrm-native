import Foundation
import CryptoKit
import Darwin

struct CampaignMailConfiguration: Equatable {
    let publicURL: URL
    let appName: String
    init(publicURL: String, appName: String = "NextCRM", allowLoopbackHTTP: Bool = false) throws {
        guard var parts = URLComponents(string:publicURL), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme == "https" || (allowLoopbackHTTP && parts.scheme == "http" && ["127.0.0.1","localhost","[::1]","::1"].contains(host)),
              !parts.path.split(separator:"/").contains("..") else { throw NativeDBError.message("配信停止ページの公開HTTPS URLを設定してください。") }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw NativeDBError.message("公開URLが不正です。") }
        self.publicURL = url; self.appName = appName
    }
    func unsubscribeURL(token: String) throws -> URL {
        guard UUID(uuidString:token) != nil,
              var parts = URLComponents(url:publicURL.appendingPathComponent("api/campaigns/unsubscribe"),resolvingAgainstBaseURL:false) else { throw NativeDBError.message("配信停止の識別子が不正です。") }
        parts.queryItems = [URLQueryItem(name:"token",value:token)]
        guard let url = parts.url else { throw NativeDBError.message("配信停止URLが不正です。") }; return url
    }
}

enum CampaignMail {
    struct Prepared { let body: InvoiceMailBody; let from: String; let to: String; let subject: String; let replyTo: String; let unsubscribeURL: URL }
    static func sender(address: String, name: String) throws -> String {
        let address = try InvoiceMail.mailbox(address)
        guard !name.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}), name.utf8.count <= 800 else { throw NativeDBError.message("差出人名は制御文字なし・800バイト以内で入力してください。") }
        guard !name.isEmpty else { return address }
        return "\""+name.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\" <"+address+">"
    }
    /// One exclusive immutable file per send. HTML and JSON are escaped in
    /// bounded chunks and hashed as written; no DOM or full rendered body copy.
    static func prepare(root: URL, id: String, address: String, fromName: String, to: String, subject: String, html: String, replyTo: String, token: String, target: [String:String], configuration: CampaignMailConfiguration) throws -> Prepared {
        let from = try sender(address:address,name:fromName), to = try InvoiceMail.mailbox(to)
        let reply = try replyTo.isEmpty ? "" : InvoiceMail.mailbox(replyTo)
        let subject = try CampaignMergeTags.resolveBounded(subject,target:target,maximumBytes:998)
        guard !subject.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, subject.utf8.count <= 998,
              !subject.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw NativeDBError.message("件名は制御文字なし・998バイト以内で入力してください。") }
        guard html.utf8.count <= CampaignHTML.maximumInputBytes else { throw NativeDBError.message("メール本文が40 MBを超えています。") }
        let unsubscribe = try configuration.unsubscribeURL(token:token)
        var metadata: [String:Any] = ["from":from,"to":[to],"subject":subject,"headers":["List-Unsubscribe":"<"+unsubscribe.absoluteString+">"]]
        if !reply.isEmpty { metadata["reply_to"] = reply }
        let url = try InvoiceMail.bodyURL(root:root,id:id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor = Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw NativeDBError.message("送信用ファイルを作成できません。") }
        let output = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true); var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at:url) } }
        var hash = SHA256(); var written = 0; var buffer = Data(); buffer.reserveCapacity(64*1024+6)
        let digits = Array("0123456789abcdef".utf8)
        func write(_ data: Data) throws {
            guard written+data.count <= InvoiceMail.maximumBytes else { throw NativeDBError.message("メールが40 MBを超えています。") }
            try output.write(contentsOf:data); hash.update(data:data); written += data.count
        }
        func escaped(_ value: String) throws {
            for byte in value.utf8 {
                switch byte {
                case 34,92: buffer.append(92); buffer.append(byte)
                case 0...31: buffer.append(contentsOf:[92,117,48,48,digits[Int(byte)/16],digits[Int(byte)%16]])
                default: buffer.append(byte)
                }
                if buffer.count >= 64*1024 { try write(buffer); buffer.removeAll(keepingCapacity:true) }
            }
        }
        var header = try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys,.withoutEscapingSlashes]); header.removeLast()
        try write(header); try write(Data(",\"html\":\"".utf8))
        try CampaignHTML.render(CampaignMergeTags.resolveBounded(html,target:target,escaped:true,maximumBytes:CampaignHTML.maximumInputBytes),unsubscribeURL:unsubscribe,appName:configuration.appName,emit:escaped)
        try write(buffer); try write(Data("\"}".utf8)); try output.synchronize(); complete = true
        return Prepared(body:InvoiceMailBody(url:url,bytes:written,sha256:hash.finalize().map{String(format:"%02x",$0)}.joined()),from:from,to:to,subject:subject,replyTo:reply,unsubscribeURL:unsubscribe)
    }
}
