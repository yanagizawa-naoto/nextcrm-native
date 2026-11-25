import Foundation

enum CampaignMergeTags {
    static let fields = ["first_name","last_name","email","company","position"]
    static func htmlEscape(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&#39;") }
    static func resolve(_ source: String, target: [String:String], escaped: Bool = false) -> String {
        let pattern = try! NSRegularExpression(pattern:#"\{\{([A-Za-z0-9_]+)\}\}"#)
        let original = source as NSString; let out = NSMutableString(string:source)
        for match in pattern.matches(in:source,range:NSRange(location:0,length:original.length)).reversed() {
            let key = original.substring(with:match.range(at:1)); guard fields.contains(key) else { continue }
            let value = target[key] ?? ""; out.replaceCharacters(in:match.range,with:escaped ? htmlEscape(value) : value)
        }
        return out as String
    }
    /// Delivery has a strict output cap. Scan the original text once and bound
    /// expansions as they are appended, avoiding an array of every regex match
    /// or a huge intermediate string when a merge value occurs many times.
    static func resolveBounded(_ source: String, target: [String:String], escaped: Bool = false, maximumBytes: Int) throws -> String {
        guard maximumBytes >= 0, source.utf8.count <= maximumBytes else { throw NativeDBError.message("差し込み後のメールが送信可能なサイズを超えています。") }
        if !source.contains("{{") { return source }
        let bytes = source.utf8; var index = bytes.startIndex; var output = Data(); output.reserveCapacity(min(maximumBytes,64*1024))
        func append(_ byte: UInt8) throws {
            guard output.count < maximumBytes else { throw NativeDBError.message("差し込み後のメールが送信可能なサイズを超えています。") }; output.append(byte)
        }
        func appendValue(_ value: String) throws {
            for byte in value.utf8 {
                let entity: String?
                if escaped { switch byte { case 38: entity = "&amp;"; case 60: entity = "&lt;"; case 62: entity = "&gt;"; case 34: entity = "&quot;"; case 39: entity = "&#39;"; default: entity = nil } } else { entity = nil }
                if let entity { for b in entity.utf8 { try append(b) } } else { try append(byte) }
            }
        }
        while index < bytes.endIndex {
            let byte = bytes[index], next = bytes.index(after:index)
            if byte == 123, next < bytes.endIndex, bytes[next] == 123 {
                var end = bytes.index(after:next); let start = end; var count = 0
                while end < bytes.endIndex, count <= 10 {
                    let b = bytes[end]
                    guard (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || b == 95 else { break }
                    end = bytes.index(after:end); count += 1
                }
                if count > 0 && count <= 10, end < bytes.endIndex, bytes[end] == 125 {
                    let close = bytes.index(after:end)
                    if close < bytes.endIndex, bytes[close] == 125 {
                        let key = String(decoding:bytes[start..<end],as:UTF8.self)
                        if fields.contains(key) { try appendValue(target[key] ?? ""); index = bytes.index(after:close); continue }
                    }
                }
            }
            try append(byte); index = next
        }
        return String(decoding:output,as:UTF8.self)
    }
}
