import Foundation

/// Local HTTP object operations use signed capabilities, not a second CRM
/// permission gate. UI callers resolve through NativeDocumentFiles instead.
final class NativeMCPDocumentObjectStore {
    typealias Reader = NativeMCPDocumentObjectReader
    let db: NativeDatabase, bucket: String
    private let signer: NativeMCPDocumentLocalSigner
    init(db: NativeDatabase, bucket: String, signer: NativeMCPDocumentLocalSigner, activateForDocuments: Bool = true) throws {
        guard !bucket.isEmpty,!bucket.contains("\0") else { throw NativeMCPFailure.internalError }
        self.db=db;self.bucket=bucket;self.signer=signer
        if activateForDocuments { try db.setMetadata("document.storage.bucket",value:bucket) }
    }
    func authorize(_ url: URL, method: String, contentType: String = "") throws -> String? {
        guard url.path=="/api/storage/local" else { return nil }
        return try signer.validate(url,method:method,contentType:contentType)
    }
    func beginUpload(key: String, contentType: String) throws -> Upload {
        guard !key.isEmpty,key.utf8.count<=1024,!key.contains("\0") else { throw NativeMCPFailure.internalError }
        return try Upload(db:db,bucket:bucket,key:key,contentType:contentType)
    }
    func open(key: String) throws -> Reader {
        try db.transaction {
            let metadata: NativeMCPDocumentObjectMetadata
            if let object=try db.documentObject(bucket:bucket,key:key) {
                metadata = .init(fileKey:object.fileKey,contentType:object.contentType,bytes:object.bytes,sha256:object.sha256)
            } else {
                // Legacy native imports already occupy the same immutable
                // directory. A signed URL may address their existing key.
                guard (try? NativeDocumentFiles.fileName(for:key)) != nil,
                      let document=try db.page("Documents",fields:["key","size","content_hash","document_file_mimeType"],equal:["key":.text(key)],includeDeleted:true,limit:1).rows.first,
                      let bytes=Int64(document["size"].string),bytes>=0 else { throw NativeMCPFailure.notFound }
                metadata = .init(fileKey:key,contentType:document["document_file_mimeType"].string,bytes:bytes,sha256:document["content_hash"].string)
            }
            // Opening under the same DB lock as cleanup pins the inode before
            // a concurrent mapping replacement can unlink the old file.
            return try Reader(dataRoot:db.url.deletingLastPathComponent(),metadata:metadata)
        }
    }
    final class Upload {
        private let db: NativeDatabase,bucket: String,key: String,staged: NativeMCPDocumentUpload
        private var finished=false
        fileprivate init(db: NativeDatabase,bucket: String,key: String,contentType: String) throws {
            self.db=db;self.bucket=bucket;self.key=key
            staged=try NativeMCPDocumentUpload(dataRoot:db.url.deletingLastPathComponent(),contentType:contentType)
        }
        func append(_ chunk: Data) throws { guard !finished else { throw NativeMCPFailure.internalError };try staged.append(chunk) }
        /// Each source PUT is independent and has no 64MiB UI import limit.
        /// The hook allows shutdown/cancellation to fence the atomic commit.
        func finish(beforeCommit: () throws -> Void = {}) throws -> String {
            guard !finished else { throw NativeMCPFailure.internalError }
            do {
                let metadata=try staged.finish()
                try db.transaction {
                    try Task.checkCancellation();try staged.publish()
                    try db.putDocumentObject(bucket:bucket,key:key,fileKey:metadata.fileKey,contentType:metadata.contentType,bytes:metadata.bytes,sha256:metadata.sha256)
                    try beforeCommit();try Task.checkCancellation()
                }
                staged.retainAfterCommit();finished=true;return "\""+metadata.sha256+"\""
            } catch { discard();throw error }
        }
        func discard() { staged.discard();finished=true }
        deinit { staged.discard() }
    }
}
