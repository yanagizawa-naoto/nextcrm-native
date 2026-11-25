import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

struct NativeDocumentResolvedFile: Equatable {
    let logicalKey: String, bucket: String, fileKey: String, contentType: String, bytes: Int64, sha256: String, mappingRevision: Int64
}

final class NativeDocumentStaging {
    fileprivate let owner: NativeDocumentFiles
    fileprivate let temporaryName: String; fileprivate let fileName: String; fileprivate var descriptor: Int32
    fileprivate var published = false; fileprivate var retained = false
    let name: String; let mimeType: String; let bytes: Int64; let sha256: String; let readCount: Int
    var key: String { "native-documents/"+fileName }
    func publish(in dataRoot: URL) throws {
        guard owner.root.resolvingSymlinksInPath().standardizedFileURL == dataRoot.appendingPathComponent("native-documents",isDirectory:true).resolvingSymlinksInPath().standardizedFileURL else { throw NativeDBError.message("文書の取り込み先が一致しません。") }
        try owner.publish(self)
    }
    fileprivate init(owner: NativeDocumentFiles, temporaryName: String, fileName: String, descriptor: Int32, name: String, mimeType: String, bytes: Int64, sha256: String, readCount: Int) {
        self.owner = owner; self.temporaryName = temporaryName; self.fileName = fileName; self.descriptor = descriptor
        self.name = name; self.mimeType = mimeType; self.bytes = bytes; self.sha256 = sha256; self.readCount = readCount
    }
    /// Call only after the database transaction committed successfully.
    func retainAfterCommit() { retained = true; if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    func discard() {
        if !retained {
            if published { _ = unlinkat(owner.directory,fileName,0) }
            _ = unlinkat(owner.directory,temporaryName,0)
        }
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }
    deinit { discard() }
}

/// Private immutable files; only a 256 KiB read buffer is retained while copying
/// and hashing. Paths from records never become arbitrary filesystem paths.
final class NativeDocumentFiles {
    static let chunkBytes = 256 * 1024
    static let maximumBytes: Int64 = 64 * 1024 * 1024 // same limit as original upload UI
    /// Metadata is resolved separately from CRM fields: MCP PUT never changes
    /// the document record, and an open URL can replace its logical object.
    static func resolve(_ document: NativeRecord, db: NativeDatabase) throws -> NativeDocumentResolvedFile {
        let key = document["key"].string, bucket = try db.metadata("document.storage.bucket") ?? ""
        if let mapped = try db.documentObject(bucket:bucket,key:key) {
            _ = try fileName(for:mapped.fileKey)
            return .init(logicalKey:key,bucket:bucket,fileKey:mapped.fileKey,contentType:mapped.contentType,bytes:mapped.bytes,sha256:mapped.sha256,mappingRevision:mapped.revision)
        }
        if let mapped=try NativeOperationalAssets.document(document,db:db){return mapped}
        _ = try fileName(for:key)
        guard let bytes = Int64(document["size"].string),bytes>=0,document["content_hash"].string.utf8.count==64 else { throw NativeDBError.message("文書のファイル情報が不足しています。") }
        return .init(logicalKey:key,bucket:bucket,fileKey:key,contentType:document["document_file_mimeType"].string,bytes:bytes,sha256:document["content_hash"].string,mappingRevision:0)
    }
    static func requireCurrent(_ snapshot: NativeDocumentResolvedFile, document: NativeRecord, db: NativeDatabase) throws {
        guard try resolve(document,db:db)==snapshot else { throw NativeDBError.conflict }
    }
    let root: URL
    fileprivate let directory: Int32
    init(dataRoot: URL) throws {
        root = dataRoot.appendingPathComponent("native-documents",isDirectory:true)
        if mkdir(root.path,0o700) != 0 && errno != EEXIST { throw Self.failure("文書フォルダを作成できません。") }
        let fd = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("文書フォルダを開けません。リンク先は使用できません。") }
        if fchmod(fd,0o700) != 0 { close(fd); throw Self.failure("文書フォルダの権限を設定できません。") }
        directory = fd
    }
    deinit { _ = close(directory) }
    private static func failure(_ message: String) -> NativeDBError { .message(message+"（"+String(cString:strerror(errno))+"）") }
    private static func regular(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeDBError.message("通常のファイルを選択してください。フォルダやリンクは取り込めません。") }
        return info
    }
    static func fileName(for key: String) throws -> String {
        guard key.hasPrefix("native-documents/"), key.utf8.count <= 80 else { throw NativeDBError.message("この文書はローカル文書の保存形式ではありません。") }
        let file = String(key.dropFirst("native-documents/".count)); let parts = file.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count == 2, let id = UUID(uuidString:String(parts[0])), id.uuidString.lowercased() == parts[0],
              (1...16).contains(parts[1].count), parts[1].utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else { throw NativeDBError.message("文書ファイルの識別子が不正です。") }
        return file
    }
    private static func transfer(_ input: Int32, _ output: Int32?, maximum: Int64, cancelled: () -> Bool, progress: (Int64) -> Void) throws -> (Int64,String,Int) {
        var hash = SHA256(); var total: Int64 = 0; var reads = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount:chunkBytes,alignment:16); defer { buffer.deallocate() }
        while true {
            guard !cancelled() else { throw NativeDBError.message("文書の取り込みを中止しました。") }
            let amount = Darwin.read(input,buffer,chunkBytes)
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw failure("文書を読み取れません。") }
            if amount == 0 { break }
            guard total <= maximum-Int64(amount) else { throw NativeDBError.message("文書は1ファイル64MiB以内で選択してください。") }
            hash.update(bufferPointer:UnsafeRawBufferPointer(start:buffer,count:amount))
            if let output {
                var offset = 0
                while offset < amount {
                    let written = Darwin.write(output,buffer.advanced(by:offset),amount-offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw failure("文書を保存できません。空き容量を確認してください。") }
                    offset += written
                }
            }
            total += Int64(amount); reads += 1; progress(total)
        }
        return (total,hash.finalize().map { String(format:"%02x",$0) }.joined(),reads)
    }
    func stage(_ source: URL, cancelled: () -> Bool = { false }, progress: (Int64,Int64) -> Void = { _,_ in }) throws -> NativeDocumentStaging {
        guard source.isFileURL else { throw NativeDBError.message("このMacのファイルを選択してください。") }
        let input = open(source.path,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Self.failure("取り込む文書を開けません。") }; defer { close(input) }
        let before = try Self.regular(input)
        guard before.st_size >= 0, before.st_size <= Self.maximumBytes else { throw NativeDBError.message("文書は1ファイル64MiB以内で選択してください。") }
        let originalExtension = source.pathExtension.lowercased()
        let fileExtension = (1...16).contains(originalExtension.count) && originalExtension.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) ? originalExtension : "bin"
        let file = UUID().uuidString.lowercased()+"."+fileExtension; let temporary = ".stage-"+file
        let output = openat(directory,temporary,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard output >= 0 else { throw Self.failure("文書の一時保存を開始できません。") }
        var transferred = false
        defer { if !transferred { close(output); unlinkat(directory,temporary,0) } }
        guard flock(output,LOCK_EX | LOCK_NB) == 0 else { throw Self.failure("文書の一時保存をロックできません。") }
        let copied = try Self.transfer(input,output,maximum:Self.maximumBytes,cancelled:cancelled,progress:{ progress($0,Int64(before.st_size)) })
        let after = try Self.regular(input)
        guard copied.0 == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw NativeDBError.message("取り込み中に元の文書が変更されました。もう一度選択してください。") }
        guard fsync(output) == 0, fchmod(output,0o400) == 0 else { throw Self.failure("文書の保存を確定できません。") }
        let staged = NativeDocumentStaging(owner:self,temporaryName:temporary,fileName:file,descriptor:output,name:source.lastPathComponent,
            mimeType:UTType(filenameExtension:originalExtension)?.preferredMIMEType ?? "application/octet-stream",bytes:copied.0,sha256:copied.1,readCount:copied.2)
        transferred = true; return staged
    }
    func publish(_ staged: NativeDocumentStaging) throws {
        guard staged.owner === self, staged.descriptor >= 0, !staged.published, !staged.retained else { throw NativeDBError.message("文書の取り込みはすでに確定または中止されています。") }
        // linkat is atomic and refuses to overwrite an existing UUID filename.
        guard linkat(directory,staged.temporaryName,directory,staged.fileName,0) == 0 else { throw Self.failure("文書を保存先へ移せません。") }
        staged.published = true
        guard unlinkat(directory,staged.temporaryName,0) == 0 else { throw Self.failure("文書の一時保存を整理できません。") }
        if fsync(directory) != 0 && errno != EINVAL { throw Self.failure("文書フォルダの保存を確定できません。") }
    }
    func verifiedURL(key: String, bytes: Int64, sha256: String) throws -> URL {
        let file = try Self.fileName(for:key)
        let fd = openat(directory,file,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("文書ファイルを開けません。バックアップまたは元の文書を確認してください。") }; defer { close(fd) }
        let info = try Self.regular(fd)
        guard info.st_size == bytes, bytes >= 0 else { throw NativeDBError.message("文書ファイルのサイズが保存時と一致しません。") }
        let actual = try Self.transfer(fd,nil,maximum:bytes,cancelled:{Task.isCancelled},progress:{_ in})
        guard actual.0 == bytes, actual.1 == sha256 else { throw NativeDBError.message("文書ファイルの内容が保存時と一致しません。") }
        return root.appendingPathComponent(file)
    }
    func export(key: String, bytes: Int64, sha256: String, to destination: URL, replace: Bool, registry: NativeExportStagingRegistry, validateAndPublish: (() throws -> Void) throws -> Void) throws {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else { throw NativeDBError.message("書き出すファイル名を選択してください。") }
        let file = try Self.fileName(for:key); let input = openat(directory,file,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Self.failure("文書ファイルを開けません。") }; defer { close(input) }
        guard try Self.regular(input).st_size == bytes else { throw NativeDBError.message("文書ファイルのサイズが保存時と一致しません。") }
        let staging = try registry.begin(parent:destination.deletingLastPathComponent())
        var output:Int32 = -1
        defer { if output >= 0 { close(output) }; try? staging.finish() }
        output = try staging.createContent(named:"payload")
        guard bytes>=0 else { throw NativeDBError.message("文書ファイルのサイズが不正です。") }
        let actual = try Self.transfer(input,output,maximum:bytes,cancelled:{Task.isCancelled},progress:{_ in})
        guard actual.0 == bytes, actual.1 == sha256 else { throw NativeDBError.message("文書ファイルの内容が保存時と一致しません。") }
        guard fsync(output) == 0 else { throw Self.failure("書き出した文書を確定できません。") }
        close(output); output = -1
        try staging.publish(content:"payload",to:destination,replace:replace,validateAndPublish:validateAndPublish)
        try staging.finish()
    }
    /// Caller must hold a DB transaction and confirm there are no remaining
    /// references. A missing file is a successful, idempotent cleanup.
    func removeUnreferenced(key: String) throws {
        let file = try Self.fileName(for:key)
        if unlinkat(directory,file,0) != 0 && errno != ENOENT { throw Self.failure("不要になった文書ファイルを削除できません。") }
    }
    /// Directory entries are streamed. Locks protect active imports, including
    /// another process's published-but-not-yet-committed file. The caller makes
    /// the reference check and invokes remove inside one database transaction.
    func recoverAbandonedFiles(olderThan: Date, cancelled: () -> Bool = { false }, visit: (String,Bool,() throws -> Void) throws -> Void) throws -> Int {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw Self.failure("文書フォルダを確認できません。") }
        guard let entries = fdopendir(duplicate) else { close(duplicate); throw Self.failure("文書フォルダを確認できません。") }
        defer { closedir(entries) }; rewinddir(entries); var removed = 0
        while !cancelled() {
            errno = 0
            guard let entry = readdir(entries) else { if errno != 0 { throw Self.failure("文書フォルダを読み取れません。") }; break }
            let length = Int(entry.pointee.d_namlen)+1
            let name = withUnsafePointer(to:&entry.pointee.d_name) { $0.withMemoryRebound(to:CChar.self,capacity:length) { String(cString:$0) } }
            let staging = name.hasPrefix(".stage-"); let key = "native-documents/"+(staging ? String(name.dropFirst(7)) : name)
            guard (try? Self.fileName(for:key)) != nil else { continue }
            let fd = openat(directory,name,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard let info = try? Self.regular(fd), Double(info.st_ctimespec.tv_sec) < olderThan.timeIntervalSince1970,
                  flock(fd,LOCK_EX | LOCK_NB) == 0 else { continue }
            try visit(key,staging) {
                var current = stat()
                guard fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW) == 0 else { if errno == ENOENT { return }; throw Self.failure("文書の一時保存を確認できません。") }
                guard current.st_dev == info.st_dev, current.st_ino == info.st_ino, current.st_mode & S_IFMT == S_IFREG else { return }
                guard unlinkat(directory,name,0) == 0 || errno == ENOENT else { throw Self.failure("文書の一時保存を削除できません。") }
                removed += 1
            }
        }
        return removed
    }
}
