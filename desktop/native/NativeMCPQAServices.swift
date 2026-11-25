import Foundation

/// Used only after the application's isolated QA-root checks. This private
/// fixture file preserves synthetic signing keys across QA app restarts.
final class NativeMCPQAServices: NativeMCPSecretStore {
    private let file: URL, lock = NSLock()
    init(root: URL) throws {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let normal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NextCRMNative").resolvingSymlinksInPath().standardizedFileURL
        guard root != normal, (try? String(contentsOf: root.appendingPathComponent(".native-mail-test"), encoding: .utf8)) == "NextCRM isolated mail QA\n" else { throw NativeMCPSettingsError.credentials }
        file = root.appendingPathComponent(".mcp-qa-secrets.json")
    }
    private func read() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 128 * 1024 else { throw NativeMCPSettingsError.credentials }
        let values = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))
        guard values.count <= 1024, values.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.count == 32 }) else { throw NativeMCPSettingsError.credentials }; return values
    }
    private func write(_ values: [String: Data]) throws {
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func load(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return try read()[id] }
    func save(id: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard UUID(uuidString: id) != nil, data.count == 32 else { throw NativeMCPSettingsError.credentials }
        var values = try read(); guard values[id] == nil, values.count < 1024 else { throw NativeMCPSettingsError.credentials }
        values[id] = data; try write(values)
    }
    func remove(id: String) throws { lock.lock(); defer { lock.unlock() }; var values = try read(); values.removeValue(forKey: id); try write(values) }
}
