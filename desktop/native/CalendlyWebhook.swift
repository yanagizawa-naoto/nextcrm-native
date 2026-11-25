import Foundation
import CryptoKit

enum CalendlyWebhookError: LocalizedError {
    case invalidSignature, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidSignature:return "Calendlyからの通知の署名を確認できません。"
        case .tooLarge:return "Calendlyからの通知が大きすぎます。"
        }
    }
}

/// Verify at the time the public receiver accepted the original bytes. A Mac
/// resuming days later must obtain that time through an authenticated relay.
/// Calling this normalizer alone does not expose an HTTP receiver or trust a
/// client-supplied receipt time.
enum CalendlyWebhook {
    static let tolerance: TimeInterval = 180
    static func verify(_ body: Data,signature: String?,key: String,receivedAt: Date) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 16_384,
              let signature, signature.utf8.count <= 8192, receivedAt.timeIntervalSince1970.isFinite else { return false }
        var parts: [String:String] = [:]
        for field in signature.split(separator:",",omittingEmptySubsequences:false) {
            let pair = field.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            if pair.count == 2 { parts[String(pair[0])] = String(pair[1]) }
        }
        guard let timestamp = parts["t"], let seconds = Double(timestamp), seconds.isFinite,
              abs(receivedAt.timeIntervalSince1970-seconds) <= tolerance,
              let encoded = parts["v1"], encoded.range(of:#"^[a-f0-9]{64}$"#,options:.regularExpression) != nil else { return false }
        let chars = Array(encoded.utf8); var code = Data(); code.reserveCapacity(32)
        func digit(_ value: UInt8) -> UInt8 { value <= 57 ? value-48 : value-87 }
        for index in stride(from:0,to:chars.count,by:2) { code.append(digit(chars[index])*16+digit(chars[index+1])) }
        var signed = Data((timestamp+".").utf8); signed.append(body)
        return HMAC<SHA256>.isValidAuthenticationCode(code,authenticating:signed,using:SymmetricKey(data:Data(key.utf8)))
    }
    static func receive(_ body: Data,signature: String?,key: String,receivedAt: Date) throws -> NativeCalendarNormalized {
        guard verify(body,signature:signature,key:key,receivedAt:receivedAt) else { throw CalendlyWebhookError.invalidSignature }
        return try normalizeAuthenticatedRelayBody(body)
    }
    /// Only call after the receiver response signature, pinned identity, client
    /// binding, cursor and body digest were validated. The receiver already
    /// verified Calendly's signature before durably accepting the original bytes.
    static func normalizeAuthenticatedRelayBody(_ body: Data) throws -> NativeCalendarNormalized {
        guard let object = try? JSONSerialization.jsonObject(with:body), let envelope = object as? [String:Any] else { return .skipped("malformed-json") }
        guard let kind = envelope["event"] as? String, ["invitee.created","invitee.canceled"].contains(kind) else { return .skipped("unsupported-event") }
        guard let payload = envelope["payload"] as? [String:Any], let event = payload["scheduled_event"] as? [String:Any],
              let uri = payload["uri"] as? String, !uri.isEmpty, let start = event["start_time"] as? String, !start.isEmpty else { return .skipped("missing-uri-or-start") }
        let email = payload["email"] as? String, host = (event["event_memberships"] as? [[String:Any]])?.first?["user_email"] as? String
        return .event(.init(source:.calendly,externalID:uri,title:event["name"] as? String ?? "Calendlyの面談",startAt:try NativeCalendarEvents.date(start),endAt:try (event["end_time"] as? String).map(NativeCalendarEvents.date),counterpartyEmails:email.flatMap{$0.isEmpty ? nil : [$0]} ?? [],hostEmail:host,status:kind == "invitee.canceled" ? .cancelled : .scheduled,rawPayload:try NativeCalendarEvents.json(envelope)))
    }
}
