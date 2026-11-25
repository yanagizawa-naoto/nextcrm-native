import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// UTF-8 carry is at most three bytes. Invalid sequences follow the usual
/// replacement-character decoding; complete text never accumulates here.
struct DocumentUTF8Decoder {
    private var carry = Data()
    mutating func decode(_ data: Data, final: Bool = false) -> String {
        var bytes = carry; bytes.append(data); carry.removeAll(keepingCapacity:true)
        if !final, !bytes.isEmpty {
            var start = bytes.count-1
            while start > 0 && bytes[start] & 0xc0 == 0x80 && bytes.count-start < 4 { start -= 1 }
            let lead = bytes[start]
            let expected = (0xc2...0xdf).contains(lead) ? 2 : (0xe0...0xef).contains(lead) ? 3 : (0xf0...0xf4).contains(lead) ? 4 : 1
            if expected > bytes.count-start { carry = Data(bytes[start...]); bytes.removeSubrange(start...) }
        }
        return String(decoding:bytes,as:UTF8.self)
    }
}

/// Anonymous disk spool. fclose/process exit removes it, including crashes;
/// it never creates a named cache that needs a subsequent cleanup scan.
final class DocumentTextDraft {
    static let chunkBytes = 32 * 1024
    static let maximumBytes = 256 * 1024 * 1024
    private let stream: UnsafeMutablePointer<FILE>
    private let limit: Int
    let descriptor: Int32
    private(set) var bytes = 0
    init(limit: Int = DocumentTextDraft.maximumBytes) throws {
        guard limit > 0, limit <= Self.maximumBytes else { throw NativeDBError.message("本文の一時保存の上限が不正です。") }
        guard let stream = tmpfile() else { throw NativeDBError.message("文書処理用の一時保存を作成できません。") }
        let fd = fileno(stream)
        guard fchmod(fd,0o600) == 0, fcntl(fd,F_SETFD,FD_CLOEXEC) == 0 else { fclose(stream); throw NativeDBError.message("文書処理用の一時保存を保護できません。") }
        self.stream = stream; descriptor = fd; self.limit = limit
    }
    deinit { fclose(stream) }
    func append(_ text: String) throws { try appendBytes(Data(text.replacingOccurrences(of:"\0",with:"�").utf8)) }
    func appendBytes(_ data: Data) throws {
        guard data.count <= limit-bytes else { throw NativeDBError.message("抽出した本文が保存上限を超えています（通常256MiB）。文書を分割して取り込んでください。") }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(descriptor,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw NativeDBError.message("文書の本文を一時保存できません。空き容量を確認してください。") }; offset += n
            }
        }; bytes += data.count
    }
    func rewind() throws { guard lseek(descriptor,0,SEEK_SET) == 0 else { throw NativeDBError.message("文書の本文を読み直せません。") } }
    func forEachChunk(_ visit: (String) throws -> Void) throws {
        try rewind(); let input = FileHandle(fileDescriptor:descriptor,closeOnDealloc:false); var decoder = DocumentUTF8Decoder()
        while true {
            let more = try autoreleasepool { () -> Bool in
                let data = try input.read(upToCount:Self.chunkBytes) ?? Data()
                if data.isEmpty { let tail = decoder.decode(Data(),final:true); if !tail.isEmpty { try visit(tail) }; return false }
                let text = decoder.decode(data); if !text.isEmpty { try visit(text) }; return true
            }; if !more { break }
        }
    }
}

struct NativeDocumentExtraction {
    let text: DocumentTextDraft
    var thumbnail: Data?
    var note: String
}

enum NativeDocumentProcessing {
    static func classify(filename: String) -> String {
        let name = filename.lowercased()
        for (type,words) in [("RECEIPT",["invoice","receipt","bill","payment","請求","領収","支払"]),
                             ("CONTRACT",["contract","agreement","nda","terms","契約","規約"]),
                             ("OFFER",["offer","quote","proposal","estimate","見積","提案"])] {
            if words.contains(where:name.contains) { return type }
        }; return "OTHER"
    }
    static func extract(url: URL, mimeType: String, svgWorker: URL? = nil, checkpoint: @escaping () throws -> Void = {}) throws -> NativeDocumentExtraction {
        let draft = try DocumentTextDraft(); var result = NativeDocumentExtraction(text:draft,note:"")
        try checkpoint()
        switch mimeType {
        case "text/plain":
            let input = try FileHandle(forReadingFrom:url); defer { try? input.close() }
            try readText(input,to:draft,checkpoint:checkpoint)
        case "application/pdf":
            guard let pdf = PDFDocument(url:url), !pdf.isLocked else { throw NativeDBError.message("PDFを開けません。破損やパスワード保護を確認してください。") }
            var hasText = false
            for page in 0..<pdf.pageCount {
                try autoreleasepool {
                    try checkpoint()
                    guard let item = pdf.page(at:page) else { throw NativeDBError.message("PDFのページを読み取れません。") }
                    if let text = item.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        if hasText { try draft.append("\n\n") }; try draft.append(text); hasText = true
                    }
                }
            }
            if draft.bytes == 0 { result.note = "このPDFには抽出できる文字がありません。画像の文字認識は未対応です。" }
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            let xml = try DocumentTextDraft(); var declarations = WordXMLDeclarations()
            try run("/usr/bin/unzip",arguments:["-p",url.path,"word/document.xml"],checkpoint:checkpoint) { try declarations.check($0); try xml.appendBytes($0) }
            try xml.rewind()
            guard let input = InputStream(fileAtPath:"/dev/fd/\(xml.descriptor)") else { throw NativeDBError.message("Word文書の本文を開けません。") }
            let parser = XMLParser(stream:input); let delegate = WordTextReader(draft:draft,checkpoint:checkpoint)
            parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), delegate.failure == nil else { throw delegate.failure ?? NativeDBError.message("Word文書の本文が不正です。") }
        case "application/msword":
            // The legacy binary format uses the OS converter only while a job
            // is active; no helper/server is kept running after conversion.
            var decoder = DocumentUTF8Decoder()
            try run("/usr/bin/textutil",arguments:["-convert","txt","-format","doc","-stdout","-encoding","UTF-8",url.path],checkpoint:checkpoint) { try draft.append(decoder.decode($0)) }
            try draft.append(decoder.decode(Data(),final:true))
        default:
            result.note = mimeType.hasPrefix("image/") ? "画像の文字認識は未対応です。" : "この形式は本文抽出の対象外です。元のファイルは保存されています。"
        }
        if mimeType == "image/svg+xml" { result.thumbnail = try svgThumbnail(url, worker:svgWorker, checkpoint:checkpoint) }
        else if mimeType.hasPrefix("image/") { result.thumbnail = try thumbnail(url) }
        try checkpoint(); return result
    }
    private static func readText(_ input: FileHandle, to output: DocumentTextDraft, checkpoint: () throws -> Void) throws {
        var decoder = DocumentUTF8Decoder()
        while true {
            let more = try autoreleasepool { () -> Bool in
                try checkpoint(); let data = try input.read(upToCount:DocumentTextDraft.chunkBytes) ?? Data()
                if data.isEmpty { try output.append(decoder.decode(Data(),final:true)); return false }
                try output.append(decoder.decode(data)); return true
            }; if !more { break }
        }
    }
    private static func run(_ executable: String, arguments: [String], checkpoint: () throws -> Void, consume: (Data) throws -> Void) throws {
        let process = Process(); let pipe = Pipe(); let diagnostics = try DocumentTextDraft()
        process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle(fileDescriptor:diagnostics.descriptor,closeOnDealloc:false); process.standardInput = FileHandle.nullDevice
        try process.run(); try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
        while true {
            let more = try autoreleasepool { () -> Bool in
                try checkpoint(); let data = try pipe.fileHandleForReading.read(upToCount:DocumentTextDraft.chunkBytes) ?? Data()
                if data.isEmpty { return false }; try consume(data); return true
            }; if !more { break }
        }
        process.waitUntilExit()
        try diagnostics.rewind()
        let diagnostic = try FileHandle(fileDescriptor:diagnostics.descriptor,closeOnDealloc:false).read(upToCount:4096) ?? Data()
        // macOS textutil can return exit 0 even when it reports a parse error
        // on stderr. Do not mark an empty/partial result as successfully read.
        guard process.terminationStatus == 0, diagnostic.isEmpty else { throw NativeDBError.message("Word文書を変換できません。ファイルの形式や破損を確認してください。") }
    }
    private static func svgThumbnail(_ url: URL, worker: URL?, checkpoint: () throws -> Void) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw NativeDBError.message("SVG画像の保存場所が不正です。") }
        let executable = worker ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NextCRMDocumentSVG")
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath:executable.path) else { throw NativeDBError.message("SVG描画用の補助プログラムがありません。アプリを入れ直してください。") }
        let source = url.resolvingSymlinksInPath()
        let fd = open(source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw NativeDBError.message("SVG画像を開けません。") }
        let input = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? input.close() }
        func quote(_ value: String) throws -> String {
            String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes]),as:UTF8.self)
        }
        let readable = ["/System/Library","/usr/lib","/usr/share","/Library/Fonts","/Library/Apple/System","/private/var/db/dyld","/System/Volumes/Preboot/Cryptexes/OS/System/Library","/System/Volumes/Preboot/Cryptexes/OS/usr/lib"]
        let profile = "(version 1)(allow default)(deny network*)(deny file-read*)(deny file-write*)(allow file-read-metadata)(allow file-read-data (literal \"/\"))(allow file-read* " + (try readable.map { "(subpath " + (try quote($0)) + ")" }.joined()) + "(literal " + (try quote(source.path)) + ")(literal " + (try quote(executable.path)) + ")(literal \"/dev/null\"))"
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath:"/usr/bin/sandbox-exec")
        child.arguments = ["-p",profile,executable.path,"--parent",String(getpid())]
        child.standardInput = input; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        let output = pipe.fileHandleForReading
        guard fcntl(output.fileDescriptor,F_SETFL,O_NONBLOCK) == 0 else { throw NativeDBError.message("SVG描画の出力を準備できません。") }
        try checkpoint(); try child.run(); try? pipe.fileHandleForWriting.close()
        defer {
            if child.isRunning { child.terminate(); let until=ProcessInfo.processInfo.systemUptime+0.2
                while child.isRunning && ProcessInfo.processInfo.systemUptime < until { usleep(5_000) }
                if child.isRunning { kill(child.processIdentifier,SIGKILL) }
            }
            child.waitUntilExit();try? output.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var data = Data(), buffer = [UInt8](repeating:0,count:32*1024)
        while true {
            try checkpoint()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeDBError.message("SVG画像の描画が制限時間を超えました。画像を簡単にして再試行してください。") }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor,$0.baseAddress,$0.count) }
            if count > 0 {
                guard count <= 1024*1024-data.count else { throw NativeDBError.message("SVG画像の縮小表示が上限を超えています。") }
                data.append(contentsOf:buffer.prefix(count));continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            guard errno == EAGAIN else { throw NativeDBError.message("SVG画像の描画結果を読み取れません。") }
            usleep(10_000)
        }
        while child.isRunning {
            try checkpoint()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeDBError.message("SVG画像の描画を完了できません。") }
            usleep(10_000)
        }
        child.waitUntilExit()
        guard child.terminationStatus == 0,
              let decoded = CGImageSourceCreateWithData(data as CFData,nil),
              CGImageSourceGetCount(decoded) == 1, CGImageSourceGetType(decoded) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(decoded,0,nil) as? [CFString:Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 200,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 200 else { throw NativeDBError.message("SVG画像を読み取れません。外部ファイルや通信を必要とする画像は単独のSVGにしてください。") }
        try checkpoint();return data
    }
    private static func thumbnail(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { throw NativeDBError.message("画像を読み取れません。") }
        // Downsample before drawing a center crop, matching the original
        // 200x200 cover layout. Cap extreme-aspect intermediate images.
        let ratio = max(width.doubleValue,height.doubleValue)/min(width.doubleValue,height.doubleValue)
        let edge = min(4096,max(200,ceil(200*ratio)))
        let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:edge,kCGImageSourceShouldCacheImmediately:false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary),
              let context = CGContext(data:nil,width:200,height:200,bitsPerComponent:8,bytesPerRow:200*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NativeDBError.message("画像の縮小表示を作成できません。") }
        let scale = max(200/CGFloat(image.width),200/CGFloat(image.height)); let w = CGFloat(image.width)*scale; let h = CGFloat(image.height)*scale
        context.interpolationQuality = .high; context.draw(image,in:CGRect(x:(200-w)/2,y:(200-h)/2,width:w,height:h))
        let data = NSMutableData()
        guard let cropped = context.makeImage(), let target = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw NativeDBError.message("画像の縮小表示を保存できません。") }
        CGImageDestinationAddImage(target,cropped,nil)
        guard CGImageDestinationFinalize(target) else { throw NativeDBError.message("画像の縮小表示を保存できません。") }; return data as Data
    }
}

/// WordprocessingML does not need a DTD. Reject declarations before parsing;
/// XMLParser can silently omit external-entity delegate callbacks when entity
/// resolution is disabled. Keep only enough bytes to span a read boundary.
private struct WordXMLDeclarations {
    private static let patterns = ["<!DOCTYPE","<!ENTITY"].flatMap { word in
        [String.Encoding.utf8,.utf16LittleEndian,.utf16BigEndian,.utf32LittleEndian,.utf32BigEndian].map { word.data(using:$0)! }
    }
    private var tail = Data()
    mutating func check(_ data: Data) throws {
        var block = tail; block.append(data)
        guard !Self.patterns.contains(where:{block.range(of:$0) != nil}) else { throw NativeDBError.message("外部参照や独自の実体宣言を含むWord文書は処理できません。") }
        tail = Data(block.suffix(35))
    }
}

private final class WordTextReader: NSObject, XMLParserDelegate {
    let draft: DocumentTextDraft; let checkpoint: () throws -> Void
    var failure: Error?; private var textDepth = 0; private var depth = 0
    private var skippedDepth = 0
    private var alternateContent: [(depth: Int, usedFallback: Bool)] = []
    init(draft: DocumentTextDraft, checkpoint: @escaping () throws -> Void) { self.draft = draft; self.checkpoint = checkpoint }
    private func apply(_ parser: XMLParser, _ action: () throws -> Void) { do { try checkpoint(); try action() } catch { failure = error; parser.abortParsing() } }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        depth += 1
        guard depth <= 256 else { failure = NativeDBError.message("Word文書の構造が深すぎます。"); parser.abortParsing(); return }
        if skippedDepth > 0 { return }
        let compatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"
        if let parent = alternateContent.last, depth == parent.depth + 1 {
            guard namespaceURI == compatibility, name == "Fallback", !parent.usedFallback else { skippedDepth = depth; return }
            alternateContent[alternateContent.count-1].usedFallback = true
        }
        if namespaceURI == compatibility && name == "AlternateContent" { alternateContent.append((depth,false)); return }
        guard namespaceURI == "http://schemas.openxmlformats.org/wordprocessingml/2006/main" || namespaceURI == "http://purl.oclc.org/ooxml/wordprocessingml/main" else { return }
        if name == "t" { textDepth = depth }
        if name == "tab" { apply(parser) { try draft.append("\t") } }
        if name == "br" || name == "cr" { apply(parser) { try draft.append("\n") } }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if skippedDepth == 0 && textDepth > 0 { apply(parser) { try draft.append(string) } } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skippedDepth > 0 { if depth == skippedDepth { skippedDepth = 0 }; depth -= 1; return }
        if alternateContent.last?.depth == depth { alternateContent.removeLast() }
        if depth == textDepth { textDepth = 0 }
        if name == "p", namespaceURI == "http://schemas.openxmlformats.org/wordprocessingml/2006/main" || namespaceURI == "http://purl.oclc.org/ooxml/wordprocessingml/main" { apply(parser) { try draft.append("\n\n") } }
        depth -= 1
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { failure = NativeDBError.message("外部参照や独自の実体宣言を含むWord文書は処理できません。"); parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { failure = NativeDBError.message("外部参照を含むWord文書は処理できません。"); parser.abortParsing() }
}
