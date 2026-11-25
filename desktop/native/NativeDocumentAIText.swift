import Foundation
import CryptoKit

/// A UTF-16 cursor matches JS slice/length and survives process restarts.
/// Only one extraction page and one embedding window are retained at a time.
struct NativeDocumentAICursor: Codable, Equatable {
    var part = 0, offset = 0
}
struct NativeDocumentAIWindow {
    let text: String, next: NativeDocumentAICursor, final: Bool
}
struct NativeDocumentAIText {
    static let singleLimit = 32_000, windowSize = 2048, overlap = 200
    typealias Page = (_ part: Int) throws -> (text: String, parts: Int)
    let page: Page
    init(page: @escaping Page) { self.page = page }
    init(db: NativeDatabase, documentID: String) {
        page = { part in let value = try db.documentTextPage(documentID, part: part); return (value.text, value.parts) }
    }
    /// UTF-8 replacement of isolated surrogate halves follows Node's UTF-8
    /// encoding of JS slices; overlapping windows retain the complete scalar.
    static func prefix(_ value: String, units: Int) -> String { String(decoding: value.utf16.prefix(units), as: UTF16.self) }
    func window(from start: NativeDocumentAICursor, limit: Int, overlap: Int = 0) throws -> NativeDocumentAIWindow {
        guard start.part >= 0, start.offset >= 0, limit > 0, limit <= Self.singleLimit + 1, overlap >= 0, overlap < limit else { throw NativeAIError(message: "文書の読み取り位置が不正です。") }
        var cursor = start, units: [UInt16] = [], next = start
        units.reserveCapacity(limit)
        var final = false, keptBoundary = false
        while units.count < limit {
            try Task.checkCancellation()
            let part = try page(cursor.part), contents = Array(part.text.utf16)
            guard part.parts >= 0, cursor.part <= part.parts, cursor.offset <= contents.count else { throw NativeDBError.conflict }
            if cursor.part == part.parts { guard cursor.offset == 0 else { throw NativeDBError.conflict }; final = true; break }
            let count = min(limit - units.count, contents.count - cursor.offset)
            let boundary = limit - overlap
            if !keptBoundary, units.count + count >= boundary {
                next = NativeDocumentAICursor(part: cursor.part, offset: cursor.offset + boundary - units.count); keptBoundary = true
            }
            units.append(contentsOf: contents[cursor.offset..<cursor.offset + count]); cursor.offset += count
            if cursor.offset == contents.count { cursor.part += 1; cursor.offset = 0 }
            if cursor.part == part.parts { final = true; break }
        }
        if final || overlap == 0 { next = cursor }
        return NativeDocumentAIWindow(text: String(decoding: units, as: UTF16.self), next: next, final: final)
    }
    func inspect(validate: () throws -> Void = {}) throws -> (utf16Count: Int, hash: String) {
        var part = 0, total = 0, digest = SHA256()
        while true {
            try Task.checkCancellation(); try validate()
            let done = try autoreleasepool { () -> Bool in
                let value = try page(part)
                guard part <= value.parts else { throw NativeDBError.conflict }
                if part == value.parts { return true }
                let count = value.text.utf16.count
                guard total <= Int.max - count else { throw NativeAIError(message: "文書が大きすぎます。") }
                total += count; digest.update(data: Data(value.text.utf8)); part += 1
                return part == value.parts
            }
            if done { break }
        }
        return (total, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
