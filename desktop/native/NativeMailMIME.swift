import Foundation
import CoreFoundation
import Darwin

struct NativeMailAddress: Codable, Equatable {
    let email: String
    var name: String? = nil
    static func checked(_ email: String) throws -> NativeMailAddress {
        let value = email.trimmingCharacters(in:.whitespaces)
        _ = try transport(value)
        return NativeMailAddress(email:value)
    }
    private static var invalid: NativeMailFailure { .invalid("メールアドレスを確認してください。表示名は「名前 <address@example.com>」の形式で入力できます。") }
    private static let atomASCII = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~.".unicodeScalars)
    /// Keep the spelling used by the sender for display/storage. Convert only
    /// the DNS part for SMTP, using the system IDNA implementation (no runtime).
    var transportAddress: String { get throws { try Self.transport(email) } }
    private static func transport(_ value:String) throws -> String {
        guard value.utf8.count <= 1024, !value.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}), let at = value.lastIndex(of:"@") else { throw invalid }
        let local = String(value[..<at]), domain = String(value[value.index(after:at)...])
        guard !local.isEmpty, local.utf8.count <= 64, !domain.isEmpty else { throw invalid }
        if local.first == "\"" {
            guard local.count >= 2, local.last == "\"" else { throw invalid }
            var escaped = false
            for c in local.dropFirst().dropLast() {
                if escaped { escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if c == "\"" { throw invalid }
            }
            guard !escaped else { throw invalid }
        } else {
            guard !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."), local.unicodeScalars.allSatisfy({ atomASCII.contains($0) || ($0.value >= 128 && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)) }) else { throw invalid }
        }
        let host:String
        if domain.hasPrefix("[") && domain.hasSuffix("]") {
            let literal = String(domain.dropFirst().dropLast()); var v4 = in_addr(), v6 = in6_addr()
            if literal.lowercased().hasPrefix("ipv6:"), inet_pton(AF_INET6,String(literal.dropFirst(5)),&v6) == 1 { host = "[IPv6:"+String(literal.dropFirst(5))+"]" }
            else if inet_pton(AF_INET,literal,&v4) == 1 { host = domain }
            else { throw invalid }
        } else {
            guard !domain.unicodeScalars.contains(where:{ CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || "@:/\\?#%[]<>\";,()".unicodeScalars.contains($0) }) else { throw invalid }
            // Most mailboxes have an ASCII domain. Avoid allocating a URL/IDNA
            // conversion for each one in a large recipient list.
            guard let converted = domain.utf8.allSatisfy({$0 < 128}) ? domain : URL(string:"https://"+domain)?.host, converted.utf8.count <= 253 else { throw invalid }
            let labels = converted.split(separator:".",omittingEmptySubsequences:false)
            guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) }) else { throw invalid }
            host = converted.lowercased()
        }
        let result = local+"@"+host
        guard result.utf8.count <= 254 else { throw invalid }; return result
    }
    /// A single pass respects quoted commas, nested comments, groups, and
    /// address literals. Sending fails the whole list on an invalid token;
    /// reading an incoming header can retain its other valid mailboxes.
    static func list(_ sources:[String], strict:Bool = true) throws -> [NativeMailAddress] {
        guard !strict || sources.reduce(0,{$0+$1.utf8.count}) <= NativeMailMIME.maximumHeaderBytes else { throw NativeMailFailure.tooLarge }
        var result:[NativeMailAddress] = []
        for source in sources {
            guard !source.unicodeScalars.contains(where:{$0.value < 32 && $0.value != 9 || $0.value == 127}) else { if strict { throw invalid }; continue }
            var buffer = "", commentText = "", quoted = false, escaped = false, comment = 0, angle = false, literal = false, group = false
            func emit() throws {
                let token = buffer.trimmingCharacters(in:.whitespaces), fallback = commentText.trimmingCharacters(in:.whitespaces)
                defer { buffer = ""; commentText = "" }
                guard !token.isEmpty else { return }
                do {
                    var quote = false, escape = false, left:String.Index?, right:String.Index?
                    for i in token.indices {
                        let c = token[i]
                        if escape { escape = false; continue }
                        if quote && c == "\\" { escape = true; continue }
                        if c == "\"" { quote.toggle(); continue }
                        if !quote && c == "<" { guard left == nil else { throw invalid }; left = i }
                        if !quote && c == ">" { guard left != nil && right == nil else { throw invalid }; right = i }
                    }
                    guard !quote && !escape else { throw invalid }
                    var address:NativeMailAddress
                    if let left, let right {
                        guard left < right, token[token.index(after:right)...].trimmingCharacters(in:.whitespaces).isEmpty else { throw invalid }
                        address = try checked(String(token[token.index(after:left)..<right]))
                        var name = "", escape = false, quote = false
                        for c in token[..<left] {
                            if escape { name.append(c); escape = false }
                            else if quote && c == "\\" { escape = true }
                            else if c == "\"" { quote.toggle() }
                            else { name.append(c) }
                        }
                        name = NativeMailMIME.decodedWords(name.trimmingCharacters(in:.whitespaces))
                        address.name = name.isEmpty ? nil : name
                    } else {
                        guard left == nil && right == nil else { throw invalid }; address = try checked(token)
                    }
                    if address.name == nil && !fallback.isEmpty { address.name = NativeMailMIME.decodedWords(fallback) }
                    // The total header byte bound limits allocation. Do not
                    // silently truncate otherwise valid recipients by count.
                    result.append(address)
                } catch { if strict { throw error } }
            }
            for c in source {
                if escaped { if comment > 0 { commentText.append(c) } else { buffer.append(c) }; escaped = false; continue }
                if c == "\\" && (quoted || comment > 0) { if comment == 0 { buffer.append(c) }; escaped = true; continue }
                if comment > 0 {
                    if c == "(" { comment += 1; guard comment <= 16 else { throw NativeMailFailure.tooLarge }; commentText.append(" ") }
                    else if c == ")" { comment -= 1; commentText.append(" ") }
                    else { commentText.append(c) }; continue
                }
                if c == "\"" { quoted.toggle(); buffer.append(c); continue }
                if !quoted {
                    if c == "(" { comment = 1; buffer.append(" "); continue }
                    if c == "[" { literal = true }; if c == "]" { literal = false }
                    if c == "<" { angle = true }; if c == ">" { angle = false }
                    if !angle && !literal {
                        if c == ":" && !buffer.contains("@") { guard !group else { throw invalid }; group = true; buffer = ""; commentText = ""; continue }
                        if c == "," || c == ";" { try emit(); if c == ";" { group = false }; continue }
                    }
                }
                buffer.append(c)
            }
            if quoted || escaped || comment != 0 || angle || literal || group { if strict { throw invalid } }
            else { try emit() }
        }
        return result
    }
    func header() throws -> String {
        let address = try transportAddress
        guard let name, !name.isEmpty else { return address }
        guard name.utf8.count <= 4096, !name.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw NativeMailFailure.invalid("宛先の表示名は、改行や制御文字を含めず4096バイト以内で入力してください。") }
        let encoded = try NativeMailMIME.encodedHeader(name)
        let phrase = encoded.hasPrefix("=?UTF-8?B?") ? encoded : "\""+encoded.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""
        return phrase+" <"+address+">"
    }
}

extension NativeMailMIME {
    /// A cursor yields one child at a time. Only active ancestor boundaries
    /// are retained; there is no recursive Swift call or all-child array.
    private struct IncomingCursor {
        let payload:Data,marker:Data,alternative:Bool
        var cursor:Int,start:Int?=nil,closed=false
        mutating func next()throws->Data? {
            while !closed && cursor<payload.endIndex {
                try Task.checkCancellation()
                let end=payload[cursor...].firstIndex(of:10).map{$0+1} ?? payload.endIndex
                var lineEnd=end;while lineEnd>cursor && [10,13,32,9].contains(payload[lineEnd-1]){lineEnd -= 1}
                let line=payload[cursor..<lineEnd],closing=line==marker+Data("--".utf8)
                if line==marker || closing {
                    let begin=start;start=closing ? nil:end;closed=closing
                    var partEnd=cursor;cursor=end
                    if let begin {
                        if partEnd>begin && payload[partEnd-1]==10{partEnd -= 1};if partEnd>begin && payload[partEnd-1]==13{partEnd -= 1}
                        return payload[begin..<partEnd]
                    }
                }else{cursor=end}
            }
            if !closed,let start,start<payload.endIndex{closed=true;return payload[start..<payload.endIndex]}
            return nil
        }
    }
    private static func incomingBody(_ data:Data,deriveHTMLText:((String)throws->String)?,derivePlainHTML:((String)throws->String)?,temporaryRoot:URL)throws->NativeMailBody {
        let parts=try NativeMailMIMESpool(temporaryRoot:temporaryRoot);var stack:[IncomingCursor]=[]
        func visit(_ bytes:Data,alternative:Bool,root:Bool)throws {
            try Task.checkCancellation()
            let emptyHead:Range<Int>?=bytes.starts(with:[13,10]) ? bytes.startIndex..<bytes.startIndex+2 : bytes.starts(with:[10]) ? bytes.startIndex..<bytes.startIndex+1:nil
            guard let divider=emptyHead ?? bytes.range(of:Data("\r\n\r\n".utf8)) ?? bytes.range(of:Data("\n\n".utf8)) else{return}
            guard divider.upperBound-bytes.startIndex <= maximumIncomingHeaderBytes else{throw NativeMailFailure.tooLarge}
            let head=try headers(bytes[bytes.startIndex..<divider.lowerBound],allowLargeIncoming:true),payload=bytes[divider.upperBound..<bytes.endIndex]
            let kind=parameters(head["content-type"]),disposition=parameters(head["content-disposition"])
            let cid=head["content-id"].trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"<>"))
            if !cid.isEmpty,kind.type.range(of:"^image/[a-z0-9_]+$",options:.regularExpression) != nil {
                try parts.appendImage(cid:cid,type:kind.type,encoding:head["content-transfer-encoding"],payload:payload);return
            }
            if disposition.type=="attachment"{return}
            if kind.type.hasPrefix("multipart/") {
                guard let boundary=kind.values["boundary"],!boundary.isEmpty,!boundary.utf8.contains(where:{$0<32 || $0==127}) else{throw NativeMailFailure.malformed}
                stack.append(.init(payload:payload,marker:Data(("--"+boundary).utf8),alternative:alternative || kind.type=="multipart/alternative",cursor:payload.startIndex));return
            }
            guard ["","text/plain","text/html","message/delivery-status"].contains(kind.type) else{return}
            let decoded=try decodePayload(payload,head["content-transfer-encoding"],recover:true),charset=kind.values["charset"] ?? "utf-8"
            guard var value=["utf-8","utf8"].contains(charset.lowercased()) ? String(decoding:decoded,as:UTF8.self) : text(decoded,charset:charset) else{throw NativeMailFailure.malformed}
            value=value.replacingOccurrences(of:"\r\n",with:"\n");value.makeContiguousUTF8()
            try parts.append(.init(text:value,html:kind.type=="text/html",root:root,alternative:alternative))
        }
        try visit(data,alternative:false,root:true)
        while !stack.isEmpty {
            let index=stack.count-1
            if let child=try stack[index].next(){let alternative=stack[index].alternative;try autoreleasepool{try visit(child,alternative:alternative,root:false)}}
            else{stack.removeLast()}
        }
        try parts.finish()
        var plain:String?,html:String?
        func append(_ value:String,to output:inout String?,separator:String){if output==nil{output=value}else{output! += separator+value}}
        try parts.forEach { part in
            if part.html {
                if let deriveHTMLText,(!part.alternative && parts.hasPlain) || (part.root && !parts.hasPlain) {append(try deriveHTMLText(part.text),to:&plain,separator:"\n")}
                append(part.text,to:&html,separator:"<br/>\n")
            }else{
                append(part.text,to:&plain,separator:"\n")
                if !part.alternative,parts.hasHTML,let derivePlainHTML{append(try derivePlainHTML(part.text),to:&html,separator:"<br/>\n")}
            }
        }
        if let original=html {
            let regex=try NSRegularExpression(pattern:"\\bcid:([^'\"\\s]+)"),source=original as NSString
            var end=0,expanded="",failure:Error?
            regex.enumerateMatches(in:original,range:NSRange(location:0,length:source.length)){match,_,stop in
                do {
                    guard let match,let url=try parts.imageURL(cid:source.substring(with:match.range(at:1)),decode:{try decodePayload($0,$1,recover:true)}) else{return}
                    expanded += source.substring(with:NSRange(location:end,length:match.range.location-end))+url;end=NSMaxRange(match.range)
                }catch{failure=error;stop.pointee=true}
            }
            if let failure{throw failure};if end>0{expanded += source.substring(from:end);html=expanded}
        }
        return NativeMailBody(text:plain,html:html)
    }
}
struct NativeMailHeaders {
    var fields: [String:[String]]
    subscript(_ key: String) -> String { fields[key.lowercased()]?.joined(separator:", ") ?? "" }
    var messageID: String? {
        guard let value = fields["message-id"]?.first?.trimmingCharacters(in:.whitespaces), value.utf8.count <= 998, !value.isEmpty else { return nil }
        return value
    }
    var subject: String { NativeMailMIME.decodedWords(self["subject"]) }
    var sentAt: Date? {
        let raw = self["date"].replacingOccurrences(of:"\\([^)]*\\)",with:"",options:.regularExpression).trimmingCharacters(in:.whitespaces)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z","d MMM yyyy HH:mm:ss Z","EEE, d MMM yyyy HH:mm Z","d MMM yyyy HH:mm Z","EEE, d MMM yy HH:mm:ss Z"] {
            formatter.dateFormat = format; if let date = formatter.date(from:raw) { return date }
        }
        return nil
    }
}
struct NativeMailBody { var text: String?; var html: String? }

enum NativeMailMIME {
    static let maximumIncomingHeaderBytes = 1_048_576 // installed @zone-eu/mailsplit default, including separator
    static let maximumHeaderBytes = 262_144
    static let maximumMessageBytes = 33_554_432
    static let maximumTextBytes = 8_388_608
    static let maximumEnvelopeBytes = 1_048_576
    static func headers(_ data: Data,allowLargeIncoming:Bool=false) throws -> NativeMailHeaders {
        guard data.count <= (allowLargeIncoming ? maximumIncomingHeaderBytes:maximumHeaderBytes) else { throw NativeMailFailure.tooLarge }
        guard !data.contains(0) else { throw NativeMailFailure.malformed }
        let source = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\r\n",with:"\n")
        var fields:[String:[String]] = [:], key: String? = nil
        for line in source.components(separatedBy:"\n") {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                guard let key, let count = fields[key]?.count, count > 0 else { throw NativeMailFailure.malformed }
                fields[key]![count-1] += " "+line.trimmingCharacters(in:.whitespaces); continue
            }
            guard let colon = line.firstIndex(of:":") else { throw NativeMailFailure.malformed }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 58 }) else { throw NativeMailFailure.malformed }
            key = name; fields[name,default:[]].append(String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces))
        }
        return NativeMailHeaders(fields:fields)
    }
    private static func text(_ data: Data,charset: String) -> String? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if encoding != kCFStringEncodingInvalidId, let value = String(data:data,encoding:String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(encoding))) { return value }
        return String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1)
    }
    static func quotedPrintable(_ data: Data,header: Bool = false) throws -> Data {
        var result = Data(); result.reserveCapacity(data.count); var i = data.startIndex
        func hex(_ c: UInt8) -> UInt8? { if (48...57).contains(c) { return c-48 }; if (65...70).contains(c) { return c-55 }; if (97...102).contains(c) { return c-87 }; return nil }
        while i < data.endIndex {
            let c = data[i]; i += 1
            if header && c == 95 { result.append(32); continue }
            if c != 61 { result.append(c); continue }
            if i < data.endIndex && data[i] == 10 { i += 1; continue }
            if i+1 < data.endIndex && data[i] == 13 && data[i+1] == 10 { i += 2; continue }
            guard i+1 < data.endIndex, let high = hex(data[i]), let low = hex(data[i+1]) else { throw NativeMailFailure.malformed }
            result.append(high*16+low); i += 2
        }
        return result
    }
    static func decodedWords(_ source: String) -> String {
        let regex = try! NSRegularExpression(pattern:"=\\?([^?\\s]+)\\?([bBqQ])\\?([^?]*)\\?=")
        let ns = source as NSString, matches = regex.matches(in:source,range:NSRange(location:0,length:ns.length))
        // Decode adjacent same-charset/same-encoding words as one byte stream.
        // Upstream mailparser/libmime does this before charset conversion: real
        // mail sometimes splits one UTF-8 character across encoded words.
        // Each transfer token must still decode; malformed words remain visible.
        func key(_ charset: String) -> String {
            let normalized = charset.lowercased().replacingOccurrences(of:"_",with:"-")
            let encoding = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
            return encoding == kCFStringEncodingInvalidId ? normalized : "iana:\(encoding)"
        }
        func token(_ match: NSTextCheckingResult) -> (charset:String, kind:String, bytes:Data?) {
            let charset = ns.substring(with:match.range(at:1)), kind = ns.substring(with:match.range(at:2)).lowercased()
            let encoded = ns.substring(with:match.range(at:3))
            return (charset,kind,kind == "b" ? Data(base64Encoded:encoded) : try? quotedPrintable(Data(encoded.utf8),header:true))
        }
        var result = "", end = 0, previousEncoded = false, index = 0
        while index < matches.count {
            let match = matches[index], first = token(matches[index])
            let gap = ns.substring(with:NSRange(location:end,length:match.range.location-end))
            var lastEnd = NSMaxRange(match.range), nextIndex = index+1, bytes = first.bytes
            if bytes != nil {
                let charsetKey = key(first.charset)
                while nextIndex < matches.count {
                    let next = matches[nextIndex], nextToken = token(next)
                    let between = ns.substring(with:NSRange(location:lastEnd,length:next.range.location-lastEnd))
                    guard between.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                          nextToken.kind == first.kind, key(nextToken.charset) == charsetKey,
                          let nextBytes = nextToken.bytes else { break }
                    bytes!.append(nextBytes); lastEnd = NSMaxRange(next.range); nextIndex += 1
                }
            }
            let value = bytes.flatMap { text($0,charset:first.charset) }
            if !(previousEncoded && value != nil && gap.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) { result += gap }
            result += value ?? ns.substring(with:NSRange(location:match.range.location,length:lastEnd-match.range.location))
            previousEncoded = value != nil; end = lastEnd; index = nextIndex
        }
        result += ns.substring(from:end); return result
    }
    static func addresses(_ source: String) -> [NativeMailAddress] {
        let parsed = (try? NativeMailAddress.list([source],strict:false)) ?? []
        return parsed.map { address in
            // Incoming mailparser decodes a leading lower-case A-label before
            // storing addresses and linking CRM records. Composer spelling and
            // the SMTP envelope remain governed by NativeMailAddress instead.
            guard address.email.contains("@xn--"), let at = address.email.lastIndex(of:"@") else { return address }
            let domain = String(address.email[address.email.index(after:at)...])
                .replacingOccurrences(of:"\u{3002}",with:".")
                .replacingOccurrences(of:"\u{FF0E}",with:".")
                .replacingOccurrences(of:"\u{FF61}",with:".")
            var labels = domain.components(separatedBy:".")
            for index in labels.indices where labels[index].hasPrefix("xn--") {
                // Decode each A-label separately so Foundation's host case
                // folding does not alter the other, untouched domain labels.
                guard let host = URLComponents(string:"https://"+labels[index]+".invalid")?.host,
                      host.hasSuffix(".invalid") else { return address }
                labels[index] = String(host.dropLast(".invalid".count))
            }
            return NativeMailAddress(email:String(address.email[...at])+labels.joined(separator:"."),name:address.name)
        }
    }
    private static func parameters(_ source: String) -> (type:String,values:[String:String]) {
        var chunks:[String] = [], part = "", quoted = false, escaped = false
        for c in source {
            if escaped { part.append(c); escaped = false; continue }
            if c == "\\" && quoted { escaped = true; continue }
            if c == "\"" { quoted.toggle(); continue }
            if c == ";" && !quoted { chunks.append(part); part = "" } else { part.append(c) }
        }
        chunks.append(part); var result:[String:String] = [:]
        for item in chunks.dropFirst() {
            guard let eq = item.firstIndex(of:"=") else { continue }
            result[String(item[..<eq]).trimmingCharacters(in:.whitespaces).lowercased()] = String(item[item.index(after:eq)...]).trimmingCharacters(in:.whitespaces)
        }
        return (chunks.first?.trimmingCharacters(in:.whitespaces).lowercased() ?? "",result)
    }
    private static func decodePayload(_ payload:Data,_ encoding:String,recover:Bool = false) throws -> Data {
        switch encoding.trimmingCharacters(in:.whitespaces).lowercased() {
        case "base64":
            if recover {
                // Node's base64 body decoder ignores noise and tolerates
                // missing padding. A dangling sextet contains no byte.
                var clean = Data(); clean.reserveCapacity(payload.count)
                for byte in payload { if byte == 61 { break }; if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47 { clean.append(byte) } }
                if clean.count % 4 == 1 { clean.removeLast() }
                while clean.count % 4 != 0 { clean.append(61) }
                return Data(base64Encoded:clean) ?? Data()
            }
            let clean = payload.filter { ![9,10,13,32].contains($0) }
            guard let result = Data(base64Encoded:clean) else { throw NativeMailFailure.malformed }; return result
        case "quoted-printable":
            if !recover { return try quotedPrintable(payload) }
            var result = Data(), i = payload.startIndex
            func hex(_ c:UInt8)->UInt8? { if (48...57).contains(c) { return c-48 }; if (65...70).contains(c) { return c-55 }; if (97...102).contains(c) { return c-87 }; return nil }
            while i < payload.endIndex {
                let c=payload[i];i += 1
                if c != 61 { result.append(c);continue }
                if i == payload.endIndex { break }
                var soft = i
                while soft < payload.endIndex && (payload[soft] == 32 || payload[soft] == 9) { soft += 1 }
                if soft < payload.endIndex && payload[soft] == 10 { i = soft+1;continue }
                if soft+1 < payload.endIndex && payload[soft] == 13 && payload[soft+1] == 10 { i = soft+2;continue }
                if i+1 < payload.endIndex,let high=hex(payload[i]),let low=hex(payload[i+1]) { result.append(high*16+low);i += 2 }
                else { result.append(61) }
            }
            return result
        case "", "7bit", "8bit", "binary": return payload
        default: if recover { return payload }; throw NativeMailFailure.malformed
        }
    }
    /// Incoming mail uses the installed upstream parser's finite recovery rules.
    /// Frozen outgoing payloads retain their strict byte-preserving decoder.
    static func body(_ data: Data,recoverIncoming: Bool = false,deriveHTMLText: ((String) throws -> String)? = nil,derivePlainHTML: ((String) throws -> String)? = nil,temporaryRoot:URL=FileManager.default.temporaryDirectory) throws -> NativeMailBody {
        if recoverIncoming { return try incomingBody(data,deriveHTMLText:deriveHTMLText,derivePlainHTML:derivePlainHTML,temporaryRoot:temporaryRoot) }
        guard data.count <= maximumMessageBytes else { throw NativeMailFailure.tooLarge }
        var count = 0, textBytes = 0
        var incomingParts:[(plain:String?,html:String?,root:Bool,alternative:Bool)] = [], hasIncomingPlain = false
        // Keep encoded slices until the HTML actually references them. Large,
        // unreferenced attachments must not expand into resident image buffers.
        var images:[String:(type:String,encoding:String,payload:Data)] = [:]
        func parse(_ bytes: Data,depth: Int,alternative:Bool = false) throws -> NativeMailBody {
            count += 1; guard count <= 200, depth <= 12 else { throw NativeMailFailure.tooLarge }
            let emptyHead: Range<Int>? = recoverIncoming && bytes.starts(with:[13,10]) ? bytes.startIndex..<bytes.startIndex+2 : recoverIncoming && bytes.starts(with:[10]) ? bytes.startIndex..<bytes.startIndex+1 : nil
            let divider = emptyHead ?? bytes.range(of:Data("\r\n\r\n".utf8)) ?? bytes.range(of:Data("\n\n".utf8))
            guard let divider else { if recoverIncoming { return NativeMailBody() }; throw NativeMailFailure.malformed }
            let head = try headers(bytes[bytes.startIndex..<divider.lowerBound])
            let payload = bytes[divider.upperBound..<bytes.endIndex]
            let kind = parameters(head["content-type"]), disposition = parameters(head["content-disposition"])
            let cid = head["content-id"].trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"<>"))
            if !cid.isEmpty, cid.utf8.count <= 256, kind.type.range(of:"^image/[a-z0-9_]+$",options:.regularExpression) != nil {
                if images[cid] == nil { images[cid] = (kind.type,head["content-transfer-encoding"],payload) }
                return NativeMailBody()
            }
            if disposition.type == "attachment" { return NativeMailBody() }
            if kind.type.hasPrefix("multipart/") {
                guard let boundary = kind.values["boundary"], !boundary.isEmpty, boundary.utf8.count <= 70,
                      !boundary.utf8.contains(where:{$0 < 32 || $0 == 127}) else { throw NativeMailFailure.malformed }
                let marker = Data(("--"+boundary).utf8)
                var cursor = payload.startIndex, start: Int? = nil, closed = false, parts:[NativeMailBody] = []
                while cursor < payload.endIndex {
                    let end = payload[cursor...].firstIndex(of:10).map{$0+1} ?? payload.endIndex
                    var lineEnd = end; while lineEnd > cursor && [10,13,32,9].contains(payload[lineEnd-1]) { lineEnd -= 1 }
                    let line = payload[cursor..<lineEnd]
                    if line == marker || line == marker+Data("--".utf8) {
                        if let start {
                            var partEnd = cursor; if partEnd > start && payload[partEnd-1] == 10 { partEnd -= 1 }; if partEnd > start && payload[partEnd-1] == 13 { partEnd -= 1 }
                            parts.append(try parse(payload[start..<partEnd],depth:depth+1,alternative:alternative || kind.type == "multipart/alternative"))
                        }
                        if line == marker+Data("--".utf8) { closed = true; break }; start = end
                    }
                    cursor = end
                }
                if !closed {
                    guard recoverIncoming else { throw NativeMailFailure.malformed }
                    if let start,start < payload.endIndex { parts.append(try parse(payload[start..<payload.endIndex],depth:depth+1,alternative:alternative || kind.type == "multipart/alternative")) }
                }
                let plain = parts.compactMap(\.text), html = parts.compactMap(\.html)
                return NativeMailBody(text:plain.isEmpty ? nil : plain.joined(separator:"\n"),html:html.isEmpty ? nil : html.joined(separator:"\n"))
            }
            guard ["","text/plain","text/html"].contains(kind.type) else { return NativeMailBody() }
            let decoded = try decodePayload(payload,head["content-transfer-encoding"],recover:recoverIncoming)
            textBytes += decoded.count; guard textBytes <= maximumTextBytes else { throw NativeMailFailure.tooLarge }
            let charset = kind.values["charset"] ?? "utf-8"
            let utf8 = ["utf-8","utf8"].contains(charset.lowercased())
            guard var value = recoverIncoming && utf8 ? String(decoding:decoded,as:UTF8.self) : text(decoded,charset:charset) else { throw NativeMailFailure.malformed }
            if recoverIncoming && kind.type != "text/html" { hasIncomingPlain = true }
            if recoverIncoming { value = value.replacingOccurrences(of:"\r\n",with:"\n"); if value.isEmpty { return NativeMailBody() };value.makeContiguousUTF8() }
            if recoverIncoming && deriveHTMLText != nil { incomingParts.append((kind.type == "text/html" ? nil : value,kind.type == "text/html" ? value : nil,depth==0,alternative)) }
            return kind.type == "text/html" ? NativeMailBody(html:value) : NativeMailBody(text:value)
        }
        var result = try parse(data,depth:0)
        if recoverIncoming,let deriveHTMLText {
            var pieces:[String]=[], bytes=0
            for part in incomingParts {
                let value:String?
                if let plain=part.plain { value=plain }
                else if let html=part.html,(!part.alternative && hasIncomingPlain) || (part.root && !hasIncomingPlain) { value=try deriveHTMLText(html) }
                else {value=nil}
                if let value { let added=value.utf8.count+(pieces.isEmpty ? 0:1);guard added<=Int.max-bytes else{throw NativeMailFailure.tooLarge};bytes += added;pieces.append(value) }
            }
            result.text = pieces.isEmpty ? nil : pieces.joined(separator:"\n")
        }
        guard let html = result.html, !images.isEmpty else { return result }
        // Match the original mailparser's CID rules and first matching image.
        // Stop before repeated CID references expand beyond the body budget.
        let regex = try NSRegularExpression(pattern:"\\bcid:([^'\"\\s]{1,256})")
        let original = html as NSString
        var expanded = "", end = 0, bytes = 0, urls:[String:String] = [:], failure:Error?
        func append(_ value:String) throws { bytes += value.utf8.count; guard bytes <= maximumTextBytes else { throw NativeMailFailure.tooLarge }; expanded += value }
        regex.enumerateMatches(in:html,range:NSRange(location:0,length:original.length)) { match,_,stop in
            guard let match else { return }
            let id = original.substring(with:match.range(at:1)); guard let image = images[id] else { return }
            do {
                let url:String
                if let cached = urls[id] { url = cached }
                else {
                    let decoded = try decodePayload(image.payload,image.encoding)
                    guard decoded.count <= (maximumTextBytes/4)*3 else { throw NativeMailFailure.tooLarge }
                    url = "data:"+image.type+";base64,"+decoded.base64EncodedString(); urls[id] = url
                }
                try append(original.substring(with:NSRange(location:end,length:match.range.location-end))); try append(url); end = NSMaxRange(match.range)
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        if end != 0 { try append(original.substring(from:end)); result.html = expanded }
        return result
    }
    static func encodedHeader(_ text: String) throws -> String {
        guard text.utf8.count <= 4096, !text.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw NativeMailFailure.invalid("件名に改行や制御文字は使えません。") }
        if text.utf8.allSatisfy({$0 < 127}) && text.utf8.count <= 60 { return text }
        var words:[String] = [], chunk = Data()
        func flush() { if !chunk.isEmpty { words.append("=?UTF-8?B?"+chunk.base64EncodedString()+"?="); chunk.removeAll(keepingCapacity:true) } }
        for scalar in text.unicodeScalars { let bytes = Data(String(scalar).utf8); if chunk.count+bytes.count > 30 { flush() }; chunk.append(bytes) }; flush()
        return words.joined(separator:"\r\n ")
    }
    static func outgoing(from: String,to: [String],cc: [String] = [],bcc: [String] = [],subject: String,body: String,messageID: String,inReplyTo: String? = nil,references: [String] = [],date: Date = Date()) throws -> Data {
        let from = try NativeMailAddress.checked(from).transportAddress
        let to = try NativeMailAddress.list(to), cc = try NativeMailAddress.list(cc), bcc = try NativeMailAddress.list(bcc)
        guard !to.isEmpty, body.utf8.count <= maximumTextBytes, !body.contains("\0") else { throw NativeMailFailure.invalid("宛先と本文の長さ・使用できない文字を確認してください。") }
        var envelopeBytes = 0
        for list in [to,cc,bcc] { for address in list { envelopeBytes += try address.transportAddress.utf8.count+1; guard envelopeBytes <= maximumEnvelopeBytes else { throw NativeMailFailure.tooLarge } } }
        func checkedID(_ id: String) throws -> String {
            guard id.utf8.count <= 998, id.range(of:"^<[^<>\\s@]+@[^<>\\s@]+>$",options:.regularExpression) != nil else { throw NativeMailFailure.invalid("メールの識別子を確認してください。") }; return id
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; formatter.timeZone = TimeZone(secondsFromGMT:0)
        func recipientHeader(_ name: String,_ values:[NativeMailAddress]) throws -> String { name+": "+(try values.map{try $0.header()}).joined(separator:",\r\n ")+"\r\n" }
        var output = "Date: "+formatter.string(from:date)+"\r\nMessage-ID: "+(try checkedID(messageID))+"\r\nFrom: "+from+"\r\n"+(try recipientHeader("To",to))
        if !cc.isEmpty { output += try recipientHeader("Cc",cc) }
        output += "Subject: "+(try encodedHeader(subject))+"\r\n"
        if let inReplyTo { output += "In-Reply-To: "+(try checkedID(inReplyTo))+"\r\n" }
        guard references.reduce(0,{$0+$1.utf8.count+3}) <= maximumHeaderBytes else { throw NativeMailFailure.tooLarge }
        if !references.isEmpty { output += "References: "+(try references.map(checkedID)).joined(separator:"\r\n ")+"\r\n" }
        output += "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        guard output.utf8.count <= maximumHeaderBytes else { throw NativeMailFailure.tooLarge }
        // Count normalized bytes without creating intermediate whole-body
        // strings. The second pass normalizes directly into small Base64
        // batches. Only the final MIME Data and a 28.5KiB batch are retained.
        var normalizedBytes = 0, previousCR = false
        for byte in body.utf8 {
            normalizedBytes += byte == 13 ? 2 : byte == 10 ? (previousCR ? 0 : 2) : 1
            previousCR = byte == 13
            guard normalizedBytes <= maximumTextBytes else { throw NativeMailFailure.tooLarge }
        }
        let base64Bytes = (normalizedBytes+2)/3*4
        var result = Data(output.utf8)
        result.reserveCapacity(result.count+base64Bytes+max(1,(base64Bytes+75)/76)*2)
        let batchBytes = 57*512 // Complete 76-character encoded lines.
        var batch = Data(); batch.reserveCapacity(batchBytes)
        func flush() {
            guard !batch.isEmpty else { return }
            autoreleasepool { result.append(batch.base64EncodedData(options:[.lineLength76Characters,.endLineWithCarriageReturn,.endLineWithLineFeed])) }
            result.append(contentsOf:[13,10]); batch.removeAll(keepingCapacity:true)
        }
        func append(_ byte:UInt8) { batch.append(byte); if batch.count == batchBytes { flush() } }
        previousCR = false
        for byte in body.utf8 {
            if byte == 13 { append(13); append(10) }
            else if byte == 10 { if !previousCR { append(13); append(10) } }
            else { append(byte) }
            previousCR = byte == 13
        }
        flush()
        if normalizedBytes == 0 { result.append(contentsOf:[13,10]) }
        return result
    }
}
