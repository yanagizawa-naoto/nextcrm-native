import Foundation
import Darwin

/// Persisted only inside the explicitly marked, isolated application QA root.
/// No system Keychain or real provider is used by candidate-app QA.
final class NativePluginsQACredentials: NativePluginCredentialBacking {
    private let root: URL
    private let lock = NSLock()
    init(root: URL) throws {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let normal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NextCRMNative").resolvingSymlinksInPath().standardizedFileURL
        guard root != normal, (try? String(contentsOf: root.appendingPathComponent(".native-mail-test"), encoding: .utf8)) == "NextCRM isolated mail QA\n" else {
            throw NativeDBError.message("連携の検証には専用の検証データフォルダが必要です。")
        }
        self.root = root.appendingPathComponent(".plugin-qa-secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func url(_ reference: String) throws -> URL {
        guard NativePluginCredentialVault.valid(reference) else { throw NativeDBError.conflict }
        return root.appendingPathComponent(String(reference.dropFirst(NativePluginCredentialVault.prefix.count)) + ".json")
    }
    func load(_ reference: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let file = try url(reference)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }
    func save(_ reference: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let destination = try url(reference)
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NativeDBError.conflict }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); var complete = false
        defer { try? file.close(); if !complete { try? FileManager.default.removeItem(at: destination) } }
        try file.write(contentsOf: data); try file.synchronize(); complete = true
    }
    func remove(_ reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        let destination = try url(reference)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    }
}
