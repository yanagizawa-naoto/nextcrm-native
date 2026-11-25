import Foundation

enum NativeAccountProtection {
    static let id="account-protection"
    static func owner(_ value:Any?) -> String? { guard let text=value as? String,!text.isEmpty else { return nil };return text }
    static func dictionary(_ store:NativePluginStore,_ key:String) throws -> NativePluginRecord? { try store.get(key) as? NativePluginRecord }
    static func key(_ account:NativePluginRecord,_ ctx:NativePluginContext) -> String? { NativeAccountProtectionState.numberKey(account,defaultCountry:ctx.settings["defaultCountry"] as? String ?? "CZ") }
    static func due(_ reg:NativePluginRecord,_ id:String) -> String { "due:"+NativeAccountProtectionState.dueDay(reg)+":"+id }
    static func start(_ store:NativePluginStore,_ id:String,_ reg:NativePluginRecord) throws { try store.set("reg:"+id,reg);try store.set(due(reg,id),NativePluginRecord()) }
    @discardableResult static func clear(_ store:NativePluginStore,_ id:String) throws -> NativePluginRecord? {
        guard let reg=try dictionary(store,"reg:"+id) else { return nil };try store.delete(due(reg,id));try store.delete("reg:"+id);return reg
    }
    static func lastHistory(_ store:NativePluginStore,_ id:String) throws -> NativePluginRecord? { try store.list("hist:"+id+":").last?.value as? NativePluginRecord }
    static func checkKey(_ key:String,selfId:String?,ctx:NativePluginContext) throws -> NativePluginRuleResult {
        guard let holder=try dictionary(ctx.store,"num:"+key),let id=holder["accountId"] as? String,id != selfId else { return .allow }
        let reg=try dictionary(ctx.store,"reg:"+id),me=(ctx.actor.type == .user || ctx.actor.type == .token) ? ctx.actor.userId:nil
        if let reg,let me,reg["ownerId"] as? String == me { return .reject(messageKey:"rules.ownAccount") }
        if ctx.actor.representative {
            let at=NativePluginJSON.stamp(ctx.clock()),noticeKey="notice:"+at+":"+String(UUID().uuidString.lowercased().prefix(6))
            let notice:NativePluginRecord=["at":at,"kind":reg == nil ? "blocked-free":"blocked-protected","userId":me as Any? ?? NSNull(),"accountId":id]
            let store=ctx.store
            try store.set(noticeKey,notice)
            ctx.persistAfterTransaction { try? store.set(noticeKey,notice) }
        }
        if let reg { return .reject(messageKey:"rules.protected",params:["until":try NativeAccountProtectionState.formatDay(reg["protectedUntil"] as! String,locale:ctx.locale)]) }
        return .reject(messageKey:ctx.actor.representative ? "rules.alreadyInCrm":"rules.exists")
    }
    static func beforeCreate(_ input:NativePluginRuleInput,_ ctx:NativePluginContext) throws -> NativePluginRuleResult {
        guard let key=key(input.data,ctx) else { return NativePluginJSON.truthy(ctx.settings["requireNumber"]) && ctx.actor.representative ? .reject(messageKey:"rules.numberRequired"):.allow }
        return try checkKey(key,selfId:nil,ctx:ctx)
    }
    static func beforeUpdate(_ input:NativePluginRuleInput,_ ctx:NativePluginContext) throws -> NativePluginRuleResult {
        let existing=input.existing ?? [:],data=input.data
        if data["assigned_to"] != nil,owner(data["assigned_to"]) != owner(existing["assigned_to"]),ctx.actor.representative { return .reject(messageKey:"rules.ownerManagersOnly") }
        if data["company_id"] != nil || data["billing_country"] != nil,let after=key(existing.merging(data) { _,new in new },ctx),after != key(existing,ctx) { return try checkKey(after,selfId:input.recordId,ctx:ctx) }
        return .allow
    }
    static func latestOrder(_ ctx:NativePluginContext,_ id:String) -> (readable:Bool,day:String?) {
        do {
            let order=try ctx.data.find("orders",["where":["accountId":id,"status":["in":["CONFIRMED","DELIVERED","INVOICED","PAID"]]],"orderBy":["orderDate":"desc"],"take":1]).first
            return (true,(order?["orderDate"] as? String).map { String($0.prefix(10)) })
        } catch { ctx.warnOnce("account-protection.orders","Orders cannot be read; protection ignores orders: "+error.localizedDescription);return (false,nil) }
    }
    @discardableResult static func recompute(_ id:String,_ ctx:NativePluginContext) throws -> NativePluginRecord? {
        guard let reg=try dictionary(ctx.store,"reg:"+id) else { return nil }
        let latest=latestOrder(ctx,id);guard latest.readable else { return reg }
        let next=try NativeAccountProtectionState.withOrders(reg,last:latest.day,months:Int(NativePluginJSON.number(ctx.settings["orderMonths"]) ?? 12))
        guard !NativePluginJSON.equal(next,reg) else { return reg }
        try ctx.store.delete(due(reg,id));try start(ctx.store,id,next)
        ctx.log("info","Protection recomputed from orders",["accountId":id,"from":reg["protectedUntil"] ?? NSNull(),"to":next["protectedUntil"] ?? NSNull(),"lastOrderAt":next["lastOrderAt"] ?? NSNull()]);return next
    }
    static func register(_ ctx:NativePluginContext,_ id:String,_ reg:NativePluginRecord) throws { try start(ctx.store,id,reg);try recompute(id,ctx) }
    static func newRegistration(_ key:String,_ owner:String,_ at:Date,_ ctx:NativePluginContext) throws -> NativePluginRecord { try NativeAccountProtectionState.newRegistration(key:key,ownerId:owner,at:at,settings:ctx.settings) }
    @discardableResult static func indexNumber(_ account:NativePluginRecord,_ ctx:NativePluginContext,_ at:Date) throws -> String? {
        let id=account["id"] as! String,key=key(account,ctx)
        try ctx.store.delete("conflict:"+id)
        if let old=try dictionary(ctx.store,"acct:"+id),let previous=old["key"] as? String,previous != key {
            let holder=try dictionary(ctx.store,"num:"+previous);try ctx.store.delete("acct:"+id)
            if holder?["accountId"] as? String == id { try ctx.store.delete("num:"+previous);try handOver(id,ctx,at,nil) }
        }
        guard let key else { return nil }
        if let holder=try dictionary(ctx.store,"num:"+key),let other=holder["accountId"] as? String,other != id { try ctx.store.set("conflict:"+id,["key":key,"otherAccountId":other,"foundAt":NativePluginJSON.stamp(at)]);return nil }
        try ctx.store.set("num:"+key,["accountId":id]);try ctx.store.set("acct:"+id,["key":key]);return key
    }
    static func handOver(_ fromId:String,_ ctx:NativePluginContext,_ at:Date,_ actor:NativePluginActor?) throws {
        for entry in try ctx.store.list("conflict:") where (entry.value as? NativePluginRecord)?["otherAccountId"] as? String == fromId {
            try ctx.store.delete(entry.key)
            if let duplicate=try ctx.data.get("accounts",String(entry.key.dropFirst(9))),!NativePluginJSON.truthy(duplicate["deletedAt"]) { try claimNumber(duplicate,ctx,at,actor) }
        }
    }
    static func claimNumber(_ account:NativePluginRecord,_ ctx:NativePluginContext,_ at:Date,_ actor:NativePluginActor?=nil) throws {
        let id=account["id"] as! String,key=try indexNumber(account,ctx,at)
        guard let to=owner(account["assigned_to"]) else { return }
        try recordOwner(account,to,actor,"assigned",ctx,at)
        guard let key else { return };try clear(ctx.store,id);try register(ctx,id,newRegistration(key,to,at,ctx))
    }
    static func recordOwner(_ account:NativePluginRecord,_ to:String?,_ actor:NativePluginActor?,_ reason:String,_ ctx:NativePluginContext,_ at:Date) throws {
        let id=account["id"] as! String,last=try lastHistory(ctx.store,id),key=try dictionary(ctx.store,"acct:"+id)?["key"] as? String
        if last != nil ? (last?["to"] as? String == to):(to == nil) {
            if let last,let to,let key,try ctx.store.get("reg:"+id) == nil { try register(ctx,id,newRegistration(key,to,NativePluginJSON.date(last["at"] as! String),ctx)) }
            return
        }
        try clear(ctx.store,id)
        let stamp=NativePluginJSON.stamp(at)
        try ctx.store.set("hist:"+id+":"+stamp,["at":stamp,"from":last?["to"] ?? NSNull(),"to":to as Any? ?? NSNull(),"byUserId":actor?.userId as Any? ?? NSNull(),"byType":actor?.type.rawValue ?? "system","reason":reason])
        if let to,let key { try register(ctx,id,newRegistration(key,to,at,ctx)) }
    }
    static func after(_ input:NativePluginAfterInput,_ ctx:NativePluginContext) throws {
        let at=ctx.clock(),id=input.recordId
        if input.entity == .order {
            if input.operation == .updated,!(input.changed ?? []).contains(where:{["status","orderDate"].contains($0)}) { return }
            do { if let order=try ctx.data.get("orders",id),let account=order["accountId"] as? String { try recompute(account,ctx) } }
            catch { ctx.log("warn","Order \(id) could not be read: "+error.localizedDescription) };return
        }
        if input.operation == .deleted {
            if let indexed=try dictionary(ctx.store,"acct:"+id),let key=indexed["key"] as? String {
                if try dictionary(ctx.store,"num:"+key)?["accountId"] as? String == id { try ctx.store.delete("num:"+key) };try ctx.store.delete("acct:"+id)
            }
            try clear(ctx.store,id);try ctx.store.delete("conflict:"+id);try handOver(id,ctx,at,input.actor);return
        }
        guard let account=try ctx.data.get("accounts",id) else { return }
        if input.operation == .created { try indexNumber(account,ctx,at);if let to=owner(account["assigned_to"]) { try recordOwner(account,to,input.actor,"created",ctx,at) };return }
        let changed=input.changed ?? []
        if changed.contains("deletedAt"),!NativePluginJSON.truthy(account["deletedAt"]) {
            if let key=try indexNumber(account,ctx,at),let to=owner(account["assigned_to"]),try ctx.store.get("reg:"+id) == nil { try register(ctx,id,newRegistration(key,to,at,ctx)) }
        }
        if changed.contains("company_id") || changed.contains("billing_country") {
            let key=try indexNumber(account,ctx,at),reg=try dictionary(ctx.store,"reg:"+id),to=owner(account["assigned_to"])
            if var reg { reg["key"]=key ?? "";try ctx.store.set("reg:"+id,reg) }
            else if let key,let to { try register(ctx,id,newRegistration(key,to,at,ctx)) }
        }
        if changed.contains("assigned_to") { let to=owner(account["assigned_to"]);try recordOwner(account,to,input.actor,to == nil ? "released":"assigned",ctx,at) }
    }
}
