import Foundation
import Darwin

/// Only disposable receiving spools use this namespace. Durable mail-outbox,
/// invoice PDFs and legacy temporary directories are never discovered here.
/// Each content file is empty until its inode-bound ownership lease is durable.
final class NativeMailTemporaryFiles {
    enum Kind: String, Codable { case response, uids, mime
        var filename: String { self == .response ? "response" : self == .uids ? "uids.sqlite" : "mime.sqlite" }
    }
    fileprivate struct Identity: Codable, Equatable {
        let device: UInt64, inode: UInt64
        init(_ value: stat) { device = UInt64(value.st_dev); inode = UInt64(value.st_ino) }
    }
    fileprivate struct Owner: Codable {
        let version: Int, purpose: String, uid: UInt32, id: String, kind: Kind
        let root: Identity, directory: Identity, lease: Identity, content: Identity
    }
    static let namespace = "NextCRM-MailSpools-v1"
    fileprivate static let leaseName = ".lease"
    fileprivate static var failure: NativeMailFailure { NativeMailResponseFile.fileError }
    fileprivate static func info(_ fd: Int32) throws -> stat { var value = stat(); guard fstat(fd,&value) == 0 else { throw failure }; return value }
    fileprivate static func at(_ fd: Int32,_ name: String) throws -> stat? {
        var value = stat(); if fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }; throw failure
    }
    fileprivate static func privateDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o077 == 0 }
    fileprivate static func privateFile(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_mode & 0o077 == 0 && value.st_nlink == 1 }
    fileprivate static func same(_ fd: Int32,_ name: String,_ expected: Identity) throws -> Bool { try at(fd,name).map { Identity($0) == expected } ?? false }
    fileprivate static func directory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw failure }
        // Foundation can shorten a resolved /private/var URL back to /var
        // after locale initialization. Resolve the trusted temporary parent
        // with POSIX, then walk its bytes without NSURL path normalization.
        guard let resolved = realpath(url.path,nil) else { throw failure }
        let path = String(cString:resolved);free(resolved)
        var fd = open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        do {
            for name in path.split(separator:"/") {
                guard name != ".", name != ".." else { throw failure }
                let next = openat(fd,String(name),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard next >= 0 else { throw failure }; close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    fileprivate static func withNames<T>(_ fd: Int32,_ operation: (UnsafeMutablePointer<DIR>) throws -> T) throws -> T {
        let copy = openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard copy >= 0 else { throw failure }
        guard let stream = fdopendir(copy) else { close(copy); throw failure }
        defer { closedir(stream) }; return try operation(stream)
    }
    fileprivate static func next(_ stream: UnsafeMutablePointer<DIR>) throws -> String? {
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw failure }; return nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self,capacity:Int(entry.pointee.d_namlen)+1) { String(cString:$0) } }
            if name != ".", name != ".." { return name }
        }
    }
    fileprivate static func lock(_ fd: Int32,nonblocking: Bool) throws -> Bool {
        while flock(fd,LOCK_EX|(nonblocking ? LOCK_NB:0)) != 0 {
            if errno == EINTR { continue }; if nonblocking && errno == EWOULDBLOCK { return false }; throw failure
        }; return true
    }
    fileprivate static func write(_ data: Data,_ fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw failure }; offset += count
            }
        }
    }
    fileprivate static func owner(_ fd: Int32) throws -> Owner {
        let before = try info(fd); guard privateFile(before), (1...2048).contains(before.st_size) else { throw failure }
        var bytes = [UInt8](repeating:0,count:Int(before.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { pread(fd,$0.baseAddress!.advanced(by:offset),$0.count-offset,off_t(offset)) }
            if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw failure }; offset += count
        }
        let after = try info(fd)
        guard Identity(before) == Identity(after), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw failure }
        let result = try JSONDecoder().decode(Owner.self,from:Data(bytes))
        guard result.version == 1, result.purpose == "mail-disposable-spool", result.uid == geteuid(),
              UUID(uuidString:result.id)?.uuidString.lowercased() == result.id else { throw failure }
        return result
    }
    fileprivate final class Root {
        let base: URL, url: URL, parent: Int32, fd: Int32, lockFD: Int32
        let parentID: Identity, rootID: Identity, lockID: Identity
        init(base: URL,create: Bool) throws {
            // Resolve only the trusted temporary parent. Every component below
            // that boundary is opened with NOFOLLOW and retained by descriptor.
            self.base = base.resolvingSymlinksInPath(); url = self.base.appendingPathComponent(namespace)
            let p = try directory(self.base); var r:Int32 = -1, l:Int32 = -1
            do {
                if create && mkdirat(p,namespace,0o700) != 0 && errno != EEXIST { throw failure }
                r = openat(p,namespace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard r >= 0, privateDirectory(try info(r)) else { throw failure }
                l = openat(r,".lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(create ? O_CREAT:0),0o600)
                guard l >= 0, privateFile(try info(l)) else { throw failure }
                parentID = Identity(try info(p)); rootID = Identity(try info(r)); lockID = Identity(try info(l))
                parent = p; fd = r; lockFD = l
            } catch { if l >= 0 { close(l) }; if r >= 0 { close(r) }; close(p); throw error }
        }
        deinit { close(lockFD); close(fd); close(parent) }
        func validate() throws {
            let current = try directory(base); defer { close(current) }
            guard Identity(try info(current)) == parentID, try same(parent,namespace,rootID),
                  try same(fd,".lock",lockID), privateDirectory(try info(fd)), privateFile(try info(lockFD)) else { throw failure }
        }
    }
    /// A producer owns the lease before any response or SQLite bytes are written.
    /// Closing content/SQLite must precede release of this object.
    final class Lease {
        fileprivate let root: Root, directoryFD: Int32, leaseFD: Int32, owner: Owner
        let url: URL
        fileprivate init(root:Root,directoryFD:Int32,leaseFD:Int32,owner:Owner) {
            self.root = root; self.directoryFD = directoryFD; self.leaseFD = leaseFD; self.owner = owner
            url = root.url.appendingPathComponent(owner.id).appendingPathComponent(owner.kind.filename)
        }
        func openContent() throws -> Int32 {
            let fd = openat(directoryFD,owner.kind.filename,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
            guard fd >= 0 else { throw failure }
            do { guard privateFile(try info(fd)), Identity(try info(fd)) == owner.content else { throw failure }; return fd }
            catch { close(fd); throw error }
        }
        deinit {
            // A simultaneous collector cannot block deinit. If its namespace
            // lock is busy, retain these files for a subsequent bounded pass.
            if (try? lock(root.lockFD,nonblocking:true)) == true {
                defer { flock(root.lockFD,LOCK_UN) }
                _ = try? remove(root:root,name:owner.id,fd:directoryFD,lease:leaseFD,expected:owner)
            }
            close(leaseFD); close(directoryFD)
        }
    }
    static func create(_ kind: Kind,base: URL = FileManager.default.temporaryDirectory) throws -> Lease {
        let root = try Root(base:base,create:true)
        guard try lock(root.lockFD,nonblocking:true) else { throw NativeMailFailure.spoolBusy }; defer { flock(root.lockFD,LOCK_UN) }
        try root.validate()
        let id = UUID().uuidString.lowercased()
        guard mkdirat(root.fd,id,0o700) == 0 else { throw failure }
        let d = openat(root.fd,id,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard d >= 0 else { throw failure }
        var l:Int32 = -1, c:Int32 = -1
        do {
            l = openat(d,leaseName,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard l >= 0 else { throw failure }; guard try lock(l,nonblocking:true) else { throw NativeMailFailure.spoolBusy }
            c = openat(d,kind.filename,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard c >= 0 else { throw failure }
            let record = Owner(version:1,purpose:"mail-disposable-spool",uid:geteuid(),id:id,kind:kind,root:root.rootID,directory:Identity(try info(d)),lease:Identity(try info(l)),content:Identity(try info(c)))
            try write(JSONEncoder().encode(record),l)
            guard fsync(l) == 0, fsync(d) == 0, fsync(root.fd) == 0 else { throw failure }
            close(c); c = -1
            return Lease(root:root,directoryFD:d,leaseFD:l,owner:record)
        } catch {
            // No payload has been handed to a writer. Even a crash here can
            // leave only an empty file; incomplete ownership is never swept.
            if c >= 0 { close(c) }; if l >= 0 { close(l) }; close(d); throw error
        }
    }
    fileprivate static func remove(root: Root,name: String,fd: Int32,lease: Int32,expected: Owner) throws -> Bool {
        try root.validate()
        guard expected.id == name, expected.root == root.rootID, expected.directory == Identity(try info(fd)),
              expected.lease == Identity(try info(lease)), privateDirectory(try info(fd)),
              try same(root.fd,name,expected.directory), try same(fd,leaseName,expected.lease) else { throw failure }
        var count = 0
        try withNames(fd) { stream in
            while let child = try next(stream) {
                count += 1; guard count <= 2, child == leaseName || child == expected.kind.filename else { throw failure }
            }
        }
        if let content = try at(fd,expected.kind.filename) {
            guard privateFile(content), Identity(content) == expected.content else { throw failure }
            guard unlinkat(fd,expected.kind.filename,0) == 0 else { throw failure }
        }
        guard try same(root.fd,name,expected.directory), try same(fd,leaseName,expected.lease),
              unlinkat(fd,leaseName,0) == 0 else { throw failure }
        // A crash after unlinking the marker can leave an empty unmarked dir.
        // Its absence of authority is deliberate: later sweeps preserve it.
        guard unlinkat(root.fd,name,AT_REMOVEDIR) == 0 else { throw failure }
        return true
    }
    /// Called from the existing mail runtime scan Task, never during App init.
    /// Missing namespace is a no-op; a busy collector yields to the next resume.
    static func recover(base: URL = FileManager.default.temporaryDirectory) async throws {
        let path = base.resolvingSymlinksInPath().appendingPathComponent(namespace)
        var value = stat()
        if lstat(path.path,&value) != 0 {
            if errno == ENOENT { return }; throw failure
        }
        let cursor = try Recovery(base:base)
        while true {
            try Task.checkCancellation()
            let page = try cursor.step()
            if page.finished || page.busy { return }
            // One bounded batch per wake; this sleep is cancellable, and the
            // existing parent scan retains the cursor until it has really ended.
            try await Task.sleep(nanoseconds:25_000_000)
        }
    }
    struct Page { var examined = 0, removed = 0, live = 0, preserved = 0; var busy = false, finished = false }
    /// Retain a cursor and call step on a background worker with delays. Each
    /// call examines at most 64 entries by default; no array of names/bodies.
    /// A new pass may be needed after concurrent directory mutation. This
    /// deliberately has no App startup side effects or persistent DB writes.
    final class Recovery {
        private let root: Root, stream: UnsafeMutablePointer<DIR>, mutex = NSLock()
        private var finished = false
        init(base: URL = FileManager.default.temporaryDirectory) throws {
            root = try Root(base:base,create:false)
            let copy = openat(root.fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard copy >= 0 else { throw failure }
            guard let value = fdopendir(copy) else { close(copy); throw failure }; stream = value
        }
        deinit { closedir(stream) }
        func step(maximumEntries: Int = 64) throws -> Page {
            guard (1...256).contains(maximumEntries) else { throw failure }
            mutex.lock(); defer { mutex.unlock() }
            var result = Page(); if finished { result.finished = true; return result }
            guard try lock(root.lockFD,nonblocking:true) else { result.busy = true; return result }
            defer { flock(root.lockFD,LOCK_UN) }; try root.validate()
            while result.examined < maximumEntries {
                try Task.checkCancellation()
                guard let name = try next(stream) else { finished = true; result.finished = true; break }
                result.examined += 1
                if name == ".lock" { continue }
                guard UUID(uuidString:name)?.uuidString.lowercased() == name else { result.preserved += 1; continue }
                let d = openat(root.fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard d >= 0 else { result.preserved += 1; continue }; defer { close(d) }
                guard privateDirectory(try info(d)) else { result.preserved += 1; continue }
                let l = openat(d,leaseName,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                guard l >= 0 else { result.preserved += 1; continue }; defer { close(l) }
                guard privateFile(try info(l)) else { result.preserved += 1; continue }
                guard try lock(l,nonblocking:true) else { result.live += 1; continue }
                do {
                    let record = try owner(l)
                    if try remove(root:root,name:name,fd:d,lease:l,expected:record) { result.removed += 1 }
                } catch { result.preserved += 1 }
            }
            return result
        }
    }
}
