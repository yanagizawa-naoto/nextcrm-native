import Foundation
import Darwin

extension NativePluginHost {
    private func administrator(_ actor:NativePluginActor) throws {
        guard (actor.type == .user || actor.type == .token),actor.role == "admin",let id=actor.userId,
              let user=try db.get("Users",key:["id":.text(id)]),user["userStatus"] == .text("ACTIVE"),user["banned"] != .integer(1),Self.role(user["role"].string)=="admin" else { throw NativePluginError(message:"操作する権限がありません") }
    }
    private func audit(_ id:String,_ actor:NativePluginActor,_ action:String) {
        NativePluginData(db:db,pluginId:id,permissions:[]).audit(entity:"plugin",id:id,action:action,changes:nil,user:actor.userId)
    }
    private func secretReference(_ id:String,_ values:NativePluginRecord) throws -> String? { try values.isEmpty ? nil:secretStore.write(id,values) }
    func install(_ id:String,actor:NativePluginActor,settings:NativePluginRecord,secrets:NativePluginRecord) throws {
        try administrator(actor)
        guard let definition=definition(id) else { throw NativePluginError(message:"Plugin not found") }
        guard try state(id)==nil else { throw NativePluginError(message:"Plugin already installed") }
        guard try NativePluginSDK.satisfies(definition.sdk) else { throw NativePluginError(message:"Incompatible SDK: requires \(definition.sdk), running \(NativePluginSDK.version)") }
        let settings=try definition.settings.parse(settings),secrets=try definition.secrets.parse(secrets),reference=try secretReference(id,secrets)
        do { try db.transaction {
            if let reference { db.deferUntilTransactionEnds(onCommit:{},onRollback:{ [secretStore] in try? secretStore.remove(reference) }) }
            try administrator(actor)
            if let reference { try secretStore.validatePublication(reference) }
            try db.insert("InstalledPlugin",values:["id":.text(id),"version":.text(definition.version),"status":.text("ENABLED"),"settings":.text(try NativePluginJSON.text(settings)),"secrets":reference.map(SQLValue.text) ?? .null,"installedBy":actor.userId.map(SQLValue.text) ?? .null],actor:actor.auditID)
            do { try db.enqueue("plugin/installed",payload:["pluginId":id],now:clock()) }
            catch { log(id,"error","Install event could not be sent");throw NativePluginError(message:"Plugin installation could not be started; please try again.") }
        } } catch { if let reference { try? secretStore.remove(reference) };throw error }
        audit(id,actor,"installed")
    }
    func setEnabled(_ id:String,actor:NativePluginActor,enabled:Bool) throws {
        try db.transaction { try administrator(actor);guard let state=try state(id) else { throw NativePluginError(message:"Plugin not installed") };try db.update(state,changes:["status":.text(enabled ? "ENABLED":"DISABLED")],actor:actor.auditID) };audit(id,actor,enabled ? "enabled":"disabled")
    }
    func saveSettings(_ id:String,actor:NativePluginActor,settings:NativePluginRecord,secrets submitted:NativePluginRecord,expectedRevision:Int64?=nil) throws {
        try administrator(actor);guard let definition=definition(id),let state=try state(id) else { throw NativePluginError(message:"Plugin not installed") }
        if let expectedRevision,expectedRevision != state.revision { throw NativePluginError(message:"設定が別の操作で更新されています。再読み込みしてください") }
        let settings=try definition.settings.parse(settings)
        var existing:NativePluginRecord=[:];if state["secrets"] != .null { existing=(try? secretStore.read(state["secrets"].string)) ?? [:] }
        existing.merge(submitted.filter { ($0.value as? String) != "" }) { _,new in new }
        let secrets=try definition.secrets.parse(existing),reference=try secretReference(id,secrets),old=state["secrets"] == .null ? nil:state["secrets"].string
        do { try db.transaction {
            db.deferUntilTransactionEnds(onCommit:{ [secretStore] in if let old,old != reference { try? secretStore.remove(old) } },onRollback:{ [secretStore] in if let reference { try? secretStore.remove(reference) } })
            try administrator(actor)
            if let reference { try secretStore.validatePublication(reference) }
            try db.update(state,changes:["settings":.text(try NativePluginJSON.text(settings)),"secrets":reference.map(SQLValue.text) ?? .null],actor:actor.auditID)
        } } catch { if let reference { try? secretStore.remove(reference) };throw error }
        audit(id,actor,"settings_changed")
    }
    func summary(_ id:String) throws -> NativePluginRecord {
        try db.transaction {
        var entries=0,groups=0,previous:String?
        while true {
            let rows=try db.mcpPage("PluginData",fields:["entityType","entityId"],filter:.equal("pluginId",.text(id)),limit:100,offset:entries,order:[("entityType",false),("entityId",false),("key",false)],includeDeleted:true).rows
            for row in rows where !row["entityId"].string.isEmpty { let pair=row["entityType"].string+"\0"+row["entityId"].string;if previous != pair { groups+=1;previous=pair } }
            entries+=rows.count;if rows.count<100 { break }
        }
        return ["entries":entries,"records":groups,"logLines":try db.page("PluginLog",fields:[],equal:["pluginId":.text(id)],limit:1).total]
        }
    }
    /// Exclusive, owner-only output: each page holds at most 100 store values.
    /// The UI supplies a new URL selected by its save panel. A partial file is
    /// removed on cancellation, lost authority or any read/write failure.
    func exportFile(_ id:String,to destination:URL,actor:NativePluginActor) throws {
        try administrator(actor)
        let descriptor=Darwin.open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        guard descriptor>=0 else { throw NativePluginError(message:"書き出し先に新しいファイルを作成できません") }
        let file=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);var complete=false
        defer { try? file.close();if !complete { try? FileManager.default.removeItem(at:destination) } }
        func write(_ text:String) throws { try file.write(contentsOf:Data(text.utf8)) }
        try db.transaction {
        let settings=try state(id).map { try NativePluginJSON.parse($0["settings"].string) } ?? NativePluginRecord()
        try write("{\"pluginId\":"+NativePluginJSON.text(id)+",\"exportedAt\":"+NativePluginJSON.text(NativePluginJSON.stamp(clock()))+",\"settings\":"+NativePluginJSON.text(settings)+",\"data\":[")
        var offset=0,first=true
        while true {
            try Task.checkCancellation();try administrator(actor)
            let rows=try db.mcpPage("PluginData",fields:["entityType","entityId","key","value"],filter:.equal("pluginId",.text(id)),limit:100,offset:offset,order:[("entityType",false),("entityId",false),("key",false)],includeDeleted:true).rows
            for row in rows { let value:NativePluginRecord=["entityType":row["entityType"].string,"entityId":row["entityId"].string,"key":row["key"].string,"value":try NativePluginJSON.parse(row["value"].string)];try write((first ? "":",")+NativePluginJSON.text(value));first=false }
            offset+=rows.count;if rows.count<100 { break }
        }
        try administrator(actor);try write("]}");try file.synchronize()
        };complete=true
    }
    func export(_ id:String,actor:NativePluginActor) throws -> NativePluginRecord {
        try administrator(actor)
        let data=NativePluginData(db:db,pluginId:id,permissions:[]),rows=try data.all("PluginData",where:["pluginId":id]).sorted { a,b in
            for key in ["entityType","entityId","key"] { let left=a[key] as? String ?? "",right=b[key] as? String ?? "";if left != right { return left.utf8.lexicographicallyPrecedes(right.utf8) } };return false
        }
        return ["pluginId":id,"exportedAt":NativePluginJSON.stamp(clock()),"settings":try state(id).map { try NativePluginJSON.parse($0["settings"].string) } ?? NativePluginRecord(),"data":rows.map { $0.filter { ["entityType","entityId","key","value"].contains($0.key) } }]
    }
    func uninstall(_ id:String,actor:NativePluginActor) async throws {
        try administrator(actor)
        if let definition=definition(id),let hook=definition.onUninstall {
            do { let context=try context(definition,actor:.plugin(id));try await NativePluginActorScope.withActor(.plugin(id)) { try await hook(context) } }
            catch { log(id,"error","onUninstall failed") }
        }
        try db.transaction {
            try administrator(actor)
            for model in ["PluginData","PluginLog"] {
                while true { let rows=try db.page(model,fields:[],equal:["pluginId":.text(id)]).rows;if rows.isEmpty { break };for row in rows { try db.remove(row,actor:actor.auditID) } }
            }
            guard let state=try state(id) else { throw NativePluginError(message:"Plugin not installed") }
            if state["secrets"] != .null { let reference=state["secrets"].string;db.deferUntilTransactionEnds(onCommit:{ [secretStore] in try? secretStore.remove(reference) },onRollback:{}) }
            try db.remove(state,actor:actor.auditID)
        }
        audit(id,actor,"uninstalled")
    }
    func list() throws -> [NativePluginRecord] {
        let data=NativePluginData(db:db,pluginId:"core",permissions:[]),states=try data.all("InstalledPlugin",where:[:])
        let ids=Set(definitions.map(\.id)).union(states.compactMap { $0["id"] as? String })
        return ids.sorted().map { id in
            let definition=definition(id),state=states.first { $0["id"] as? String == id }
            return ["id":id,"name":definition?.name ?? id,"description":definition?.description as Any? ?? NSNull(),"version":definition?.version as Any? ?? NSNull(),"installedVersion":state?["version"] ?? NSNull(),"status":definition == nil ? "MISSING":state?["status"] ?? "NOT_INSTALLED","settings":state?["settings"] ?? NativePluginRecord(),"fields":definition?.settings.description ?? [],"secretFields":definition?.secrets.description ?? []]
        }
    }
    /// OS advisory lock mirrors PostgreSQL's nonblocking session lock and is
    /// released on process death; no database transaction spans an await.
    func upgradeAll() async throws {
        guard !definitions.isEmpty else { return }
        let path=db.url.path+".plugins-upgrade.lock",fd=Darwin.open(path,O_CREAT|O_RDWR|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        guard fd>=0 else { throw NativePluginError(message:"Plugin upgrade lock is unavailable") };defer { Darwin.close(fd) }
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else { return };defer { flock(fd,LOCK_UN) }
        for definition in definitions {
            try Task.checkCancellation()
            guard let state=try state(definition.id),try NativePluginSDK.compareVersions(definition.version,state["version"].string)>0 else { continue }
            do {
                if let hook=definition.onUpgrade { let context=try context(definition,actor:.plugin(definition.id));try await NativePluginActorScope.withActor(.plugin(definition.id)) { try await hook(context,state["version"].string) } }
                try db.transaction { try NativePluginExecutionScope.check(definition.id);if let current=try self.state(definition.id),current.revision==state.revision { try db.update(current,changes:["version":.text(definition.version)],actor:"system");audit(definition.id,.system,"upgraded") } }
            } catch {
                try Task.checkCancellation()
                try NativePluginExecutionScope.check(definition.id)
                log(definition.id,"error","onUpgrade failed")
                try db.transaction { try NativePluginExecutionScope.check(definition.id);if let current=try self.state(definition.id),current.revision==state.revision { try db.update(current,changes:["status":.text("DISABLED")],actor:"system");audit(definition.id,.system,"disabled") } }
            }
        }
    }
    func adminAction(_ id:String,_ action:String,input:NativePluginRecord,actor:NativePluginActor) async throws -> Any {
        try administrator(actor)
        guard let definition=definition(id),try state(id)?["status"] == .text("ENABLED"),let handler=definition.actions[action] else { throw NativePluginError(message:"Not found") }
        let context=try context(definition,actor:actor)
        return try await NativePluginActorScope.withActor(.plugin(id)) { try await handler(input,context) }
    }
}
