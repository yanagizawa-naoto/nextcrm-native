import Foundation
import Darwin

@main struct NativeTargetSpreadsheetExportTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NativeTargetSpreadsheetExport.Failure.message(message) }; checks += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw NativeTargetSpreadsheetExport.Failure.message(message)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let headers = fixture["headers"] as! [String], rows = fixture["rows"] as! [[String]]
        for format in [NativeTargetSpreadsheetExport.Format.csv, .xlsx] {
            let ext = format == .csv ? "csv" : "xlsx"
            let path = root.appendingPathComponent("rows." + ext)
            let writer = try NativeTargetSpreadsheetExport(stagedOutput: path, format: format, headers: headers)
            for row in rows { try writer.append(row) }
            try check(try writer.finish() == path, "finish returns caller staging URL")
            try check(writer.rowCount == rows.count, "all rows emitted")
            try check(writer.maximumBufferBytes <= 131_072, "byte buffer bounded")
            writer.cancel(); try check(fm.fileExists(atPath: path.path), "cancel after delivery preserves caller output")
            try rejects("finished writer cannot append") { try writer.append(rows[0]) }
            try check(fm.fileExists(atPath: path.path), "invalid reuse preserves delivered output")
            try rejects("existing output must be preserved") { _ = try NativeTargetSpreadsheetExport(stagedOutput: path, format: format, headers: headers) }
            let empty = try NativeTargetSpreadsheetExport(stagedOutput: root.appendingPathComponent("empty." + ext), format: format, headers: headers)
            try empty.finish(); try check(empty.rowCount == 0, "empty export retains header")
            let cancelledPath = root.appendingPathComponent("cancelled." + ext)
            var stop = false
            let cancelled = try NativeTargetSpreadsheetExport(stagedOutput: cancelledPath, format: format, headers: headers, cancelled: { stop })
            try cancelled.append(rows[0]); stop = true
            try rejects("cancellation must reject finish") { try cancelled.finish() }
            try check(!fm.fileExists(atPath: cancelledPath.path), "cancelled output removed")
            let invalidPath = root.appendingPathComponent("invalid." + ext)
            let invalid = try NativeTargetSpreadsheetExport(stagedOutput: invalidPath, format: format, headers: headers)
            try rejects("invalid row is rejected") { try invalid.append(["too short"]) }
            try check(!fm.fileExists(atPath: invalidPath.path), "partial invalid output removed")
            let link = root.appendingPathComponent("existing-link." + ext)
            try fm.createSymbolicLink(at: link, withDestinationURL: path)
            try rejects("symlink is never followed") { _ = try NativeTargetSpreadsheetExport(stagedOutput: link, format: format, headers: headers) }
            try check(try fm.destinationOfSymbolicLink(atPath: link.path) == path.path, "existing symlink preserved")
            let replaced = root.appendingPathComponent("replaced." + ext)
            let replacement = Data("foreign existing output".utf8)
            let owned = try NativeTargetSpreadsheetExport(stagedOutput: replaced, format: format, headers: headers)
            if fm.fileExists(atPath: replaced.path) { try fm.moveItem(at: replaced, to: root.appendingPathComponent("unlinked-old." + ext)) }
            try replacement.write(to: replaced)
            try rejects("destination replacement must fail") { try owned.finish() }
            try check(try Data(contentsOf: replaced) == replacement, "replacement untouched after failure")
            let dropped = root.appendingPathComponent("dropped." + ext)
            do { let pending = try NativeTargetSpreadsheetExport(stagedOutput: dropped, format: format, headers: headers); try pending.append(rows[0]) }
            try check(!fm.fileExists(atPath: dropped.path), "uncompleted deinit removes private output")
            let partialPath = root.appendingPathComponent("partial-cancel." + ext)
            var cancellationPolls = 0
            let partial = try NativeTargetSpreadsheetExport(stagedOutput: partialPath, format: format, headers: headers, cancelled: { cancellationPolls += 1; return cancellationPolls >= 5 })
            try rejects("large row cancellation is observed during byte flushing") { try partial.append([String(repeating: "a", count: 500_000)] + Array(repeating: "", count: 20)) }
            try check(cancellationPolls >= 5 && !fm.fileExists(atPath: partialPath.path), "partially emitted row is removed on cancellation")
        }
        let scale = try NativeTargetSpreadsheetExport(stagedOutput: root.appendingPathComponent("scale.xlsx"), format: .xlsx, headers: headers)
        for index in 0..<10_000 { try scale.append((0..<21).map { "日本語\(index)-\($0)" }) }
        try scale.finish()
        try check(scale.rowCount == 10_000 && scale.maximumBufferBytes <= 131_072, "ten thousand rows use bounded output buffer")
        let large = try NativeTargetSpreadsheetExport(stagedOutput: root.appendingPathComponent("large.xlsx"), format: .xlsx, headers: headers)
        try large.append([String(repeating: "大きな説明😀<&\r\n", count: 100_000)] + Array(repeating: "", count: 20))
        try large.finish(); try check(large.maximumBufferBytes <= 131_072, "multi-megabyte cell output buffer is bounded")
        let zipCancelPath = root.appendingPathComponent("zip-cancel.xlsx")
        var cancelAtZip = false, observedZip = false
        let zipCancel = try NativeTargetSpreadsheetExport(stagedOutput: zipCancelPath, format: .xlsx, headers: headers, cancelled: {
            guard cancelAtZip else { return false }
            let directories = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let present = directories.contains { $0.lastPathComponent.hasPrefix(".nextcrm-target-export-") && fm.fileExists(atPath: $0.appendingPathComponent("zip.log").path) }
            if present { observedZip = true }; return present
        })
        try zipCancel.append([String(repeating: "長い説明😀", count: 200_000)] + Array(repeating: "", count: 20))
        cancelAtZip = true
        try rejects("zip-phase cancellation must join before returning") { try zipCancel.finish() }
        try check(observedZip && !fm.fileExists(atPath: zipCancelPath.path), "zip phase ran, was cancelled, and did not deliver output")
        try check(try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).allSatisfy { !$0.lastPathComponent.hasPrefix(".nextcrm-target-export-") }, "all owned workbook staging directories cleaned")
        print("{\"checks\":\(checks),\"rows\":\(rows.count),\"scaleRows\":10000,\"maximumBufferBytes\":\(max(scale.maximumBufferBytes,large.maximumBufferBytes))}")
    }
}
