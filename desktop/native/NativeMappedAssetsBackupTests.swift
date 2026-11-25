import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main enum MappedAssetsBackupTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
    static func rejects(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("FAIL accepted: "+label)}
    final class Fixture {
        let root:URL,db:NativeDatabase,service:CRMService,resources:URL
        let invoice:NativeRecord,attachment:NativeRecord,user:NativeRecord,fallback:NativeRecord
        var mappings:[NativeOperationalAssets.Mapping]=[],files:[String:Data]=[:]
        init(_ resources:URL,_ root:URL)throws {
            self.root=root;self.resources=resources
            db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            let account=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("移行取引先")],actor:service.identity.id)
            invoice=try db.insert("Invoices",values:["createdBy":.text(service.identity.id),"accountId":account["id"],"currency":.text("JPY"),"pdfStorageKey":.text("invoices/original-source.pdf")],actor:service.identity.id)
            attachment=try db.insert("Invoice_Attachments",values:["invoiceId":invoice["id"],"storageKey":.text("invoices/source/attachments/original"),"filename":.text("過去添付.txt"),"mimeType":.text("text/plain"),"size":.integer(24),"uploadedBy":.text(service.identity.id)],actor:service.identity.id)
            let owner=try db.get("Users",key:["id":.text(service.identity.id)])!
            user=try db.update(owner,changes:["avatar":.text("https://objects.example.invalid/original-avatar.png")],actor:service.identity.id)
            fallback=try db.insert("Users",values:["email":.text("fallback@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE"),"image":.text("https://objects.example.invalid/original-image.png")],actor:service.identity.id)
            try mapped(invoice,field:"pdfStorageKey",data:Data("%PDF-1.4\nsynthetic historical invoice bytes\n".utf8),mime:"application/pdf")
            try mapped(attachment,field:"storageKey",data:Data("過去添付 exact raw bytes\n".utf8),mime:"text/plain")
            try avatar(user,field:"avatar");try avatar(fallback,field:"image")
        }
        func write(_ path:String,_ data:Data)throws {
            let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try data.write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);files[path]=data
        }
        func mapped(_ row:NativeRecord,field:String,data:Data,mime:String)throws {
            let local="invoice-pdfs/"+UUID().uuidString.lowercased()+".pdf";try write(local,data)
            let map=NativeOperationalAssets.Mapping(model:row.model,id:row["id"].string,field:field,sourceSHA256:NativeOperationalAssets.digest(row[field].string),local:local,mime:mime,bytes:Int64(data.count),sha256:NativeOperationalAssets.digest(String(decoding:data,as:UTF8.self)),avatarBinding:nil,contentBinding:nil)
            try NativeOperationalAssets.save(map,db:db);mappings.append(map)
        }
        func avatar(_ row:NativeRecord,field:String)throws {
            let image=CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            image.setFillColor(CGColor(red:0.2,green:0.4,blue:0.8,alpha:1));image.fill(CGRect(x:0,y:0,width:2,height:2))
            let data=NSMutableData(),destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(destination,image.makeImage()!,nil);guard CGImageDestinationFinalize(destination) else{throw NativeDBError.conflict}
            let original=data as Data,prepared=try NativeUserAvatarStore.migrationImage(original),id=UUID().uuidString.lowercased()
            try write("native-avatars/"+id+".png",prepared.thumbnail);try write("native-avatars/"+id+".original.png",original)
            let map=NativeOperationalAssets.Mapping(model:"Users",id:row["id"].string,field:field,sourceSHA256:NativeOperationalAssets.digest(row[field].string),local:"native-avatar:v1:"+id+".png",mime:prepared.mime,bytes:Int64(original.count),sha256:NativeMigrationCodec.hash(original),avatarBinding:NativeOperationalAssets.avatarBinding(row),contentBinding:nil)
            try NativeOperationalAssets.save(map,db:db);mappings.append(map)
        }
        func snapshot(_ name:String,base:URL)->NativeBackupResult{NativeBackup().prepare(source:db,destinationURL:base.appendingPathComponent(name))}
        func raw(_ map:NativeOperationalAssets.Mapping)throws->String{try db.metadata(NativeOperationalAssets.key(model:map.model,id:map.id,field:map.field))!}
        func replace(_ map:NativeOperationalAssets.Mapping,with object:[String:Any])throws{try db.setMetadata(NativeOperationalAssets.key(model:map.model,id:map.id,field:map.field),value:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self))}
    }
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("MappedAssetsBackupTests: \(error)\n".utf8));exit(1)}}
    static func run()throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
        let base=try NativeMigrationImportWorkspace.resolvedTemporaryDirectory().appendingPathComponent("NextCRM-G05-Assets-"+UUID().uuidString.lowercased());try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        let f=try Fixture(resources,base.appendingPathComponent("source"));let rows=[f.invoice,f.attachment,f.user,f.fallback],raw=try f.mappings.map{try f.raw($0)}
        try check(try Data(contentsOf:f.service.invoicePDFURL(f.invoice))==f.files[f.mappings[0].local],"actual invoice reader resolves original source mapping before backup")
        let store=try NativeUserAvatarStore(service:f.service)
        for u in [f.user,f.fallback] {try check(try store.image(forUserID:u["id"].string) != nil && store.original(forUserID:u["id"].string) != nil,"actual avatar reader resolves mapped image before backup")}
        let backup=f.snapshot("backup",base:base);try check(backup.candidateCreated,"mapped backup created: "+backup.diagnostics.map(\.code).joined(separator:","))
        let restoredURL=base.appendingPathComponent("restored"),restore=NativeRestore().prepare(backupURL:base.appendingPathComponent("backup"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:restoredURL)
        try check(restore.candidateCreated,"mapped restore staged: "+restore.diagnostics.map(\.code).joined(separator:","))
        let db=try NativeDatabase(url:restoredURL.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),service=CRMService(db:db,identity:f.service.identity)
        for row in rows {try check(try db.get(row.model,key:f.db.key(for:row))!.values==row.values,"source business fields kept exactly, no flattening")}
        for (i,map) in f.mappings.enumerated() {try check(try db.metadata(NativeOperationalAssets.key(model:map.model,id:map.id,field:map.field))==raw[i],"mapping metadata bytes preserved")}
        let restoredStore=try NativeUserAvatarStore(service:service)

            try check(backup.fileCount==6 && restore.fileCount==6,"all PDF, attachment and two avatar pairs copied")
            try check(!backup.pending.contains(.externalFiles),"fully mapped original references do not create false external-file pending")
            for (path,data) in f.files {try check(try Data(contentsOf:restoredURL.appendingPathComponent(path))==data,"mapped exact bytes read after restore")}
            try check(try Data(contentsOf:service.invoicePDFURL(f.invoice))==f.files[f.mappings[0].local],"actual invoice reader opens restored historical bytes")
            let attachmentPath=try NativeOperationalAssets.localReference(f.attachment,field:"storageKey",db:db)!
            try check(try Data(contentsOf:restoredURL.appendingPathComponent(attachmentPath))==f.files[f.mappings[1].local],"attachment mapping is usable without changing original key")
            for u in [f.user,f.fallback] {try check(try restoredStore.image(forUserID:u["id"].string) != nil && restoredStore.original(forUserID:u["id"].string)?.data==store.original(forUserID:u["id"].string)?.data,"actual avatar display/original exact after restore")}
            let live=try db.get("Users",key:["id":.text(service.identity.id)])!;_=try db.update(live,changes:["banned":.integer(1)],actor:service.identity.id)
            try rejects("restored mapped invoice still rechecks fresh banned authority"){_ = try service.invoicePDFURL(f.invoice)}
            try rejects("restored mapped avatar still rechecks fresh banned authority"){_ = try restoredStore.image(forUserID:f.user["id"].string)}
            try boundaries(f,base:base)
        for (path,data) in f.files {try check(try Data(contentsOf:f.root.appendingPathComponent(path))==data,"source asset bytes retained")}
        let result:[String:Any]=["mode":"production","checks":checks,"backupFiles":backup.fileCount,"restoredFiles":restore.fileCount,"maps":f.mappings.count,"realNetworkRequests":0,"realKeychainCalls":0,"fixtureWillBeRemoved":true,"actualReaders":["CRMService.invoicePDFURL","NativeUserAvatarStore.image","NativeUserAvatarStore.original","NativeOperationalAssets.localReference"]]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out);print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
    }
    static func boundaries(_ f:Fixture,base:URL)throws {
        let map=f.mappings[0],key=NativeOperationalAssets.key(model:map.model,id:map.id,field:map.field),raw=try f.raw(map)
        var object=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
        for (field,value) in [("id",UUID().uuidString.lowercased()),("sourceSHA256",String(repeating:"0",count:64)),("field","wrong"),("model","Users")] {
            var changed=object;changed[field]=value;try f.replace(map,with:changed)
            let result=f.snapshot("stale-"+field,base:base)
            try check(result.candidateCreated && result.fileCount==5 && result.pending.contains(.externalFiles),"stale "+field+" metadata cannot shadow original reference")
        }
        try f.db.setMetadata(key,value:raw)
        for (label,value) in [("malformed","{"),("oversized",String(repeating:"x",count:8193))] {
            try f.db.setMetadata(key,value:value);let result=f.snapshot(label,base:base);try check(!result.candidateCreated,"invalid mapped metadata "+label+" fails closed")
        }
        try f.db.setMetadata(key,value:raw)
        object["sha256"]=String(repeating:"0",count:64);try f.replace(map,with:object);try check(!f.snapshot("bad-hash",base:base).candidateCreated,"wrong imported file hash fails")
        try f.db.setMetadata(key,value:raw)
        let file=f.root.appendingPathComponent(map.local),data=f.files[map.local]!;try FileManager.default.removeItem(at:file);try check(!f.snapshot("missing",base:base).candidateCreated,"missing imported invoice fails")
        try data.write(to:file)
        let fresh=try f.db.get("Invoices",key:f.db.key(for:f.invoice))!;_=try f.db.update(fresh,changes:["pdfStorageKey":.text("invoices/new-source.pdf")],actor:f.service.identity.id)
        let changed=f.snapshot("edited-field",base:base);try check(changed.candidateCreated && changed.fileCount==5 && changed.pending.contains(.externalFiles),"current source edit disables old import mapping")
        _=try f.db.update(f.db.get("Invoices",key:f.db.key(for:f.invoice))!,changes:["pdfStorageKey":f.invoice["pdfStorageKey"]],actor:f.service.identity.id)
        let avatar=f.mappings[2],avatarKey=NativeOperationalAssets.key(model:avatar.model,id:avatar.id,field:avatar.field),avatarRaw=try f.raw(avatar)
        var avatarObject=try JSONSerialization.jsonObject(with:Data(avatarRaw.utf8)) as! [String:Any];avatarObject["avatarBinding"]=String(repeating:"0",count:64);try f.replace(avatar,with:avatarObject)
        let binding=f.snapshot("avatar-binding",base:base);try check(binding.candidateCreated && binding.fileCount==4 && binding.pending.contains(.externalFiles),"stale combined avatar/image scalar binding remains external")
        try f.db.setMetadata(avatarKey,value:avatarRaw)
        try f.db.setMetadata("migration.avatar.cleared.v1."+avatar.id,value:NativeOperationalAssets.avatarBinding(f.user))
        let cleared=f.snapshot("avatar-cleared",base:base);try check(cleared.candidateCreated && cleared.fileCount==4,"explicit avatar clear marker is respected")
        try f.db.setMetadata("migration.avatar.cleared.v1."+avatar.id,value:"")
        let original="native-avatars/"+String(avatar.local.dropFirst("native-avatar:v1:".count).dropLast(4))+".original.png",originalURL=f.root.appendingPathComponent(original)
        try FileManager.default.removeItem(at:originalURL);let missingOriginal=f.snapshot("avatar-original-missing",base:base);try check(!missingOriginal.candidateCreated,"mapped avatar requires original, never silent thumbnail-only success")
        try f.files[original]!.write(to:originalURL);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:originalURL.path)
        // An outer rollback cannot rewrite source mapping or retire its files.
        enum Rollback:Error{case expected}
        do {try f.db.transaction {try f.db.setMetadata(key,value:"{}");throw Rollback.expected}}catch Rollback.expected{}
        try check(try f.raw(map)==raw && Data(contentsOf:file)==data,"outer rollback preserves exact map and immutable file")
        var cancel=false
        let cancelled=NativeBackup(cancelled:{cancel},checkpoint:{if $0=="pinsComplete"{cancel=true}}).prepare(source:f.db,destinationURL:base.appendingPathComponent("mapped-cancel"))
        try check(cancelled.status == .cancelled && !FileManager.default.fileExists(atPath:base.appendingPathComponent("mapped-cancel").path),"cancel after asset pins removes only new staging")
        let final=f.snapshot("final",base:base);try check(final.candidateCreated && final.fileCount==6,"same source remains fully usable after all rejected candidates")
    }
}
