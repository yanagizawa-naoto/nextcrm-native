import Foundation
import Darwin
import CryptoKit

struct NativeRestoreActivationCandidate {
    let root: NativeRestoreActivationRoot
    let result: NativeRestoreResult
    let seal: NativeRestoreActivationSeal
}

/// Reuses the real restore validator by reconstructing a bounded temporary
/// backup from the candidate's managed files. No application DB initializer,
/// credentials, jobs, or candidate bytes are modified during verification.
struct NativeRestoreActivationVerifier {
    static let publicationMarker = ".nextcrm-maintenance-owner.json"
    let schemaURL: URL
    let sqlURL: URL
    let cancelled: () -> Bool
    private func publicationMarkerHash(_ root: NativeRestoreActivationRoot, files: NativeMigrationFiles) throws -> String? {
        let fd=try NativeBackupWorkspace.openDirectory(root.url);defer{close(fd)};var info=stat()
        if fstatat(fd,Self.publicationMarker,&info,AT_SYMLINK_NOFOLLOW) != 0 {if errno==ENOENT{return nil};throw NativeMigrationFiles.io}
        guard info.st_mode & S_IFMT==S_IFREG,info.st_mode & 0o777==0o600,info.st_uid==geteuid(),info.st_nlink==1 else{throw NativeRestoreActivationFailure("candidate.publicationMarker")}
        let raw=try files.data(Self.publicationMarker,maximum:4096,cancelled:cancelled)
        guard let value=try NativeMigrationJSON.parse(raw).object,Set(value.keys)==Set(["version","registry","operation","role","nonce","uid"]),
              value["version"]?.integer==1,value["uid"]?.integer==Int64(geteuid()),value["role"]?.string=="publication",
              ["registry","operation","nonce"].allSatisfy({key in guard let id=value[key]?.string else{return false};return UUID(uuidString:id)?.uuidString.lowercased()==id}) else{throw NativeRestoreActivationFailure("candidate.publicationMarker")}
        // This is bounded inert metadata, never proof of origin or authority to
        // delete anything. Only the separate recovery registry owns that right.
        return NativeMigrationCodec.hash(raw)
    }
    func inspect(_ url: URL) throws -> NativeRestoreActivationCandidate {
        let root = try NativeRestoreActivationControl.root(url), files = try NativeMigrationFiles(root: root.url)
        let raw = try files.data("restore.json", maximum: 4*1024*1024, cancelled: cancelled)
        let shape = Set(try NativeMigrationJSON.parse(JSONEncoder().encode(NativeRestoreResult())).object!.keys)
        guard let object = try NativeMigrationJSON.parse(raw).object, Set(object.keys) == shape else { throw NativeRestoreActivationFailure("candidate.manifest") }
        let result = try JSONDecoder().decode(NativeRestoreResult.self, from: raw)
        let kinds = result.activationGate.obligations.map(\.kind)
        guard result.formatVersion == 1, result.status == .staged, result.candidateCreated, !result.activated, !result.workersStarted, !result.keychainAccessed,
              result.activationGate.phase == "requiresActivationReview", kinds.count == 8, Set(kinds) == Set(NativeRestoreActivationGate.review.obligations.map(\.kind)),
              UUID(uuidString: result.snapshotID)?.uuidString.lowercased() == result.snapshotID,
              result.databaseBytes > 0, result.fileCount >= 0, result.tableCount > 0, result.planRows > 0,
              [result.databaseSHA256,result.filesManifestSHA256,result.tablesManifestSHA256,result.resumePlanSHA256,result.backupManifestSHA256,result.schemaSHA256,result.sourceNamespaceSHA256,result.stagingNamespaceSHA256].allSatisfy(NativeMigrationCodec.validHash)
        else { throw NativeRestoreActivationFailure("candidate.state") }
        let marker = try files.data(".native-restore-candidate", maximum: 256, cancelled: cancelled)
        guard marker == Data("NextCRM native restore staging; ACTIVATION REVIEW REQUIRED\n".utf8) else { throw NativeRestoreActivationFailure("candidate.marker") }
        let seal = NativeRestoreActivationSeal(snapshotID: result.snapshotID, restoreSHA256: NativeMigrationCodec.hash(raw), databaseSHA256: result.databaseSHA256,
            filesManifestSHA256: result.filesManifestSHA256,tablesManifestSHA256: result.tablesManifestSHA256,resumePlanSHA256: result.resumePlanSHA256,
            backupManifestSHA256: result.backupManifestSHA256,schemaSHA256: result.schemaSHA256,
            sourceNamespaceSHA256: result.sourceNamespaceSHA256, stagingNamespaceSHA256: result.stagingNamespaceSHA256,
            // Match existing credential adapters exactly; this is deliberately
            // separate from the realpath used for safe descriptor traversal.
            finalNamespaceSHA256: NativeMigrationCodec.hash(Data(root.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL.path.utf8)),
            publicationMarkerSHA256:try publicationMarkerHash(root,files:files),planRows: result.planRows)
        guard try NativeRestoreActivationControl.root(root.url) == root else { throw NativeRestoreActivationFailure("candidate.replaced") }
        return .init(root: root, result: result, seal: seal)
    }
    private func manifest(_ files: NativeMigrationFiles, name: String, rows: Int64, hash: String) throws -> NativeMigrationManifest.File {
        let actual = try files.read(name,cancelled:cancelled){_ in}
        guard actual.sha256 == hash else { throw NativeRestoreActivationFailure("candidate.hash") }
        return .init(path:name,rows:rows,bytes:actual.bytes,sha256:hash)
    }
    private func semanticPlan(_ files: NativeMigrationFiles, rows: Int64, hash: String) throws -> String {
        let item = try manifest(files,name:"resume-plan.ndjson",rows:rows,hash:hash)
        var digest = SHA256()
        _ = try files.lines(item,limit:65536,cancelled:cancelled){data,_ in
            let row = try NativeRestoreActivationPlanCursor.row(data).0
            let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            var normalized = try encoder.encode(row);normalized.append(10);digest.update(data:normalized)
        }
        return digest.finalize().map{String(format:"%02x",$0)}.joined()
    }
    /// A sealed staging DB has no WAL/journal. Opening it with an application
    /// initializer before commit would otherwise introduce unverified pages.
    /// Count managed files without materializing the directory or manifest.
    private func sealedTree(_ candidate: NativeRestoreActivationCandidate) throws {
        let root = try NativeBackupWorkspace.openDirectory(candidate.root.url);defer{close(root)}
        var metadata:Set<String> = [".native-restore-candidate","crm.sqlite","tables.ndjson","files.ndjson","backup-snapshot.json","resume-plan.ndjson","restore.json"]
        if candidate.seal.publicationMarkerSHA256 != nil {metadata.insert(Self.publicationMarker)}
        let folders = Set(NativeRestoreWorkspace.names+["assets"])
        func entries(_ fd:Int32,_ visit:(String,stat)throws->Void)throws {
            var before=stat();guard fstat(fd,&before)==0 else{throw NativeMigrationFiles.io}
            let copy=dup(fd);guard copy>=0 else{throw NativeMigrationFiles.io}
            guard let stream=fdopendir(copy) else{close(copy);throw NativeMigrationFiles.io};defer{closedir(stream)}
            while true {
                if cancelled(){throw CancellationError()};errno=0
                guard let item=readdir(stream) else{guard errno==0 else{throw NativeMigrationFiles.io};break}
                let size=Int(item.pointee.d_namlen)+1
                let name=withUnsafePointer(to:&item.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:size){String(cString:$0)}}
                if name=="." || name==".."{continue}
                var info=stat();guard fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW)==0,info.st_uid==geteuid(),info.st_mode & 0o077==0 else{throw NativeRestoreActivationFailure("candidate.filePermissions")}
                try visit(name,info)
            }
            var after=stat();guard fstat(fd,&after)==0,NativeMigrationFiles.Fingerprint(before)==NativeMigrationFiles.Fingerprint(after) else{throw NativeRestoreActivationFailure("candidate.treeChanged")}
        }
        var seen=Set<String>(),count:Int64=0
        try entries(root){name,info in
            guard metadata.contains(name) || folders.contains(name) else{throw NativeRestoreActivationFailure("candidate.unsealedFile")}
            seen.insert(name)
            if metadata.contains(name){guard info.st_mode & S_IFMT==S_IFREG,info.st_nlink==1 else{throw NativeRestoreActivationFailure("candidate.fileType")};return}
            guard info.st_mode & S_IFMT==S_IFDIR else{throw NativeRestoreActivationFailure("candidate.folderType")}
            let folder=openat(root,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard folder>=0 else{throw NativeMigrationFiles.io};defer{close(folder)}
            try entries(folder){leaf,item in
                guard name != "assets",item.st_mode & S_IFMT==S_IFREG,item.st_nlink==1 else{throw NativeRestoreActivationFailure("candidate.unsealedFile")}
                _ = try NativeRestoreWorkspace.path(name+"/"+leaf)
                let (next,overflow)=count.addingReportingOverflow(1);guard !overflow else{throw NativeRestoreActivationFailure("candidate.fileCount")};count=next
            }
            var current=stat();guard fstat(folder,&current)==0,current.st_dev==info.st_dev,current.st_ino==info.st_ino else{throw NativeRestoreActivationFailure("candidate.treeChanged")}
        }
        guard seen==metadata.union(folders),count==candidate.result.fileCount else{throw NativeRestoreActivationFailure("candidate.fileCount")}
    }
    func unchanged(_ candidate: NativeRestoreActivationCandidate) throws {
        let current = try inspect(candidate.root.url)
        guard current.root == candidate.root, current.seal == candidate.seal else { throw NativeRestoreActivationFailure("candidate.changed") }
        let files = try NativeMigrationFiles(root:candidate.root.url)
        let database = try files.read("crm.sqlite",cancelled:cancelled){_ in}
        guard database.sha256 == candidate.seal.databaseSHA256, database.bytes == candidate.result.databaseBytes else { throw NativeRestoreActivationFailure("candidate.databaseChanged") }
        for (name,hash) in [("backup-snapshot.json",candidate.seal.backupManifestSHA256),("tables.ndjson",candidate.seal.tablesManifestSHA256),("resume-plan.ndjson",candidate.seal.resumePlanSHA256)] {
            guard try files.read(name,cancelled:cancelled,chunk:{_ in}).sha256 == hash else { throw NativeRestoreActivationFailure("candidate.metadataChanged") }
        }
        let inventory = try manifest(files,name:"files.ndjson",rows:candidate.result.fileCount,hash:candidate.seal.filesManifestSHA256)
        _ = try files.lines(inventory,limit:65536,cancelled:cancelled){data,_ in
            let asset = try JSONDecoder().decode(NativeBackupFile.self,from:data);_ = try NativeRestoreWorkspace.path(asset.sourcePath)
            let measured = try files.read(asset.sourcePath,maximum:asset.bytes,cancelled:cancelled){_ in}
            guard measured.bytes == asset.bytes, measured.sha256 == asset.sha256 else { throw NativeRestoreActivationFailure("candidate.assetChanged") }
        }
        try sealedTree(candidate)
        guard try NativeRestoreActivationControl.root(candidate.root.url) == candidate.root else { throw NativeRestoreActivationFailure("candidate.replaced") }
    }
    func validate(_ candidate: NativeRestoreActivationCandidate) throws {
        try unchanged(candidate)
        let temporary = try NativeMigrationImportWorkspace.resolvedTemporaryDirectory()
        let scratch = try NativeDataMaintenanceDirectory(parentURL:temporary,name:"NextCRMActivationVerify-"+UUID().uuidString.lowercased())
        do {
            let source = try NativeMigrationFiles(root:candidate.root.url)
            let backup = try NativeDataMaintenanceDirectory(parentURL:scratch.url,name:"backup")
            guard mkdirat(backup.fd,"assets",0o700) == 0 else { throw NativeMigrationFiles.io }
            let assets = openat(backup.fd,"assets",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard assets >= 0 else { throw NativeMigrationFiles.io };defer{close(assets)}
            func copy(_ from: String, _ parent: Int32, _ leaf: String, expected: String) throws {
                let fd = openat(parent,leaf,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                guard fd >= 0 else { throw NativeMigrationFiles.io };defer{close(fd)}
                let actual = try source.read(from,cancelled:cancelled){try NativeMigrationImportWorkspace.write($0,to:fd)}
                guard actual.sha256 == expected, fsync(fd) == 0 else { throw NativeRestoreActivationFailure("candidate.copy") }
            }
            try copy("crm.sqlite",backup.fd,"database.sqlite",expected:candidate.seal.databaseSHA256)
            try copy("backup-snapshot.json",backup.fd,"snapshot.json",expected:candidate.seal.backupManifestSHA256)
            try copy("tables.ndjson",backup.fd,"tables.ndjson",expected:candidate.seal.tablesManifestSHA256)
            try copy("files.ndjson",backup.fd,"files.ndjson",expected:candidate.seal.filesManifestSHA256)
            let inventory = try manifest(source,name:"files.ndjson",rows:candidate.result.fileCount,hash:candidate.seal.filesManifestSHA256)
            _ = try source.lines(inventory,limit:65536,cancelled:cancelled){data,_ in
                guard let object = try NativeMigrationJSON.parse(data).object,Set(object.keys) == Set(["sourcePath","archivePath","bytes","sha256"]) else { throw NativeRestoreActivationFailure("candidate.assetManifest") }
                let asset = try JSONDecoder().decode(NativeBackupFile.self,from:data)
                _ = try NativeRestoreWorkspace.path(asset.sourcePath)
                guard NativeMigrationCodec.matches(#"\Aassets/[0-9a-f]{64}\.blob\z"#,asset.archivePath) else { throw NativeMigrationFiles.badPath }
                try copy(asset.sourcePath,assets,String(asset.archivePath.dropFirst(7)),expected:asset.sha256)
            }
            let verifiedURL = scratch.url.appendingPathComponent("verified",isDirectory:true)
            let verified = NativeRestore(cancelled:cancelled).prepare(backupURL:backup.url,schemaURL:schemaURL,sqlURL:sqlURL,destinationURL:verifiedURL)
            guard verified.status == .staged, verified.candidateCreated, verified.snapshotID == candidate.seal.snapshotID,
                  verified.schemaSHA256 == candidate.seal.schemaSHA256, verified.planRows == candidate.result.planRows,
                  verified.fileCount == candidate.result.fileCount, verified.tableCount == candidate.result.tableCount,
                  verified.totalRows == candidate.result.totalRows, verified.totalFileBytes == candidate.result.totalFileBytes,
                  Set(verified.inheritedPending.map(\.rawValue)) == Set(candidate.result.inheritedPending.map(\.rawValue)),
                  verified.planCounts == candidate.result.planCounts else { throw NativeRestoreActivationFailure("candidate.validation") }
            let actualPlan = try semanticPlan(source,rows:candidate.result.planRows,hash:candidate.seal.resumePlanSHA256)
            let regeneratedPlan = try semanticPlan(NativeMigrationFiles(root:verifiedURL),rows:verified.planRows,hash:verified.resumePlanSHA256)
            guard actualPlan == regeneratedPlan else { throw NativeRestoreActivationFailure("candidate.planChanged") }
            try unchanged(candidate)
            guard scratch.cleanup() else { throw NativeRestoreActivationFailure("candidate.cleanup") }
        } catch {
            guard scratch.cleanup() else { throw NativeRestoreActivationFailure("candidate.cleanup") };throw error
        }
    }
}
