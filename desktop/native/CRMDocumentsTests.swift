import Foundation
import SQLite3
import CryptoKit
import Darwin

@main enum CRMDocumentsTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String, _ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
    static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data("CRMDocumentsTests: \(error)\n".utf8)); exit(1) }
    }
    static func sourceScopes(_ resources: URL, root: URL) throws {
        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/documents-reference.json"))) as! [String:Any]
        let records = fixture["records"] as! [String:[[String:Any]]]
        let db = try NativeDatabase(url:root.appendingPathComponent("scope/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let actor = (records["Users"]![0]["id"] as! String)
        func scalar(_ value: Any) -> SQLValue {
            if value is NSNull { return .null }; if let number = value as? NSNumber { return .integer(number.int64Value) }; return .text(value as! String)
        }
        try db.transaction { for (model,rows) in records { for row in rows {
            var values = row.mapValues(scalar)
            // The native schema cannot store an unknown role. Exercise a
            // stale/unknown caller identity against an otherwise valid user.
            if model == "Users", values["role"] == .text("unknown") { values["role"] = .text("user") }
            _ = try db.insert(model,values:values,actor:actor)
        } } }
        for test in fixture["cases"] as! [[String:Any]] {
            let identity = CRMIdentity(id:test["userId"] as! String,role:test["role"] as! String,partnerAccountID:test["partnerAccountId"] as? String)
            let service = CRMService(db:db,identity:identity)
            let readable = Set(test["readable"] as! [String]); let writable = Set(test["writable"] as! [String])
            for record in records["Documents"]! {
                let id = record["id"] as! String
                try check(((try? service.assertAccess("Documents",id:id)) != nil) == readable.contains(id),"source read scope: \(identity.role) / \(record["document_name"]!)")
                try check(((try? service.assertAccess("Documents",id:id,write:true)) != nil) == writable.contains(id),"source write scope: \(identity.role) / \(record["document_name"]!)")
            }
        }
        try check(try db.integrityCheck(),"source fixture foreign keys")
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-DocumentsTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try sourceScopes(resources,root:root)
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("main/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open()
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        func user(_ name: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:"user",partnerAccountID:nil))
        }
        let owner = try user("owner"); let other = try user("other")
        let writer2 = CRMService(db:second,identity:owner.identity)
        let sourceFolder = root.appendingPathComponent("sources"); try FileManager.default.createDirectory(at:sourceFolder,withIntermediateDirectories:true)
        func source(_ name: String, _ text: String) throws -> URL { let url = sourceFolder.appendingPathComponent(name); try Data(text.utf8).write(to:url); return url }
        func fresh(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model,key:db.key(for:row))! }
        func imported(_ service: CRMService, _ source: URL, replacing: NativeRecord? = nil) throws -> NativeRecord { try service.commitDocument(service.stageDocument(source),replacing:replacing) }
        func sql(_ command: String) throws {
            var connection: OpaquePointer?; guard sqlite3_open(db.url.path,&connection) == SQLITE_OK else { throw NativeDBError.message("test SQLite") }; defer { sqlite3_close(connection) }
            guard sqlite3_exec(connection,command,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("test SQL: "+String(cString:sqlite3_errmsg(connection))) }
        }
        let files = try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent())
        func fileNames() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath:files.root.path)) }
        let firstSource = try source("日本語の議事録.txt","元の文書です。\n二行目 😀")
        let staged = try owner.stageDocument(firstSource)
        try check(staged.bytes == Data("元の文書です。\n二行目 😀".utf8).count && staged.mimeType == "text/plain","stage derives exact bytes and MIME")
        try check(try owner.documentPage().total == 0,"staging does not create metadata")
        var document = try owner.commitDocument(staged)
        let originalID = document["id"].string
        try check(document["document_name"] == .text("日本語の議事録.txt") && document["createdBy"] == .text(owner.identity.id),"Japanese import and ownership")
        try check(document["processing_status"] == .text("PENDING") && document["version"] == .integer(1),"import reserves enrichment without pretending it ran")
        try rejects("generic editor cannot bypass document workflow") { _ = try owner.save(.documents,original:document,input:["document_name":.text("迂回")]) }
        try rejects("generic soft deletion cannot bypass file lifecycle") { try owner.delete(document) }
        try check(try db.jobs(events:["document/uploaded"]).count == 1,"import and enrichment intent committed together")
        let originalURL = try owner.documentFile(originalID)
        try check(try Data(contentsOf:originalURL) == Data(contentsOf:firstSource),"stored content matches source")
        try check(try (FileManager.default.attributesOfItem(atPath:originalURL.path)[.posixPermissions] as! NSNumber).intValue == 0o400,"committed file is private and readonly")
        let exported = sourceFolder.appendingPathComponent("書き出し.txt")
        try owner.exportDocument(originalID,to:exported)
        try check(try Data(contentsOf:exported) == Data(contentsOf:firstSource),"streamed export retains exact bytes")
        try rejects("export never silently overwrites existing files") { try owner.exportDocument(originalID,to:exported) }
        try Data("置換前".utf8).write(to:exported); try owner.exportDocument(originalID,to:exported,replace:true)
        try check(try Data(contentsOf:exported) == Data(contentsOf:firstSource),"explicit replacement export")
        try rejects("export cannot overwrite CRM database") { try owner.exportDocument(originalID,to:db.url,replace:true) }
        try check(try other.documentPage().total == 0 && other.duplicateDocument(hash:staged.sha256) == nil,"private metadata and duplicate detection do not leak")
        try rejects("private file is inaccessible") { _ = try other.documentFile(originalID) }
        try check(try owner.duplicateDocument(hash:staged.sha256)?["id"] == document["id"],"authorized duplicate is found")
        try rejects("staging token cannot be reused") { _ = try owner.commitDocument(staged) }
        try check(try owner.documentPage().total == 1 && FileManager.default.fileExists(atPath:originalURL.path),"reuse rollback retains original committed file")

        let newer = try source("差し替え.pdf","架空のPDFファイル内容（型情報の検証用）")
        document = try imported(owner,newer,replacing:document)
        let history = try owner.documentVersions(originalID)
        try check(document["id"].string == originalID && document["version"] == .integer(2) && history.total == 2,"version replacement keeps root ID and archives old version")
        try check(document["document_file_mimeType"] == .text("application/pdf") && document["content_hash"] != .text(staged.sha256),"replacement updates MIME and hash")
        let version1 = history.rows.first { $0["version"] == .integer(1) }!
        try check(try Data(contentsOf:owner.documentFile(version1["id"].string)) == Data(contentsOf:firstSource),"old bytes remain available after replacement")
        try check(try owner.documentPage().total == 1 && owner.documentStorageBytes() == staged.bytes + Int64(Data(contentsOf:newer).count),"root listing excludes history while scoped sum includes it")
        try check(try owner.documentPage().rows[0].values["content_text"] == nil && owner.documentVersions(originalID).rows[0].values["summary"] == nil,"lists project small metadata only")
        try rejects("old snapshot cannot be edited") { _ = try owner.updateDocument(version1,changes:["document_name":.text("変更")]) }
        try rejects("stale replacement is rejected") { _ = try imported(owner,newer,replacing:NativeRecord(model:document.model,values:document.values,revision:1)) }
        try check(try owner.documentVersions(originalID).total == 2,"stale replacement leaves no extra version")

        let beforeFiles = try fileNames(); let beforeDocs = try db.page("Documents",fields:[]).total
        try sql("CREATE TRIGGER fail_document_queue BEFORE INSERT ON native_outbox WHEN NEW.event='document/uploaded' BEGIN SELECT RAISE(ABORT,'test'); END")
        let rollbackStage = try owner.stageDocument(firstSource)
        try rejects("outbox failure rolls back metadata and file") { _ = try owner.commitDocument(rollbackStage) }
        try check(try fileNames() == beforeFiles && db.page("Documents",fields:[]).total == beforeDocs,"failed queue removes staging even while caller retains token")
        try sql("DROP TRIGGER fail_document_queue")
        try sql("CREATE TRIGGER fail_document_commit AFTER INSERT ON Documents WHEN NEW.document_name='deferred failure' BEGIN INSERT INTO DocumentsToAccounts(document_id,account_id) VALUES(NEW.id,'00000000-0000-4000-8000-000000000099'); END")
        let commitStage = try owner.stageDocument(firstSource)
        try rejects("deferred commit failure after publication") { _ = try owner.commitDocument(commitStage,name:"deferred failure") }
        try check(try fileNames() == beforeFiles && db.page("Documents",fields:[]).total == beforeDocs,"commit rollback releases published file")
        try sql("DROP TRIGGER fail_document_commit")

        let revoked = try user("revoked"); let revokedStage = try revoked.stageDocument(firstSource)
        let revokedUser = try db.get("Users",key:["id":.text(revoked.identity.id)])!
        _ = try db.update(revokedUser,changes:["banned":.integer(1)],actor:identity.id)
        try rejects("access revoked between staging and commit") { _ = try revoked.commitDocument(revokedStage) }
        try check(try fileNames() == beforeFiles && db.page("Documents",fields:[]).total == beforeDocs,"revoked import leaves no metadata or file")

        let damaged = try imported(owner,try source("破損の検証.txt","保存した文書"))
        let damagedURL = try owner.documentFile(damaged["id"].string)
        guard chmod(damagedURL.path,0o600) == 0 else { throw NativeDBError.message("test chmod") }
        try Data("壊された文書".utf8).write(to:damagedURL)
        try rejects("same-size modified document cannot be previewed") { _ = try owner.documentFile(damaged["id"].string) }
        let protectedExport = try source("破損時の書き出し先.txt","保持する既存ファイル")
        try rejects("modified document cannot replace an export destination") { try owner.exportDocument(damaged["id"].string,to:protectedExport,replace:true) }
        try check(try Data(contentsOf:protectedExport) == Data("保持する既存ファイル".utf8),"failed integrity check preserves destination")
        try owner.deleteDocuments([damaged])

        let concurrent = try fresh(document); let stageA = try owner.stageDocument(firstSource); let stageB = try writer2.stageDocument(newer)
        let raceA = Task.detached { (try? owner.commitDocument(stageA,replacing:concurrent)) != nil }
        let raceB = Task.detached { (try? writer2.commitDocument(stageB,replacing:concurrent)) != nil }
        let successes = await [raceA.value,raceB.value].filter { $0 }.count
        document = try fresh(document)
        try check(successes == 1 && document["version"] == .integer(3) && (try owner.documentVersions(originalID)).total == 3,"two connections cannot allocate duplicate next version")
        try check(try !fileNames().contains { $0.hasPrefix(".stage-") },"competing failed import leaves no staging files")

        let account = try owner.save(CRMModule.find("crm_Accounts")!,original:nil,input:["name":.text("関連先株式会社")])
        try owner.setDocumentLink(document,to:DocumentLink(model:"crm_Accounts",id:account["id"].string),linked:true); document = try fresh(document)
        try check(try owner.documentPage(DocumentQuery(linkedTo:DocumentLink(model:"crm_Accounts",id:account["id"].string))).total == 1,"account relation is queryable")
        try owner.setDocumentLink(document,to:DocumentLink(model:"crm_Accounts",id:account["id"].string),linked:true); document = try fresh(document)
        try check(try db.page("DocumentsToAccounts",fields:[]).total == 1,"duplicate linking is idempotent")
        try rejects("unreadable parent cannot expose document list") { _ = try other.documentPage(DocumentQuery(linkedTo:DocumentLink(model:"crm_Accounts",id:account["id"].string))) }
        let board = try owner.saveProject(original:nil,input:["title":.text("文書リンク"),"description":.text("検証"),"visibility":.text("public")])
        let task = try owner.createProjectTaskInBoard(board["id"].string,input:["title":.text("添付するタスク")])
        try owner.setDocumentLink(document,to:DocumentLink(model:"Tasks",id:task["id"].string),linked:true); document = try fresh(document)
        try check(try owner.documentPage(DocumentQuery(linkedTo:DocumentLink(model:"Tasks",id:task["id"].string))).total == 1,"project task document relation")
        try check(try other.documentPage(DocumentQuery(linkedTo:DocumentLink(model:"Tasks",id:task["id"].string))).total == 0,"task readership alone does not bypass document access")
        try owner.setDocumentLink(document,to:DocumentLink(model:"Tasks",id:task["id"].string),linked:false); document = try fresh(document)
        try check(try db.page("DocumentsToTasks",fields:[]).total == 0,"unlink removes relation")

        document = try owner.updateDocument(document,changes:["visibility":.text("public"),"favourite":.integer(1),"document_system_type":.text("CONTRACT")])
        try check(try other.documentPage(DocumentQuery(systemType:"CONTRACT",favourites:true)).total == 1,"public, favourite and type filters")
        _ = try db.update(db.get("Documents",key:["id":version1["id"]])!,changes:["createdBy":.text(other.identity.id),"created_by_user":.text(other.identity.id)],actor:identity.id)
        document = try owner.updateDocument(document,changes:["visibility":.text("private")])
        try rejects("version uploader cannot bypass revoked root access") { _ = try other.documentRecord(version1["id"].string) }
        let foreign = try imported(other,try source("他者の文書.txt","他の利用者の文書"))
        try rejects("bulk deletion is all-or-nothing") { try owner.deleteDocuments([document,foreign]) }
        try check(try owner.documentRecord(originalID)["id"] == document["id"],"authorized document survives denied bulk deletion")
        try rejects("bulk type change is all-or-nothing") { try owner.changeDocumentTypes([document,foreign],systemType:"RECEIPT") }
        try check(try owner.documentRecord(originalID)["document_system_type"] == .text("CONTRACT"),"failed bulk change preserves earlier rows")

        let large = sourceFolder.appendingPathComponent("分割読み込み.bin")
        FileManager.default.createFile(atPath:large.path,contents:nil); let output = try FileHandle(forWritingTo:large)
        for _ in 0..<32 { try output.write(contentsOf:Data(repeating:0x61,count:NativeDocumentFiles.chunkBytes)) }; try output.close()
        let largeStage = try owner.stageDocument(large)
        try check(largeStage.bytes == 8*1024*1024 && largeStage.readCount == 32,"8MiB copied and hashed in exactly32 bounded reads")
        largeStage.discard()
        var cancel = false
        try rejects("cancelled copy") { _ = try owner.stageDocument(large,cancelled:{cancel},progress:{_,_ in cancel=true}) }
        var changed = false
        try rejects("source changed during copy") { _ = try owner.stageDocument(large,progress:{_,_ in if !changed { changed=true; let h=try! FileHandle(forWritingTo:large);try! h.write(contentsOf:Data([0x62]));try! h.close() } }) }
        try check(try !fileNames().contains { $0.hasPrefix(".stage-") },"cancelled and changed copies release staging")
        let oversized = sourceFolder.appendingPathComponent("大きすぎる文書.bin"); let fd = Darwin.open(oversized.path,O_RDWR | O_CREAT,0o600); guard fd >= 0 else { throw NativeDBError.message("test large file") }
        ftruncate(fd,NativeDocumentFiles.maximumBytes+1); close(fd)
        try rejects("64MiB source limit before reading") { _ = try owner.stageDocument(oversized) }
        let symbolic = sourceFolder.appendingPathComponent("リンク.txt"); try FileManager.default.createSymbolicLink(at:symbolic,withDestinationURL:firstSource)
        try rejects("source symlink rejected") { _ = try owner.stageDocument(symbolic) }
        let fifo = sourceFolder.appendingPathComponent("pipe"); mkfifo(fifo.path,0o600)
        try rejects("FIFO does not block or import") { _ = try owner.stageDocument(fifo) }
        try rejects("directory source rejected") { _ = try owner.stageDocument(sourceFolder) }
        for invalid in ["../secret","native-documents/../secret","native-documents/not-a-uuid.txt","native-documents/"+UUID().uuidString+".TXT","https://example.invalid/a.pdf"] { try rejects("unsafe key rejected") { _ = try NativeDocumentFiles.fileName(for:invalid) } }

        let worker = DocumentFileCleanupWorker(db:db)
        while try await worker.runNext() {} // Finish the earlier damaged-file deletion before counting crash leftovers.
        let liveStage = try owner.stageDocument(firstSource)
        let abandonedName = ".stage-"+UUID().uuidString.lowercased()+".txt"; let orphanName = UUID().uuidString.lowercased()+".txt"
        try Data("未確定".utf8).write(to:files.root.appendingPathComponent(abandonedName)); try Data("孤立".utf8).write(to:files.root.appendingPathComponent(orphanName))
        let unmanaged = files.root.appendingPathComponent("README.txt"); try Data("残す".utf8).write(to:unmanaged)
        let reclaimed = try await worker.recoverAbandonedFiles(olderThan:.distantFuture)
        try check(reclaimed == 2 && FileManager.default.fileExists(atPath:unmanaged.path),"crash cleanup reclaims only recognized abandoned files")
        try check(try fileNames().contains { $0.hasPrefix(".stage-") },"active staged file lock prevents cleanup")
        liveStage.discard()
        try check(try Data(contentsOf:owner.documentFile(originalID)).count > 0,"crash cleanup retains referenced file")

        let manyVersions = try imported(owner,try source("長い版履歴.txt","多数の版で共有する内容"))
        let manyVersionsURL = try owner.documentFile(manyVersions["id"].string)
        try db.transaction {
            var firstArchive: SQLValue?
            for i in 1...205 {
                var values = manyVersions.values; values.removeValue(forKey:"id")
                values["parent_document_id"] = manyVersions["id"]; values["version"] = .integer(Int64(i))
                let archive = try db.insert("Documents",values:values,actor:identity.id)
                if firstArchive == nil { firstArchive = archive["id"] }
            }
            var legacy = manyVersions.values; legacy.removeValue(forKey:"id"); legacy["parent_document_id"] = firstArchive!
            _ = try db.insert("Documents",values:legacy,actor:identity.id)
        }
        let versionPage = try owner.documentVersions(manyVersions["id"].string,offset:200)
        try check(versionPage.rows.count == 6 && versionPage.total == 206,"long history pages preserve the full count")
        try owner.deleteDocuments([manyVersions]); while try await worker.runNext() {}
        try check(try !db.documentFileIsReferenced(manyVersions["key"].string),"family deletion crosses pages and includes legacy nested versions")
        try check(!FileManager.default.fileExists(atPath:manyVersionsURL.path),"long history file is removed only after final reference deletion")

        var sharedValues = try fresh(document).values; sharedValues.removeValue(forKey:"id"); sharedValues["document_name"] = .text("共有ファイルの参照")
        let shared = try db.insert("Documents",values:sharedValues,actor:identity.id)
        let sharedURL = try owner.documentFile(shared["id"].string)
        try owner.deleteDocuments([document])
        while try await worker.runNext() {}
        try check(try db.get("Documents",key:["id":document["id"]]) == nil && db.page("Documents",fields:[],equal:["parent_document_id":document["id"]]).total == 0,"delete removes current record and every version")
        try check(FileManager.default.fileExists(atPath:sharedURL.path),"cleanup does not delete a file referenced by another document")
        try check(try db.page("DocumentsToAccounts",fields:[]).total == 0,"document deletion cascades links")
        try owner.deleteDocuments([shared]); while try await worker.runNext() {}
        try check(!FileManager.default.fileExists(atPath:sharedURL.path),"last reference cleanup removes file")
        try check(try db.jobs(events:DocumentFileCleanupWorker.events).allSatisfy { $0.status == "done" },"cleanup jobs finish durably")
        try check(try db.integrityCheck(),"final database integrity and foreign keys")
        let reopened = try open(); let service = CRMService(db:reopened,identity:other.identity)
        try check(try Data(contentsOf:service.documentFile(foreign["id"].string)) == Data("他の利用者の文書".utf8),"unrelated document persists across restart")
        print("Native documents: \(checks) checks passed including192 original-source access comparisons; temporary files only")
    }
}

