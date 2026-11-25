import Foundation

extension NativeAccountProtection {
    static func resume(_ ctx:NativePluginContext,_ now:Date) throws {
        if let last=try dictionary(ctx.store,"meta:lastRun"),let stamp=last["at"] as? String,let since=try? NativePluginJSON.date(stamp),now.timeIntervalSince(since)>3600 {
            func lapsed(_ value:Any?) -> Bool { guard let text=value as? String,let date=try? NativePluginJSON.date(text) else { return false };return date>since && date<=now }
            var seen=Set<String>(),ids:[String]=[]
            for (prefix,count) in [("reg:",4),("acct:",5)] { for entry in try ctx.store.list(prefix) { let id=String(entry.key.dropFirst(count));if seen.insert(id).inserted { ids.append(id) } } }
            for id in ids {
                do {
                    guard let account=try ctx.data.get("accounts",id),!NativePluginJSON.truthy(account["deletedAt"]) else { continue }
                    let to=owner(account["assigned_to"])
                    if try lastHistory(ctx.store,id)?["to"] as? String != to { try recordOwner(account,to,.plugin(ctx.plugin.id),to == nil ? "released":"assigned",ctx,now) }
                    if let reg=try dictionary(ctx.store,"reg:"+id),lapsed(reg["protectedUntil"]) || (!NativePluginJSON.truthy(reg["contactAt"]) && lapsed(reg["contactDeadline"])) {
                        try clear(ctx.store,id);try register(ctx,id,newRegistration(reg["key"] as! String,reg["ownerId"] as! String,now,ctx))
                    }
                } catch { ctx.log("error","Catch-up after a pause failed for account \(id): "+error.localizedDescription) }
            }
        }
        try ctx.store.set("meta:lastRun",["at":NativePluginJSON.stamp(now)])
    }
    static func pruneConflicts(_ ctx:NativePluginContext,_ at:Date) throws {
        for entry in try ctx.store.list("conflict:") {
            guard let conflict=entry.value as? NativePluginRecord,let number=conflict["key"] as? String else { continue }
            guard let duplicate=try ctx.data.get("accounts",String(entry.key.dropFirst(9))),!NativePluginJSON.truthy(duplicate["deletedAt"]) else { try ctx.store.delete(entry.key);continue }
            let holder=try dictionary(ctx.store,"num:"+number)
            if holder?["accountId"] as? String == conflict["otherAccountId"] as? String,key(duplicate,ctx)==number { continue }
            try claimNumber(duplicate,ctx,at)
        }
    }
    static func expire(_ ctx:NativePluginContext,_ now:Date) async throws {
        try resume(ctx,now);try pruneConflicts(ctx,now)
        let today=String(NativePluginJSON.stamp(now).prefix(10));var freed:[String]=[]
        for entry in try ctx.store.list("reg:") {
            let id=String(entry.key.dropFirst(4))
            do { try recompute(id,ctx) } catch { ctx.log("error","Order recompute failed for account \(id): "+error.localizedDescription) }
        }
        for entry in try ctx.store.list("due:") {
            let day=String(entry.key.dropFirst(4).prefix(10)),id=String(entry.key.dropFirst(15));if day>today { continue }
            do {
                guard var reg=try dictionary(ctx.store,"reg:"+id) else { try ctx.store.delete(entry.key);continue }
                var verdict=try NativeAccountProtectionState.evaluate(reg,now:now)
                if verdict == "check-contact" {
                    let types=NativeAccountProtectionState.contactTypes(ctx.settings["contactTypes"] as? String ?? "visit,meeting"),since=String((reg["registeredAt"] as! String).prefix(10))+"T00:00:00.000Z"
                    if let contact=try ctx.data.activitiesForRecord("account",id,["types":types,"status":"completed","since":since,"take":1]).first {
                        reg["contactAt"]=NativePluginJSON.stamp(try NativePluginJSON.date(contact["date"] as! String));try ctx.store.delete(entry.key);try start(ctx.store,id,reg);continue
                    }
                    verdict="expired-no-contact"
                }
                if verdict == "keep" { continue }
                let row=try ctx.data.update(.account,id,["assigned_to":NSNull()]),stamp=NativePluginJSON.stamp(now)
                try ctx.store.set("hist:"+id+":"+stamp,["at":stamp,"from":reg["ownerId"] ?? NSNull(),"to":NSNull(),"byUserId":NSNull(),"byType":"plugin","reason":verdict])
                try ctx.store.set("freed:"+today+":"+id,["reason":verdict]);try clear(ctx.store,id)
                freed.append(NativePluginJSON.string(row["name"] is NSNull || row["name"] == nil ? id:row["name"]))
            } catch { ctx.log("error","Expiry failed for account \(id): "+error.localizedDescription) }
        }
        let cutoff=String(NativePluginJSON.stamp(now.addingTimeInterval(-7*NativeAccountProtectionState.day)).prefix(10))
        for entry in try ctx.store.list("freed:") where String(entry.key.dropFirst(6).prefix(10)) < cutoff { try ctx.store.delete(entry.key) }
        if !freed.isEmpty { try await ctx.notify(.init(roles:["manager","admin"],subject:ctx.t("mail.expiredSubject",["count":freed.count]),text:([ctx.t("mail.expiredText")]+freed.map { "- "+$0 }).joined(separator:"\n"))) }
    }
    static func sendNotices(_ ctx:NativePluginContext,_ now:Date) async throws {
        try resume(ctx,now)
        for entry in try ctx.store.list("notice:") {
            guard let notice=entry.value as? NativePluginRecord,let id=notice["accountId"] as? String,let kind=notice["kind"] as? String else { continue }
            do {
                let account=try ctx.data.get("accounts",id),user=try (notice["userId"] as? String).flatMap { try ctx.data.get("users",$0) }
                func coalesce(_ candidates:[Any?])->Any { candidates.first { $0 != nil && !($0 is NSNull) }!! }
                let params=["account":NativePluginJSON.string(coalesce([account?["name"],id])),"user":NativePluginJSON.string(coalesce([user?["name"],user?["email"],"-"]))]
                try await ctx.notify(.init(roles:["manager","admin"],subject:ctx.t("mail.\(kind).subject",params),text:ctx.t("mail.\(kind).text",params)))
                try ctx.store.delete(entry.key)
            } catch {
                let date=(notice["at"] as? String).flatMap { try? NativePluginJSON.date($0) }
                if let date,now.timeIntervalSince(date)>NativeAccountProtectionState.day { ctx.log("error","Notice dropped after 24 h: "+error.localizedDescription,["accountId":id]);try ctx.store.delete(entry.key) }
                else { ctx.log("warn","Notice not sent, will retry: "+error.localizedDescription,["accountId":id]) }
            }
        }
    }
    static func install(_ ctx:NativePluginContext,_ at:Date) throws {
        try ctx.store.set("meta:lastRun",["at":NativePluginJSON.stamp(at)]);var skip=0
        while true {
            let page=try ctx.data.find("accounts",["where":["deletedAt":NSNull()],"orderBy":["createdAt":"asc"],"take":100,"skip":skip])
            for account in page { try indexNumber(account,ctx,at);if let to=owner(account["assigned_to"]) { try recordOwner(account,to,.plugin(ctx.plugin.id),"install",ctx,at) } }
            if page.count<100 { break };skip+=100
        }
    }
    static func upgrade(_ ctx:NativePluginContext,_ at:Date) throws {
        if try ctx.store.get("meta:lastRun") == nil { try ctx.store.set("meta:lastRun",["at":NativePluginJSON.stamp(at)]) }
        try pruneConflicts(ctx,at)
        for entry in try ctx.store.list("reg:") {
            let id=String(entry.key.dropFirst(4))
            do { try recompute(id,ctx) } catch { ctx.log("error","Upgrade recompute failed for account \(id): "+error.localizedDescription) }
        }
    }
    static func definition() -> NativePluginDefinition {
        var d=NativePluginDefinition(id:id,name:"取引先の担当保護",version:"0.2.0",sdk:"^0.2.0",description:"法人番号ごとに担当者を管理し、担当の保護期間・変更履歴・期限の確認を行います。",permissions:["accounts:read","accounts:write","activities:read","orders:read","users:read","notify"],settings:.accountProtection)
        d.rules=[.init(entity:.account,operation:.beforeCreate,onError:"block",handler:beforeCreate),.init(entity:.account,operation:.beforeUpdate,onError:"block",handler:beforeUpdate)]
        d.afters=[(.account,.created),(.account,.updated),(.account,.deleted),(.order,.created),(.order,.updated)].map { entity,operation in .init(entity:entity,operation:operation,handler:{ input,ctx in try after(input,ctx) }) }
        d.crons=[.init(id:"expire",schedule:"0 6 * * *",handler:{ try await expire($0,$0.clock()) }),.init(id:"notices",schedule:"*/5 * * * *",handler:{ try await sendNotices($0,$0.clock()) })]
        d.slots=[.init(kind:.accountTab,id:"protection",title:"tab.title"),.init(kind:.accountPanel,id:"protection"),.init(kind:.page,id:"expiring",title:"expiring.title",roles:["manager","admin"],nav:"expiring.nav"),.init(kind:.adminSection,id:"conflicts")]
        d.onInstall={ try install($0,$0.clock()) };d.onUpgrade={ ctx,_ in try upgrade(ctx,ctx.clock()) }
        return d
    }
}
