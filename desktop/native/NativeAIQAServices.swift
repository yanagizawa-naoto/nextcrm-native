import Foundation

/// Used only after the app's existing isolated QA-directory validation.
/// Synthetic credentials never touch Keychain or an external provider.
final class NativeAIQAServices: NativeAISecretStore {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func load(id: String, interactive: Bool) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(id: String, data: Data) throws { lock.lock(); defer { lock.unlock() }; guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data }
    func remove(id: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
    static func generate(_ text: String, _ key: String) async throws -> NativeEmbeddingVector {
        try Task.checkCancellation()
        if key.hasPrefix("qa-reject") { throw NativeAIError(message: "検証用APIキーの拒否を再現しました。") }
        var values = [Float](repeating: 0, count: NativeEmbeddingVector.dimensions)
        values[0] = 1
        return try NativeEmbeddingVector(values)
    }
    static func summarize(_ text: String, _ key: String) async throws -> String? {
        try Task.checkCancellation(); return "検証用の文書要約です。本文の内容を確認しました。"
    }
    static func classify(_ name: String, _ summary: String?, _ text: String, _ key: String) async throws -> String {
        try Task.checkCancellation(); return "CONTRACT"
    }
}
