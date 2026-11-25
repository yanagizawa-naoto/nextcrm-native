import Foundation
import Darwin

@main enum GuardTests {
    static var checks=0
    static func check(_ condition:Bool,_ label:String) throws { guard condition else { throw NativeDBError.message(label) };checks += 1 }
    static func reject(_ action:() throws -> Void) throws {
        do { try action() } catch { checks += 1;return };throw NativeDBError.message("Unexpected acceptance")
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),svg=root.appendingPathComponent("fixtures/solid.svg")
        let worker=root.appendingPathComponent("NextCRMDocumentSVG")
        _ = try NativeDocumentProcessing.extract(url:svg,mimeType:"image/svg+xml",svgWorker:worker)
        let before=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        try reject { _ = try NativeDocumentProcessing.extract(url:svg,mimeType:"image/svg+xml",svgWorker:root.appendingPathComponent("absent")) }
        try reject { _ = try NativeDocumentProcessing.extract(url:URL(string:"https://example.invalid"+svg.path)!,mimeType:"image/svg+xml",svgWorker:worker) }
        try reject { _ = try NativeDocumentProcessing.extract(url:svg,mimeType:"image/svg+xml",svgWorker:URL(string:"https://example.invalid"+worker.path)!) }
        for name in ["FakeSVGInvalid","FakeSVGOversized"] {
            try reject { _ = try NativeDocumentProcessing.extract(url:svg,mimeType:"image/svg+xml",svgWorker:root.appendingPathComponent(name)) }
        }
        for data in [Data("not XML".utf8),Data("<!DOCTYPE svg [<!ENTITY x 'large'>]><svg xmlns=\"http://www.w3.org/2000/svg\">&x;</svg>".utf8)] {
            let file=root.appendingPathComponent("fixtures/rejected.svg");try data.write(to:file)
            try reject { _ = try NativeDocumentProcessing.extract(url:file,mimeType:"image/svg+xml",svgWorker:worker) }
        }
        do {
            _ = try NativeDocumentProcessing.extract(url:svg,mimeType:"image/svg+xml",svgWorker:worker,checkpoint:{ throw CancellationError() })
            throw NativeDBError.message("Pre-cancel accepted")
        } catch is CancellationError { checks += 1 }
        let start=ProcessInfo.processInfo.systemUptime
        do {
            _ = try NativeDocumentProcessing.extract(url:svg,mimeType:"image/svg+xml",svgWorker:root.appendingPathComponent("FakeSVGHang"),checkpoint:{
                if ProcessInfo.processInfo.systemUptime-start > 0.25 { throw CancellationError() }
            })
            throw NativeDBError.message("Cancellation accepted")
        } catch is CancellationError { checks += 1 }
        let cancelled=ProcessInfo.processInfo.systemUptime-start
        try check(cancelled<1.2,"Cancellation must kill and join a TERM-ignoring child")
        let timeoutStart=ProcessInfo.processInfo.systemUptime
        try reject { _ = try NativeDocumentProcessing.extract(url:svg,mimeType:"image/svg+xml",svgWorker:root.appendingPathComponent("FakeSVGHang")) }
        let timed=ProcessInfo.processInfo.systemUptime-timeoutStart
        try check(timed>=20 && timed<21.5,"Timed child must be killed and joined")
        let after=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        try check(after<=before+2,"File descriptors must not accumulate")
        let report:[String:Any]=["checks":checks,"cancelSeconds":cancelled,"timeoutSeconds":timed,"beforeFDs":before,"afterFDs":after]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("guards.json"))
        print("SVG guards: \(checks) checks")
    }
}
