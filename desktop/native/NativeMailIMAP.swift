import Foundation

indirect enum NativeMailIMAPToken {
    case atom(String), bytes(Data), list([NativeMailIMAPToken])
    var string: String? { switch self { case .atom(let s):return s; case .bytes(let d):return String(data:d,encoding:.utf8); case .list:return nil } }
}
struct NativeMailIMAPHeader {
    let uid: UInt32
    let seen: Bool
    let headers: NativeMailHeaders
}
enum NativeMailIMAP {
    static func rows(_ data: Data) throws -> [[NativeMailIMAPToken]] {
        guard data.count <= NativeMailMIME.maximumMessageBytes else { throw NativeMailFailure.tooLarge }
        var position = data.startIndex, tokens = 0
        func token(depth: Int) throws -> NativeMailIMAPToken {
            tokens += 1; guard depth <= 16, tokens <= 100_000, position < data.endIndex else { throw NativeMailFailure.malformed }
            let first = data[position]; position += 1
            if first == 40 {
                var result:[NativeMailIMAPToken] = []
                while position < data.endIndex {
                    if data[position] == 32 || data[position] == 9 { position += 1; continue }
                    if data[position] == 41 { position += 1; return .list(result) }
                    result.append(try token(depth:depth+1))
                }
                throw NativeMailFailure.malformed
            }
            if first == 34 {
                var value = Data()
                while position < data.endIndex {
                    let c = data[position]; position += 1
                    if c == 34 { return .bytes(value) }
                    if c == 92 { guard position < data.endIndex, data[position] == 92 || data[position] == 34 else { throw NativeMailFailure.malformed }; value.append(data[position]); position += 1 }
                    else { guard c != 13 && c != 10 && c != 0 else { throw NativeMailFailure.malformed }; value.append(c) }
                    guard value.count <= 65_536 else { throw NativeMailFailure.tooLarge }
                }
                throw NativeMailFailure.malformed
            }
            if first == 123 {
                let start = position
                while position < data.endIndex && (48...57).contains(data[position]) { position += 1 }
                guard position > start, position-start <= 10, let length = Int(String(decoding:data[start..<position],as:UTF8.self)) else { throw NativeMailFailure.malformed }
                if position < data.endIndex && data[position] == 43 { position += 1 }
                guard position+2 < data.endIndex, data[position] == 125, data[position+1] == 13, data[position+2] == 10 else { throw NativeMailFailure.malformed }
                position += 3
                guard length <= data.endIndex-position else { throw NativeMailFailure.malformed }
                let value = data[position..<position+length]; position += length
                return .bytes(value)
            }
            guard ![0,10,13,41].contains(first) else { throw NativeMailFailure.malformed }
            let start = position-1
            while position < data.endIndex && ![0,9,10,13,32,40,41,34,123].contains(data[position]) { position += 1 }
            guard position-start <= 65_536 else { throw NativeMailFailure.tooLarge }
            return .atom(String(decoding:data[start..<position],as:UTF8.self))
        }
        var result:[[NativeMailIMAPToken]] = []
        while position < data.endIndex {
            var row:[NativeMailIMAPToken] = []
            while position < data.endIndex && data[position] != 13 && data[position] != 10 {
                if data[position] == 32 || data[position] == 9 { position += 1; continue }
                row.append(try token(depth:0))
            }
            if position < data.endIndex && data[position] == 13 { position += 1; guard position < data.endIndex && data[position] == 10 else { throw NativeMailFailure.malformed } }
            if position < data.endIndex && data[position] == 10 { position += 1 }
            if !row.isEmpty { result.append(row) }
        }
        return result
    }
    static func quotedMailbox(_ name: String) throws -> String {
        let value = try NativeMailUTF7.encode(name)
        return "\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""
    }
    static func folderNames(_ data: Data) throws -> [String] {
        var result:[String] = []
        for row in try rows(data) where row.count >= 5 && row[0].string == "*" && row[1].string?.uppercased() == "LIST" {
            guard case .list(let flags) = row[2], let name = row[4].string else { throw NativeMailFailure.malformed }
            if flags.contains(where:{$0.string?.lowercased() == "\\noselect"}) { continue }
            result.append(try NativeMailUTF7.decode(name))
        }
        return Array(Set(result)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func status(_ data: Data,mailbox: String) throws -> (validity:UInt32,next:UInt32) {
        let expected = try NativeMailUTF7.encode(mailbox)
        let matches = try rows(data).filter { $0.count == 4 && $0[0].string == "*" && $0[1].string?.uppercased() == "STATUS" && $0[2].string == expected }
        guard matches.count == 1, case .list(let pairs) = matches[0][3], pairs.count%2 == 0 else { throw NativeMailFailure.malformed }
        var fields:[String:UInt32] = [:]
        for i in stride(from:0,to:pairs.count,by:2) {
            guard let key = pairs[i].string?.uppercased(), let raw = pairs[i+1].string, let number = UInt32(raw), fields[key] == nil else { throw NativeMailFailure.malformed }; fields[key] = number
        }
        guard let validity = fields["UIDVALIDITY"], validity > 0, let next = fields["UIDNEXT"], next > 0 else { throw NativeMailFailure.malformed }
        return (validity,next)
    }
    static func selectedValidity(_ data: Data) throws -> UInt32 {
        var values:[UInt32] = []
        for row in try rows(data) where row.count >= 4 && row[0].string == "*" && row[1].string?.uppercased() == "OK" && row[2].string?.uppercased() == "[UIDVALIDITY" {
            guard let raw = row[3].string, raw.hasSuffix("]"), let value = UInt32(raw.dropLast()), value > 0 else { throw NativeMailFailure.malformed }; values.append(value)
        }
        guard values.count == 1 else { throw NativeMailFailure.malformed }; return values[0]
    }
    static func searchUIDs(_ data: Data,after: UInt32) throws -> [UInt32] {
        var result:Set<UInt32> = [], found = false
        for row in try rows(data) where row.count >= 2 && row[0].string == "*" && row[1].string?.uppercased() == "SEARCH" {
            guard !found else { throw NativeMailFailure.malformed }; found = true
            for token in row.dropFirst(2) {
                guard let raw = token.string, let uid = UInt32(raw), uid > 0 else { throw NativeMailFailure.malformed }
                // IMAP n:* can include n's lower counterpart when n exceeds
                // the highest UID. Never move the cursor backwards.
                if uid > after { result.insert(uid) }
            }
        }
        guard found else { throw NativeMailFailure.malformed }; return result.sorted()
    }
    private static func fetchedPayloads(_ data: Data,expected: Set<UInt32>) throws -> [(uid:UInt32,seen:Bool,section:String,body:Data)] {
        var result:[(uid:UInt32,seen:Bool,section:String,body:Data)] = [], observed:Set<UInt32> = []
        for row in try rows(data) where row.count >= 4 && row[0].string == "*" && row[2].string?.uppercased() == "FETCH" {
            guard case .list(let fields) = row[3] else { throw NativeMailFailure.malformed }
            var uid: UInt32? = nil, seen = false, body: Data? = nil, section: String? = nil
            for i in fields.indices {
                let key: String
                if case .atom(let value) = fields[i] { key = value.uppercased() } else { key = "" }
                if key == "UID" {
                    guard uid == nil, i+1 < fields.count, let value = fields[i+1].string.flatMap(UInt32.init), value > 0 else { throw NativeMailFailure.malformed }; uid = value
                }
                if key == "FLAGS" {
                    guard i+1 < fields.count, case .list(let flags) = fields[i+1] else { throw NativeMailFailure.malformed }
                    seen = flags.contains { $0.string?.lowercased() == "\\seen" }
                }
                if key.hasPrefix("BODY[") { guard section == nil else { throw NativeMailFailure.malformed }; section = key }
                if case .bytes(let value) = fields[i] { guard section != nil, body == nil else { throw NativeMailFailure.malformed }; body = value }
            }
            // Servers may interleave flag changes for unrelated messages. They
            // do not supply a payload and must not break a requested fetch.
            guard let body else { continue }
            guard let uid, expected.contains(uid), observed.insert(uid).inserted, let section else { throw NativeMailFailure.malformed }
            result.append((uid,seen,section,body))
        }
        return result.sorted{$0.uid < $1.uid}
    }
    static func fetchedHeaders(_ data: Data,expected: Set<UInt32>) throws -> [NativeMailIMAPHeader] {
        try fetchedPayloads(data,expected:expected).map { item in
            guard item.section.hasPrefix("BODY[HEADER") else { throw NativeMailFailure.malformed }
            return .init(uid:item.uid,seen:item.seen,headers:try NativeMailMIME.headers(item.body,allowLargeIncoming:true))
        }
    }
    static func fetchedBody(_ data: Data,expected: UInt32) throws -> Data? {
        let items = try fetchedPayloads(data,expected:[expected])
        guard let item = items.first else { return nil } // Expunged after discovery.
        guard items.count == 1, item.section == "BODY[]" else { throw NativeMailFailure.malformed }
        return item.body
    }
    static func headerCommand(_ uids:[UInt32]) throws -> String {
        guard !uids.isEmpty, uids.count <= 50, uids.allSatisfy({$0>0}), Set(uids).count == uids.count else { throw NativeMailFailure.malformed }
        return "UID FETCH "+uids.map(String.init).joined(separator:",")+" (UID FLAGS BODY.PEEK[HEADER.FIELDS (DATE SUBJECT FROM TO CC MESSAGE-ID IN-REPLY-TO REFERENCES)])"
    }
}
