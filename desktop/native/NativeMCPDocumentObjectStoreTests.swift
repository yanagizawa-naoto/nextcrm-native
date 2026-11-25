import Foundation
import CryptoKit

@main enum NativeMCPDocumentObjectStoreTests {
    enum Failure: Error { case assertion(String), injected }
    static var checks=0
    static func check(_ ok:Bool,_ name:String)throws {guard ok else{throw Failure.assertion(name)};checks+=1}
    static func rejects(_ label:String,_ body:()throws->Void)throws {do{try body();throw Failure.assertion(label)}catch is NativeDBError{checks+=1}catch is NativeMCPFailure{checks+=1}}
    static func id(_ n:Int)->String{"00000000-0000-4000-8000-"+String(format:"%012d",n)}
    static func read(_ reader:NativeMCPDocumentObjectReader)throws->Data {var data=Data();while let part=try reader.readChunk(){try check(part.count<=256*1024,"bounded reader");data.append(part)};return data}
    static func main()async {do{try await run();print("Native document object integration: \(checks) checks passed")}catch{fputs("After \(checks): \(error)\n",stderr);exit(1)}}
    static func run()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=try NativeMCPAccountsFixture(resources:resources)
        defer{fixture.close()}
        let db=fixture.db,alice=CRMService(db:db,identity:CRMIdentity(id:id(1),role:"user",partnerAccountID:nil))
        let signer=try NativeMCPDocumentLocalSigner(appURL:"http://127.0.0.1:45678",secret:"isolated-object-store-secret")
        let store=try NativeMCPDocumentObjectStore(db:db,bucket:"fixture-bucket",signer:signer)
        let key="documents/"+id(2001)+".txt",body=Data("日本語本文\nline two\0binary".utf8)
        let doc=try db.insert("Documents",values:["id":.text(id(2001)),"document_name":.text("MCP document"),"created_by_user":.text(id(1)),"createdBy":.text(id(1)),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("http://fixture.invalid/fixture-bucket/"+key),"key":.text(key)],actor:id(1))
        let signed=try signer.url(key:key,method:"PUT",expiresIn:600,contentType:"text/plain")
        try check(try store.authorize(URL(string:signed)!,method:"PUT",contentType:"text/plain")==key,"signed capability resolves logical key")
        try check(try store.authorize(URL(string:signed)!,method:"PUT",contentType:"text/html")==nil,"signed content type is binding")
        let audit=try db.auditCount("Documents"),upload=try store.beginUpload(key:key,contentType:"text/plain")
        try upload.append(body);let etag=try upload.finish()
        let first=try db.documentObject(bucket:"fixture-bucket",key:key)!
        try check(etag=="\""+first.sha256+"\"" && first.bytes==body.count && first.revision==1,"mapping and ETag commit")
        let unchanged=try db.get("Documents",key:["id":doc["id"]])!
        try check(unchanged.values==doc.values && unchanged.revision==doc.revision && db.auditCount("Documents")==audit,"PUT preserves every CRM scalar revision and audit")
        try check(try read(store.open(key:key))==body,"GET mapped body exact")
        try check(try Data(contentsOf:alice.documentFile(id(2001)))==body,"UI preview resolves mapping with nil CRM size/hash")
        try check(try alice.documentStorageBytes()==body.count,"UI storage totals use resolved length")
        try check(try alice.documentPage(DocumentQuery(id:id(2001))).rows.first?["size"] == .integer(Int64(body.count)),"UI list displays mapped length without scalar mutation")
        let exported=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-object-export-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:exported)}
        try alice.exportDocument(id(2001),to:exported,replace:false);try check(try Data(contentsOf:exported)==body,"UI export uses same file")
        let snapshot=try NativeDocumentFiles.resolve(doc,db:db),pinned=try store.open(key:key)
        let replace=try store.beginUpload(key:key,contentType:"text/plain");try replace.append(body);_ = try replace.finish()
        let second=try db.documentObject(bucket:"fixture-bucket",key:key)!
        try check(second.revision==2 && second.fileKey != first.fileKey && second.sha256==first.sha256,"same-content replacement still changes mapping revision")
        try rejects("old mapping snapshot rejected"){try NativeDocumentFiles.requireCurrent(snapshot,document:doc,db:db)}
        let cleanup=DocumentFileCleanupWorker(db:db)
        while try await cleanup.runNext() {}
        try check(!FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(first.fileKey).path),"superseded physical file cleaned")
        try check(try read(pinned)==body,"started GET survives old-file cleanup")
        let beforeFiles=try FileManager.default.contentsOfDirectory(atPath:fixture.root.appendingPathComponent("native-documents").path).sorted()
        let rollback=try store.beginUpload(key:key,contentType:"application/pdf");try rollback.append(Data("rollback".utf8))
        do{_ = try rollback.finish{throw Failure.injected};throw Failure.assertion("injected failure committed")}catch Failure.injected{checks+=1}
        let afterRollback=try db.documentObject(bucket:"fixture-bucket",key:key)!
        try check(afterRollback.fileKey==second.fileKey && afterRollback.revision==second.revision,"mapping rollback preserves former object")
        try check(try FileManager.default.contentsOfDirectory(atPath:fixture.root.appendingPathComponent("native-documents").path).sorted()==beforeFiles,"failed commit removes staged and published file")
        let cancelled=Task {()throws->Void in let upload=try store.beginUpload(key:key,contentType:"text/plain");try upload.append(body);_ = try upload.finish{withUnsafeCurrentTask{$0?.cancel()}}}
        do{try await cancelled.value;throw Failure.assertion("cancelled mapping committed")}catch is CancellationError{checks+=1}
        try check(try db.documentObject(bucket:"fixture-bucket",key:key)!.revision==second.revision,"cancel after publish rolls back mapping")
        try check(try FileManager.default.contentsOfDirectory(atPath:fixture.root.appendingPathComponent("native-documents").path).sorted()==beforeFiles,"cancel after publish removes new blob")
        // Document retry/processing use the mapping identity without copying
        // its length/hash back into the CRM document's original scalar fields.
        let plain=Data("これは資料処理の検証です。\nsecond line".utf8),new=try store.beginUpload(key:key,contentType:"text/plain");try new.append(plain);_ = try new.finish()
        try alice.retryDocumentProcessing(db.get("Documents",key:["id":doc["id"]])!)
        let worker=DocumentProcessingWorker(db:db)
        try check(try await worker.runNext(),"mapped document extraction runs")
        let text=try alice.documentExtractedText(id(2001))
        try check(text.ready && text.text.contains("資料処理"),"mapped extraction text is visible")
        let processed=try db.get("Documents",key:["id":doc["id"]])!
        try check(processed["size"] == .null && processed["content_hash"] == .null && processed["key"] == .text(key),"retry leaves source storage scalar identity intact")
        try alice.retryDocumentProcessing(processed)
        let stale=try store.beginUpload(key:key,contentType:"text/plain");try stale.append(Data("replacement".utf8));_ = try stale.finish()
        try check(try !db.documentTextPage(id(2001)).ready,"PUT invalidates stale extraction generation")
        _ = try await worker.runNext()
        try check(try !db.documentTextPage(id(2001)).ready,"older queued extraction cannot republish stale text")
        try alice.retryDocumentProcessing(db.get("Documents",key:["id":doc["id"]])!)
        let during=DocumentProcessingWorker(db:db,extract:{url,type,checkpoint in
            let result=try NativeDocumentProcessing.extract(url:url,mimeType:type,checkpoint:checkpoint)
            let upload=try store.beginUpload(key:key,contentType:"text/plain");try upload.append(Data("changed during extraction".utf8));_ = try upload.finish()
            return result
        })
        try check(try await during.runNext(),"in-flight extraction executes mapping replacement fixture")
        try check(try !db.documentTextPage(id(2001)).ready,"in-flight old mapping cannot publish extracted content")
        let otherBucket=try NativeMCPDocumentObjectStore(db:db,bucket:"other-bucket",signer:signer,activateForDocuments:false)
        let isolated=try otherBucket.beginUpload(key:key,contentType:"text/plain");try isolated.append(Data("other bucket".utf8));_ = try isolated.finish()
        try check(try read(otherBucket.open(key:key))==Data("other bucket".utf8),"bucket-specific object mapping")
        try check(try read(store.open(key:key))==Data("changed during extraction".utf8),"other bucket does not replace active object")
        try await largeUpload(store:store,root:fixture.root)
        // Existing native imports are readable before a mapping exists, and
        // their signed PUT also leaves the original CRM fields untouched.
        let source=fixture.root.appendingPathComponent("source.txt");try Data("original".utf8).write(to:source)
        let imported=try alice.commitDocument(alice.stageDocument(source)),legacyKey=imported["key"].string
        let legacyRead=try store.open(key:legacyKey)
        try check(try read(store.open(key:legacyKey))==Data("original".utf8),"existing native key fallback")
        let override=try store.beginUpload(key:legacyKey,contentType:"text/plain");try override.append(Data("overridden".utf8));_ = try override.finish()
        try check(try db.get("Documents",key:["id":imported["id"]])!.values==imported.values,"legacy overwrite preserves original CRM metadata")
        while try await cleanup.runNext() {}
        try check(try read(legacyRead)==Data("original".utf8),"legacy fallback reader pins inode across replacement cleanup")
        try check(try Data(contentsOf:alice.documentFile(imported["id"].string))==Data("overridden".utf8),"UI prefers mapping over stale native metadata")
        let replacementSource=fixture.root.appendingPathComponent("replacement.txt");try Data("version two".utf8).write(to:replacementSource)
        let revised=try alice.commitDocument(alice.stageDocument(replacementSource),replacing:db.get("Documents",key:["id":imported["id"]])!)
        let archive=try db.page("Documents",fields:db.schema.model("Documents").fields.map(\.name),equal:["parent_document_id":revised["id"]],limit:1).rows.first!
        try check(archive["key"].string != legacyKey && archive["key"].string.hasPrefix("native-documents/"),"native UI version archives immutable resolved file")
        while try await cleanup.runNext() {}
        try check(try Data(contentsOf:alice.documentFile(archive["id"].string))==Data("overridden".utf8),"version remains readable after logical mapping cleanup")
        // On-disk full-directory backup is the existing documented workflow.
        // Copy only after closing the source DB fixture in a separate scope;
        // below uses an independently checkpointed isolated database snapshot.
        try await backup(resources:resources)
        let retainedFile=try db.documentObject(bucket:"fixture-bucket",key:key)!.fileKey
        try alice.deleteDocuments([try db.get("Documents",key:["id":doc["id"]])!])
        try check(try await cleanup.runNext(),"logical mapping cleanup commits first")
        try check(try db.documentObject(bucket:"fixture-bucket",key:key)==nil && FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(retainedFile).path),"cleanup cut point has no mapping but still has recoverable physical bytes")
        while try await cleanup.runNext() {}
        try check(try db.documentObject(bucket:"fixture-bucket",key:key)==nil,"purge removes unreferenced logical mapping")
        try check(!FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(retainedFile).path),"separate physical job completes deferred cleanup")
        try rejects("purged object unavailable"){_ = try store.open(key:key)}
        try check(try db.integrityCheck(),"SQLite foreign keys and storage mapping integrity")
    }
    static func backup(resources:URL)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-object-backup-"+UUID().uuidString)
        let copy=root.appendingPathComponent("restored"),source=root.appendingPathComponent("source")
        defer{try? FileManager.default.removeItem(at:root)}
        let key="documents/backup.txt",bytes=Data("durable mapped object".utf8)
        do {
            let db=try NativeDatabase(url:source.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let signer=try NativeMCPDocumentLocalSigner(appURL:"http://127.0.0.1:45678",secret:"isolated-backup-secret"),store=try NativeMCPDocumentObjectStore(db:db,bucket:"fixture-bucket",signer:signer)
            let upload=try store.beginUpload(key:key,contentType:"text/plain");try upload.append(bytes);_ = try upload.finish()
        }
        try FileManager.default.copyItem(at:source,to:copy)
        let restored=try NativeDatabase(url:copy.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let signer=try NativeMCPDocumentLocalSigner(appURL:"http://127.0.0.1:45678",secret:"isolated-backup-secret"),store=try NativeMCPDocumentObjectStore(db:restored,bucket:"fixture-bucket",signer:signer)
        try check(try read(store.open(key:key))==bytes,"closed-app directory backup restores mapping and same physical binary")
        try check(try restored.integrityCheck(),"restored database integrity")
    }
    static func largeUpload(store:NativeMCPDocumentObjectStore,root:URL)async throws {
        let key="documents/over-ui-limit.bin",block=Data(repeating:7,count:64*1024),upload=try store.beginUpload(key:key,contentType:"application/octet-stream")
        for _ in 0..<(65*16) {try upload.append(block)}
        _ = try upload.finish();let object=try store.db.documentObject(bucket:store.bucket,key:key)!
        try check(object.bytes==65*1024*1024,"MCP PUT accepts 65MiB beyond native UI import limit")
        let reader=try store.open(key:key);var total:Int64=0,largest=0
        while let chunk=try reader.readChunk(){total+=Int64(chunk.count);largest=max(largest,chunk.count)}
        try check(total==object.bytes && largest<=256*1024,"large download remains bounded")
        let file=try NativeDocumentFiles(dataRoot:root).verifiedURL(key:object.fileKey,bytes:object.bytes,sha256:object.sha256)
        try check(FileManager.default.fileExists(atPath:file.path),"native preview verification accepts mapped files over 64MiB")
        let document=try store.db.insert("Documents",values:["document_name":.text("large fixture"),"key":.text(key),"created_by_user":.text(id(1)),"createdBy":.text(id(1)),"document_file_url":.text("http://fixture.invalid/"+key),"document_file_mimeType":.text("application/octet-stream")],actor:id(1))
        let service=CRMService(db:store.db,identity:CRMIdentity(id:id(1),role:"user",partnerAccountID:nil))
        try service.retryDocumentProcessing(document)
        var extracted=false
        let bounded=DocumentProcessingWorker(db:store.db,extract:{_,_,_ in extracted=true;throw Failure.injected})
        try check(try await bounded.runNext() && !extracted,"65MiB cannot enter PDFKit or other bounded extraction engines")
        try store.db.remove(store.db.get("Documents",key:["id":document["id"]])!,actor:id(1))
        for physical in try store.db.removeUnreferencedDocumentObjects(key) {try NativeDocumentFiles(dataRoot:root).removeUnreferenced(key:physical)}
        try check(!FileManager.default.fileExists(atPath:file.path),"large generated fixture cleaned")
    }
}
