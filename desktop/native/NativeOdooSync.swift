import Foundation

enum NativeOdooSync {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    static let customerDomain:[[Any]]=[["customer_rank",">",0],["parent_id","=",false]]
    static func zero()->Row { ["created":0,"updated":0,"unchanged":0,"skipped":0,"conflicts":0,"failed":0] }
    final class Run {
        let ctx:NativePluginContext,client:NativeOdooClient,now:Date,dry:Bool,started:Date
        var counts=zero(),fields:[String]=[],countries:[String:String]=[:],owners:[Double:Any]=[:],done=Set<Double>(),top:String?,catalog:Row?,orders:Row?
        init(_ ctx:NativePluginContext,_ client:NativeOdooClient,_ now:Date) { self.ctx=ctx;self.client=client;self.now=now;dry=M.truth(ctx.settings["dryRun"]);started=ctx.clock() }
        func increment(_ key:String) { counts[key]=(counts[key] as? Int ?? 0)+1 }
        func owner(_ user:Any?) async throws -> String? {
            guard let id=M.id(user) else { return nil }
            if owners[id] == nil {
                let row=try await client.rows("res.users","read",["ids":[id],"fields":["login","email"]]).first
                let email=(row?["email"] as? String).flatMap { $0.isEmpty ? nil:$0 } ?? row?["login"] as? String
                if let email,!email.isEmpty { owners[id]=try ctx.data.find("users",["where":["email":["equals":email,"mode":"insensitive"],"userStatus":"ACTIVE"],"take":1]).first?["id"] ?? NSNull() }
                else { owners[id]=NSNull() }
            };return owners[id] as? String
        }
        func customer(_ p:Row) async throws {
            let id=M.number(p["id"]),link=try S.stored(ctx,S.key("partner",id))
            if NativePluginJSON.boolean(p["active"]) == false || !M.truth(p["customer_rank"]) {
                if !dry { try ctx.store.delete(S.key("conflict",id)) }
                if let link,!dry {
                    let key=S.key("account",link["accountId"] ?? NSNull()),prev=try S.stored(ctx,key)
                    try ctx.store.set(key,["partnerId":id,"salesperson":M.coalesce(prev?["salesperson"],NSNull()),"syncedAt":NativePluginJSON.stamp(now),"archived":NativePluginJSON.boolean(p["active"]) == false,"notCustomer":!M.truth(p["customer_rank"]),"odooPriceList":M.coalesce(prev?["odooPriceList"],NSNull())])
                };increment("skipped");return
            }
            let fields=M.accountFields(p,countries:countries,defaultCountry:M.string(ctx.settings["defaultCountry"])),match=try NativeOdooPartners.matchAccount(ctx,partnerID:id,fields:fields)
            if M.string(match["kind"]) == "conflict" {
                increment("conflicts");let info:Row=["partnerId":id,"reason":match["reason"] ?? NSNull(),"candidates":match["candidates"] ?? []]
                if dry { ctx.log("info","Dry run: would conflict",info) }
                else { try ctx.store.set(S.key("conflict",id),info.merging(["name":fields["name"]!,"foundAt":NativePluginJSON.stamp(now)]) { _,v in v }) };return
            }
            if !dry { try ctx.store.delete(S.key("conflict",id)) }
            let accountID:String,salesperson:Any
            if M.string(match["kind"]) == "new" {
                let owner=try await owner(p["user_id"]);salesperson=owner != nil ? NSNull() : M.label(p["user_id"]) ?? NSNull();increment("created")
                if dry { ctx.log("info","Dry run: would create account",fields.merging(["partnerId":id,"assigned_to":owner as Any? ?? NSNull()]) { _,v in v });return }
                accountID=M.string(try ctx.data.create(.account,fields.merging(["assigned_to":owner as Any? ?? NSNull(),"status":"Active"]) { _,v in v })["id"])
            } else {
                accountID=M.string(match["accountId"]);let current=try ctx.data.get("accounts",accountID) ?? [:];var diff=M.changedFields(current,fields)
                let owner = !M.truth(current["assigned_to"]) && M.truth(ctx.settings["fillOwners"]) ? try await owner(p["user_id"]) : nil
                if let owner { diff["assigned_to"]=owner }
                if diff.isEmpty { increment("unchanged") }
                else { increment("updated");if dry { ctx.log("info","Dry run: would update account",diff.merging(["partnerId":id,"accountId":accountID]) { _,v in v });return };_=try ctx.data.update(.account,accountID,diff) }
                if dry { return };salesperson=M.truth(current["assigned_to"]) || owner != nil ? NSNull() : M.label(p["user_id"]) ?? NSNull()
            }
            try ctx.store.set(S.key("partner",id),["accountId":accountID]);try ctx.store.set(S.key("account",accountID),["partnerId":id,"syncedAt":NativePluginJSON.stamp(now),"salesperson":salesperson,"odooPriceList":M.or(p["property_product_pricelist"],NSNull())])
        }
        func person(_ p:Row) async throws {
            let id=M.number(p["id"]),parent=try M.id(p["parent_id"]).flatMap { try S.stored(ctx,S.key("partner",$0)) }
            guard NativePluginJSON.boolean(p["active"]) != false,let parent else { increment("skipped");return }
            let fields=M.contactFields(p),link=try S.stored(ctx,S.key("contact",id));var current=try (link?["contactId"] as? String).flatMap { try ctx.data.get("contacts",$0) }
            if current == nil,M.truth(fields["email"]) { current=try ctx.data.find("contacts",["where":["accountsIDs":parent["accountId"] ?? NSNull(),"email":["equals":fields["email"]!,"mode":"insensitive"]],"take":1]).first }
            guard let current else {
                increment("created");if dry { ctx.log("info","Dry run: would create contact",fields.merging(["partnerId":id,"accountId":parent["accountId"] ?? NSNull()]) { _,v in v });return }
                let row=try ctx.data.create(.contact,fields.merging(["accountsIDs":parent["accountId"] ?? NSNull()]) { _,v in v });try ctx.store.set(S.key("contact",id),["contactId":row["id"] ?? NSNull()]);return
            }
            let diff=M.changedFields(current,fields)
            if diff.isEmpty { increment("unchanged") }
            else { increment("updated");if dry { ctx.log("info","Dry run: would update contact",diff.merging(["partnerId":id,"contactId":current["id"] ?? NSNull()]) { _,v in v });return };_=try ctx.data.update(.contact,M.string(current["id"]),diff) }
            if !dry { try ctx.store.set(S.key("contact",id),["contactId":current["id"] ?? NSNull()]) }
        }
        func guarded(_ row:Row,kind:String) async throws {
            let id=M.number(row["id"]);guard done.insert(id).inserted else { return }
            do { if kind == "person" || (kind == "dispatch" && M.truth(row["parent_id"])) { try await person(row) } else { try await customer(row) };if !dry { try ctx.store.delete(S.key("retry",id)) } }
            catch {
                if (error as? NativeOdooError)?.authentication == true { throw error }
                increment("failed");ctx.log("error","Partner \(M.string(id)) failed: "+NativeOdooError.message(error),["partnerId":id]);if !dry { try ctx.store.set(S.key("retry",id),Row()) }
            }
        }
        func pages(_ domain:[Any],order:String,kind:String,archived:Bool=false,track:Bool=false) async throws {
            var offset=0
            while true {
                var body:Row=["domain":domain,"fields":fields,"limit":100,"offset":offset,"order":order];if archived { body["context"]=["active_test":false] }
                let rows=try await client.rows("res.partner","search_read",body)
                for row in rows { try await guarded(row,kind:kind) }
                if track { for row in rows { if let date=row["write_date"] as? String,top == nil || date>top! { top=date } } }
                try ctx.store.set("meta:lock",["until":NativePluginJSON.stamp(now.addingTimeInterval(ctx.clock().timeIntervalSince(started)+600))])
                if rows.count<100 { return };offset += 100
            }
        }
        func linkedIDs()throws->[Double] { try ctx.store.list("partner:").map { M.number(String($0.key.dropFirst(8))) } }
        func first() async throws {
            try await pages(customerDomain+[["active","=",true]],order:"id asc",kind:"customer",track:true)
            let parents=try linkedIDs();if !parents.isEmpty { try await pages([["parent_id","in",parents],["type","=","contact"],["active","=",true]],order:"id asc",kind:"person",track:true) }
        }
        func incremental(_ cursor:String) async throws {
            let since=try NativeOdooCatalog.odooTime(NativeOdooCatalog.fromOdoo(cursor).addingTimeInterval(-120)),linked=try linkedIDs();top=cursor
            try await pages([["write_date",">",since],["parent_id","=",false],"|",["customer_rank",">",0],["id","in",linked]],order:"write_date asc, id asc",kind:"customer",archived:true,track:true)
            try await pages(customerDomain+[["active","=",true],["id","not in",linked]],order:"id asc",kind:"customer")
            let retry=try ctx.store.list("retry:").map { M.number(String($0.key.dropFirst(6))) };if !retry.isEmpty { try await pages([["id","in",retry]],order:"id asc",kind:"dispatch",archived:true) }
            let parents=try linkedIDs();if !parents.isEmpty { try await pages([["write_date",">",since],["type","=","contact"],["parent_id","in",parents]],order:"write_date asc, id asc",kind:"person",archived:true,track:true) }
            let fresh=parents.filter { !linked.contains($0) };if !fresh.isEmpty { try await pages([["parent_id","in",fresh],["type","=","contact"],["active","=",true]],order:"id asc",kind:"person") }
        }
        func summary(ok:Bool,error:String?=nil)->Row { var out=counts;out["at"]=NativePluginJSON.stamp(now);out["ok"]=ok;out["dryRun"]=dry;out["catalog"]=catalog;out["orders"]=orders;out["error"]=error;return out }
    }
    static func summaryText(_ ctx:NativePluginContext,_ summary:Row)->String {
        if !M.truth(summary["ok"]) { return ctx.t("admin.failed",["error":M.coalesce(summary["error"],"?")]) }
        var counts:Row=[:];for key in ["created","updated","unchanged","skipped","conflicts","failed"] { counts[key]=summary[key] }
        var parts=[ctx.t("admin.counts",counts)]
        if let orders=summary["orders"] as? Row { if M.truth(orders["checked"]) { parts.append(ctx.t("admin.orderCounts",["checked":orders["checked"]!,"moved":orders["moved"] ?? 0])) };if M.truth(orders["imported"]) { parts.append(ctx.t("admin.orderImported",["imported":orders["imported"]!])) } };return parts.joined(separator:" · ")
    }
    static func run(_ ctx:NativePluginContext,_ client:NativeOdooClient,now:Date) async throws -> Row {
        let r=Run(ctx,client,now)
        if let lock=try S.stored(ctx,"meta:lock"),let date=try? NativePluginJSON.date(M.string(lock["until"])),date>now { ctx.log("info","Sync skipped: another run is in progress");return r.summary(ok:false,error:ctx.t("admin.running")) }
        try ctx.store.set("meta:lock",["until":NativePluginJSON.stamp(now.addingTimeInterval(600))])
        let summary:Row = try await S.cleanup(ctx,key:"meta:lock") {
        var summary:Row
        do {
            r.fields=try await client.availableFields("res.partner",M.partnerFields)
            for country in try await client.rows("res.country","search_read",["domain":[Any](),"fields":["code"]]) { r.countries[M.string(country["id"])]=country["code"] as? String }
            if let cursor=try S.stored(ctx,"meta:cursor") { try await r.incremental(M.string(cursor["at"])) } else { try await r.first() }
            r.catalog=try await NativeOdooCatalog.sync(ctx,client,dry:r.dry,now:now)
            do { r.orders=try await NativeOdooOrdersStatus.sync(ctx,client,dry:r.dry,now:now) }
            catch { if (error as? NativeOdooError)?.authentication == true { throw error };ctx.log("error","Order statuses failed: "+NativeOdooError.message(error)) }
            do { let count=try await NativeOdooOrdersIn.sync(ctx,client,dry:r.dry,now:now);var orders=r.orders ?? ["checked":0,"moved":0];orders["imported"]=count;r.orders=orders }
            catch { if (error as? NativeOdooError)?.authentication == true { throw error };ctx.log("error","Orders from Odoo failed: "+NativeOdooError.message(error)) }
            if !r.dry,let top=r.top,!top.isEmpty { try ctx.store.set("meta:cursor",["at":top]) };summary=r.summary(ok:true);try ctx.store.set("meta:failures",["count":0])
            ctx.log("info","Sync finished"+(r.dry ? " (dry run)":""),r.counts.merging(["ms":floor(ctx.clock().timeIntervalSince(r.started)*1000)]) { _,v in v })
        } catch {
            let message=NativeOdooError.message(error);summary=r.summary(ok:false,error:message);ctx.log("error","Sync failed: "+message,r.counts)
            let failures=M.number(M.coalesce(try S.stored(ctx,"meta:failures")?["count"],0))+1;try ctx.store.set("meta:failures",["count":failures])
            if failures == 3 { await S.tell(ctx,.init(roles:["admin"],subject:ctx.t("mail.failingSubject"),text:ctx.t("mail.failingText",["error":message]))) }
        }
        return summary
        }
        try ctx.store.set("meta:lastRun",summary);return summary
    }
    static func scheduled(_ ctx:NativePluginContext,_ client:NativeOdooClient,now:Date) async throws -> Bool {
        if M.truth(ctx.settings["dryRun"]) { return false }
        if let last=try S.stored(ctx,"meta:lastRun"),let date=try? NativePluginJSON.date(M.string(last["at"])),now.timeIntervalSince(date)<M.number(ctx.settings["syncMinutes"])*60-30 { return false }
        _=try await run(ctx,client,now:now);return true
    }
}
