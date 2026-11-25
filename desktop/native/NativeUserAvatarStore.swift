import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import Darwin

/// Local replacement for the original presigned avatar upload. Only immutable,
/// original bytes and a sanitized 256px PNG persist as one UUID bundle.
/// No path or remote URL from Users is opened.
final class NativeUserAvatarStore {
    static let maximumInputBytes = 4 * 1024 * 1024 // original profile uploader
    static let maximumSourcePixels = 16_777_216
    static let maximumSourceDimension = 16_384
    static let outputSide = 256, maximumStoredBytes = 1024 * 1024
    static let prefix = "native-avatar:v1:"
    struct Prepared {
        fileprivate let ticket:UUID, store:UUID
        let reference:String, sourceContentType:String
        let width:Int, height:Int
    }
    struct Receipt { let reference:String; let cleanupDeferred:Bool }
    struct Original { let data:Data, contentType:String }
    private static let originalExtensions=["image/png":"png","image/jpeg":"jpg","image/gif":"gif","image/webp":"webp"]
    enum Checkpoint { case afterDecode, beforeMetadata, afterMetadata, beforeCleanup }
    private struct Pending { let prepared:Prepared; let previous:SQLValue; let owner:String; let filename:String; let originalFilename:String; let originalDigest:Data; let createdAt:Date }
    private let service:CRMService, directory:Int32, lockFile:Int32, storeID=UUID(), mutex=NSRecursiveLock()
    private let checkpoint:(Checkpoint)throws->Void, clock:()->Date
    private var pending:[UUID:Pending]=[:]
    let root:URL
    init(service:CRMService, checkpoint:@escaping(Checkpoint)throws->Void={_ in}, clock:@escaping()->Date=Date.init)throws{
        try service.authenticated();guard service.identity.role != "partner" else{throw Self.failure("この利用者ではプロフィール写真を変更できません。")}
        self.service=service;self.checkpoint=checkpoint;self.clock=clock
        root=service.db.url.deletingLastPathComponent().appendingPathComponent("native-avatars",isDirectory:true)
        let parent=try Self.openDirectory(service.db.url.deletingLastPathComponent());defer{Darwin.close(parent)}
        if mkdirat(parent,"native-avatars",0o700) != 0 && errno != EEXIST {throw Self.failure("写真の保存フォルダを作成できません。")}
        let fd=openat(parent,"native-avatars",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw Self.failure("写真の保存先にリンクは使用できません。")}
        do{var info=stat();guard fstat(fd,&info)==0,info.st_uid==geteuid(),info.st_mode & 0o077 == 0 else{throw Self.failure("写真の保存先は本人だけがアクセスできるフォルダを指定してください。")}
            let lock=openat(fd,".lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard lock>=0 else{throw Self.failure("写真の保存先をロックできません。")}
            do{_ = try Self.regular(lock,maximum:1,privateFile:true)}catch{Darwin.close(lock);throw error}
            directory=fd;lockFile=lock
        }catch{Darwin.close(fd);throw error}
    }
    deinit{for item in pending.values{_ = unlinkat(directory,item.filename,0);_ = unlinkat(directory,item.originalFilename,0)};Darwin.close(lockFile);Darwin.close(directory)}
    private static func failure(_ text:String)->NativeDBError{.message(text)}
    /// Every component is opened relative to its already pinned parent. This
    /// rejects ancestor symlinks too, and never follows a replaced root path.
    private static func openDirectory(_ url:URL)throws->Int32{
        guard url.isFileURL,url.path.hasPrefix("/"),!url.path.contains("\0")else{throw failure("このMacの保存先を指定してください。")}
        guard !url.pathComponents.contains(".."),!url.pathComponents.contains(".")else{throw failure("保存先のパスが正しくありません。")}
        var components=Array(url.pathComponents.dropFirst())
        // macOS's root-owned /var and /tmp aliases also appear in Foundation's
        // supposedly resolved temporary URLs. Trust only these exact OS links;
        // every user-controlled component below them still uses O_NOFOLLOW.
        if let first=components.first,["var","tmp","etc"].contains(first){
            var info=stat()
            if lstat("/"+first,&info)==0,info.st_mode & S_IFMT == S_IFLNK {
                var bytes=[CChar](repeating:0,count:128)
                let count=readlink("/"+first,&bytes,bytes.count-1)
                guard info.st_uid==0,count>0 else{throw failure("保存先のシステムパスを確認できません。")}
                let target=String(cString:bytes)
                guard target=="private/"+first || target=="/private/"+first else{throw failure("保存先のシステムパスが正しくありません。")}
                components.insert("private",at:0)
            }
        }
        var fd=Darwin.open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard fd>=0 else{throw failure("保存先を開けません。")}
        do{for component in components{let next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else{throw failure("保存先のフォルダにリンクは使用できません。")};Darwin.close(fd);fd=next};return fd}catch{Darwin.close(fd);throw error}
    }
    private static func regular(_ fd:Int32,maximum:Int,privateFile:Bool=false)throws->stat{
        var info=stat();guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_size>=0,info.st_size<=maximum else{throw failure("画像ファイルの形式またはサイズを確認してください。入力は4 MiBまでです。")}
        if privateFile{guard info.st_uid==geteuid(),info.st_nlink==1,info.st_mode & 0o077 == 0 else{throw failure("保存済み写真のアクセス権が不正です。")}}
        return info
    }
    private func synchronized<T>(_ body:()throws->T)throws->T{mutex.lock();defer{mutex.unlock()};return try body()}
    private func verifyRoot()throws{
        let parent=try Self.openDirectory(service.db.url.deletingLastPathComponent());defer{Darwin.close(parent)}
        var linked=stat(),held=stat(),linkedLock=stat(),heldLock=stat()
        guard fstatat(parent,"native-avatars",&linked,AT_SYMLINK_NOFOLLOW)==0,fstat(directory,&held)==0,
              linked.st_mode & S_IFMT == S_IFDIR,linked.st_uid==geteuid(),linked.st_mode & 0o077 == 0,
              linked.st_ino==held.st_ino,linked.st_dev==held.st_dev,
              fstatat(directory,".lock",&linkedLock,AT_SYMLINK_NOFOLLOW)==0,fstat(lockFile,&heldLock)==0,
              linkedLock.st_mode & S_IFMT == S_IFREG,linkedLock.st_nlink==1,
              linkedLock.st_ino==heldLock.st_ino,linkedLock.st_dev==heldLock.st_dev else{throw Self.failure("写真の保存先が変更されました。アプリを開き直して確認してください。")}
    }
    private func locked<T>(verifyRoot:Bool=true,_ body:()throws->T)throws->T{
        try synchronized{while flock(lockFile,LOCK_EX) != 0{if errno != EINTR{throw Self.failure("写真の保存先をロックできません。")}};defer{_ = flock(lockFile,LOCK_UN)};if verifyRoot{try self.verifyRoot()};return try body()}
    }
    private func currentUser()throws->NativeRecord{
        try service.authenticated();guard service.identity.role != "partner",let row=try service.db.get("Users",key:["id":.text(service.identity.id)])else{throw Self.failure("この利用者ではプロフィール写真を変更できません。")};return row
    }
    private static func equal(_ a:SQLValue,_ b:SQLValue)->Bool{if case let .text(x)=a,case let .text(y)=b{return x.utf8.elementsEqual(y.utf8)};return a==b}
    private static func filename(_ reference:String)throws->String{
        guard reference.hasPrefix(prefix)else{throw failure("この写真はアプリ内の保存形式ではありません。")}
        let name=String(reference.dropFirst(prefix.count));guard name.hasSuffix(".png"),let uuid=UUID(uuidString:String(name.dropLast(4))),uuid.uuidString.lowercased()+".png"==name else{throw failure("写真の識別子が正しくありません。")};return name
    }
    private static func bytes(_ fd:Int32,maximum:Int)throws->Data{
        let info=try regular(fd,maximum:maximum);var data=Data();data.reserveCapacity(Int(info.st_size));var chunk=[UInt8](repeating:0,count:64*1024)
        while true{try Task.checkCancellation();let amount=chunk.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,$0.count)};if amount<0 && errno==EINTR{continue};guard amount>=0 else{throw failure("写真を読み取れません。")};if amount==0{break};guard data.count<=maximum-amount else{throw failure("プロフィール写真は4 MiB以内で選択してください。")};data.append(contentsOf:chunk.prefix(amount))}
        let after=try regular(fd,maximum:maximum)
        guard after.st_size==info.st_size,after.st_mtimespec.tv_sec==info.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==info.st_mtimespec.tv_nsec,data.count==Int(info.st_size)else{throw failure("選択した写真が変更されました。もう一度選択してください。")};return data
    }
    private static func source(_ data:Data)throws->(CGImageSource,String,Int,Int){
        guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)>0,let type=CGImageSourceGetType(source) as String?,let mime=[UTType.png.identifier:"image/png",UTType.jpeg.identifier:"image/jpeg",UTType.gif.identifier:"image/gif",UTType.webP.identifier:"image/webp"][type],let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=props[kCGImagePropertyPixelWidth] as? NSNumber,let h=props[kCGImagePropertyPixelHeight] as? NSNumber else{throw failure("PNG・JPEG・GIF・WebP の画像を選択してください。")}
        let width=w.intValue,height=h.intValue
        guard width>0,height>0,width<=maximumSourceDimension,height<=maximumSourceDimension,width<=maximumSourcePixels/height else{throw failure("写真の画素数が上限を超えています。1,677万画素以内の画像を選択してください。")}
        return(source,mime,width,height)
    }
    /// No frame decode or metadata array: inspect only bounded RIFF chunks.
    /// One ANMF is enough; browser playback also ignores EXIF for that case.
    private static func animatedWebP(_ data:Data)->Bool {
        guard data.count>=30,String(bytes:data.prefix(4),encoding:.ascii)=="RIFF",
              String(bytes:data[8..<16],encoding:.ascii)=="WEBPVP8X",
              data[16]==10,data[17]==0,data[18]==0,data[19]==0,data[20]&2 != 0 else{return false}
        func little(_ offset:Int)->Int{Int(data[offset]) | (Int(data[offset+1])<<8) | (Int(data[offset+2])<<16) | (Int(data[offset+3])<<24)}
        let end=little(4)+8;guard end>=30,end<=data.count else{return false}
        var offset=30,animation=false
        while offset<end {
            guard end-offset>=8 else{return false}
            let size=little(offset+4),start=offset+8
            guard size<=end-start,size+size%2<=end-start else{return false}
            let tag=String(bytes:data[offset..<(offset+4)],encoding:.ascii)
            if tag=="ANIM"{guard size==6 else{return false};animation=true}
            if tag=="ANMF"{return animation && size>=16}
            offset=start+size+size%2
        }
        return false
    }
    private static func canonical(_ data:Data)throws->(Data,String){
        let(source,mime,_,_)=try source(data)
        let transform = !(mime=="image/webp" && animatedWebP(data))
        guard let thumb=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:transform,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceShouldCacheImmediately:true,kCGImageSourceShouldCache:false] as CFDictionary)else{throw failure("画像を読み込めません。破損していない画像を選択してください。")}
        let side=min(thumb.width,thumb.height),target=min(outputSide,side)
        guard side>0,thumb.width<=512,thumb.height<=512,let cropped=thumb.cropping(to:CGRect(x:(thumb.width-side)/2,y:(thumb.height-side)/2,width:side,height:side)),let context=CGContext(data:nil,width:target,height:target,bitsPerComponent:8,bytesPerRow:target*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw failure("写真のプレビューを作成できません。")}
        context.interpolationQuality = .high;context.draw(cropped,in:CGRect(x:0,y:0,width:target,height:target));guard let image=context.makeImage()else{throw failure("写真を変換できません。")}
        let output=NSMutableData();guard let destination=CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil)else{throw failure("写真を保存形式に変換できません。")}
        CGImageDestinationAddImage(destination,image,[: ] as CFDictionary)
        guard CGImageDestinationFinalize(destination),output.length<=maximumStoredBytes else{throw failure("写真の変換結果が大きすぎます。")};return(output as Data,mime)
    }
    private func write(_ data:Data,name:String)throws{
        let fd=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw Self.failure("写真を保存できません。空き容量を確認してください。")};var done=false;defer{Darwin.close(fd);if !done{_ = unlinkat(directory,name,0)}}
        try data.withUnsafeBytes{buffer in var offset=0;while offset<buffer.count{try Task.checkCancellation();let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset);if count<0 && errno==EINTR{continue};guard count>0 else{throw Self.failure("写真を書き込めません。")};offset+=count}}
        guard fchmod(fd,0o400)==0,fsync(fd)==0,fsync(directory)==0 else{throw Self.failure("写真の保存を確定できません。")};done=true
    }
    /// Offline migration codec only. It does not authenticate, save or publish.
    static func migrationImage(_ data:Data)throws->(thumbnail:Data,mime:String,extensionName:String){
        guard data.count<=maximumInputBytes else{throw failure("移行する写真は4 MiB以内である必要があります。")}
        let value=try canonical(data);return(value.0,value.1,originalExtensions[value.1]!)
    }
    private func resolvedAvatar(_ user:NativeRecord)throws->String {
        try NativeOperationalAssets.avatar(user,db:service.db) ?? user["avatar"].string
    }
    func prepare(_ file:URL)async throws->Prepared{
        let work=Task.detached(priority:.utility){try self.prepareSynchronously(file)}
        return try await withTaskCancellationHandler(operation:{let prepared=try await work.value;do{try Task.checkCancellation();try service.db.transaction{_ = try currentUser()};return prepared}catch{discard(prepared);throw error}},onCancel:{work.cancel()})
    }
    private func prepareSynchronously(_ file:URL)throws->Prepared{
        try synchronized{try autoreleasepool{
            guard pending.count<4 else{throw Self.failure("未保存の写真を保存または取り消してから選択してください。")}
            let before=try service.db.transaction{try currentUser()}
            guard file.isFileURL,[nil,"","localhost"].contains(file.host),file.query==nil,file.fragment==nil,!file.lastPathComponent.isEmpty,!file.lastPathComponent.contains("\0") else{throw Self.failure("このMacの画像ファイルを選択してください。")}
            let parent=try Self.openDirectory(file.deletingLastPathComponent());defer{Darwin.close(parent)}
            let fd=openat(parent,file.lastPathComponent,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw Self.failure("画像ファイルを開けません。リンクは選択できません。")};defer{Darwin.close(fd)}
            let data=try Self.bytes(fd,maximum:Self.maximumInputBytes)
            let(output,mime)=try Self.canonical(data);try checkpoint(.afterDecode);try Task.checkCancellation()
            return try locked{
                let ticket=UUID(),name=ticket.uuidString.lowercased(),file=name+".pending.png",original=name+".pending.original."+Self.originalExtensions[mime]!,reference=Self.prefix+name+".png"
                let source=try Self.source(output);let prepared=Prepared(ticket:ticket,store:storeID,reference:reference,sourceContentType:mime,width:source.2,height:source.3)
                do {
                    try service.db.transaction{let current=try currentUser();guard Self.equal(current["avatar"],before["avatar"])else{throw NativeDBError.conflict}}
                    // File I/O stays outside the DB transaction. Reauthenticate
                    // after it before exposing the prepared pair to the caller.
                    try write(data,name:original);try write(output,name:file)
                    try service.db.transaction{let current=try currentUser();guard Self.equal(current["avatar"],before["avatar"])else{throw NativeDBError.conflict}}
                    pending[ticket]=Pending(prepared:prepared,previous:before["avatar"],owner:before["id"].string,filename:file,originalFilename:original,originalDigest:Data(SHA256.hash(data:data)),createdAt:clock());return prepared
                } catch {_ = unlinkat(directory,file,0);_ = unlinkat(directory,original,0);throw error}
            }
        }}
    }
    @discardableResult func commit(_ prepared:Prepared)throws->Receipt{
        try locked{
            guard prepared.store==storeID,let item=pending[prepared.ticket],item.owner==service.identity.id else{throw Self.failure("写真のプレビューが見つかりません。もう一度選択してください。")}
            let final=try Self.filename(prepared.reference),originalFinal=String(final.dropLast(4))+".original."+Self.originalExtensions[prepared.sourceContentType]!
            var committed=false,published:[String]=[]
            defer{pending.removeValue(forKey:prepared.ticket);if !committed{for name in [item.filename,item.originalFilename]+published{_ = unlinkat(directory,name,0)}}}
            guard clock().timeIntervalSince(item.createdAt)<=86400 else{throw Self.failure("写真のプレビューの有効期限が切れました。もう一度選択してください。")}
            try service.db.transaction{
                let current=try currentUser();guard Self.equal(current["avatar"],item.previous)else{throw NativeDBError.conflict};try Task.checkCancellation()
                let thumb=openat(directory,item.filename,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC),original=openat(directory,item.originalFilename,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
                defer{if thumb>=0{Darwin.close(thumb)};if original>=0{Darwin.close(original)}}
                guard thumb>=0,original>=0 else{throw Self.failure("写真のプレビューまたは元画像を開けません。")}
                let thumbInfo=try Self.regular(thumb,maximum:Self.maximumStoredBytes,privateFile:true),originalInfo=try Self.regular(original,maximum:Self.maximumInputBytes,privateFile:true)
                _ = try decodedImage(thumb)
                let originalBytes=try Self.bytes(original,maximum:Self.maximumInputBytes)
                guard Data(SHA256.hash(data:originalBytes))==item.originalDigest else{throw Self.failure("プレビューの元画像が変更されました。もう一度選択してください。")}
                for (from,to) in [(item.originalFilename,originalFinal),(item.filename,final)]{
                    guard renameatx_np(directory,from,directory,to,UInt32(RENAME_EXCL))==0 else{throw Self.failure("写真を公開できません。")};published.append(to)
                }
                guard fsync(directory)==0 else{throw Self.failure("写真の保存を確定できません。")}
                try checkpoint(.beforeMetadata);try verifyRoot();let latest=try currentUser();guard Self.equal(latest["avatar"],item.previous)else{throw NativeDBError.conflict}
                for (name,info) in [(final,thumbInfo),(originalFinal,originalInfo)]{
                    var after=stat();guard fstatat(directory,name,&after,AT_SYMLINK_NOFOLLOW)==0,after.st_mode & S_IFMT == S_IFREG,after.st_ino==info.st_ino,after.st_dev==info.st_dev,after.st_size==info.st_size else{throw NativeDBError.conflict}
                }
                _ = try service.db.update(latest,changes:["avatar":.text(prepared.reference)],actor:service.identity.id,action:"user_avatar");try checkpoint(.afterMetadata);try verifyRoot();_ = try currentUser();try Task.checkCancellation()
            };committed=true
            let cleaned=cleanupReference(item.previous);return Receipt(reference:prepared.reference,cleanupDeferred:!cleaned)
        }
    }
    func discard(_ prepared:Prepared){try? locked(verifyRoot:false){guard prepared.store==storeID,let item=pending.removeValue(forKey:prepared.ticket)else{return};_ = unlinkat(directory,item.filename,0);_ = unlinkat(directory,item.originalFilename,0)}}
    func replace(_ file:URL)async throws->String{let prepared=try await prepare(file);do{try Task.checkCancellation();return try commit(prepared).reference}catch{discard(prepared);throw error}}
    var gateway:(URL)async throws->String{{[self] file in try await replace(file)}}
    @discardableResult func clearCurrent(expectedReference:String)throws->Bool{
        try locked{
            let previous=try service.db.transaction{
                try Task.checkCancellation()
                let user=try currentUser()
                // Delete only the photo the caller displayed and confirmed.
                // Another profile window may already have saved a replacement.
                guard user["avatar"].string==expectedReference else{throw NativeDBError.conflict}
                try checkpoint(.beforeMetadata);try verifyRoot()
                let latest=try currentUser()
                guard Self.equal(latest["avatar"],user["avatar"])else{throw NativeDBError.conflict}
                try Task.checkCancellation()
                let cleared = try service.db.update(latest,changes:["avatar":.null],actor:service.identity.id,action:"user_avatar_clear")
                if try NativeOperationalAssets.avatar(latest,db:service.db) != nil {try service.db.setMetadata("migration.avatar.cleared.v1."+latest["id"].string,value:NativeOperationalAssets.avatarBinding(cleared))}
                try checkpoint(.afterMetadata);try verifyRoot();_ = try currentUser()
                // Cancellation before commit must roll back both the reference
                // and its audit entry. Cleanup starts only after commit succeeds.
                try Task.checkCancellation()
                return user["avatar"]
            }
            return cleanupReference(previous)
        }
    }
    private static func bundleFiles(_ reference:String,pending:Bool=false)throws->[String]{
        let file=try filename(reference),base=String(file.dropLast(4))+(pending ? ".pending":"")
        return [base+".png"]+originalExtensions.values.sorted().map{base+".original."+$0}
    }
    private func cleanupReference(_ reference:SQLValue)->Bool{
        guard let files=try? Self.bundleFiles(reference.string)else{return true}
        do{try checkpoint(.beforeCleanup);return try service.db.transaction{if try service.db.page("Users",fields:[],equal:["avatar":reference],limit:1).total>0{return true};for file in files{if unlinkat(directory,file,0) != 0 && errno != ENOENT{throw Self.failure("以前の写真を削除できません。")}};return true}}catch{return false}
    }
    private func originalFile(_ reference:String)throws->(String,String){
        let base=String(try Self.filename(reference).dropLast(4));var found:(String,String)?
        for (mime,ext) in Self.originalExtensions{let name=base+".original."+ext;var info=stat()
            if fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW) != 0{if errno==ENOENT{continue};throw Self.failure("写真の元画像を確認できません。")}
            guard found==nil,info.st_mode & S_IFMT == S_IFREG,info.st_uid==geteuid(),info.st_nlink==1,info.st_mode & 0o077 == 0,info.st_size>0,info.st_size<=Self.maximumInputBytes else{throw Self.failure("写真の元画像の保存情報が正しくありません。")};found=(name,mime)
        }
        guard let found else{throw Self.failure("写真の元画像が見つかりません。")};return found
    }
    /// The prepared original is read only on demand for an animated preview.
    /// It remains private to its issuing store and authenticated owner, and is
    /// invalid after commit/discard. Never retain this buffer in a hidden view.
    func original(_ prepared:Prepared)throws->Original{
        try locked{
            _ = try service.db.transaction{try currentUser()}
            guard prepared.store==storeID,let item=pending[prepared.ticket],item.owner==service.identity.id else{throw NativeDBError.conflict}
            try Task.checkCancellation()
            let fd=openat(directory,item.originalFilename,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0 else{throw Self.failure("選択した写真の元画像を開けません。")};defer{Darwin.close(fd)}
            _ = try Self.regular(fd,maximum:Self.maximumInputBytes,privateFile:true)
            let data=try Self.bytes(fd,maximum:Self.maximumInputBytes)
            guard Data(SHA256.hash(data:data))==item.originalDigest,try Self.source(data).1==prepared.sourceContentType else{throw Self.failure("選択した写真の元画像が変更されています。もう一度選択してください。")}
            try Task.checkCancellation();_ = try service.db.transaction{try currentUser()}
            return Original(data:data,contentType:prepared.sourceContentType)
        }
    }
    /// Exact original bytes, including GIF frames and metadata. Callers should
    /// load on demand and must not keep this up-to-4MiB buffer in the avatar view.
    func original(forUserID id:String)throws->Original?{
        try locked{try service.db.transaction{_ = try currentUser();guard let user=try service.db.get("Users",key:["id":.text(id)]) else{return nil};let reference=try resolvedAvatar(user);guard reference.hasPrefix(Self.prefix)else{return nil}
            let(name,mime)=try originalFile(reference),fd=openat(directory,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw Self.failure("写真の元画像を開けません。")};defer{Darwin.close(fd)}
            _ = try Self.regular(fd,maximum:Self.maximumInputBytes,privateFile:true);let data=try Self.bytes(fd,maximum:Self.maximumInputBytes);guard try Self.source(data).1==mime else{throw Self.failure("写真の元画像の形式が一致しません。")};return Original(data:data,contentType:mime)
        }}
    }
    private func readImage(_ filename:String)throws->CGImage{
        let fd=openat(directory,filename,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw Self.failure("保存済みの写真を読み取れません。")};defer{Darwin.close(fd)}
        return try decodedImage(fd)
    }
    private func decodedImage(_ fd:Int32)throws->CGImage{
        _ = try Self.regular(fd,maximum:Self.maximumStoredBytes,privateFile:true);let data=try Self.bytes(fd,maximum:Self.maximumStoredBytes)
        let(source,mime,w,h)=try Self.source(data);guard mime=="image/png",w==h,w<=Self.outputSide,CGImageSourceGetCount(source)==1,let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:true] as CFDictionary)else{throw Self.failure("保存済みの写真の形式が正しくありません。")};return image
    }
    func preview(_ prepared:Prepared)throws->CGImage{try locked{_ = try service.db.transaction{try currentUser()};guard prepared.store==storeID,let item=pending[prepared.ticket],item.owner==service.identity.id else{throw NativeDBError.conflict};return try readImage(item.filename)}}
    /// The original local avatar GET is available to authenticated internal users.
    /// A legacy remote avatar is deliberately not fetched by this local store.
    func image(forUserID id:String)throws->CGImage?{
        try locked{try service.db.transaction{_ = try currentUser();guard let user=try service.db.get("Users",key:["id":.text(id)]) else{return nil};let reference=try resolvedAvatar(user);guard reference.hasPrefix(Self.prefix)else{return nil};_ = try originalFile(reference);return try readImage(Self.filename(reference))}}
    }
    /// Startup/maintenance recovery for crashes between file publication and DB
    /// commit. Iterate directory entries singly, retaining no full file index.
    @discardableResult func cleanupUnreferenced(olderThan age:TimeInterval=86400)throws->Int{
        try locked{_ = try service.db.transaction{try currentUser()};guard age>=0,age.isFinite else{throw NativeDBError.conflict}
            guard let entries=fdopendir(dup(directory))else{throw Self.failure("写真の保存先を確認できません。")};defer{closedir(entries)};rewinddir(entries);var removed=0
            while let entry=readdir(entries){try Task.checkCancellation();let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:1024){String(cString:$0)}}
                guard name.utf8.count<100,name.count>36 else{continue}
                let base=String(name.prefix(36)),reference=Self.prefix+base+".png"
                guard let regularFiles=try? Self.bundleFiles(reference),let stagedFiles=try? Self.bundleFiles(reference,pending:true),(regularFiles+stagedFiles).contains(name),!pending.values.contains(where:{$0.prepared.reference==reference})else{continue}
                let names=regularFiles+stagedFiles;var existing:[String]=[],latest:TimeInterval=0,hasStaged=false
                for candidate in names{var info=stat();if fstatat(directory,candidate,&info,AT_SYMLINK_NOFOLLOW)==0{existing.append(candidate);latest=max(latest,Double(info.st_mtimespec.tv_sec));hasStaged = hasStaged || stagedFiles.contains(candidate)}}
                guard !existing.isEmpty,latest<clock().timeIntervalSince1970-(hasStaged ? max(age,86400):age)else{continue}
                try service.db.transaction{_ = try currentUser();guard try service.db.page("Users",fields:[],equal:["avatar":.text(reference)],limit:1).total==0,try !NativeOperationalAssets.avatarReferenced(reference,db:service.db) else{return};var changed=false;for candidate in existing{if unlinkat(directory,candidate,0)==0{changed=true}else if errno != ENOENT{throw Self.failure("未使用の写真を削除できません。")}};if changed{removed+=1}}

            };return removed
        }
    }
}
