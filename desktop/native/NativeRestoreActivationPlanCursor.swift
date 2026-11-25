import Foundation
import Darwin
import CryptoKit

/// One bounded plan row at a time across provider awaits. Descriptor identity,
/// raw digest and count are checked at EOF; source root is rechecked before commit.
final class NativeRestoreActivationPlanCursor {
    private let fd: Int32
    private let initial: NativeMigrationFiles.Fingerprint
    private let expected: NativeRestoreActivationSeal
    private var buffer = Data(), digest = SHA256(), rows: Int64 = 0, ended = false
    init(root: URL, seal: NativeRestoreActivationSeal) throws {
        let directory = try NativeBackupWorkspace.openDirectory(root); defer { close(directory) }
        let file = openat(directory,"resume-plan.ndjson",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
        var info = stat()
        guard file >= 0, fstat(file,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { if file >= 0 { close(file) }; throw NativeRestoreActivationFailure("plan.open") }
        fd = file; initial = .init(info); expected = seal
    }
    deinit { close(fd) }
    static func row(_ data: Data) throws -> (NativeRestorePlanEntry,String) {
        let allowed:Set<String> = ["kind","model","key","field","revision","state","flags","count","action","event"]
        guard let object = try NativeMigrationJSON.parse(data).object, Set(object.keys).isSubset(of:allowed), Set(["kind","model","flags","count","action"]).isSubset(of:Set(object.keys)) else { throw NativeRestoreActivationFailure("plan.shape") }
        let value = try JSONDecoder().decode(NativeRestorePlanEntry.self,from:data)
        guard value.count >= 0 else { throw NativeRestoreActivationFailure("plan.count") }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return (value,NativeMigrationCodec.hash(try encoder.encode(value)))
    }
    func next() throws -> (NativeRestorePlanEntry,String)? {
        guard !ended else { return nil }
        while true {
            try Task.checkCancellation()
            if let newline = buffer.firstIndex(of:10) {
                let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard !data.isEmpty, data.count <= 65536 else { throw NativeRestoreActivationFailure("plan.lineLimit") }
                rows += 1; return try Self.row(data)
            }
            guard buffer.count <= 65536 else { throw NativeRestoreActivationFailure("plan.lineLimit") }
            var bytes = [UInt8](repeating:0,count:65536)
            let count = Darwin.read(fd,&bytes,bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NativeRestoreActivationFailure("plan.read") }
            if count == 0 {
                var final = stat()
                guard buffer.isEmpty, rows == expected.planRows, fstat(fd,&final) == 0, initial == NativeMigrationFiles.Fingerprint(final), digest.finalize().map({String(format:"%02x",$0)}).joined() == expected.resumePlanSHA256 else { throw NativeRestoreActivationFailure("plan.changed") }
                ended = true;return nil
            }
            let chunk = Data(bytes.prefix(count));digest.update(data:chunk);buffer.append(chunk)
        }
    }
}
