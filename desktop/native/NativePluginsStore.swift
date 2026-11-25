import Foundation

/// Values and claims share the database transaction with their caller. A claim
/// uses BEGIN IMMEDIATE, including when separate processes open the same file.
final class NativePluginStore {
    let db: NativeDatabase, pluginId: String, entityType: String, entityId: String
    let clock: () -> Date
    init(db: NativeDatabase, pluginId: String, entityType: String = "", entityId: String = "", clock: @escaping () -> Date = Date.init) {
        self.db=db; self.pluginId=pluginId; self.entityType=entityType; self.entityId=entityId; self.clock=clock
    }
    func forRecord(_ entity: NativePluginEntity, _ id: String) -> NativePluginStore {
        .init(db:db,pluginId:pluginId,entityType:entity.rawValue,entityId:id,clock:clock)
    }
    private var scope: [String:SQLValue] { ["pluginId":.text(pluginId),"entityType":.text(entityType),"entityId":.text(entityId)] }
    private func row(_ key: String) throws -> NativeRecord? {
        try db.page("PluginData",fields:["id","value"],equal:scope.merging(["key":.text(key)]) { _,new in new },includeDeleted:true,limit:1).rows.first
    }
    func get(_ key: String) throws -> Any? {
        try NativePluginExecutionScope.check(pluginId)
        guard let row = try row(key) else { return nil }
        let value = try NativePluginJSON.parse(row["value"].string)
        return value is NSNull ? nil : value
    }
    func set(_ key: String, _ value: Any) throws {
        try NativePluginExecutionScope.check(pluginId)
        let json: Data
        do { json = try NativePluginJSON.data(value) } catch { throw NativePluginStoreError(message:"Store value must be JSON-serialisable") }
        guard json.count <= 256 * 1024 else { throw NativePluginStoreError(message:"Store value for \(key) exceeds 256 KB") }
        try db.transaction {
            let value = SQLValue.text(String(decoding:json,as:UTF8.self))
            if let current = try row(key) { try db.update(current,changes:["value":value],actor:"plugin:"+pluginId) }
            else { try db.insert("PluginData",values:scope.merging(["key":.text(key),"value":value]) { _,new in new },actor:"plugin:"+pluginId) }
        }
    }
    func delete(_ key: String) throws { try NativePluginExecutionScope.check(pluginId);try db.transaction { if let row = try row(key) { try db.remove(row,actor:"plugin:"+pluginId) } } }
    func list(_ prefix: String = "") throws -> [(key: String,value: Any)] {
        try NativePluginExecutionScope.check(pluginId)
        var output: [(key:String,value:Any)] = [], offset=0
        repeat {
            let page = try db.page("PluginData",fields:["key","value"],equal:scope,includeDeleted:true,offset:offset,sort:"key",limit:100)
            for row in page.rows where row["key"].string.hasPrefix(prefix) { output.append((row["key"].string,try NativePluginJSON.parse(row["value"].string))) }
            offset += page.rows.count
            if page.rows.isEmpty || offset >= page.total { break }
        } while true
        return output.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }
    func claim(_ key: String, ms: Double) throws -> Bool {
        try NativePluginExecutionScope.check(pluginId)
        guard ms.isFinite, ms >= Double(Int32.min), ms <= Double(Int32.max) else { throw NativePluginError(message:"integer out of range") }
        return try db.transaction {
            let now = clock()
            if let existing = try get(key) as? NativePluginRecord, let until = existing["until"], !(until is NSNull), try NativePluginJSON.date(NativePluginJSON.string(until)) > now { return false }
            // PostgreSQL casts the numeric argument to int with half-away rounding.
            try set(key,["until":NativePluginJSON.stamp(now.addingTimeInterval(ms.rounded(.toNearestOrAwayFromZero)/1000))])
            return true
        }
    }
}
