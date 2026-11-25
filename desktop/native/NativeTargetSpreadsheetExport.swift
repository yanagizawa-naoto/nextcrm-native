import Foundation
import Darwin

/// Sequential target export into a caller-owned, unpublished output path.
/// Call from the import/export worker; the class never retains prior rows.
final class NativeTargetSpreadsheetExport {
    enum Format { case csv, xlsx }
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private final class Sink {
        private var descriptor: Int32
        private var bytes = [UInt8]()
        private let cancelled: () -> Bool
        private(set) var maximumBufferBytes = 0
        let identity: Identity
        init(_ url: URL, cancelled: @escaping () -> Bool) throws {
            descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.message("出力用の一時ファイルを作成できません。既存のファイルは上書きしません。") }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                Darwin.close(descriptor); descriptor = -1
                throw Failure.message("出力ファイルを確認できません。")
            }
            identity = Identity(info); self.cancelled = cancelled
            bytes.reserveCapacity(65_536)
        }
        deinit { close() }
        func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
        func append(_ byte: UInt8) throws {
            bytes.append(byte); maximumBufferBytes = max(maximumBufferBytes, bytes.count)
            if bytes.count == 65_536 { try flush() }
        }
        func append(_ text: String) throws { for byte in text.utf8 { try append(byte) } }
        func scalar(_ value: UInt32) throws {
            if value < 0x80 { try append(UInt8(value)) }
            else if value < 0x800 { try append(UInt8(0xC0 | value >> 6)); try append(UInt8(0x80 | value & 63)) }
            else if value < 0x10000 { try append(UInt8(0xE0 | value >> 12)); try append(UInt8(0x80 | value >> 6 & 63)); try append(UInt8(0x80 | value & 63)) }
            else { try append(UInt8(0xF0 | value >> 18)); try append(UInt8(0x80 | value >> 12 & 63)); try append(UInt8(0x80 | value >> 6 & 63)); try append(UInt8(0x80 | value & 63)) }
        }
        func flush() throws {
            if cancelled() { throw CancellationError() }
            guard descriptor >= 0 else { throw Failure.message("出力ファイルは閉じられています。") }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure.message("出力ファイルへ書き込めません。空き容量を確認してください。") }
                    offset += count
                }
            }
            bytes.removeAll(keepingCapacity: true)
        }
        func finish() throws {
            try flush()
            guard fsync(descriptor) == 0 else { throw Failure.message("出力ファイルを確定できません。") }
            close()
        }
    }
    private let output: URL, format: Format, cancelled: () -> Bool
    private var sink: Sink?
    private var strings: Sink?
    private var workspace: URL?
    private var outputIdentity: Identity?
    private var closed = false, delivered = false
    private(set) var rowCount = 0
    private(set) var maximumBufferBytes = 0

    init(stagedOutput: URL, format: Format, headers: [String], cancelled: @escaping () -> Bool = { false }) throws {
        guard stagedOutput.isFileURL, headers.count == 21 else { throw Failure.message("営業対象の出力には21列の見出しが必要です。") }
        output = stagedOutput; self.format = format; self.cancelled = cancelled
        var existing = stat()
        guard lstat(output.path, &existing) != 0 && errno == ENOENT else { throw Failure.message("出力先にファイルがあります。新しい一時ファイルを指定してください。") }
        do {
            try check()
            if format == .csv {
                let stream = try Sink(output, cancelled: cancelled); sink = stream; outputIdentity = stream.identity
                try csvRow(headers)
            } else {
                let directory = output.deletingLastPathComponent().appendingPathComponent(".nextcrm-target-export-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                workspace = directory
                for name in ["_rels", "xl", "xl/_rels", "xl/worksheets"] {
                    try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                try Self.part(Self.types, directory.appendingPathComponent("[Content_Types].xml"))
                try Self.part(Self.rootRelationships, directory.appendingPathComponent("_rels/.rels"))
                try Self.part(Self.workbook, directory.appendingPathComponent("xl/workbook.xml"))
                try Self.part(Self.workbookRelationships, directory.appendingPathComponent("xl/_rels/workbook.xml.rels"))
                sink = try Sink(directory.appendingPathComponent("xl/worksheets/sheet1.xml"), cancelled: cancelled)
                strings = try Sink(directory.appendingPathComponent("xl/sharedStrings.xml"), cancelled: cancelled)
                try strings!.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">")
                try sink!.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>")
                try xlsxRow(headers, number: 1)
            }
        } catch { cancel(); throw error }
    }
    deinit { if !delivered { cancel() } }
    func append(_ row: [String]) throws {
        do {
            try check()
            guard row.count == 21, rowCount < Int.max / 21 - 2 else { throw Failure.message("営業対象の出力行の形式が正しくありません。") }
            if format == .csv { try sink!.append("\n"); try csvRow(row) }
            else { try xlsxRow(row, number: rowCount + 2) }
            rowCount += 1; maximumBufferBytes = max(maximumBufferBytes, sink!.maximumBufferBytes + (strings?.maximumBufferBytes ?? 0))
        } catch { cancel(); throw error }
    }
    @discardableResult func finish() throws -> URL {
        do {
            try check()
            if format == .xlsx { try sink!.append("</sheetData></worksheet>"); try strings!.append("</sst>") }
            maximumBufferBytes = max(maximumBufferBytes, sink!.maximumBufferBytes + (strings?.maximumBufferBytes ?? 0))
            try sink!.finish(); sink = nil
            if let stringStream = strings { try stringStream.finish(); strings = nil }
            if format == .xlsx {
                let directory = workspace!, archive = directory.appendingPathComponent("targets.xlsx")
                let log = directory.appendingPathComponent("zip.log")
                guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.message("出力処理の記録を作成できません。") }
                let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = directory
                process.arguments = ["-q", "-X", archive.path, "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml", "xl/sharedStrings.xml"]
                process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
                try process.run()
                while process.isRunning {
                    if cancelled() { process.terminate(); process.waitUntilExit(); throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw Failure.message("Excelファイルを作成できません。空き容量を確認してください。") }
                try check()
                guard chmod(archive.path, 0o600) == 0, Darwin.link(archive.path, output.path) == 0 else { throw Failure.message("Excelの出力先を確定できません。既存のファイルは上書きしません。") }
                var info = stat()
                guard lstat(output.path, &info) == 0 else { throw Failure.message("Excelファイルを確認できません。") }
                outputIdentity = Identity(info)
            }
            guard ownedOutputStillPresent() else { throw Failure.message("出力先が変更されたため、保存を中止しました。") }
            try check()
            if let directory = workspace { try FileManager.default.removeItem(at: directory); workspace = nil }
            closed = true; delivered = true
            return output
        } catch { cancel(); throw error }
    }
    func cancel() {
        guard !delivered else { return }
        closed = true; sink?.close(); sink = nil; strings?.close(); strings = nil
        if ownedOutputStillPresent() { _ = Darwin.unlink(output.path) }
        outputIdentity = nil
        if let directory = workspace { try? FileManager.default.removeItem(at: directory); workspace = nil }
    }
    private func check() throws {
        if cancelled() { throw CancellationError() }
        guard !closed else { throw Failure.message("出力処理は終了しています。") }
    }
    private func ownedOutputStillPresent() -> Bool {
        guard let expected = outputIdentity else { return false }
        var info = stat()
        return lstat(output.path, &info) == 0 && Identity(info) == expected && (info.st_mode & S_IFMT) == S_IFREG
    }
    private func csvRow(_ row: [String]) throws {
        for (index, value) in row.enumerated() {
            if index > 0 { try sink!.append(",") }
            // Also protect a bare CR: otherwise a CSV reader creates another row.
            let quoted = value.utf8.contains { $0 == 44 || $0 == 34 || $0 == 10 || $0 == 13 }
            if quoted { try sink!.append(34) }
            for byte in value.utf8 { if byte == 34 { try sink!.append(34) }; try sink!.append(byte) }
            if quoted { try sink!.append(34) }
        }
    }
    private func xlsxRow(_ row: [String], number: Int) throws {
        try sink!.append("<row r=\"\(number)\">")
        for (index, value) in row.enumerated() {
            let column = String(UnicodeScalar(65 + index)!)
            let stringIndex = (number - 1) * 21 + index
            try sink!.append("<c r=\"\(column)\(number)\" t=\"s\"><v>\(stringIndex)</v></c>")
            try strings!.append("<si><t xml:space=\"preserve\">")
            try xmlText(value)
            try strings!.append("</t></si>")
        }
        try sink!.append("</row>")
    }
    private func xmlText(_ text: String) throws {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index], value = scalar.value
            if value == 95 && Self.isOOXMLEscape(scalars, at: index) {
                try strings!.append("_x005F_")
            } else if (value < 32 && value != 9 && value != 10) || value == 0xFFFE || value == 0xFFFF {
                try strings!.append(String(format: "_x%04X_", value))
            } else {
                switch value {
                case 38: try strings!.append("&amp;")
                case 60: try strings!.append("&lt;")
                case 62: try strings!.append("&gt;")
                default: try strings!.scalar(value)
                }
            }
            index = scalars.index(after: index)
        }
    }
    private static func isOOXMLEscape(_ scalars: String.UnicodeScalarView, at start: String.UnicodeScalarView.Index) -> Bool {
        var index = scalars.index(after: start)
        guard index < scalars.endIndex, scalars[index] == "x" else { return false }
        index = scalars.index(after: index)
        for _ in 0..<4 {
            guard index < scalars.endIndex else { return false }
            let value = scalars[index].value
            guard (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value) else { return false }
            index = scalars.index(after: index)
        }
        return index < scalars.endIndex && scalars[index] == "_"
    }
    private static func part(_ contents: String, _ url: URL) throws {
        let stream = try Sink(url, cancelled: { false }); try stream.append(contents); try stream.finish()
    }
    private static let types = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/></Types>"
    private static let rootRelationships = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
    private static let workbook = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Targets\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
    private static let workbookRelationships = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>"
}
