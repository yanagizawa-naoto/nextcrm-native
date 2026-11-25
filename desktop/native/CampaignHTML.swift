import Foundation

/// Streaming, allowlisted HTML output; macOS libxml2 supplies only SAX events.
/// User markup never becomes a web view, executable script, or external entity.
enum CampaignHTML {
    static let maximumInputBytes = 40_000_000
    static let tags: Set<String> = ["p","h1","h2","h3","h4","h5","h6","strong","b","em","i","u","s","strike","code","pre","ul","ol","li","blockquote","hr","br","a","img","div","span","table","thead","tbody","tr","td","th"]
    private static let discardedText: Set<String> = ["script","style","textarea","option","xmp"]
    private static let voidTags: Set<String> = ["br","hr","img"]
    private static let universal: Set<String> = ["style","align","width","height"]
    private static let tagAttributes: [String:Set<String>] = ["a":["href","target","rel"],"img":["src","alt"]]
    private struct Frame { let tag: String; let emitted: Bool; let suppressed: Bool }
    private final class Stream {
        var stack: [Frame] = []; var attribute = ""; var error: Error?; var syntheticStarts = 3
        let emit: (String) throws -> Void
        init(_ emit: @escaping (String) throws -> Void) { self.emit = emit }
        func event(_ kind: Int32,_ value: String) throws {
            switch kind {
            case 1:
                guard stack.count < 128 else { throw NativeDBError.message("メール本文の入れ子が深すぎます。") }
                let tag = value.lowercased(), suppressed = stack.last?.suppressed == true || discardedText.contains(tag)
                let emitted = syntheticStarts == 0 && !suppressed && tags.contains(tag)
                syntheticStarts = max(0,syntheticStarts-1)
                stack.append(Frame(tag:tag,emitted:emitted,suppressed:suppressed)); if emitted { try emit("<"+tag) }
            case 2: attribute = value.lowercased()
            case 3:
                guard let frame = stack.last, frame.emitted, universal.contains(attribute) || tagAttributes[frame.tag]?.contains(attribute) == true else { return }
                if ["href","src"].contains(attribute), !safeURL(value) { return }
                let v: String
                if attribute == "style" { guard let style = style(value) else { return }; v = style } else { v = value }
                try emit(" "+attribute+"=\""); try emit(CampaignMergeTags.htmlEscape(v)); try emit("\"")
            case 4: if stack.last?.emitted == true { try emit(">") }
            case 5: if stack.last?.suppressed != true { try emit(CampaignMergeTags.htmlEscape(value)) }
            case 6:
                guard let frame = stack.popLast(), frame.tag == value.lowercased() else { throw NativeDBError.message("メール本文の構造を確認できません。") }
                if frame.emitted && !voidTags.contains(frame.tag) { try emit("</"+frame.tag+">") }
            default: break
            }
        }
    }
    static func safeURL(_ input: String) -> Bool {
        var value = String(String.UnicodeScalarView(input.unicodeScalars.filter{$0.value > 32}))
        while let start = value.range(of:"<!--"), let end = value.range(of:"-->",range:start.upperBound..<value.endIndex) { value.removeSubrange(start.lowerBound..<end.upperBound) }
        guard let scheme = value.range(of:#"^[A-Za-z][A-Za-z0-9.\-+]*:"#,options:.regularExpression) else { return true }
        return ["http","https","mailto"].contains(String(value[scheme].dropLast()).lowercased())
    }
    /// Keep inline declarations (including quoted delimiters and function args).
    /// Invalid CSS drops the attribute, like the original PostCSS-backed filter.
    /// Legacy executable CSS is additionally rejected rather than carried into
    /// old mail clients that might interpret it.
    static func style(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of:#"/\*[\s\S]*?\*/"#,with:"",options:.regularExpression)
        if value.contains("/*") { return nil }
        let lower = decodedCSS(value).lowercased().filter { !$0.isWhitespace }
        if lower.contains("expression"), lower.range(of:#"expression\s*\("#,options:.regularExpression) != nil { return nil }
        if lower.contains("javascript:") || lower.contains("vbscript:") || lower.contains("-moz-binding") || lower.contains("behavior:") { return nil }
        var quote: Character?; var escaped = false; var nesting = 0; var part = ""; var parts: [String] = []
        for ch in value {
            if escaped { part.append(ch); escaped = false; continue }
            if ch == "\\" { part.append(ch); escaped = true; continue }
            if let q = quote { part.append(ch); if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; part.append(ch); continue }
            if ch == "{" || ch == "}" { return nil }
            if ch == "(" || ch == "[" { nesting += 1 }
            if ch == ")" || ch == "]" { nesting -= 1; if nesting < 0 { return nil } }
            if ch == ";", nesting == 0 { parts.append(part); part = "" } else { part.append(ch) }
        }
        guard quote == nil, !escaped, nesting == 0 else { return nil }; parts.append(part)
        var declarations: [String] = []
        for part in parts {
            let item = part.trimmingCharacters(in:.whitespacesAndNewlines); if item.isEmpty { continue }
            guard let colon = item.firstIndex(of:":") else { return nil }
            let property = item[..<colon].trimmingCharacters(in:.whitespacesAndNewlines), content = item[item.index(after:colon)...].trimmingCharacters(in:.whitespacesAndNewlines)
            guard property.range(of:#"^(?:--)?[A-Za-z_\-][A-Za-z0-9_\-]*$"#,options:.regularExpression) != nil, !content.isEmpty else { return nil }
            declarations.append(property+":"+content)
        }
        value = declarations.joined(separator:";"); return value.isEmpty ? nil : value
    }
    private static func decodedCSS(_ value: String) -> String {
        let scalars = value.unicodeScalars; var index = scalars.startIndex; var output = String.UnicodeScalarView()
        while index < scalars.endIndex {
            let scalar = scalars[index]; index = scalars.index(after:index)
            guard scalar.value == 92, index < scalars.endIndex else { output.append(scalar); continue }
            var number: UInt32 = 0; var count = 0
            while index < scalars.endIndex, count < 6, let digit = hex(scalars[index].value) {
                number = number * 16 + digit; count += 1; index = scalars.index(after:index)
            }
            if count > 0 {
                output.append(UnicodeScalar(number == 0 ? 0xfffd : number) ?? "\u{fffd}")
                if index < scalars.endIndex, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) { index = scalars.index(after:index) }
            } else {
                let next = scalars[index]; index = scalars.index(after:index)
                if next.value != 10 && next.value != 13 && next.value != 12 { output.append(next) }
            }
        }
        return String(output)
    }
    private static func hex(_ value: UInt32) -> UInt32? {
        if value >= 48 && value <= 57 { return value - 48 }
        if value >= 65 && value <= 70 { return value - 55 }
        if value >= 97 && value <= 102 { return value - 87 }
        return nil
    }
    /// Translate HTML5 references to numeric references understood by the OS
    /// HTML parser. This is a single pass: escaped ampersands never get decoded
    /// twice, and the input is not duplicated into an expanded full-size string.
    private static func normalizedInput(_ html: String, emit: (UInt8) throws -> Void) throws {
        let bytes = html.utf8; var index = bytes.startIndex; var inTag = false; var quote: UInt8?
        func alpha(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
        func alnum(_ b: UInt8) -> Bool { alpha(b) || (48...57).contains(b) }
        func append(_ text: String) throws { for byte in text.utf8 { try emit(byte) } }
        while index < bytes.endIndex {
            let byte = bytes[index], next = bytes.index(after:index)
            if !inTag, byte == 60 {
                var nameEnd = next
                if nameEnd < bytes.endIndex, bytes[nameEnd] == 47 { nameEnd = bytes.index(after:nameEnd) }
                let nameStart = nameEnd
                while nameEnd < bytes.endIndex, alnum(bytes[nameEnd]) || bytes[nameEnd] == 45 { nameEnd = bytes.index(after:nameEnd) }
                let name = String(decoding:bytes[nameStart..<nameEnd],as:UTF8.self).lowercased()
                // Document tags have no content semantics in the source
                // sanitizer. Never let them close the synthetic fragment root.
                if ["html","body","head","nextcrm-fragment-root"].contains(name), nameEnd == bytes.endIndex || [9,10,12,13,32,47,62].contains(bytes[nameEnd]) {
                    var end = nameEnd; var tagQuote: UInt8?
                    while end < bytes.endIndex {
                        let b = bytes[end]; end = bytes.index(after:end)
                        if let q = tagQuote { if b == q { tagQuote = nil } }
                        else if b == 34 || b == 39 { tagQuote = b }
                        else if b == 62 { break }
                    }
                    index = end; continue
                }
            }
            if byte == 38, next < bytes.endIndex {
                if bytes[next] == 35 {
                    var end = bytes.index(after:next); var base: UInt32 = 10
                    if end < bytes.endIndex, bytes[end] == 120 || bytes[end] == 88 { base = 16; end = bytes.index(after:end) }
                    var value: UInt32 = 0; var count = 0
                    while end < bytes.endIndex, let digit = hex(UInt32(bytes[end])), digit < base {
                        // Saturate invalid references instead of overflowing.
                        value = value > 0x10ffff ? 0x110000 : value * base + digit
                        end = bytes.index(after:end); count += 1
                    }
                    if count > 0 {
                        if end < bytes.endIndex, bytes[end] == 59 { end = bytes.index(after:end) }
                        let windows: [UInt32] = [0x20ac,0x81,0x201a,0x192,0x201e,0x2026,0x2020,0x2021,0x2c6,0x2030,0x160,0x2039,0x152,0x8d,0x17d,0x8f,0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x2dc,0x2122,0x161,0x203a,0x153,0x9d,0x17e,0x178]
                        if value >= 0x80 && value <= 0x9f { value = windows[Int(value-0x80)] }
                        if value == 0 || value > 0x10ffff || (0xd800...0xdfff).contains(value) { value = 0xfffd }
                        try append("&#x"+String(value,radix:16)+";"); index = end; continue
                    }
                } else {
                    var candidate: [UInt8] = []; var end = next
                    while end < bytes.endIndex, candidate.count < 48, alnum(bytes[end]) {
                        candidate.append(bytes[end]); end = bytes.index(after:end)
                    }
                    if end < bytes.endIndex, bytes[end] == 59 { candidate.append(59) }
                    var matched = false
                    for length in stride(from:candidate.count,through:1,by:-1) {
                        guard let numeric = candidate.withUnsafeBufferPointer({nextcrm_html_entity($0.baseAddress,length)}) else { continue }
                        let after = bytes.index(next,offsetBy:length)
                        if inTag, candidate[length-1] != 59, after < bytes.endIndex, alnum(bytes[after]) || bytes[after] == 61 { break }
                        try append(String(cString:numeric)); index = after; matched = true; break
                    }
                    if matched { continue }
                }
            }
            if inTag {
                if let current = quote { if byte == current { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { inTag = false }
            } else if byte == 60 {
                var valid = next < bytes.endIndex && (alpha(bytes[next]) || bytes[next] == 33 || bytes[next] == 63)
                if next < bytes.endIndex, bytes[next] == 47 {
                    let after = bytes.index(after:next); valid = after < bytes.endIndex && alpha(bytes[after])
                }
                if !valid { try append("&#60;"); index = next; continue }
                inTag = true
            }
            try emit(byte); index = next
        }
    }
    static func sanitize(_ html: String, emit: @escaping (String) throws -> Void) throws {
        guard html.utf8.count <= maximumInputBytes else { throw NativeDBError.message("メール本文が40 MBを超えています。") }
        let stream = Stream(emit), context = Unmanaged.passUnretained(stream).toOpaque()
        guard let parser = nextcrm_html_create(context,{ context,kind,bytes,count in
            guard let context else { return 0 }; let stream = Unmanaged<Stream>.fromOpaque(context).takeUnretainedValue()
            do { let value = bytes.map{String(decoding:UnsafeRawBufferPointer(start:$0,count:count),as:UTF8.self)} ?? ""; try stream.event(kind,value); return 1 }
            catch { stream.error = error; return 0 }
        }) else { throw NativeDBError.message("メール本文を解析できません。") }
        defer { nextcrm_html_destroy(parser) }
        var buffer = [UInt8](); buffer.reserveCapacity(64*1024)
        func feed(_ final: Bool) throws {
            let result = buffer.withUnsafeBufferPointer{nextcrm_html_feed(parser,$0.baseAddress,$0.count,final ? 1 : 0)}
            if let error = stream.error { throw error }
            guard result == 0 else { throw NativeDBError.message("メール本文の文字コードまたは構造が不正です。") }
            buffer.removeAll(keepingCapacity:true)
        }
        // A fragment container avoids implied paragraphs around plain text and
        // keeps all siblings; NOIMPLIED alone can silently stop at root one.
        buffer.append(contentsOf:"<html><body><nextcrm-fragment-root>".utf8); try feed(false)
        try normalizedInput(html) { byte in buffer.append(byte); if buffer.count >= 64*1024 { try feed(false) } }
        buffer.append(contentsOf:"</nextcrm-fragment-root></body></html>".utf8)
        try feed(true)
        guard stream.stack.isEmpty else { throw NativeDBError.message("メール本文を最後まで読み取れません。") }
    }
    static let contentStyles = """
      .campaign-content p { margin: 0 0 16px; font-size: 14px; line-height: 24px; color: #1f2937; }
      .campaign-content h1 { margin: 24px 0 16px; font-size: 24px; line-height: 32px; color: #111827; }
      .campaign-content h2 { margin: 24px 0 12px; font-size: 20px; line-height: 28px; color: #111827; }
      .campaign-content h3 { margin: 20px 0 12px; font-size: 16px; line-height: 24px; color: #111827; }
      .campaign-content a { color: #2563eb; text-decoration: underline; }
      .campaign-content ul, .campaign-content ol { margin: 0 0 16px; padding-left: 24px; font-size: 14px; line-height: 24px; color: #1f2937; }
      .campaign-content blockquote { margin: 0 0 16px; padding-left: 16px; border-left: 3px solid #e5e7eb; color: #4b5563; }
      .campaign-content hr { border: none; border-top: 1px solid #e5e7eb; margin: 24px 0; }
    """
    static func render(_ html: String, unsubscribeURL: URL, appName: String = "NextCRM", emit: @escaping (String) throws -> Void) throws {
        try emit("<!doctype html><html lang=\"ja\"><head><meta charset=\"utf-8\"><style>"+contentStyles+"</style></head><body style=\"background-color:#f4f4f5;margin:0;font-family:Arial,sans-serif\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td align=\"center\"><table role=\"presentation\" width=\"600\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:#ffffff;border:1px solid #e2e8f0;border-radius:6px;margin:40px auto;max-width:600px;width:100%\"><tr><td style=\"padding:32px\"><div class=\"campaign-content\">")
        try sanitize(html,emit:emit)
        try emit("</div><hr style=\"border:0;border-top:1px solid #eaeaea;margin:26px 0\"><p style=\"color:#64748b;font-size:12px;line-height:20px\">このメールの送信元：<strong>"+CampaignMergeTags.htmlEscape(appName)+"</strong>。 <a href=\""+CampaignMergeTags.htmlEscape(unsubscribeURL.absoluteString)+"\" style=\"color:#64748b;text-decoration:underline\">配信停止</a></p></td></tr></table></td></tr></table></body></html>")
    }
}
