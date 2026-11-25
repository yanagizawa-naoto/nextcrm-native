import Foundation
import CryptoKit

struct NativeAIError: LocalizedError {
    let message: String
    var retryable = false
    var status: Int? = nil
    var errorDescription: String? { message }
}

/// pgvector stores float32 components. The native representation is exactly
/// 1536 little-endian float32 values, without JSON or a resident vector server.
struct NativeEmbeddingVector {
    static let model = "text-embedding-3-small"
    static let dimensions = 1536
    let values: [Float]
    private let norm: Double

    init(_ values: [Float]) throws {
        guard values.count == Self.dimensions, values.allSatisfy({ $0.isFinite }) else {
            throw NativeAIError(message: "AI検索データの次元または数値が不正です。")
        }
        let squared = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squared > 0, squared.isFinite else { throw NativeAIError(message: "AI検索データが空です。") }
        self.values = values; norm = squared.squareRoot()
    }
    init(bytes: Data) throws {
        guard bytes.count == Self.dimensions * 4 else { throw NativeAIError(message: "AI検索データの長さが不正です。") }
        let values = bytes.withUnsafeBytes { raw in
            (0..<Self.dimensions).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        try self.init(values)
    }
    var bytes: Data {
        var data = Data(capacity: Self.dimensions * 4)
        for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        return data
    }
    func similarity(to other: Self) -> Double {
        var dot = 0.0
        for index in values.indices { dot += Double(values[index]) * Double(other.values[index]) }
        return max(-1, min(1, dot / (norm * other.norm)))
    }
    /// Match buildEmbeddingText: omit empty fields, preserve retained spelling
    /// and whitespace, then use one ASCII space between fields.
    static func text(_ fields: [String?]) -> String {
        fields.compactMap { $0 }.filter { !isBlank($0) }.joined(separator: " ")
    }
    // ECMAScript String.trim whitespace differs from Foundation (FEFF/0085).
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            switch $0.value {
            case 9...13, 32, 160, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct NativeEmbeddingHit: Equatable {
    let id: String
    let similarity: Double
}

/// The retained result set is bounded by k, even when multiple document chunks
/// match one document. Scores are exact cosine similarity, not an approximation.
struct NativeEmbeddingTopK {
    let limit: Int
    private(set) var hits: [NativeEmbeddingHit] = []
    init(limit: Int) throws {
        guard (1...100).contains(limit) else { throw NativeAIError(message: "検索件数が不正です。") }
        self.limit = limit
    }
    mutating func consider(id: String, similarity: Double) {
        guard similarity.isFinite else { return }
        if let index = hits.firstIndex(where: { $0.id == id }) {
            guard similarity > hits[index].similarity else { return }; hits.remove(at: index)
        }
        let hit = NativeEmbeddingHit(id: id, similarity: similarity)
        let index = hits.firstIndex { similarity > $0.similarity || (similarity == $0.similarity && id < $0.id) } ?? hits.endIndex
        if index < limit { hits.insert(hit, at: index); if hits.count > limit { hits.removeLast() } }
    }
}
