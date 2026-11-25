import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main enum NativeUserAvatarStoreTests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value()else{throw NativeDBError.message("FAIL "+label)};checks+=1}
    static func rejects(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("FAIL accepted "+label)}
    static func rejectsAsync(_ label:String,_ body:()async throws->Void)async throws{do{try await body()}catch{checks+=1;return};throw NativeDBError.message("FAIL accepted "+label)}
    static func id(_ n:Int)->String{String(format:"b3000000-0000-4000-8000-%012d",n)}
    static func image(_ width:Int=800,_ height:Int=400)->CGImage{let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height));c.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1));c.fill(CGRect(x:(width-height)/2,y:0,width:height,height:height));return c.makeImage()!}
    static func encoded(_ image:CGImage,_ type:UTType,frames:Int=1)->Data{let data=NSMutableData(),dest=CGImageDestinationCreateWithData(data,type.identifier as CFString,frames,nil)!;for _ in 0..<frames{CGImageDestinationAddImage(dest,image,nil)};precondition(CGImageDestinationFinalize(dest));return data as Data}
    static func color(_ image:CGImage)->[UInt8]{var values=[UInt8](repeating:0,count:4);values.withUnsafeMutableBytes{let c=CGContext(data:$0.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:1,height:1))};return values}
    static func pixelBytes(_ image:CGImage)->Data{var bytes=Data(count:image.width*image.height*4);bytes.withUnsafeMutableBytes{raw in let context=CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))};return bytes}
    @MainActor static func main()async{_ = NSApplication.shared;NSApp.setActivationPolicy(.accessory);do{try await run();print("NativeUserAvatarStoreTests: \(checks) source contract / image / SQLite / filesystem checks passed")}catch{fputs("After \(checks): \(error.localizedDescription)\n",stderr);exit(1)}}
    @MainActor static func run()async throws{
        let n=URL(fileURLWithPath:CommandLine.arguments[1]),base=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NextCRM-Avatars-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        let db=try NativeDatabase(url:base.appendingPathComponent("data/crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"))
        for (i,role) in [(1,"admin"),(2,"user"),(3,"partner")]{_ = try db.insert("Users",values:["id":.text(id(i)),"email":.text("u\(i)@fixture.invalid"),"name":.text("利用者\(i)"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:id(1))}
        let service=CRMService(db:db,identity:.init(id:id(1),role:"admin",partnerAccountID:nil)),other=CRMService(db:db,identity:.init(id:id(2),role:"user",partnerAccountID:nil))
        let photoDir=base.appendingPathComponent("selected");try FileManager.default.createDirectory(at:photoDir,withIntermediateDirectories:true)
        let png=photoDir.appendingPathComponent("画像.original.exe"),jpeg=photoDir.appendingPathComponent("写真.jpeg"),gif=photoDir.appendingPathComponent("動画.gif"),webp=n.appendingPathComponent("build/user-avatar-webp.webp")
        try encoded(image(),.png).write(to:png);try encoded(image(),.jpeg).write(to:jpeg);try encoded(image(),.gif,frames:2).write(to:gif)
        var failure:NativeUserAvatarStore.Checkpoint?
        let store=try NativeUserAvatarStore(service:service,checkpoint:{phase in if phase==failure{throw NativeDBError.message("synthetic failure")}},clock:{Date().addingTimeInterval(3600)})
        func row(_ user:Int=1)throws->NativeRecord{try db.get("Users",key:["id":.text(id(user))])!}
        func files()throws->[String]{try FileManager.default.contentsOfDirectory(atPath:store.root.path).filter{$0.hasSuffix(".png") && !$0.contains(".original.")}.sorted()}
        func name(_ reference:String)->String{String(reference.dropFirst(NativeUserAvatarStore.prefix.count))}
        func path(_ reference:String)->URL{store.root.appendingPathComponent(name(reference))}
        func pendingPath(_ ticket:NativeUserAvatarStore.Prepared)->URL{store.root.appendingPathComponent(String(name(ticket.reference).dropLast(4))+".pending.png")}
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:n.appendingPathComponent("build/user-avatar-reference.json"))) as! [String:Any]
        try check(Set(reference["allowed"] as! [String])==Set(["image/png","image/jpeg","image/gif","image/webp"]),"original MIME allowlist")
        for (file,mime) in [(png,"image/png"),(jpeg,"image/jpeg"),(gif,"image/gif"),(webp,"image/webp")]{let before=try row()["avatar"],ticket=try await store.prepare(file)
            try check(ticket.sourceContentType==mime,"actual decoded MIME \(mime)");try check(try row()["avatar"]==before,"preview does not modify metadata")
            let preview=try store.preview(ticket);try check(preview.width==preview.height && preview.width<=256,"bounded square thumbnail")
            let pendingOriginal=try store.original(ticket);try check(pendingOriginal.data == Data(contentsOf:file) && pendingOriginal.contentType==mime,"prepared animation reads exact original \(mime)")
            try check(preview.bytesPerRow*preview.height<=256*256*4,"bounded retained pixels")
            if mime != "image/webp"{let pixel=color(preview);try check(pixel[1]>230 && pixel[0]<30,"center crop excludes red sides")}
            let receipt=try store.commit(ticket)
            try rejects("consumed preview cannot read original"){_ = try store.original(ticket)}
            let original=try store.original(forUserID:id(1))!;try check(original.data == Data(contentsOf:file) && original.contentType==mime,"exact original preserved \(mime)")
            if mime=="image/gif"{try check(CGImageSourceGetCount(CGImageSourceCreateWithData(original.data as CFData,nil)!)==2,"original animation frames retained")}
            try check(try row()["avatar"] == .text(receipt.reference),"metadata committed");try check(!receipt.cleanupDeferred,"old image cleanup complete")
            try check(try files().count==1,"one retained photo after replacement");try check(try FileManager.default.contentsOfDirectory(atPath:store.root.path).filter{$0 != ".lock"}.count==2,"only original and thumbnail retained");try check(try store.image(forUserID:id(1)) != nil,"stored image readable")
            var info=stat();try check(lstat(path(receipt.reference).path,&info)==0 && info.st_mode & 0o777==0o400,"private immutable file permissions")
            let stored=try Data(contentsOf:path(receipt.reference));try check(CGImageSourceGetCount(CGImageSourceCreateWithData(stored as CFData,nil)!)==1,"single PNG frame")
        }
        // Tiny fixtures source-checked against Chrome/Next/locked sharp in
        // build/avatar-orientation-candidate/verification.json. Keep bytes in
        // this isolated suite so it does not depend on retained build fixtures.
        let orientedAnimated=Data(base64Encoded:"UklGRigBAABXRUJQVlA4WAoAAAAaAAAACwAABwAAQU5JTQYAAAAAAAAAAQBBTk1GQgAAAAAAAAAAAAsAAAcAAJABAAJWUDhMKgAAAC8LwAEAHyAQSNofeo35FxAU+T/a/AdfJIBMwEJJt2puJX3LENH/eAzqAEFOTUYoAAAAAQAAAQAAAwAAAwAAkAEAAVZQOEwQAAAALwPAABAH0P/ofwEDEdH/AEFOTUYoAAAABAAAAAAAAwAAAwAAkAEAAlZQOEwQAAAALwPAAAAHEP3vf/8DEdH/AEFOTUYwAAAAAAAAAAAACwAABwAAkAEAAFZQOEwYAAAALwvAARAPEPMfAxgMgmybbffnvkJE/2M8RVhJRhoAAABJSSoACAAAAAEAEgEDAAEAAAAGAAAAAAAAAA==")!,orientedSingle=Data(base64Encoded:"UklGRpAAAABXRUJQVlA4WAoAAAAaAAAACwAABwAAQU5JTQYAAAAAAAAAAQBBTk1GQgAAAAAAAAAAAAsAAAcAAJABAAJWUDhMKgAAAC8LwAEAHyAQSNofeo35FxAU+T/a/AdfJIBMwEJJt2puJX3LENH/eAzqAEVYSUYaAAAASUkqAAgAAAABABIBAwABAAAABgAAAAAAAAA=")!,orientedStatic=Data(base64Encoded:"UklGRmoAAABXRUJQVlA4WAoAAAAYAAAACwAABwAAVlA4TCoAAAAvC8ABAB8gEEjaH3qN+RcQFPk/2vwHXySATMBCSbdqbiV9yxDR/3gM6gBFWElGGgAAAElJKgAIAAAAAQASAQMAAQAAAAYAAAAAAAAA")!
        let unorientedExpected=Data(base64Encoded:"/wAA//8AAP//AAD//wAA/wD/AP8A/wD/AP8A/wD/AP//AAD//wAA//8AAP//AAD/AP8A/wD/AP8A/wD/AP8A//8AAP//AAD//wAA//8AAP8A/wD/AP8A/wD/AP8A/wD//wAA//8AAP//AAD//wAA/wD/AP8A/wD/AP8A/wD/AP8AAP//AAD//wAA//8AAP////8A////AP///wD///8A/wAA//8AAP//AAD//wAA/////wD///8A////AP///wD/AAD//wAA//8AAP//AAD/////AP///wD///8A////AP8AAP//AAD//wAA//8AAP////8A////AP///wD///8A/w==")!
        let orientedExpected:[Data]=[
            "/wAA//8AAP//AAD//wAA/wD/AP8A/wD/AP8A/wD/AP//AAD//wAA//8AAP//AAD/AP8A/wD/AP8A/wD/AP8A//8AAP//AAD//wAA//8AAP8A/wD/AP8A/wD/AP8A/wD//wAA//8AAP//AAD//wAA/wD/AP8A/wD/AP8A/wD/AP8AAP//AAD//wAA//8AAP////8A////AP///wD///8A/wAA//8AAP//AAD//wAA/////wD///8A////AP///wD/AAD//wAA//8AAP//AAD/////AP///wD///8A////AP8AAP//AAD//wAA//8AAP////8A////AP///wD///8A/w==",
            "AP8A/wD/AP8A/wD/AP8A//8AAP//AAD//wAA//8AAP8A/wD/AP8A/wD/AP8A/wD//wAA//8AAP//AAD//wAA/wD/AP8A/wD/AP8A/wD/AP//AAD//wAA//8AAP//AAD/AP8A/wD/AP8A/wD/AP8A//8AAP//AAD//wAA//8AAP///wD///8A////AP///wD/AAD//wAA//8AAP//AAD/////AP///wD///8A////AP8AAP//AAD//wAA//8AAP////8A////AP///wD///8A/wAA//8AAP//AAD//wAA/////wD///8A////AP///wD/AAD//wAA//8AAP//AAD//w==",
            "//8A////AP///wD///8A/wAA//8AAP//AAD//wAA/////wD///8A////AP///wD/AAD//wAA//8AAP//AAD/////AP///wD///8A////AP8AAP//AAD//wAA//8AAP////8A////AP///wD///8A/wAA//8AAP//AAD//wAA//8A/wD/AP8A/wD/AP8A/wD//wAA//8AAP//AAD//wAA/wD/AP8A/wD/AP8A/wD/AP//AAD//wAA//8AAP//AAD/AP8A/wD/AP8A/wD/AP8A//8AAP//AAD//wAA//8AAP8A/wD/AP8A/wD/AP8A/wD//wAA//8AAP//AAD//wAA/w==",
            "AAD//wAA//8AAP//AAD/////AP///wD///8A////AP8AAP//AAD//wAA//8AAP////8A////AP///wD///8A/wAA//8AAP//AAD//wAA/////wD///8A////AP///wD/AAD//wAA//8AAP//AAD/////AP///wD///8A////AP//AAD//wAA//8AAP//AAD/AP8A/wD/AP8A/wD/AP8A//8AAP//AAD//wAA//8AAP8A/wD/AP8A/wD/AP8A/wD//wAA//8AAP//AAD//wAA/wD/AP8A/wD/AP8A/wD/AP//AAD//wAA//8AAP//AAD/AP8A/wD/AP8A/wD/AP8A/w==",
            "/wAA//8AAP//AAD//wAA/wAA//8AAP//AAD//wAA////AAD//wAA//8AAP//AAD/AAD//wAA//8AAP//AAD///8AAP//AAD//wAA//8AAP8AAP//AAD//wAA//8AAP///wAA//8AAP//AAD//wAA/wAA//8AAP//AAD//wAA//8A/wD/AP8A/wD/AP8A/wD///8A////AP///wD///8A/wD/AP8A/wD/AP8A/wD/AP///wD///8A////AP///wD/AP8A/wD/AP8A/wD/AP8A////AP///wD///8A////AP8A/wD/AP8A/wD/AP8A/wD///8A////AP///wD///8A/w==",
            "AAD//wAA//8AAP//AAD///8AAP//AAD//wAA//8AAP8AAP//AAD//wAA//8AAP///wAA//8AAP//AAD//wAA/wAA//8AAP//AAD//wAA////AAD//wAA//8AAP//AAD/AAD//wAA//8AAP//AAD///8AAP//AAD//wAA//8AAP///wD///8A////AP///wD/AP8A/wD/AP8A/wD/AP8A////AP///wD///8A////AP8A/wD/AP8A/wD/AP8A/wD///8A////AP///wD///8A/wD/AP8A/wD/AP8A/wD/AP///wD///8A////AP///wD/AP8A/wD/AP8A/wD/AP8A/w==",
            "//8A////AP///wD///8A/wD/AP8A/wD/AP8A/wD/AP///wD///8A////AP///wD/AP8A/wD/AP8A/wD/AP8A////AP///wD///8A////AP8A/wD/AP8A/wD/AP8A/wD///8A////AP///wD///8A/wD/AP8A/wD/AP8A/wD/AP8AAP//AAD//wAA//8AAP///wAA//8AAP//AAD//wAA/wAA//8AAP//AAD//wAA////AAD//wAA//8AAP//AAD/AAD//wAA//8AAP//AAD///8AAP//AAD//wAA//8AAP8AAP//AAD//wAA//8AAP///wAA//8AAP//AAD//wAA/w==",
            "AP8A/wD/AP8A/wD/AP8A////AP///wD///8A////AP8A/wD/AP8A/wD/AP8A/wD///8A////AP///wD///8A/wD/AP8A/wD/AP8A/wD/AP///wD///8A////AP///wD/AP8A/wD/AP8A/wD/AP8A////AP///wD///8A////AP//AAD//wAA//8AAP//AAD/AAD//wAA//8AAP//AAD///8AAP//AAD//wAA//8AAP8AAP//AAD//wAA//8AAP///wAA//8AAP//AAD//wAA/wAA//8AAP//AAD//wAA////AAD//wAA//8AAP//AAD/AAD//wAA//8AAP//AAD//w=="
        ].map{Data(base64Encoded:$0)!}
        for orientation in 1...8 {
            for (kind,source) in [("animated",orientedAnimated),("static",orientedStatic)] {
                var bytes=source;bytes[bytes.count-8]=UInt8(orientation)
                let file=photoDir.appendingPathComponent("orientation-\(kind)-\(orientation).webp");try bytes.write(to:file)
                let ticket=try await store.prepare(file),preview=try store.preview(ticket)
                try check(pixelBytes(preview)==(kind=="animated" ? unorientedExpected:orientedExpected[orientation-1]),"animated ignores/static retains EXIF \(kind)/\(orientation)")
                try check(try store.original(ticket).data==bytes,"orientation original remains exact")
                store.discard(ticket);try check(try files().count==1,"orientation stage cleanup")
            }
        }
        let singleFile=photoDir.appendingPathComponent("one-frame-oriented.webp");try orientedSingle.write(to:singleFile)
        let singleTicket=try await store.prepare(singleFile)
        try check(pixelBytes(try store.preview(singleTicket))==unorientedExpected,"one-frame animated WebP thumbnail ignores EXIF")
        try check(try store.original(singleTicket).data==orientedSingle,"one-frame original retained");store.discard(singleTicket)
        // JPEG keeps the existing EXIF transform. Use its actual encoded bytes
        // and check a rotated corner, independent of WebP animated metadata.
        let jpegSource=CGImageSourceCreateWithData(orientedStatic as CFData,nil)!,jpegBase=CGImageSourceCreateImageAtIndex(jpegSource,0,nil)!
        let jpegBytes=NSMutableData(),jpegDestination=CGImageDestinationCreateWithData(jpegBytes,UTType.jpeg.identifier as CFString,1,nil)!
        let jpegProperties:[CFString:Any]=[kCGImagePropertyOrientation:6,kCGImageDestinationLossyCompressionQuality:1.0]
        CGImageDestinationAddImage(jpegDestination,jpegBase,jpegProperties as CFDictionary);try check(CGImageDestinationFinalize(jpegDestination),"JPEG orientation fixture")
        let jpegFixtureSource=CGImageSourceCreateWithData(jpegBytes,nil)!;let jpegFixtureProperties=CGImageSourceCopyPropertiesAtIndex(jpegFixtureSource,0,nil)as! [CFString:Any];try check((jpegFixtureProperties[kCGImagePropertyOrientation]as? NSNumber)?.intValue==6,"JPEG fixture contains integer EXIF orientation")
        let jpegOrientedFile=photoDir.appendingPathComponent("oriented.jpeg");try (jpegBytes as Data).write(to:jpegOrientedFile)
        let jpegTicket=try await store.prepare(jpegOrientedFile),jpegPixels=pixelBytes(try store.preview(jpegTicket))
        try check(Int(jpegPixels[2])>Int(jpegPixels[0])+100 && Int(jpegPixels[2])>Int(jpegPixels[1])+100,"JPEG retains clockwise EXIF transform: \(Array(jpegPixels.prefix(16)))")
        try check(try store.original(jpegTicket).data==jpegBytes as Data,"JPEG original retained");store.discard(jpegTicket)
        try check(try files().count==1,"all orientation previews cleaned")
        let pending=try await store.prepare(png);store.discard(pending);try check(try files().count==1,"cancel removes staged image");try rejects("discarded original read"){_ = try store.original(pending)};try rejects("discarded ticket"){_ = try store.commit(pending)}
        let before=try row()["avatar"],bytesBefore=try Data(contentsOf:path(before.string)),audit=try db.auditCount("Users")
        for phase in [NativeUserAvatarStore.Checkpoint.beforeMetadata,.afterMetadata]{let t=try await store.prepare(png);failure=phase;try rejects("transaction rollback"){_ = try store.commit(t)};failure=nil;try check(try row()["avatar"]==before,"failed save retains old metadata");try check(try Data(contentsOf:path(before.string))==bytesBefore,"failed save retains old bytes");try check(try db.auditCount("Users")==audit,"failed save audit rollback");try check(try files().count==1,"failed save removes new file")}
        let t=try await store.prepare(png);failure = .beforeCleanup;let kept=try store.commit(t);failure=nil;try check(kept.cleanupDeferred,"cleanup failure explicit");try check(try files().count==2,"cleanup failure retains old until recovery");try check(try store.cleanupUnreferenced(olderThan:0)==1,"recovery removes only orphan");try check(try store.cleanupUnreferenced(olderThan:0)==0,"recovery idempotent and directory rewind")
        let shared=try row()["avatar"];_ = try db.update(row(2),changes:["avatar":shared],actor:id(1));_ = try await store.replace(jpeg);try check(FileManager.default.fileExists(atPath:path(shared.string).path),"another user's reference retains old photo")
        let otherStore=try NativeUserAvatarStore(service:other);try check(try otherStore.image(forUserID:id(1)) != nil,"authenticated internal avatar read")
        try check(try otherStore.clearCurrent(expectedReference:try row(2)["avatar"].string),"self clear cleanup");try check(!FileManager.default.fileExists(atPath:path(shared.string).path),"last reference cleanup")
        let a=try await store.prepare(png),b=try await store.prepare(jpeg);_ = try store.commit(a);try rejects("concurrent avatar CAS"){_ = try store.commit(b)};try check(try row()["avatar"] == .text(a.reference),"newer photo preserved")
        let clearRevision=try row().revision,clearAudit=try db.auditCount("Users")
        let clearOriginal=try store.original(forUserID:id(1))!.data
        try rejects("stale displayed photo cannot delete replacement"){_ = try store.clearCurrent(expectedReference:b.reference)}
        try check(try row()["avatar"] == .text(a.reference) && row().revision==clearRevision,"stale removal preserves reference and revision")
        try check(try db.auditCount("Users")==clearAudit && store.original(forUserID:id(1))?.data==clearOriginal,"stale removal preserves audit and original")
        for phase in [NativeUserAvatarStore.Checkpoint.beforeMetadata,.afterMetadata] {
            let cancellingStore=try NativeUserAvatarStore(service:service,checkpoint:{point in
                if point==phase {withUnsafeCurrentTask{$0?.cancel()}}
            })
            let removal=Task.detached{try cancellingStore.clearCurrent(expectedReference:a.reference)}
            try await rejectsAsync("photo removal cancelled before commit"){_ = try await removal.value}
            try check(try row()["avatar"] == .text(a.reference) && row().revision==clearRevision,"cancelled removal rolls back reference and revision")
            try check(try db.auditCount("Users")==clearAudit,"cancelled removal rolls back audit")
            try check(try store.original(forUserID:id(1))?.data==clearOriginal && store.image(forUserID:id(1)) != nil,"cancelled removal preserves original and thumbnail")
        }
        let ticket=try await store.prepare(png);try rejects("cross store original read"){_ = try otherStore.original(ticket)};try rejects("cross store ticket"){_ = try otherStore.commit(ticket)};store.discard(ticket)
        let noAuth=try await store.prepare(png);_ = try db.update(row(),changes:["userStatus":.text("INACTIVE")],actor:id(2));try rejects("revoked prepared original read"){_ = try store.original(noAuth)};try rejects("revoked commit"){_ = try store.commit(noAuth)};try rejects("revoked read"){_ = try store.image(forUserID:id(1))};_ = try db.update(row(),changes:["userStatus":.text("ACTIVE")],actor:id(2));try check(try files().count==1,"revoked staged file removed")
        try rejects("partner store"){_ = try NativeUserAvatarStore(service:CRMService(db:db,identity:.init(id:id(3),role:"partner",partnerAccountID:nil)))}
        let cancelled=Task{try await store.prepare(png)};cancelled.cancel();try await rejectsAsync("cancelled decoding"){_ = try await cancelled.value};try check(try files().count==1,"cancel leaves no stage")
        failure = .afterDecode;try await rejectsAsync("decode checkpoint failure"){_ = try await store.prepare(png)};failure=nil;try check(try files().count==1,"decode failure no file publication")
        let revoked=try NativeUserAvatarStore(service:service,checkpoint:{phase in if phase == .afterDecode{_ = try db.update(row(),changes:["banned":.integer(1)],actor:id(2))}})
        try await rejectsAsync("authority after detached decode"){_ = try await revoked.prepare(png)};_ = try db.update(row(),changes:["banned":.integer(0)],actor:id(2))
        // Actual file type wins over a user-controlled extension; unsupported and
        // oversized/decompression-bomb inputs never become metadata or a preview.
        let bad=photoDir.appendingPathComponent("bad.png");try Data("<svg/>".utf8).write(to:bad);try await rejectsAsync("SVG disguised PNG"){_ = try await store.prepare(bad)}
        let tiff=photoDir.appendingPathComponent("a.tiff");try encoded(image(20,20),.tiff).write(to:tiff);try await rejectsAsync("TIFF outside source allowlist"){_ = try await store.prepare(tiff)}
        let oversized=photoDir.appendingPathComponent("large.png");FileManager.default.createFile(atPath:oversized.path,contents:nil);let handle=try FileHandle(forWritingTo:oversized);try handle.truncate(atOffset:UInt64(NativeUserAvatarStore.maximumInputBytes+1));try handle.close();try await rejectsAsync("4 MiB input cap"){_ = try await store.prepare(oversized)}
        try await rejectsAsync("decoded pixel cap"){_ = try await store.prepare(n.appendingPathComponent("build/user-avatar-pixel-limit.png"))}
        let symlink=photoDir.appendingPathComponent("link.png");try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:png);try await rejectsAsync("source leaf symlink"){_ = try await store.prepare(symlink)}
        let parentLink=base.appendingPathComponent("linked");try FileManager.default.createSymbolicLink(at:parentLink,withDestinationURL:photoDir);try await rejectsAsync("source ancestor symlink"){_ = try await store.prepare(parentLink.appendingPathComponent(png.lastPathComponent))}
        let replaced=try await store.prepare(png),staged=pendingPath(replaced);try FileManager.default.removeItem(at:staged);try FileManager.default.createSymbolicLink(at:staged,withDestinationURL:png);try rejects("staged symlink read"){_ = try store.preview(replaced)};try rejects("staged symlink commit"){_ = try store.commit(replaced)};try check(try Data(contentsOf:png)==encoded(image(),.png),"outside selected image unchanged")
        let hard=try await store.prepare(png);try FileManager.default.removeItem(at:pendingPath(hard));try check(link(png.path,pendingPath(hard).path)==0,"fixture hard link");try rejects("hardlink preview"){_ = try store.preview(hard)};store.discard(hard)
        let current=try row()["avatar"],file=path(current.string);try FileManager.default.removeItem(at:file);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:png);try rejects("stored symlink read"){_ = try store.image(forUserID:id(1))};_ = try store.clearCurrent(expectedReference:try row()["avatar"].string);try check(FileManager.default.fileExists(atPath:png.path),"clear unlinks symlink itself")
        _ = try db.update(row(),changes:["avatar":.text("native-avatar:v1:../../selected/画像.original.exe")],actor:id(1));try rejects("reference traversal"){_ = try store.image(forUserID:id(1))}
        _ = try db.update(row(),changes:["avatar":.text("https://fixture.invalid/avatar.png")],actor:id(1));try check(try store.image(forUserID:id(1))==nil,"legacy URL not fetched")
        _ = try store.clearCurrent(expectedReference:try row()["avatar"].string);let old=store.root,renamed=old.deletingLastPathComponent().appendingPathComponent("held-avatar-inode"),external=base.appendingPathComponent("external");try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true);try FileManager.default.moveItem(at:old,to:renamed);try FileManager.default.createSymbolicLink(at:old,withDestinationURL:external)
        try await rejectsAsync("retargeted root rejects publication"){_ = try await store.replace(png)};try check(try FileManager.default.contentsOfDirectory(atPath:external.path).isEmpty && row()["avatar"] == .null,"directory fd prevents retargeting and metadata change")
        try rejects("new store symlink root"){_ = try NativeUserAvatarStore(service:service)};try FileManager.default.removeItem(at:old);try FileManager.default.moveItem(at:renamed,to:old)
        _ = try store.clearCurrent(expectedReference:try row()["avatar"].string);try check(try files().isEmpty,"delete clears metadata and file");try check(try FileManager.default.contentsOfDirectory(atPath:store.root.path)==[".lock"],"clear removes original and thumbnail")
        let otherPending=try await otherStore.prepare(png)
        try check(try store.cleanupUnreferenced(olderThan:0)==0,"GC preserves another store's fresh preview")
        try check(try otherStore.preview(otherPending).width>0,"other preview still readable");otherStore.discard(otherPending)
        var tamperedReference=""
        let tampered=try NativeUserAvatarStore(service:service,checkpoint:{phase in if phase == .beforeMetadata{let destination=path(tamperedReference);try FileManager.default.removeItem(at:destination);try FileManager.default.createSymbolicLink(at:destination,withDestinationURL:png)}})
        let tamperedTicket=try await tampered.prepare(png);tamperedReference=tamperedTicket.reference
        try rejects("published inode replacement"){_ = try tampered.commit(tamperedTicket)}
        try check(try row()["avatar"] == .null && files().isEmpty,"replaced inode rollback and safe unlink")
        _ = try db.update(row(),changes:["banned":.integer(1)],actor:id(2));try rejects("revoked clear"){_ = try store.clearCurrent(expectedReference:try row()["avatar"].string)};_ = try db.update(row(),changes:["banned":.integer(0)],actor:id(2))
        let exact=photoDir.appendingPathComponent("exact.png");try encoded(image(20,20),.png).write(to:exact);let exactHandle=try FileHandle(forWritingTo:exact);try exactHandle.truncate(atOffset:UInt64(NativeUserAvatarStore.maximumInputBytes));try exactHandle.close()
        let exactTicket=try await store.prepare(exact);try check(exactTicket.width==20,"exact 4 MiB accepted");try check(try store.original(exactTicket).data.count==NativeUserAvatarStore.maximumInputBytes,"prepared original exact 4MiB boundary");store.discard(exactTicket)
        let altered=try await store.prepare(png),originalPath=store.root.appendingPathComponent(String(name(altered.reference).dropLast(4))+".pending.original.png")
        try FileManager.default.removeItem(at:originalPath);try encoded(image(30,20),.png).write(to:originalPath);try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:originalPath.path)
        try rejects("altered pending original rejected before animation"){_ = try store.original(altered)};store.discard(altered)
        try await rejectsAsync("external URL input"){_ = try await store.prepare(URL(string:"https://fixture.invalid/photo.png")!)}
        let orphan=UUID().uuidString.lowercased()+".png";try encoded(image(10,10),.png).write(to:store.root.appendingPathComponent(orphan));try check(try store.cleanupUnreferenced(olderThan:0)==1,"later GC scan sees new orphan")
        try check(chmod(store.root.path,0o755)==0,"fixture root permissions");try rejects("root permission downgrade"){_ = try store.image(forUserID:id(1))};try check(chmod(store.root.path,0o700)==0,"restore private root")
        let lock=store.root.appendingPathComponent(".lock"),savedLock=store.root.appendingPathComponent("held-lock")
        try FileManager.default.moveItem(at:lock,to:savedLock);try Data().write(to:lock);try rejects("lock inode replacement"){_ = try store.image(forUserID:id(1))};try FileManager.default.removeItem(at:lock);try FileManager.default.moveItem(at:savedLock,to:lock)
        // Circular rendering uses the bounded image; no original file is retained.
        let avatar=NativeUserAvatarView(frame:NSRect(x:0,y:0,width:100,height:100));avatar.set(image:image(100,100),name:"山田 太郎")
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:100,pixelsHigh:100,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:400,bitsPerPixel:32)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap);avatar.draw(avatar.bounds);NSGraphicsContext.restoreGraphicsState();let corner=bitmap.colorAt(x:0,y:0)!,center=bitmap.colorAt(x:50,y:50)!
        try check(corner.alphaComponent<0.01 && center.alphaComponent>0.99,"circular object-cover view")
        try bitmap.representation(using:.png,properties:[:])!.write(to:n.appendingPathComponent("build/user-avatar-circle.png"))
        try check(try db.page("ImageUpload",fields:[]).total==0,"original unused ImageUpload bookkeeping not invented")
    }
}
