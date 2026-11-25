import Foundation
import Darwin

/// Private sibling control holds the admission receipt before any DB exists.
/// Uses the existing control codec, descriptor walker and durable publication.
/// This admits only a newly created personal root; it never adopts an existing
/// user-selected/imported root merely because its directory or database is empty.
final class NativePersonalApplicationPaths {
    struct FreshReceipt: Codable, Equatable {
        let version: Int
        let id: String
        let uid: UInt32
        let parent: NativeRestoreActivationRoot
        let rootPath: String
        let stagingName: String
        var root: NativeRestoreActivationRoot?
        var phase: String
    }
    let baseRootURL: URL, controlURL: URL
    private(set) var freshReceipt: FreshReceipt?
    private static let receiptName = "personal-fresh-root.json"
    /// Fault seams are test-only notifications of actual durable boundaries;
    /// they neither manufacture admission nor bypass filesystem validation.
    init(baseRootURL: URL, controlURL: URL, checkpoint: (String) throws -> Void = { _ in }) throws {
        guard baseRootURL.isFileURL, controlURL.isFileURL,
              try NativeMigrationFiles.path(baseRootURL.lastPathComponent).count == 1,
              try NativeMigrationFiles.path(controlURL.lastPathComponent).count == 1,
              baseRootURL.lastPathComponent != controlURL.lastPathComponent,
              let resolved = realpath(baseRootURL.deletingLastPathComponent().path, nil) else { throw NativeRestoreActivationFailure("personal.paths") }
        let parentURL = URL(fileURLWithPath: String(cString: resolved), isDirectory: true); free(resolved)
        guard let controlParent = realpath(controlURL.deletingLastPathComponent().path, nil) else { throw NativeRestoreActivationFailure("personal.controlParent") }
        let controlParentPath = String(cString: controlParent); free(controlParent)
        guard controlParentPath == parentURL.path else { throw NativeRestoreActivationFailure("personal.siblingControl") }
        let parentFD = try NativeBackupWorkspace.openDirectory(parentURL); defer { close(parentFD) }
        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0, parentStat.st_uid == geteuid(), parentStat.st_mode & 0o022 == 0 else { throw NativeRestoreActivationFailure("personal.parentPermissions") }
        let parent = NativeRestoreActivationRoot(path: parentURL.path, device: UInt64(bitPattern: Int64(parentStat.st_dev)), inode: UInt64(parentStat.st_ino))
        self.baseRootURL = parentURL.appendingPathComponent(baseRootURL.lastPathComponent, isDirectory: true)
        self.controlURL = parentURL.appendingPathComponent(controlURL.lastPathComponent, isDirectory: true)
        let control = try NativeRestoreActivationControl(url: self.controlURL)
        try control.acquire(); defer { control.release() }
        var rootInfo = stat()
        let exists = fstatat(parentFD, baseRootURL.lastPathComponent, &rootInfo, AT_SYMLINK_NOFOLLOW) == 0
        if !exists && errno != ENOENT { throw NativeRestoreActivationFailure("personal.rootRead") }
        if exists && rootInfo.st_mode & S_IFMT != S_IFDIR { throw NativeRestoreActivationFailure("personal.rootNotDirectory") }
        if var receipt = try control.read(Self.receiptName, as: FreshReceipt.self) {
            guard receipt.version == 1, UUID(uuidString: receipt.id) != nil, receipt.uid == geteuid(), receipt.parent == parent,
                  receipt.rootPath == self.baseRootURL.path, receipt.stagingName == ".personal-new-" + receipt.id,
                  ["planned", "staged", "published", "initialized"].contains(receipt.phase) else { throw NativeRestoreActivationFailure("personal.freshReceipt") }
            if exists {
                guard let expected = receipt.root, expected.path == self.baseRootURL.path,
                      try NativeRestoreActivationControl.root(self.baseRootURL) == expected else { throw NativeRestoreActivationFailure("personal.freshRootChanged") }
                if receipt.phase == "staged" { receipt.phase = "published"; try control.write(receipt, name: Self.receiptName) }
                guard ["published", "initialized"].contains(receipt.phase) else { throw NativeRestoreActivationFailure("personal.freshPhase") }
                freshReceipt = receipt; return
            }
            guard receipt.phase == "planned" || receipt.phase == "staged" else { throw NativeRestoreActivationFailure("personal.freshRootMissing") }
            try Self.requireNoActivation(control)
            receipt = try Self.publish(receipt, parentFD: parentFD, control: control, checkpoint: checkpoint)
            freshReceipt = receipt; return
        }
        if exists {
            _ = try NativeRestoreActivationControl.root(self.baseRootURL)
            freshReceipt = nil; return
        }
        try Self.requireNoActivation(control)
        let id = UUID().uuidString.lowercased()
        var receipt = FreshReceipt(version: 1, id: id, uid: geteuid(), parent: parent, rootPath: self.baseRootURL.path,
                                   stagingName: ".personal-new-" + id, root: nil, phase: "planned")
        try control.write(receipt, name: Self.receiptName); try checkpoint("planned")
        receipt = try Self.publish(receipt, parentFD: parentFD, control: control, checkpoint: checkpoint)
        freshReceipt = receipt
    }
    /// The coordinator holds the activation lock until child readiness ACK.
    /// Reuse its already validated/adopted control and instance gate without
    /// calling Control.init/acquire, creating a root or writing a fresh receipt.
    init(adopting startup: NativeRestoreApplicationStartup, baseRootURL: URL) throws {
        guard startup.plan.mode == .approvedHandoff, let selection = startup.plan.selection,
              selection.root == startup.plan.root, startup.plan.permitted == ["workspace.local"], startup.plan.requiresReview,
              baseRootURL.isFileURL else { throw NativeRestoreActivationFailure("personal.adoptPathsMode") }
        try startup.control.validate(); try startup.lease.validate()
        var info = stat()
        guard lstat(baseRootURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw NativeRestoreActivationFailure("personal.adoptBase") }
        let base = try NativeRestoreActivationControl.root(baseRootURL)
        let control = try NativeRestoreActivationControl.root(startup.control.url)
        guard base.url.deletingLastPathComponent().path == control.url.deletingLastPathComponent().path,
              base.path != control.path,
              !selection.root.path.hasPrefix(control.path + "/"), !control.path.hasPrefix(selection.root.path + "/"),
              control.path != selection.root.path,
              try NativeRestoreActivationControl.root(selection.root.url) == selection.root else {
            throw NativeRestoreActivationFailure("personal.adoptPathsBinding")
        }
        self.baseRootURL = base.url; self.controlURL = control.url; freshReceipt = nil
        try validate(startup)
    }
    private static func requireNoActivation(_ control: NativeRestoreActivationControl) throws {
        guard try control.read("active-root.json", as: NativeRestoreActivationSelection.self) == nil,
              try control.read("activation.json", as: NativeRestoreActivationJournal.self) == nil else { throw NativeRestoreActivationFailure("personal.existingActivation") }
    }
    private static func publish(_ original: FreshReceipt, parentFD: Int32, control: NativeRestoreActivationControl, checkpoint: (String) throws -> Void) throws -> FreshReceipt {
        var receipt = original
        let stagedURL = receipt.parent.url.appendingPathComponent(receipt.stagingName, isDirectory: true)
        if receipt.phase == "planned" {
            if mkdirat(parentFD, receipt.stagingName, 0o700) != 0 && errno != EEXIST { throw NativeRestoreActivationFailure("personal.freshCreate") }
            let staged = try NativeRestoreActivationControl.root(stagedURL)
            let fd = try NativeBackupWorkspace.openDirectory(stagedURL); defer { close(fd) }
            // The trusted planned receipt reserves this random private sibling.
            // A crash can leave the just-created directory before its inode is
            // recorded. Only that exact private *empty* reservation may resume.
            guard try empty(fd), fsync(fd) == 0, fsync(parentFD) == 0 else { throw NativeRestoreActivationFailure("personal.freshNotEmpty") }
            try checkpoint("directoryCreated")
            receipt.root = .init(path: receipt.rootPath, device: staged.device, inode: staged.inode); receipt.phase = "staged"
            try control.write(receipt, name: receiptName); try checkpoint("staged")
        }
        guard receipt.phase == "staged", let expected = receipt.root else { throw NativeRestoreActivationFailure("personal.freshPhase") }
        let staged = try NativeRestoreActivationControl.root(stagedURL)
        guard staged.device == expected.device, staged.inode == expected.inode else { throw NativeRestoreActivationFailure("personal.stagingChanged") }
        let fd = try NativeBackupWorkspace.openDirectory(stagedURL); defer { close(fd) }
        guard try empty(fd) else { throw NativeRestoreActivationFailure("personal.freshNotEmpty") }
        let rootLeaf = URL(fileURLWithPath: receipt.rootPath).lastPathComponent
        guard renameatx_np(parentFD, receipt.stagingName, parentFD, rootLeaf, UInt32(RENAME_EXCL)) == 0, fsync(parentFD) == 0,
              try NativeRestoreActivationControl.root(URL(fileURLWithPath: receipt.rootPath)) == expected else { throw NativeRestoreActivationFailure("personal.freshPublish") }
        try checkpoint("rootPublished")
        receipt.phase = "published"; try control.write(receipt, name: receiptName); try checkpoint("published")
        return receipt
    }
    private static func empty(_ fd: Int32) throws -> Bool {
        let copy = dup(fd); guard copy >= 0 else { throw NativeRestoreActivationFailure("personal.enumerate") }
        guard let stream = fdopendir(copy) else { close(copy); throw NativeRestoreActivationFailure("personal.enumerate") }; defer { closedir(stream) }
        while true {
            errno = 0; guard let entry = readdir(stream) else { if errno != 0 { throw NativeRestoreActivationFailure("personal.enumerate") }; return true }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { return false }
        }
    }
    func validate(_ startup: NativeRestoreApplicationStartup) throws {
        try startup.control.validate(); try startup.lease.validate()
        guard startup.control.url.path == controlURL.path,
              try NativeRestoreActivationControl.root(startup.plan.root.url) == startup.plan.root,
              try startup.control.read("active-root.json", as: NativeRestoreActivationSelection.self) == startup.plan.selection,
              try startup.control.read("activation.json", as: NativeRestoreActivationJournal.self)?.activationID == startup.plan.activationID else { throw NativeRestoreActivationFailure("personal.startupChanged") }
    }
    func permitsFreshSetup(_ startup: NativeRestoreApplicationStartup) throws -> Bool {
        try validate(startup)
        guard startup.plan.mode == .ordinary, startup.plan.selection == nil,
              let receipt = freshReceipt, receipt.phase == "published", receipt.uid == geteuid(), receipt.root == startup.plan.root,
              try startup.control.read(Self.receiptName, as: FreshReceipt.self) == receipt else { return false }
        return true
    }
    func finishFreshSetup(_ startup: NativeRestoreApplicationStartup) throws {
        try startup.control.acquire(); defer { startup.control.release() }
        guard try permitsFreshSetup(startup), var receipt = freshReceipt else { throw NativeRestoreActivationFailure("personal.freshAdmission") }
        receipt.phase = "initialized"; try startup.control.write(receipt, name: Self.receiptName); freshReceipt = receipt
    }
}
