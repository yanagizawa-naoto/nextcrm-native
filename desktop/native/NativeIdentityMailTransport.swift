import Foundation
import CryptoKit

private final class NativeIdentityMailNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Identity messages stay in memory. Ordinary large business attachments retain
/// their existing streamed-file transport and its response/idempotency policy.
enum NativeIdentityMailTransport {
    typealias Request = (URLRequest, Data) async throws -> (Data, HTTPURLResponse)
    static func network(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: NativeIdentityMailNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw MailSendError(message: "送信サービスの応答を確認できませんでした。", retryable: true, review: false) }
        return (data, http)
    }
    static func make(apiKey: String, request: @escaping Request = network) throws -> NativeIdentityMailWorker.Transport {
        _ = try ResendMailClient.envelope(jobID: UUID().uuidString.lowercased(), apiKey: apiKey, scope: "identity")
        let identity = SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(identity: identity, send: { body, id in
            let query = try ResendMailClient.envelope(jobID: id, apiKey: apiKey, scope: "identity")
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await request(query, body) }
            catch let error as MailSendError { throw error }
            catch { throw MailSendError(message: "認証メールの通信が完了しませんでした。", retryable: true, review: false) }
            return try ResendMailClient.receipt(data: data, response: response)
        })
    }
}
