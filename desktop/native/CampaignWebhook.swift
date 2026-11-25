import Foundation
import CryptoKit

/// Resend/Svix verification operates on the exact HTTP bytes, before decoding.
/// Contract: https://docs.svix.com/receiving/verifying-payloads/how-manual
enum CampaignWebhook {
    static let maximumBodyBytes = 1_048_576
    static let supportedEvents: Set<String> = ["email.delivered","email.bounced","email.opened","email.clicked"]
    static func header(_ name: String, in headers: [String:String]) -> String? {
        let matches = headers.filter{$0.key.lowercased() == name}
        return matches.count == 1 ? matches.first?.value : nil
    }
    static func verify(body: Data, headers: [String:String], secret: String, now: Date = Date()) -> Bool {
        guard body.count <= maximumBodyBytes, !secret.isEmpty, secret.utf8.count <= 2048,
              let id = header("svix-id",in:headers), !id.isEmpty, id.utf8.count <= 255,
              id.utf8.allSatisfy({$0 >= 33 && $0 <= 126}),
              let timestamp = header("svix-timestamp",in:headers), !timestamp.isEmpty, timestamp.utf8.count <= 12,
              timestamp.utf8.allSatisfy({(48...57).contains($0)}), let seconds = Int64(timestamp),
              now.timeIntervalSince1970.isFinite, abs(floor(now.timeIntervalSince1970)-Double(seconds)) <= 300,
              let signature = header("svix-signature",in:headers), signature.utf8.count <= 4096 else { return false }
        var encoded = secret.hasPrefix("whsec_") ? String(secret.dropFirst(6)) : secret
        guard encoded.utf8.count % 4 != 1 else { return false }
        encoded += String(repeating:"=",count:(4-encoded.utf8.count%4)%4)
        guard let key = Data(base64Encoded:encoded), !key.isEmpty else { return false }
        var signed = Data((id+"."+timestamp+".").utf8); signed.append(body)
        let symmetric = SymmetricKey(data:key)
        for item in signature.split(separator:" ") {
            let pair = item.split(separator:",",maxSplits:1,omittingEmptySubsequences:false)
            guard pair.count == 2, pair[0] == "v1", let bytes = Data(base64Encoded:String(pair[1])), bytes.count == 32 else { continue }
            // CryptoKit provides the constant-time MAC comparison.
            if HMAC<SHA256>.isValidAuthenticationCode(bytes,authenticating:signed,using:symmetric) { return true }
        }
        return false
    }
    struct Event: Decodable {
        struct Payload: Decodable { let email_id: String?; let message_id: String? }
        let type: String
        let data: Payload?
        var providerID: String? { data?.email_id ?? data?.message_id }
    }
    /// Authenticated but unrelated event types have no side effects. A compact
    /// durable inbox retains relevant early events until acceptance is saved.
    static func receive(db: NativeDatabase, body: Data, headers: [String:String], secret: String, now: Date = Date()) throws -> String {
        guard verify(body:body,headers:headers,secret:secret,now:now), let id = header("svix-id",in:headers) else { throw Failure.unauthorized }
        guard let event = try? JSONDecoder().decode(Event.self,from:body) else { throw Failure.invalid }
        guard supportedEvents.contains(event.type), let providerID = event.providerID, !providerID.isEmpty else { return "ignored" }
        guard providerID.utf8.count <= 512, !providerID.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw Failure.invalid }
        let digest = SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()
        return try db.receiveCampaignEvent(id:id,providerID:providerID,kind:event.type,bodySHA256:digest,now:now)
    }
    enum Failure: Error { case unauthorized, invalid }
}
