import Foundation
import SQLite3
import ImageIO
import PDFKit

@main struct NativeOperationalMigrationTests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("test: "+label)};checks+=1}
    static func main()async throws {
        let args=CommandLine.arguments,fixture=URL(fileURLWithPath:args[1]),native=URL(fileURLWithPath:args[2]),output=URL(fileURLWithPath:args[3])
        let schema=native.appendingPathComponent("schema.json"),sql=native.appendingPathComponent("schema.sql"),bundle=fixture.appendingPathComponent("bundle")
        let ids=try NativeMigrationJSON.parse(Data(contentsOf:fixture.appendingPathComponent("fixture-ids.json"))).object!
        func id(_ key:String)->String{ids[key]!.string!}
        let base=try NativeMigrationImportWorkspace.resolvedTemporaryDirectory().appendingPathComponent("OperationalMigration-"+UUID().uuidString.lowercased());try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:base)}
        let preflight=NativeMigrationPreflight().inspect(bundleURL:bundle,schemaURL:schema)
        try JSONEncoder().encode(preflight).write(to:output.appendingPathComponent("preflight.json"))
        try check(preflight.status=="incomplete","valid bundle with explicit M07/asset holds")
        try check(preflight.checkedModels==92,"92 complete models")
        let destination=base.appendingPathComponent("operational"),result=try NativeOperationalMigration(checkpoint:{point in if point=="afterSeal"{let files=try FileManager.default.contentsOfDirectory(atPath:destination.path);try JSONSerialization.data(withJSONObject:files).write(to:output.appendingPathComponent("seal-files.json"))}}).prepare(bundle:bundle,schema:schema,sql:sql,destination:destination)
        try JSONEncoder().encode(result).write(to:output.appendingPathComponent("operational-result.json"))
        try check(result.status=="prepared-with-gaps" && result.mapped==13 && result.unresolved==2,"operational + missing/external gaps")
        try check(!result.workersStarted && !result.applicationActivated && !result.credentialsMigrated,"no false activation")
        let db=try NativeDatabase(url:destination.appendingPathComponent("crm.sqlite"),schemaURL:schema,sqlURL:sql)
        try check(try db.metadata("localActor")==nil,"no local identity issuance")
        try check(try db.metadata("migration.operational.state")=="review-required","explicit startup review")
        let actor=CRMIdentity(id:id("user"),role:"admin",partnerAccountID:nil),service=CRMService(db:db,identity:actor)
        let user=try db.get("Users",key:["id":.text(id("user"))])!
        try check(user["role"] == .text("admin") && user["avatar"] == .text("avatars/profile.png"),"source role/photo scalar unchanged")
        try check(try db.page("crm_Accounts",fields:["name"],search:"移行会社").total==1,"native search populated")
        let account=try db.get("crm_Accounts",key:["id":.text(id("account"))])!
        try check(account["annual_revenue"] == .text("12345678901234.56"),"exact decimal")
        let versions=try service.documentVersions(id("document"));try check(versions.total==3,"source parent plus historical versions")
        for row in versions.rows {
            let url=try service.documentFile(row["id"].string),record=try service.documentRecord(row["id"].string)
            let expected=try Data(contentsOf:fixture.appendingPathComponent("objects").appendingPathComponent(record["key"].string))
            try check(try Data(contentsOf:url)==expected,"ordinary verified document reader exact bytes")
            try check(try NativeDocumentFiles.resolve(record,db:db).mappingRevision==1,"native mapping")
        }
        let reader=CRMService(db:db,identity:.init(id:id("reader"),role:"user",partnerAccountID:nil))
        let child=ids["versions"]!.array![0].string!,grand=id("grand")
        try check(try reader.documentVersions(child).total==2,"nested source parent is browsable")
        try check(try Data(contentsOf:reader.documentFile(grand))==Data(contentsOf:fixture.appendingPathComponent("objects/documents/grand.txt")),"grandchild original bytes via ordinary reader")
        let original=try NativeMigrationJSON.parse(Data(contentsOf:output.appendingPathComponent("document-versions-reference.json"))).object!["cases"]!.array!
        for value in original {
            let item=value.object!,label=item["label"]!.string!;if label=="anonymous" || label=="deleted-child-returned"{continue}
            let uid=item["user"]!.string!,row=try db.get("Users",key:["id":.text(uid)])!,subject=CRMService(db:db,identity:.init(id:uid,role:row["role"].string,partnerAccountID:nil))
            let expected=Set(item["ids"]!.array!.map{$0.string!});var actual=Set<String>()
            do{actual=Set(try subject.documentVersions(item["parent"]!.string!).rows.map{$0["id"].string})}catch{try check(expected.isEmpty,"source rejection mapping")}
            try check(actual==expected,"actual source versions "+label)
        }
        enum RolledBack:Error{case end}
        func rollback(_ body:()throws->Void)throws{do{try db.transaction{try body();throw RolledBack.end}}catch RolledBack.end{}}
        func denies(_ body:()throws->Void,_ name:String)throws{var denied=false;do{try body()}catch{denied=true};try check(denied,name)}
        try rollback{
            let row=try db.get("Documents",key:["id":.text(grand)])!;_ = try db.update(row,changes:["created_by_user":.text(id("other")),"createdBy":.text(id("other")),"assigned_user":.text(id("other"))],actor:actor.id)
            try denies({_ = try reader.documentFile(grand)},"changed owner cannot reuse proof")
        }
        try rollback{
            let row=try db.get("Documents",key:["id":.text(child)])!;_ = try db.update(row,changes:["created_by_user":.text(id("other")),"createdBy":.text(id("other")),"assigned_user":.text(id("other"))],actor:actor.id)
            try denies({_ = try reader.documentVersions(child)},"changed requested-parent owner revokes list access")
        }
        try rollback{
            let row=try db.get("Documents",key:["id":.text(grand)])!;_ = try db.update(row,changes:["parent_document_id":.text(id("missing"))],actor:actor.id)
            try denies({_ = try reader.documentFile(grand)},"changed parent revokes old exception")
        }
        try rollback{
            let row=try db.get("Documents",key:["id":.text(id("document"))])!;_ = try db.update(row,changes:["deletedAt":.text("2026-11-01T00:00:00Z")],actor:actor.id)
            try denies({_ = try reader.documentFile(grand)},"deleted ancestor fails closed")
        }
        try rollback{
            let row=try db.get("Documents",key:["id":.text(grand)])!;_ = try db.update(row,changes:["deletedAt":.text("2026-11-01T00:00:00Z")],actor:actor.id)
            try check(try reader.documentVersions(child).rows.contains(where:{$0["id"] == .text(grand)}),"source parent list includes deleted child metadata")
            try denies({_ = try reader.documentFile(grand)},"deleted child bytes remain inaccessible")
        }
        try rollback{
            let partner=CRMService(db:db,identity:.init(id:id("partner"),role:"partner",partnerAccountID:nil));try check(try partner.documentFile(grand).isFileURL,"current source partner link")
            let link=try db.get("DocumentsToAccounts",key:["document_id":.text(grand),"account_id":.text(id("account"))])!;try db.remove(link,actor:actor.id)
            try denies({_ = try partner.documentFile(grand)},"removed link cannot freeze partner grant")
        }
        try rollback{
            let row=try db.get("Users",key:["id":.text(id("reader"))])!;_ = try db.update(row,changes:["banned":.integer(1)],actor:actor.id)
            try denies({_ = try reader.documentFile(grand)},"fresh ban blocks source exception")
        }
        try rollback{
            var values=try db.get("Documents",key:["id":.text(grand)])!.values;values.removeValue(forKey:"id");let added=try db.insert("Documents",values:values,actor:actor.id)
            try denies({_ = try reader.documentFile(added["id"].string)},"ordinary native versions retain original guard")
        }
        let text=try service.documentExtractedText(id("document"));try check(text.text=="旧サーバーの抽出本文" && text.ready,"legacy extracted text remains visible")
        try check(try service.documentExtractedText(id("document"),thumbnail:true).thumbnail != nil,"migrated document thumbnail uses normal text/preview reader")
        try rollback{
            let current=try service.documentRecord(id("document"));_ = try db.update(current,changes:["key":.text("changed-object")],actor:actor.id)
            try denies({_ = try service.documentFile(id("document"))},"changed document key cannot fall back to stale URL mapping")
        }
        var refused=false;do{_ = try service.documentFile(id("missing"))}catch{refused=true};try check(refused,"missing asset not fabricated")
        let invoice=try db.get("Invoices",key:["id":.text(id("invoice"))])!,pdf=try service.invoicePDFURL(invoice)
        try check(try Data(contentsOf:pdf)==Data(contentsOf:fixture.appendingPathComponent("objects/invoices/historical.pdf")),"historical PDF exact normal reader")
        try check(PDFDocument(url:pdf)?.pageCount==1,"historical PDF parses in normal PDFKit reader")
        try check(invoice["pdfStorageKey"] == .text("invoices/historical.pdf"),"PDF source key retained")
        let avatars=try NativeUserAvatarStore(service:service)
        try check(try avatars.image(forUserID:actor.id)?.width==2,"ordinary ImageIO thumbnail reader")
        try check(try avatars.original(forUserID:actor.id)?.data==Data(contentsOf:fixture.appendingPathComponent("objects/avatars/profile.png")),"exact original avatar")
        let readerAvatars=try NativeUserAvatarStore(service:reader)
        try check(try readerAvatars.image(forUserID:id("reader")) != nil,"image-only imported profile visible")
        try rollback{
            _ = try readerAvatars.clearCurrent(expectedReference:"")
            try check(try readerAvatars.image(forUserID:id("reader"))==nil,"image-only clear cannot resurrect migration fallback")
        }
        try check(try readerAvatars.image(forUserID:id("reader")) != nil,"outer rollback restores image fallback")
        try check(try avatars.cleanupUnreferenced(olderThan:0)==0,"mapped avatar not treated as orphan")
        // Compare every imported scalar before any later ordinary edits.
        try compareDatabases(destination.appendingPathComponent("imported/candidate.sqlite"),destination.appendingPathComponent("crm.sqlite"),schema:schema)
        try check(try count(destination.appendingPathComponent("crm.sqlite"),"SELECT COUNT(*) FROM native_outbox")==0,"no reconstructed/runnable jobs")
        let next=try db.update(user,changes:["avatar":.null],actor:actor.id)
        try check(try avatars.image(forUserID:actor.id)==nil,"cleared source binding cannot resurrect old avatar")
        let changedInvoice=try db.update(invoice,changes:["pdfStorageKey":.text("new-source-key")],actor:actor.id)
        refused=false;do{_ = try service.invoicePDFURL(changedInvoice)}catch{refused=true};try check(refused,"changed key does not show stale historical PDF")
        _ = try db.update(next,changes:["role":.text("partner")],actor:actor.id)
        refused=false;do{_ = try avatars.image(forUserID:actor.id)}catch{refused=true};try check(refused,"fresh role rechecked by normal reader")
        let encrypted=base.appendingPathComponent("encrypted-operational")
        let deniedArchive=base.appendingPathComponent("encrypted-no-admission")
        try denies({_ = try NativeOperationalMigration().prepare(bundle:fixture.appendingPathComponent("encrypted-bundle"),schema:schema,sql:sql,destination:deniedArchive)},"encrypted root requires explicit preservation admission")
        try check(!FileManager.default.fileExists(atPath:deniedArchive.path),"missing preservation admission leaves no candidate")
        let encryptedResult=try NativeOperationalMigration().prepare(bundle:fixture.appendingPathComponent("encrypted-bundle"),schema:schema,sql:sql,destination:encrypted,preservationAdmission:{})
        try check(encryptedResult.pending.contains("encrypted-credential-application") && !encryptedResult.credentialsMigrated,"encrypted material retained without pretending native apply")
        try check(try Data(contentsOf:encrypted.appendingPathComponent("credentials.handoff"))==Data(contentsOf:fixture.appendingPathComponent("encrypted-bundle/credentials.handoff")),"handoff byte-exact through operational adapter")
        try check(try Data(contentsOf:encrypted.appendingPathComponent("migration-holds.ndjson"))==Data(contentsOf:fixture.appendingPathComponent("encrypted-bundle/holds.ndjson")),"owner digest references retained")
        let preserved=try FileManager.default.contentsOfDirectory(atPath:encrypted.appendingPathComponent(NativeCredentialArchiveBinding.folder).path)
        try check(preserved.count==2 && preserved.contains(where:{$0.hasSuffix(".handoff")}) && preserved.contains(where:{$0.hasSuffix(".holds")}),"operational root includes backup-managed encrypted artifacts")
        let tampered=base.appendingPathComponent("tampered");try FileManager.default.copyItem(at:fixture.appendingPathComponent("encrypted-bundle"),to:tampered)
        let handle=try FileHandle(forWritingTo:tampered.appendingPathComponent("credentials.handoff"));try handle.seekToEnd();try handle.write(contentsOf:Data([0]));try handle.close()
        let rejected=base.appendingPathComponent("rejected-handoff");try denies({_ = try NativeOperationalMigration().prepare(bundle:tampered,schema:schema,sql:sql,destination:rejected,preservationAdmission:{})},"handoff digest rejects tamper")
        try check(!FileManager.default.fileExists(atPath:rejected.path),"tampered handoff never publishes root")
        // Exclusive preparation rollback never alters the source bundle.
        for point in ["afterImport","asset","beforeSearch","beforePublish"] {
            let dest=base.appendingPathComponent("failure-"+point);var hit=false
            do{_ = try NativeOperationalMigration(checkpoint:{p in if p==point{hit=true;throw CancellationError()}}).prepare(bundle:bundle,schema:schema,sql:sql,destination:dest)}catch{}
            try check(hit && !FileManager.default.fileExists(atPath:dest.path),"rollback removes only owned new root at "+point)
        }
        try JSONEncoder().encode(result).write(to:output.appendingPathComponent("operational-result.json"))
        let report:[String:Any] = ["checks":checks,"exit":0,"ordinaryReaders":["documentFile","documentVersions","documentExtractedText","invoicePDFURL","avatar.image","avatar.original"],"identity":"synthetic test-only identity; no provider/auth issuance", "sourceRolePreserved":true,"workersStarted":false]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:output.appendingPathComponent("native-proof.json"));print("NativeOperationalMigrationTests: \(checks) checks")
    }
    static func count(_ url:URL,_ sql:String)throws->Int64{var db:OpaquePointer?,s:OpaquePointer?;guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_close(db)};guard sqlite3_prepare_v2(db,sql,-1,&s,nil)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else{throw NativeDBError.conflict};return sqlite3_column_int64(s,0)}
    static func compareDatabases(_ source:URL,_ destination:URL,schema:URL)throws {
        let model=try JSONDecoder().decode(NativeMigrationSchema.self,from:Data(contentsOf:schema));var a:OpaquePointer?,b:OpaquePointer?
        guard sqlite3_open_v2(source.path,&a,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open_v2(destination.path,&b,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_close(a);sqlite3_close(b)}
        for m in model.models {
            let q=NativeMigrationImportDatabase.quote,sql="SELECT "+m.fields.map{q($0.column)}.joined(separator:",")+" FROM "+q(m.name)+" ORDER BY "+m.primaryKey.map{key in q(m.fields.first(where:{$0.name==key})!.column)}.joined(separator:",")
            // Both tables retain identical insertion order and PK. All cells are
            // read with SQLite types and byte lengths, not JSON/Double conversion.
            var x:OpaquePointer?,y:OpaquePointer?;guard sqlite3_prepare_v2(a,sql,-1,&x,nil)==SQLITE_OK,sqlite3_prepare_v2(b,sql,-1,&y,nil)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_finalize(x);sqlite3_finalize(y)}
            while true {let p=sqlite3_step(x),r=sqlite3_step(y);try check(p==r,"row cardinality "+m.name);if p==SQLITE_DONE{break};guard p==SQLITE_ROW else{throw NativeDBError.conflict}
                for i in 0..<Int32(m.fields.count){let type=sqlite3_column_type(x,i);try check(type==sqlite3_column_type(y,i),"scalar type");switch type{case SQLITE_NULL:break;case SQLITE_INTEGER:try check(sqlite3_column_int64(x,i)==sqlite3_column_int64(y,i),"integer");case SQLITE_FLOAT:try check(sqlite3_column_double(x,i).bitPattern==sqlite3_column_double(y,i).bitPattern,"float");default:let n=Int(sqlite3_column_bytes(x,i)),v=Int(sqlite3_column_bytes(y,i));try check(n==v,"bytes length");let aa=n==0 ? Data():Data(bytes:sqlite3_column_blob(x,i)!,count:n),bb=v==0 ? Data():Data(bytes:sqlite3_column_blob(y,i)!,count:v);try check(aa==bb,"exact text/blob")}}
            }
        }
    }
}
