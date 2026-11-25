import Foundation
import PDFKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import SQLite3
import Darwin

@main enum DocumentProcessingTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String, _ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
    static func main() async { do { try await run() } catch { FileHandle.standardError.write(Data("DocumentProcessingTests: \(error)\n".utf8)); exit(1) } }
    static func body(_ draft: DocumentTextDraft) throws -> String { var text = ""; try draft.forEachChunk { text += $0 }; return text }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-DocumentProcessingTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/document-processing-reference.json"))) as! [String:Any]
        for test in reference["classifications"] as! [[String:Any]] { try check(NativeDocumentProcessing.classify(filename:test["name"] as! String) == test["expected"] as! String,"original filename classification") }
        for test in reference["decoding"] as! [[String:Any]] {
            let bytes = Data(base64Encoded:test["base64"] as! String)!; let size = test["size"] as! Int; var decoder = DocumentUTF8Decoder(); var text = ""
            for start in stride(from:0,to:bytes.count,by:size) { text += decoder.decode(Data(bytes[start..<min(start+size,bytes.count)])) }
            text += decoder.decode(Data(),final:true)
            try check(text == test["expected"] as! String,"original UTF8 stream decoder / \(size) / \(bytes.prefix(6).base64EncodedString())")
        }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("data/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open(); let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let service = CRMService(db:db,identity:identity); let otherConnection = CRMService(db:second,identity:identity)
        func source(_ name: String, _ data: Data) throws -> URL { let url = root.appendingPathComponent(name); try data.write(to:url); return url }
        func importFile(_ url: URL, replacing: NativeRecord? = nil) throws -> NativeRecord { try service.commitDocument(service.stageDocument(url),replacing:replacing) }
        func fresh(_ record: NativeRecord) throws -> NativeRecord { try service.documentRecord(record["id"].string) }
        func storedText(_ id: String) throws -> String { let first = try service.documentExtractedText(id); var text = first.text; if first.parts > 1 { for i in 1..<first.parts { text += try service.documentExtractedText(id,part:i).text } }; return text }
        func sql(_ text: String) throws { var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.message("test open") }; defer { sqlite3_close(c) }; guard sqlite3_exec(c,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) } }
        var now = Date(); let worker = DocumentProcessingWorker(db:db,clock:{now})
        let originalText = "日本語😀"+String(repeating:"本文と数字123、",count:10000)+"末尾"
        let originalSource = try source("契約.txt",Data(originalText.utf8)); var document = try importFile(originalSource)
        let processed = try await worker.runNext(); try check(processed,"queued document processed")
        document = try fresh(document)
        try check(document["processing_status"] == .text("READY") && document["document_system_type"] == .text("CONTRACT"),"local extraction and classification finish")
        try check(try storedText(document["id"].string) == originalText,"complete text survives chunk boundaries")
        let page = try service.documentExtractedText(document["id"].string)
        try check(page.parts > 1 && page.text.utf8.count <= 32771 && page.bytes == originalText.utf8.count,"reader pages bound text independently of document size")
        try check(document["content_text"] == .null && document["summary"] == .null,"body is not copied into large record/audit fields and no invented AI summary")
        let aiHandoff = try db.aiJobs(events:[NativeDatabase.documentAIEvent],actorID:identity.id).rows
        try check(aiHandoff.count == 1 && aiHandoff[0].payload["documentId"] == document["id"].string && aiHandoff[0].payload["sourceJob"] == db.documentProcessingJob(document),"extraction atomically hands current source generation to actor-bound AI job")
        try check(try otherConnection.documentExtractedText(document["id"].string).text == page.text,"extraction is durable across DB connections")
        let unlinked = try DocumentTextDraft(limit:4); var stat = Darwin.stat(); fstat(unlinked.descriptor,&stat)
        try check(stat.st_nlink == 0 && stat.st_mode & 0o777 == 0o600,"spool is anonymous and private")
        try unlinked.append("1234"); try rejects("spool enforces limit before write") { try unlinked.append("5") }
        try check(try body(unlinked) == "1234","limit failure preserves written bytes")
        var interrupted = 0
        try rejects("extract can be cancelled between chunks") { _ = try NativeDocumentProcessing.extract(url:originalSource,mimeType:"text/plain",checkpoint:{ interrupted += 1; if interrupted > 2 { throw CancellationError() } }) }
        let nullText = try NativeDocumentProcessing.extract(url:source("NULL.txt",Data([0x61,0,0x62])),mimeType:"text/plain")
        try check(try body(nullText.text) == "a�b","NUL is explicitly replaced for SQLite-safe text")
        let word = reference["word"] as! [String:Any]
        let extractedWord = try NativeDocumentProcessing.extract(url:URL(fileURLWithPath:word["path"] as! String),mimeType:"application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        try check(try body(extractedWord.text) == word["expected"] as! String,"native Word XML extraction matches original mammoth Japanese fixture")
        let oldWord = root.appendingPathComponent("旧形式.doc")
        let convert = Process(); convert.executableURL = URL(fileURLWithPath:"/usr/bin/textutil"); convert.arguments = ["-convert","doc","-output",oldWord.path,originalSource.path]; convert.standardOutput = FileHandle.nullDevice; convert.standardError = FileHandle.nullDevice
        try convert.run(); convert.waitUntilExit(); try check(convert.terminationStatus == 0,"OS converter prepares real legacy Word fixture")
        // The OS exporter produces an unreadable legacy file for this very
        // long single paragraph. Its importer reports the error with exit 0.
        try rejects("legacy converter stderr cannot become false READY") { _ = try NativeDocumentProcessing.extract(url:oldWord,mimeType:"application/msword") }
        let oldWordSource = try source("旧Wordの原文.txt",Data("日本語😀の旧Word本文\n二行目".utf8))
        let validOldWord = root.appendingPathComponent("有効な旧形式.doc")
        let smallConvert = Process(); smallConvert.executableURL = URL(fileURLWithPath:"/usr/bin/textutil"); smallConvert.arguments = ["-convert","doc","-output",validOldWord.path,oldWordSource.path]; smallConvert.standardError = FileHandle.nullDevice
        try smallConvert.run(); smallConvert.waitUntilExit(); guard smallConvert.terminationStatus == 0 else { throw NativeDBError.message("legacy fixture") }
        let oldWordText = try body(NativeDocumentProcessing.extract(url:validOldWord,mimeType:"application/msword").text)
        try check(oldWordText.contains("日本語😀の旧Word本文\n二行目"),"valid legacy binary Word extraction preserves Japanese text")
        try rejects("declared legacy Word cannot silently be interpreted as plain text") { _ = try NativeDocumentProcessing.extract(url:source("偽のWord.doc",Data("plain text".utf8)),mimeType:"application/msword") }
        let untrustedWord = root.appendingPathComponent("外部参照.docx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        zip.arguments = ["-c","import zipfile,sys\nwith zipfile.ZipFile(sys.argv[1],'w') as z: z.writestr('word/document.xml',sys.argv[2])",untrustedWord.path,"<!DOCTYPE document [<!ENTITY secret SYSTEM 'file:///nonexistent/never-read'>]><w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>&secret;</w:t></w:r></w:p></w:body></w:document>"]
        try zip.run(); zip.waitUntilExit(); guard zip.terminationStatus == 0 else { throw NativeDBError.message("XML fixture") }
        try rejects("Word entities cannot resolve arbitrary external files") { _ = try NativeDocumentProcessing.extract(url:untrustedWord,mimeType:"application/vnd.openxmlformats-officedocument.wordprocessingml.document") }
        let pdfURL = root.appendingPathComponent("提案.pdf"); var bounds = CGRect(x:0,y:0,width:400,height:400)
        guard let pdf = CGContext(pdfURL as CFURL,mediaBox:&bounds,nil) else { throw NativeDBError.message("PDF fixture") }
        for text in ["日本語の提案書 1000円","二ページ目の条件"] {
            pdf.beginPDFPage(nil); pdf.textPosition = CGPoint(x:30,y:300)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.font:CTFontCreateWithName("HiraginoSans-W3" as CFString,16,nil)]))
            CTLineDraw(line,pdf); pdf.endPDFPage()
        }; pdf.closePDF()
        let pdfText = try body(NativeDocumentProcessing.extract(url:pdfURL,mimeType:"application/pdf").text)
        try check(pdfText.contains("日本語の提案書") && pdfText.contains("二ページ目の条件"),"native PDF extraction covers both Japanese pages")
        let scannedURL = root.appendingPathComponent("文字のないPDF.pdf")
        let scanned = CGContext(scannedURL as CFURL,mediaBox:&bounds,nil)!
        for _ in 0..<2 { scanned.beginPDFPage(nil); scanned.setFillColor(CGColor(gray:0.5,alpha:1)); scanned.fill(CGRect(x:10,y:10,width:100,height:100)); scanned.endPDFPage() }; scanned.closePDF()
        let scanResult = try NativeDocumentProcessing.extract(url:scannedURL,mimeType:"application/pdf")
        try check(scanResult.text.bytes == 0 && scanResult.note.contains("文字認識"),"image-only PDF pages do not become fictitious separator text")
        let imageURL = root.appendingPathComponent("領収書.png")
        let bitmap = CGContext(data:nil,width:400,height:200,bitsPerComponent:8,bytesPerRow:1600,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); bitmap.fill(CGRect(x:0,y:0,width:400,height:200))
        let dest = CGImageDestinationCreateWithURL(imageURL as CFURL,UTType.png.identifier as CFString,1,nil)!; CGImageDestinationAddImage(dest,bitmap.makeImage()!,nil); guard CGImageDestinationFinalize(dest) else { throw NativeDBError.message("image fixture") }
        let imageDocument = try importFile(imageURL); _ = try await worker.runNext()
        let imagePage = try service.documentExtractedText(imageDocument["id"].string,thumbnail:true)
        let imageSource = CGImageSourceCreateWithData(imagePage.thumbnail! as CFData,nil)!; let thumb = CGImageSourceCreateImageAtIndex(imageSource,0,nil)!
        try check(thumb.width == 200 && thumb.height == 200 && imagePage.parts == 0 && imagePage.ready,"200x200 image result without invented OCR")
        try check(try service.documentExtractedText(imageDocument["id"].string).thumbnail == nil,"ordinary text metadata reads do not load thumbnail bytes")
        let unsupported = try importFile(source("記録.bin",Data([1,2,3]))); _ = try await worker.runNext()
        try check(try fresh(unsupported)["processing_status"] == .text("READY") && !service.documentExtractedText(unsupported["id"].string).note.isEmpty,"unsupported text format is classified and explained")
        document = try importFile(source("新版.txt",Data("新版の本文".utf8)),replacing:document)
        let old = try service.documentVersions(document["id"].string).rows.first { $0["version"] == .integer(1) }!
        try check(try storedText(old["id"].string) == originalText,"archived version keeps its extracted text")
        try check(try !service.documentExtractedText(document["id"].string).ready,"new version cannot expose old text")
        _ = try await worker.runNext(); document = try fresh(document)
        try check(try storedText(document["id"].string) == "新版の本文","new version gets its own extraction")

        try service.retryDocumentProcessing(document)
        var edited = false
        let editingWorker = DocumentProcessingWorker(db:db,clock:{now},extract:{ url,type,check in
            if !edited { edited = true; _ = try otherConnection.updateDocument(otherConnection.documentRecord(document["id"].string),changes:["document_system_type":.text("OFFER")]) }
            return try NativeDocumentProcessing.extract(url:url,mimeType:type,checkpoint:check)
        }); _ = try await editingWorker.runNext(); document = try fresh(document)
        try check(document["document_system_type"] == .text("OFFER"),"manual category edit wins a processing race")

        try service.retryDocumentProcessing(document); let priorJob = try db.documentProcessingJob(fresh(document))!
        let replacingWorker = DocumentProcessingWorker(db:db,clock:{now},extract:{ url,type,check in
            let result = try NativeDocumentProcessing.extract(url:url,mimeType:type,checkpoint:check)
            _ = try otherConnection.commitDocument(otherConnection.stageDocument(source("競合版.txt",Data("競合で追加した版".utf8))),replacing:otherConnection.documentRecord(document["id"].string))
            return result
        }); _ = try await replacingWorker.runNext(); document = try fresh(document)
        try check(document["processing_status"] == .text("PENDING") && (try db.job(id:priorJob))?.result["outcome"] == "skipped","old extraction cannot complete a newly replaced file")
        try check(try !service.documentExtractedText(document["id"].string).ready,"stale result never publishes its body")
        _ = try await worker.runNext(); document = try fresh(document)
        try check(try storedText(document["id"].string) == "競合で追加した版","replacement later processes normally")

        try service.retryDocumentProcessing(document); let superseded = try db.documentProcessingJob(fresh(document))!
        let retryingWorker = DocumentProcessingWorker(db:db,clock:{now},extract:{ url,type,check in
            let result = try NativeDocumentProcessing.extract(url:url,mimeType:type,checkpoint:check)
            try otherConnection.retryDocumentProcessing(otherConnection.documentRecord(document["id"].string)); return result
        }); _ = try await retryingWorker.runNext()
        try check(try db.job(id:superseded)?.result["outcome"] == "skipped" && fresh(document)["processing_status"] == .text("PENDING"),"new retry fences previous processing of the same file")
        _ = try await worker.runNext(); document = try fresh(document)

        try service.retryDocumentProcessing(document); var reclaimed: NativeJob?
        let staleWorker = DocumentProcessingWorker(db:db,clock:{now},extract:{ url,type,check in
            let result = try NativeDocumentProcessing.extract(url:url,mimeType:type,checkpoint:check)
            reclaimed = try second.claimJob(events:DocumentProcessingWorker.events,now:now.addingTimeInterval(1000)); return result
        }); _ = try await staleWorker.runNext()
        try check(reclaimed != nil && (try db.job(id:reclaimed!.id))?.leaseToken == reclaimed!.leaseToken && (try db.job(id:reclaimed!.id))?.status == "running","expired worker cannot complete a reclaimed lease")
        try second.failJob(reclaimed!,message:"resume fixture",retryAt:now); _ = try await worker.runNext(); document = try fresh(document)

        try service.retryDocumentProcessing(document)
        try sql("CREATE TRIGGER fail_document_text BEFORE INSERT ON native_document_text BEGIN SELECT RAISE(ABORT,'fixture text commit'); END")
        _ = try await worker.runNext()
        try check(try storedText(document["id"].string) == "競合で追加した版" && fresh(document)["processing_status"] == .text("PENDING"),"failed chunk publication rolls back and preserves earlier complete result")
        try sql("DROP TRIGGER fail_document_text"); now = now.addingTimeInterval(400); _ = try await worker.runNext(); document = try fresh(document)
        try check(document["processing_status"] == .text("READY"),"durable retry recovers after save failure")

        let bad = try importFile(source("破損.pdf",Data("not a PDF".utf8)))
        for _ in 0..<4 { now = now.addingTimeInterval(400); _ = try await worker.runNext() }
        let failed = try fresh(bad); let failedJob = try db.job(id:db.documentProcessingJob(failed)!)!
        try check(failed["processing_status"] == .text("FAILED") && failedJob.status == "failed" && failedJob.attempts == 4,"invalid parser input exhausts original three retries and reports failure")
        try service.retryDocumentProcessing(failed)
        try check(try fresh(bad)["processing_status"] == .text("PENDING") && db.documentProcessingJob(fresh(bad)) != failedJob.id,"explicit retry gets a new fenced generation")
        try service.deleteDocuments([fresh(bad)]); _ = try await worker.runNext()

        let actor = try db.insert("Users",values:["name":.text("文書担当"),"email":.text("doc@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let owner = CRMService(db:db,identity:CRMIdentity(id:actor["id"].string,role:"user",partnerAccountID:nil))
        let privateDoc = try owner.commitDocument(owner.stageDocument(originalSource)); _ = try db.update(actor,changes:["banned":.integer(1)],actor:identity.id)
        var called = 0
        let denied = DocumentProcessingWorker(db:db,clock:{now},extract:{ _,_,_ in called += 1; return NativeDocumentExtraction(text:try DocumentTextDraft(),note:"") })
        _ = try await denied.runNext()
        try check(called == 0 && (try fresh(privateDoc))["processing_status"] == .text("FAILED"),"revoked actor is checked before reading source contents")
        try rejects("revoked reader cannot fetch extracted text") { _ = try owner.documentExtractedText(document["id"].string) }
        _ = try db.update(db.get("Users",key:["id":actor["id"]])!,changes:["banned":.integer(0)],actor:identity.id)
        try owner.retryDocumentProcessing(owner.documentRecord(privateDoc["id"].string))
        let revokingWorker = DocumentProcessingWorker(db:db,clock:{now},extract:{ url,type,check in
            let result = try NativeDocumentProcessing.extract(url:url,mimeType:type,checkpoint:check)
            _ = try second.update(second.get("Users",key:["id":actor["id"]])!,changes:["banned":.integer(1)],actor:identity.id); return result
        }); _ = try await revokingWorker.runNext()
        try check(try !service.documentExtractedText(privateDoc["id"].string).ready && fresh(privateDoc)["processing_status"] == .text("FAILED"),"authorization is checked again before publishing extracted content")
        let legacyBody = String(repeating:"旧形式の本文😀",count:3000)
        let legacy = try db.insert("Documents",values:["document_name":.text("移行済みの本文"),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("legacy:test"),"content_text":.text(legacyBody),"processing_status":.text("READY")],actor:identity.id)
        try check(try storedText(legacy["id"].string) == legacyBody && service.documentExtractedText(legacy["id"].string).text.count <= 8192,"legacy text can be read in bounded SQL substrings")
        try service.deleteDocuments([document])
        try check(try !db.documentTextPage(old["id"].string).ready,"version deletion cascades extracted text")
        try check(try db.integrityCheck(),"processing table migration and all foreign keys remain valid")
        print("Document processing: \(checks) checks passed; source classification20/UTF8 decoding45/Word extraction; native PDF/image, fenced local jobs, temporary data only")
    }
}
