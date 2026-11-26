import Foundation
import Security
import CryptoKit

/// The only identity accepted by the session is a cryptographically verified ID token.
struct NativeChatGPTIdentity: Codable, Equatable {
    let issuer: String, subject: String, clientID: String
    let email: String?, emailVerified: Bool
    static func verify(_ jwt: String, jwks: Data, clientID: String, nonce: String?, accessToken: String?, now: Date) throws -> Self {
        let failure = NativeChatGPTError.invalid("ChatGPTの本人確認を検証できません。接続し直してください。")
        guard jwt.utf8.count <= 65_536, jwks.count <= NativeChatGPTOAuth.maximumBytes else { throw failure }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let header = try JSONSerialization.jsonObject(with: NativeChatGPTOAuth.decode64(parts[0])) as? [String: Any],
              let payload = try JSONSerialization.jsonObject(with: NativeChatGPTOAuth.decode64(parts[1])) as? [String: Any],
              let kid = header["kid"] as? String, !kid.isEmpty, kid.utf8.count <= 256,
              let alg = header["alg"] as? String, ["RS256", "ES256"].contains(alg), header["crit"] == nil, header["jku"] == nil, header["x5u"] == nil,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = set["keys"] as? [[String: Any]], keys.count <= 100 else { throw failure }
        let matches = keys.filter { ($0["kid"] as? String).map { NativeChatGPTOAuth.exact($0, kid) } == true }
        guard matches.count == 1 else { throw failure }; let jwk = matches[0]
        guard jwk["use"] == nil || jwk["use"] as? String == "sig", jwk["alg"] == nil || jwk["alg"] as? String == alg,
              jwk["key_ops"] == nil || (jwk["key_ops"] as? [String])?.contains("verify") == true else { throw failure }
        let signature = try NativeChatGPTOAuth.decode64(parts[2]); let message = Data((parts[0]+"."+parts[1]).utf8)
        let keyData: Data, keyType: CFString, algorithm: SecKeyAlgorithm, signed: Data
        if alg == "RS256" {
            guard jwk["kty"] as? String == "RSA", let n = jwk["n"] as? String, let e = jwk["e"] as? String else { throw failure }
            let modulus = try NativeChatGPTOAuth.decode64(n), exponent = try NativeChatGPTOAuth.decode64(e)
            guard (256...1024).contains(modulus.count), (1...8).contains(exponent.count), signature.count == modulus.count else { throw failure }
            keyData = der(0x30, integer(modulus)+integer(exponent)); keyType = kSecAttrKeyTypeRSA; algorithm = .rsaSignatureMessagePKCS1v15SHA256; signed = signature
        } else {
            guard jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256", let x = jwk["x"] as? String, let y = jwk["y"] as? String else { throw failure }
            let xb = try NativeChatGPTOAuth.decode64(x), yb = try NativeChatGPTOAuth.decode64(y)
            guard xb.count == 32, yb.count == 32, signature.count == 64 else { throw failure }
            keyData = Data([4])+xb+yb; keyType = kSecAttrKeyTypeECSECPrimeRandom; algorithm = .ecdsaSignatureMessageX962SHA256
            signed = der(0x30, integer(Data(signature.prefix(32)))+integer(Data(signature.suffix(32))))
        }
        guard let key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: keyType, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil), SecKeyIsAlgorithmSupported(key, .verify, algorithm), SecKeyVerifySignature(key, algorithm, message as CFData, signed as CFData, nil) else { throw failure }
        guard let issuer = payload["iss"] as? String, NativeChatGPTOAuth.exact(issuer, NativeChatGPTOAuth.issuer), let sub = payload["sub"] as? String, !sub.isEmpty, sub.utf8.count <= 1024 else { throw failure }
        let audiences = (payload["aud"] as? [String]) ?? (payload["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(where: { NativeChatGPTOAuth.exact($0, clientID) }), !audiences.isEmpty, audiences.count <= 16 else { throw failure }
        if audiences.count > 1 || payload["azp"] != nil { guard let azp = payload["azp"] as? String, NativeChatGPTOAuth.exact(azp, clientID) else { throw failure } }
        func numeric(_ field: String) -> Double? { guard let number = payload[field] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }; return number.doubleValue }
        guard let exp = numeric("exp"), let iat = numeric("iat"), exp > now.timeIntervalSince1970-5, iat <= now.timeIntervalSince1970+5, exp > iat else { throw failure }
        if payload["nbf"] != nil { guard let nbf = numeric("nbf"), nbf <= now.timeIntervalSince1970+5 else { throw failure } }
        if let nonce { guard let returned = payload["nonce"] as? String, NativeChatGPTOAuth.exact(nonce, returned) else { throw failure } }
        if let atHash = payload["at_hash"] as? String {
            guard let accessToken, NativeChatGPTOAuth.exact(atHash, NativeChatGPTOAuth.base64(Data(SHA256.hash(data: Data(accessToken.utf8)).prefix(16)))) else { throw failure }
        }
        let rawEmail = payload["email"] as? String
        let email = rawEmail.flatMap { !$0.isEmpty && $0.utf8.count <= 320 && !$0.contains(where: { $0.isNewline }) ? $0 : nil }
        let verified = (payload["email_verified"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        return .init(issuer: issuer, subject: sub, clientID: clientID, email: email, emailVerified: verified)
    }
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count; var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] }
        else { while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }; bytes.insert(0x80|UInt8(bytes.count), at: 0) }
        return Data([tag]+bytes)+data
    }
    private static func integer(_ input: Data) -> Data {
        var data = Data(input.drop(while: { $0 == 0 })); if data.isEmpty { data = Data([0]) }
        if data[0] & 0x80 != 0 { data.insert(0, at: 0) }; return der(2, data)
    }
}
