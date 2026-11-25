import Foundation
import Darwin

/// The AppKit CRM does not link WebKit. A viewer receives only this immutable
/// body over a private pipe; no database path, account secret or temporary HTML.
struct NativeMailHTMLDocument {
    static let maximumBytes = 8_388_608
    let subject:String, html:String
    init(subject:String,html:String) throws {
        guard !html.isEmpty, html.utf8.count <= Self.maximumBytes else { throw NativeMailHTMLError.invalid }
        self.subject = String(subject.prefix(512)); self.html = html
    }
    private struct Header:Codable { let version:Int, length:Int, subject:String }
    func write(to handle:FileHandle) throws {
        guard fcntl(handle.fileDescriptor,F_SETNOSIGPIPE,1) == 0 else { throw NativeMailHTMLError.invalid }
        var header = try JSONEncoder().encode(Header(version:1,length:html.utf8.count,subject:subject)); header.append(10)
        try handle.write(contentsOf:header)
        var chunk = Data(); chunk.reserveCapacity(32_768)
        for byte in html.utf8 {
            chunk.append(byte)
            if chunk.count == 32_768 { try handle.write(contentsOf:chunk); chunk.removeAll(keepingCapacity:true) }
        }
        if !chunk.isEmpty { try handle.write(contentsOf:chunk) }
    }
    static func read(from handle:FileHandle) throws -> NativeMailHTMLDocument {
        var metadata = Data()
        while true {
            guard let byte = try handle.read(upToCount:1)?.first else { throw NativeMailHTMLError.invalid }
            if byte == 10 { break }; metadata.append(byte)
            guard metadata.count <= 8192 else { throw NativeMailHTMLError.invalid }
        }
        let header = try JSONDecoder().decode(Header.self,from:metadata)
        guard header.version == 1, (1...maximumBytes).contains(header.length), header.subject.count <= 512 else { throw NativeMailHTMLError.invalid }
        var bytes = Data(); bytes.reserveCapacity(header.length)
        while bytes.count < header.length {
            guard let chunk = try handle.read(upToCount:min(32_768,header.length-bytes.count)), !chunk.isEmpty else { throw NativeMailHTMLError.invalid }
            bytes.append(chunk)
        }
        guard (try handle.read(upToCount:1) ?? Data()).isEmpty, let html = String(data:bytes,encoding:.utf8) else { throw NativeMailHTMLError.invalid }
        return try .init(subject:header.subject,html:html)
    }
}
enum NativeMailHTMLError:LocalizedError {
    case invalid, unavailable
    var errorDescription:String? { self == .invalid ? "HTMLメールを表示できません。本文の形式またはサイズを確認してください。" : "HTML表示を起動できませんでした。もう一度お試しください。" }
}
protocol NativeMailHTMLViewing:AnyObject { func close() }
protocol NativeMailHTMLDrainingViewing:NativeMailHTMLViewing {
    /// Completion is delivered on main only after the helper and pipe writer end.
    func closeAndDrain(_ completion:@escaping () -> Void)
}

final class NativeMailHTMLSession:NativeMailHTMLDrainingViewing {
    private let process = Process()
    private let lifecycle = DispatchGroup(), state = NSLock()
    private var closed = false
    private var isClosed:Bool { state.lock();defer{state.unlock()};return closed }
    init(document:NativeMailHTMLDocument,onFailure:@escaping () -> Void) throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NextCRM Mail Viewer.app/Contents/MacOS/NextCRMMailViewer")
        guard FileManager.default.isExecutableFile(atPath:url.path) else { throw NativeMailHTMLError.unavailable }
        let input = Pipe(); process.executableURL = url; process.standardInput = input
        process.environment = ["PATH":"/usr/bin:/bin","LANG":"ja_JP.UTF-8"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let lifecycle = lifecycle
        lifecycle.enter(); lifecycle.enter()
        process.terminationHandler = { [weak self] child in
            lifecycle.leave()
            DispatchQueue.main.async { guard let self, !self.isClosed, child.terminationStatus != 0 else { return }; onFailure() }
        }
        do { try process.run() } catch { process.terminationHandler = nil; lifecycle.leave();lifecycle.leave();try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close(); throw NativeMailHTMLError.unavailable }
        try? input.fileHandleForReading.close()
        DispatchQueue.global(qos:.utility).async {
            defer { try? input.fileHandleForWriting.close();lifecycle.leave() }
            // A closed/killed viewer breaks the pipe without SIGPIPE terminating CRM.
            try? document.write(to:input.fileHandleForWriting)
        }
    }
    func close() { state.lock();closed = true;state.unlock();if process.isRunning { process.terminate() } }
    func closeAndDrain(_ completion:@escaping () -> Void) {
        close();lifecycle.notify(queue:.main,execute:completion)
    }
    deinit { close() }
}
