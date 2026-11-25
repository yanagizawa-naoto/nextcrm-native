import Foundation

/// Keychain adapters return an opaque reference only; neither the reference's
/// payload nor secret values enter InstalledPlugin/settings/outbox/audit rows.
struct NativePluginSecretStore {
    let read: (String) throws -> NativePluginRecord
    let write: (String,NativePluginRecord) throws -> String
    let remove: (String) throws -> Void
    let validatePublication: (String) throws -> Void
    init(read:@escaping (String)throws->NativePluginRecord,write:@escaping (String,NativePluginRecord)throws->String,remove:@escaping (String)throws->Void,validatePublication:@escaping (String)throws->Void={_ in}) {
        self.read=read;self.write=write;self.remove=remove;self.validatePublication=validatePublication
    }
    static let unavailable = Self(read:{ _ in throw NativePluginError(message:"Plugin secrets are unavailable") },write:{ _,_ in throw NativePluginError(message:"Plugin secrets are unavailable") },remove:{ _ in })
}

final class NativePluginHost {
    /// A personal restored workspace can keep rule interpretation attached while
    /// independently denying every secret read and external effect. nil preserves
    /// the ordinary host contract.
    struct Capabilities {
        let allowSecretRead:Bool,allowExternalEffects:Bool
        let beforeWrite:(String,String,NativeRecord?,[String:SQLValue])throws->Void
        let after:(NativePluginDefinition,NativePluginAfterInput)throws->Bool
    }
    let capabilities:Capabilities?
    let db:NativeDatabase, definitions:[NativePluginDefinition], secretStore:NativePluginSecretStore, clock:()->Date, defaultLocale:String
    let sendNotification:(String,String,String) async throws -> Void
    let transport:(String,URLRequest) async throws -> (Data,HTTPURLResponse)
    let translate:(String?,String,NativePluginRecord?,String)->String
    var ruleTimeout:TimeInterval=0.5
    private var warningKeys=Set<String>(), warningLock=NSLock()
    init(db:NativeDatabase,definitions:[NativePluginDefinition],secretStore:NativePluginSecretStore = .unavailable,clock:@escaping ()->Date=Date.init,locale:String="ja",translate:@escaping (String?,String,NativePluginRecord?,String)->String=NativePluginMessages.translate,sendNotification:@escaping (String,String,String) async throws -> Void,transport:@escaping (String,URLRequest) async throws -> (Data,HTTPURLResponse),capabilities:Capabilities?=nil) throws {
        var ids=Set<String>();for definition in definitions { try definition.validate();guard ids.insert(definition.id).inserted else { throw NativePluginError(message:"Duplicate plugin id: "+definition.id) } }
        self.capabilities=capabilities
        self.db=db;self.definitions=definitions;self.secretStore=secretStore;self.clock=clock;defaultLocale=locale;self.translate=translate;self.sendNotification=sendNotification;self.transport=transport
    }
    func attach() {
        let failClosed=capabilities != nil
        db.beforeRecordWrite={ [weak self] model,operation,existing,input,actor in guard let self else { if failClosed { throw NativePluginError(message:"ローカルの保護ルールを確認できないため、編集を停止しました。") };return input };return try self.before(model:model,operation:operation,existing:existing,input:input,actorID:actor) }
        db.afterRecordWrite={ [weak self] model,operation,before,after,input,actor in self?.after(model:model,operation:operation,before:before,after:after,input:input,actorID:actor) }
    }
    func definition(_ id:String)->NativePluginDefinition? { definitions.first { $0.id==id } }
    func state(_ id:String) throws -> NativeRecord? { try db.get("InstalledPlugin",key:["id":.text(id)]) }
    func enabled() throws -> [NativePluginDefinition] { try definitions.filter { try state($0.id)?["status"] == .text("ENABLED") } }
    func actor(_ id:String)->NativePluginActor {
        if let frame=NativePluginActorScope.current { return frame.actor }
        if id.hasPrefix("plugin:") { return .plugin(String(id.dropFirst(7))) }
        if let user=try? db.get("Users",key:["id":.text(id)]) { return .init(type:.user,userId:id,role:Self.role(user["role"].string)) }
        return .system
    }
    static func role(_ value:String)->String { ["admin":"admin","member":"manager","viewer":"user","user":"user","manager":"manager","partner":"partner"][value] ?? "user" }
    func log(_ id:String,_ level:String,_ message:String,_ context:NativePluginRecord?=nil) {
        let safeMessage=String(decoding:Array(message.utf16.prefix(2000)),as:UTF16.self),safeContext=context.flatMap { try? NativePluginJSON.text($0) },db=db
        let persist={ [weak db] in guard let db else { return }
            // Only this redacted diagnostic row may survive an expired job.
            NativePluginActorScope.$current.withValue(nil) { _ = try? db.insert("PluginLog",values:["pluginId":.text(id),"level":.text(level),"message":.text(safeMessage),"context":safeContext.map(SQLValue.text) ?? .null],actor:"system") }
        }
        db.deferUntilTransactionEnds(onCommit:persist,onRollback:persist)
    }
    private func warnOnce(_ id:String,_ message:String,_ context:NativePluginRecord?) {
        warningLock.lock();let fresh=warningKeys.insert(id+"|"+message).inserted;warningLock.unlock()
        if fresh { log(id,"warn",message,context) }
    }
    func context(_ definition:NativePluginDefinition,actor:NativePluginActor,locale:String?=nil) throws -> NativePluginContext {
        let row=try state(definition.id),id=definition.id,locale=locale ?? NativePluginActorScope.current?.locale ?? defaultLocale
        let stored=try row.map { try NativePluginJSON.parse($0["settings"].string) } ?? NativePluginRecord()
        let settings=definition.settings.stored(stored) { [weak self] message,context in self?.warnOnce(id,message,context) }
        var secrets:NativePluginRecord=[:]
        if capabilities?.allowSecretRead != false,let row,row["secrets"] != .null,!row["secrets"].string.isEmpty {
            do { secrets=try secretStore.read(row["secrets"].string) }
            catch { warnOnce(id,"Secrets could not be decrypted (encryption key changed?); treating them as not set. Re-enter them in plugin settings.",nil) }
        }
        let redactor=NativePluginRedactor(secrets)
        let logger:(String,String,NativePluginRecord?)->Void={ [weak self] level,message,context in self?.log(id,level,redactor.text(message),context.map(redactor.record)) }
        let data=NativePluginData(db:db,pluginId:id,permissions:definition.permissions,clock:clock,logger:logger),store=NativePluginStore(db:db,pluginId:id,clock:clock),db=db
        return NativePluginContext(definition:definition,actor:actor,locale:locale,settings:settings,secrets:secrets,store:store,data:data,clock:clock,logger:logger,translator:{ [translate] key,params in translate(id,key,params,locale) },notification:{ [weak self] input in guard let self else { throw CancellationError() };try await self.notify(input) },transport:{ [transport,capabilities] request in guard capabilities?.allowExternalEffects != false else{throw NativePluginError(message:"復元した連携先への接続は確認待ちです。")};return try await transport(id,request) },persistAfterTransaction:{ action in db.deferUntilTransactionEnds(onCommit:action,onRollback:action) })
    }
    func notify(_ input:NativePluginNotification) async throws {
        guard capabilities?.allowExternalEffects != false else{throw NativePluginError(message:"復元した通知の送信は確認待ちです。") }
        var offset=0
        while true {
            let rows=try db.page("Users",fields:["id","email","role"],equal:["userStatus":.text("ACTIVE")],includeDeleted:true,offset:offset).rows
            for row in rows where !row["email"].string.isEmpty && (input.userIds.contains(row["id"].string) || input.roles.contains(Self.role(row["role"].string))) {
                if let id=NativePluginActorScope.current?.actor.pluginId { try NativePluginExecutionScope.check(id) }
                try await sendNotification(row["email"].string,input.subject,input.text)
                if let id=NativePluginActorScope.current?.actor.pluginId { try NativePluginExecutionScope.check(id) }
            }
            if rows.count<100 { break };offset+=rows.count
        }
    }
    func runBefore(_ input:NativePluginRuleInput,actor:NativePluginActor,locale:String) throws -> NativePluginRecord {
        let depth=NativePluginActorScope.current?.depth ?? 0
        guard depth<=3 else { throw NativePluginError(message:"Plugin write depth exceeded (max 3)") }
        var matches:[(NativePluginDefinition,NativePluginRule,Int)]=[]
        for definition in try enabled() where actor.type != .plugin || definition.id != actor.pluginId {
            for (index,rule) in definition.rules.enumerated() where rule.entity==input.entity && rule.operation==input.operation { matches.append((definition,rule,index)) }
        }
        matches.sort { a,b in a.1.priority != b.1.priority ? a.1.priority < b.1.priority:a.0.id != b.0.id ? a.0.id.compare(b.0.id,locale:Locale(identifier:"en")) == .orderedAscending:a.2<b.2 }
        var data=input.data
        for (definition,rule,_) in matches {
            let result:NativePluginRuleResult
            var redactor=NativePluginRedactor([:])
            do {
                let started=ProcessInfo.processInfo.systemUptime,context=try context(definition,actor:actor,locale:locale)
                redactor=NativePluginRedactor(context.secrets)
                var next=input;next.data=data;result=try rule.handler(next,context)
                if ProcessInfo.processInfo.systemUptime-started>ruleTimeout { throw NativePluginError(message:"Rule timed out after \(Int(ruleTimeout*1000)) ms") }
            } catch {
                log(definition.id,"error","Rule \(input.entity.rawValue).\(input.operation.rawValue) failed: "+redactor.text(error.localizedDescription))
                if rule.onError=="block" { throw NativePluginRuleError(pluginId:nil,messageKey:"ruleUnavailable",translated:translate(nil,"ruleUnavailable",nil,locale)) };continue
            }
            switch result {
            case .allow:break
            case let .modify(patch):data.merge(patch) { _,new in new }
            case let .reject(key,params):throw NativePluginRuleError(pluginId:definition.id,messageKey:key,params:params,translated:translate(definition.id,key,params,locale))
            }
        }
        return data
    }
    func before(model:String,operation:String,existing:NativeRecord?,input:[String:SQLValue],actorID:String) throws -> [String:SQLValue] {
        try capabilities?.beforeWrite(model,operation,existing,input)
        if let writer=actor(actorID).pluginId { try NativePluginExecutionScope.check(writer) }
        guard let entity=NativePluginEntity(model:model) else { return input }
        let enabled=try enabled();guard enabled.contains(where:{$0.rules.contains(where:{$0.entity==entity}) || $0.afters.contains(where:{$0.entity==entity})}) else { return input }
        let actor=actor(actorID),data=NativePluginData(db:db,pluginId:"core",permissions:[]),schema=try db.schema.model(model)
        let partial=NativeRecord(model:model,values:input,revision:0),payload=try data.record(partial)
        let deleted=operation=="delete" || input["deletedAt"].map { $0 != .null && existing?["deletedAt"] == .null } == true
        let op:NativePluginRuleInput.Operation=operation=="create" ? .beforeCreate:deleted ? .beforeDelete:.beforeUpdate
        let changed=try runBefore(.init(entity:entity,operation:op,recordId:existing?["id"].string,data:payload,existing:try existing.map(data.record)),actor:actor,locale:NativePluginActorScope.current?.locale ?? defaultLocale)
        return try changed.reduce(into:[String:SQLValue]()) { output,item in guard let field=schema.field(item.key) else { throw NativePluginError(message:"Unknown field: "+item.key) };output[item.key]=try data.sql(item.value,field:field) }
    }
    func after(model:String,operation:String,before:NativeRecord?,after:NativeRecord?,input:[String:SQLValue],actorID:String) {
        guard let entity=NativePluginEntity(model:model),let id=(after ?? before)?["id"].string else { return }
        let deleted=operation=="delete" || (before?["deletedAt"] == .null && after?["deletedAt"] != .null)
        let op:NativePluginAfterInput.Operation=operation=="create" ? .created:deleted ? .deleted:.updated
        let changed=input.keys.filter { $0 != "v" && input[$0] != before?.values[$0] }.sorted(),actor=actor(actorID)
        do {
            let enabled=try enabled()
            for definition in enabled where !(actor.type == .plugin && actor.pluginId==definition.id) && definition.afters.contains(where:{$0.entity==entity && $0.operation==op}) {
                let event=NativePluginAfterInput(entity:entity,operation:op,recordId:id,actor:actor,changed:op == .updated ? changed:nil)
                do {
                    if try capabilities?.after(definition,event)==true { continue }
                    try db.transaction { try db.enqueue("plugin/after",payload:["pluginId":definition.id,"input":String(decoding:try JSONEncoder().encode(event),as:UTF8.self)],now:clock()) }
                }
                catch { log(definition.id,"error","Failed to enqueue after hook",["entity":entity.rawValue,"recordId":id]) }
            }
            if operation=="delete",!definitions.isEmpty {
                do { try db.transaction {
                    while true { let rows=try db.page("PluginData",fields:[],equal:["entityType":.text(entity.rawValue),"entityId":.text(id)]).rows;if rows.isEmpty { break };for row in rows { try db.remove(row,actor:"system") } }
                } } catch { log("core","error","Record store cleanup failed",["entity":entity.rawValue,"recordId":id]) }
            }
        } catch { log("core","error","After hook dispatch failed",["entity":entity.rawValue,"recordId":id]) }
    }
}

final class NativePluginRedactor {
    private let values:[String]
    init(_ secrets:NativePluginRecord) { values=secrets.values.compactMap { $0 as? String }.filter { !$0.isEmpty }.sorted { $0.count>$1.count } }
    func text(_ input:String)->String { values.reduce(input) { $0.replacingOccurrences(of:$1,with:"[redacted]") } }
    func record(_ input:NativePluginRecord)->NativePluginRecord {
        input.mapValues(value)
    }
    private func value(_ value:Any)->Any {
        if let text=value as? String { return self.text(text) };if let record=value as? NativePluginRecord { return self.record(record) }
        if let array=value as? [Any] { return array.map(self.value) };return value
    }
}
