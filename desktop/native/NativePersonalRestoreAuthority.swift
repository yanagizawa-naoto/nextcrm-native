import Foundation
import Darwin

/// OS-owned control admission, distinct from the CRM user whose permissions
/// continue to apply to every business operation. No saved Session is consulted.
enum NativePersonalRestoreAuthority {
    struct FileIdentity: Codable, Equatable {
        let device: UInt64, inode: UInt64
    }
    struct Evidence: Codable, Equatable {
        let uid: UInt32
        let lease: NativeRestoreHostLeaseIdentity
        let selection: NativeRestoreActivationSelection
        let database: FileIdentity
    }
    static func database(_ root: NativeRestoreActivationRoot) throws -> FileIdentity {
        let directory=try NativeBackupWorkspace.openDirectory(root.url);defer{close(directory)}
        let fd=openat(directory,"crm.sqlite",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{throw NativeRestoreActivationFailure("personal.database")};defer{close(fd)}
        var opened=stat(),named=stat()
        guard fstat(fd,&opened)==0,fstatat(directory,"crm.sqlite",&named,AT_SYMLINK_NOFOLLOW)==0,
              opened.st_mode&S_IFMT==S_IFREG,opened.st_nlink==1,opened.st_uid==geteuid(),
              opened.st_mode&0o077==0,opened.st_dev==named.st_dev,opened.st_ino==named.st_ino else{
            throw NativeRestoreActivationFailure("personal.databaseIdentity")
        }
        return .init(device:UInt64(bitPattern:Int64(opened.st_dev)),inode:UInt64(opened.st_ino))
    }
    static func check(_ startup: NativeRestoreApplicationStartup,
                      expected: Evidence? = nil) throws -> Evidence {
        try Task.checkCancellation();try startup.control.validate();try startup.lease.validate()
        guard let selection=startup.plan.selection,
              startup.lease.identity.uid==geteuid(),
              try startup.control.read("active-root.json",as:NativeRestoreActivationSelection.self)==selection,
              try NativeRestoreActivationControl.root(selection.root.url)==selection.root,
              selection.root==startup.plan.root else{throw NativeRestoreActivationFailure("personal.selection")}
        let result=Evidence(uid:geteuid(),lease:startup.lease.identity,selection:selection,database:try database(selection.root))
        if let expected,expected != result{throw NativeRestoreActivationFailure("personal.authorityChanged")}
        return result
    }
}
