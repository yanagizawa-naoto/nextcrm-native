import Foundation
import Darwin

/// Separate private control directory. Its lock is held through the whole async
/// switch/recovery; callers must integrate the same fence in every app instance.
final class NativeRestoreActivationControl {
    private let directory: Int32, lockFD: Int32
    let url: URL
    init(url: URL) throws {
        let parentURL = try Self.canonicalDirectory(url.deletingLastPathComponent())
        let parts = try NativeMigrationFiles.path(url.lastPathComponent)
        guard parts.count == 1 else { throw NativeRestoreActivationFailure("control.path") }
        let parent = try NativeBackupWorkspace.openDirectory(parentURL); defer { close(parent) }
        if mkdirat(parent, parts[0], 0o700) != 0 && errno != EEXIST { throw NativeRestoreActivationFailure("control.create") }
        let fd = openat(parent, parts[0], O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { if fd >= 0 { close(fd) }; throw NativeRestoreActivationFailure("control.permissions") }
        let lock = openat(fd, ".activation.lock", O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0o600)
        var lockInfo = stat()
        guard lock >= 0, fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1, lockInfo.st_mode & 0o077 == 0 else { if lock >= 0 { close(lock) }; close(fd); throw NativeRestoreActivationFailure("control.lock") }
        // A committed pointer must not outlive a newly-created control directory
        // entry after a power loss. Persist the lock, directory and its parent.
        guard fsync(lock) == 0, fsync(fd) == 0, fsync(parent) == 0 else { close(lock);close(fd);throw NativeRestoreActivationFailure("control.sync") }
        directory = fd; lockFD = lock; self.url = parentURL.appendingPathComponent(parts[0], isDirectory: true)
    }
    deinit { close(lockFD); close(directory) }
    func acquire() throws { guard flock(lockFD, LOCK_EX|LOCK_NB) == 0 else { throw NativeRestoreActivationFailure("control.busy") }; do { try validate() } catch { release(); throw error } }
    func release() { _ = flock(lockFD, LOCK_UN) }
    func validate() throws {
        let fresh = try NativeBackupWorkspace.openDirectory(url); defer { close(fresh) }
        var a = stat(), b = stat(), c = stat(), d = stat()
        guard fstat(directory,&a) == 0, fstat(fresh,&b) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev,
              fstat(lockFD,&c) == 0, fstatat(directory,".activation.lock",&d,AT_SYMLINK_NOFOLLOW) == 0,
              c.st_ino == d.st_ino, c.st_dev == d.st_dev, d.st_nlink == 1 else { throw NativeRestoreActivationFailure("control.replaced") }
    }
    static func root(_ url: URL) throws -> NativeRestoreActivationRoot {
        guard url.isFileURL else { throw NativeRestoreActivationFailure("root.path") }
        let resolved = try canonicalDirectory(url)
        let fd = try NativeBackupWorkspace.openDirectory(resolved); defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw NativeRestoreActivationFailure("root.permissions") }
        return .init(path: resolved.path, device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
    private static func canonicalDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, let value = realpath(url.path,nil) else { throw NativeRestoreActivationFailure("root.path") };defer{free(value)}
        // Filesystem descriptors need the actual /private/var path. Foundation
        // may turn it back into the /var alias, rejected by O_NOFOLLOW walking.
        return URL(fileURLWithPath:String(cString:value),isDirectory:true)
    }
    func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        try validate(); var info = stat()
        if fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return nil }; throw NativeRestoreActivationFailure("control.read") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw NativeRestoreActivationFailure("control.file") }
        let bytes = try NativeMigrationFiles(root: url).data(name, maximum: 262144, cancelled: { false })
        _ = try NativeMigrationJSON.parse(bytes)
        return try JSONDecoder().decode(type, from: bytes)
    }
    func write<T: Encodable>(_ value: T, name: String) throws {
        try validate(); guard try NativeMigrationFiles.path(name).count == 1 else { throw NativeRestoreActivationFailure("control.filename") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value); guard bytes.count <= 262144 else { throw NativeRestoreActivationFailure("control.limit") }
        var existing = stat()
        if fstatat(directory,name,&existing,AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == geteuid(), existing.st_nlink == 1, existing.st_mode & 0o077 == 0 else { throw NativeRestoreActivationFailure("control.file") }
        } else if errno != ENOENT { throw NativeRestoreActivationFailure("control.read") }
        let temporary = ".write-" + UUID().uuidString.lowercased()
        let fd = openat(directory,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw NativeRestoreActivationFailure("control.write") }
        defer { close(fd); _ = unlinkat(directory,temporary,0) }
        try NativeMigrationImportWorkspace.write(bytes,to:fd)
        guard fsync(fd) == 0 else { throw NativeRestoreActivationFailure("control.sync") }
        try validate()
        guard renameat(directory,temporary,directory,name) == 0, fsync(directory) == 0 else { throw NativeRestoreActivationFailure("control.publish") }
    }
    func createLedger(_ name: String) throws -> Int32 {
        try validate(); guard try NativeMigrationFiles.path(name).count == 1 else { throw NativeRestoreActivationFailure("ledger.path") }
        let fd = openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw NativeRestoreActivationFailure("ledger.create") }; return fd
    }
    func sync() throws { try validate(); guard fsync(directory) == 0 else { throw NativeRestoreActivationFailure("control.sync") } }
}
