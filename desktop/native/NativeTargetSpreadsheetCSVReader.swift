import Foundation

/// Papa-compatible streaming string parser. Only one raw record plus the fixed
/// 1 Mi UTF-16-unit newline sample is retained; there is no row/column cap.
/// Header/row publication is a caller callback (normally a private SQLite draft).
enum NativeTargetSpreadsheetCSVReader {
    private final class Bytes {
        let input: FileHandle
        var bytes = Data(), position = 0, pushed: [UInt8] = []
        let check: () throws -> Void
        init(_ url: URL, check: @escaping () throws -> Void) throws {
            input = try FileHandle(forReadingFrom: url); self.check = check
        }
        deinit { try? input.close() }
        func next() throws -> UInt8? {
            if let result = pushed.popLast() { return result }
            if position == bytes.count {
                try check(); bytes = try input.read(upToCount: 65_536) ?? Data(); position = 0
                if bytes.isEmpty { return nil }
            }
            defer { position += 1 }; return bytes[position]
        }
        func put(_ value: [UInt8]) { pushed.append(contentsOf: value.reversed()) }
    }
    private final class Parser {
        let bytes: Bytes, delimiter: UInt8, newline: [UInt8]
        var ended = false, atStart = true
        init(_ url: URL, delimiter: UInt8, newline: [UInt8], check: @escaping () throws -> Void) throws {
            bytes = try Bytes(url, check: check); self.delimiter = delimiter; self.newline = newline
        }
        func next() throws -> [String]? {
            if ended { return nil }
            var row: [String] = [], field = Data(), quoted = false, fieldStart = true
            if atStart {
                atStart = false; var leading: [UInt8] = []
                for _ in 0..<6 { if let b = try bytes.next() { leading.append(b) } }
                // Blob.text strips one BOM; Papa.stripBom strips another.
                for _ in 0..<2 { if leading.starts(with: [239,187,191]) { leading.removeFirst(3) } }
                bytes.put(leading)
            }
            func finish() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); fieldStart = true }
            func consumeNewline(_ first: UInt8) throws -> Bool {
                guard first == newline[0] else { return false }
                if newline.count == 1 { return true }
                if let second = try bytes.next() { if second == newline[1] { return true }; bytes.put([second]) }
                return false
            }
            while let b = try bytes.next() {
                if quoted {
                    if b != 34 { field.append(b); continue }
                    guard let after = try bytes.next() else { ended = true; finish(); return row }
                    if after == 34 { field.append(34); continue }
                    // Papa uses String.trim, including Unicode whitespace.
                    var tail: [UInt8] = [], current = after
                    while true {
                        if current == delimiter { quoted = false; finish(); break }
                        if try consumeNewline(current) { finish(); return row }
                        var scalar = [current]
                        let length = current < 128 ? 1 : current >= 194 && current <= 223 ? 2 : current >= 224 && current <= 239 ? 3 : current >= 240 && current <= 244 ? 4 : 1
                        if length > 1 { for _ in 1..<length { if let v = try bytes.next() { scalar.append(v) } } }
                        tail.append(contentsOf: scalar)
                        if !NativeTargetSpreadsheetFields.trim(String(decoding: scalar, as: UTF8.self)).isEmpty {
                            // Source ignores Papa's structural error result and
                            // retains the bad closing quote as part of the field.
                            field.append(34); field.append(contentsOf: tail); break
                        }
                        guard let next = try bytes.next() else { ended = true; finish(); return row }
                        current = next
                    }
                    continue
                }
                if fieldStart && b == 34 { quoted = true; fieldStart = false; continue }
                if b == delimiter { finish(); continue }
                if try consumeNewline(b) { finish(); return row }
                fieldStart = false; field.append(b)
            }
            ended = true; finish(); return row
        }
    }
    private static func empty(_ fields: [String]) -> Bool { fields.allSatisfy { NativeTargetSpreadsheetFields.trim($0).isEmpty } }
    private static func newline(_ url: URL) throws -> [UInt8] {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        // <= 4 MiB UTF8 holds the source's <=1 Mi UTF16 units. This is a fixed
        // detection sample, never an input-size limit or a truncated import.
        let raw = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
        let decoded = String(decoding: raw, as: UTF8.self)
        let sample = String(decoding: Array(decoded.utf16.prefix(1024 * 1024)), as: UTF16.self)
        let pattern = try NSRegularExpression(pattern: "\"[\\s\\S]*?\"")
        let unquoted = pattern.stringByReplacingMatches(in: sample, range: NSRange(sample.startIndex..., in: sample), withTemplate: "")
        // JavaScript splits UTF-16 code units. Swift Character matching treats
        // CRLF as one grapheme, so do not use String.hasPrefix/components here.
        let units = Array(unquoted.utf16), cr = units.indices.filter { units[$0] == 13 }
        let firstLF = units.firstIndex(of: 10)
        if cr.isEmpty || (firstLF != nil && firstLF! < cr[0]) { return [10] }
        let withLF = cr.filter { $0 + 1 < units.count && units[$0 + 1] == 10 }.count + (units.first == 10 ? 1 : 0)
        return withLF * 2 >= cr.count + 1 ? [13,10] : [13]
    }
    static func parse(url: URL, checkpoint: @escaping () throws -> Void = {},
                      headers: ([String]) throws -> Void, row: (NativeTargetSpreadsheetRow) throws -> Void) throws {
        try checkpoint(); let line = try newline(url)
        var best: UInt8 = 44, bestDelta: Int?, maximum: Double?
        for delimiter: UInt8 in [44,9,124,59,30,31] {
            let parser = try Parser(url, delimiter: delimiter, newline: line, check: checkpoint)
            var previous: Int?, delta = 0, sum = 0, count = 0
            for _ in 0..<10 {
                guard let fields = try parser.next() else { break }
                if empty(fields) { continue }; sum += fields.count; count += 1
                if let previous { delta += abs(fields.count - previous) }; previous = fields.count
            }
            let average = count == 0 ? 0 : Double(sum) / Double(count)
            if (bestDelta == nil || delta <= bestDelta!) && (maximum == nil || average > maximum!) && average > 1.99 {
                bestDelta = delta; maximum = average; best = delimiter
            }
        }
        let parser = try Parser(url, delimiter: best, newline: line, check: checkpoint)
        var names: [String]?
        while let fields = try parser.next() {
            try checkpoint(); if empty(fields) { continue }
            if names == nil {
                var used = Set(fields.map { Data($0.utf8) }), seen = Set<Data>(), result: [String] = []
                for name in fields {
                    let key = Data(name.utf8)
                    if !seen.insert(key).inserted {
                        var counter = 1, replacement = name + "_1"
                        while used.contains(Data(replacement.utf8)) { counter += 1; replacement = name + "_" + String(counter) }
                        used.insert(Data(replacement.utf8)); result.append(replacement)
                    } else { result.append(name) }
                }
                names = result; try headers(result); continue
            }
            let header = names!; var entries: [NativeTargetSpreadsheetRow.Entry] = [], extras: [String] = []
            for (i, text) in fields.prefix(header.count).enumerated() {
                if header[i] == "__proto__" { continue } // source {} assignment
                if header[i] == "__parsed_extra" { extras.append(text) }
                else { entries.append(.init(header[i], text)) }
            }
            if fields.count > header.count { extras.append(contentsOf: fields.dropFirst(header.count)) }
            if !extras.isEmpty { entries.append(.init(extra: extras)) }
            try row(.init(entries: entries))
        }
        if names == nil { try headers([]) }
    }
}
