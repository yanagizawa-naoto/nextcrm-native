import Foundation

extension NativeOXOConnector {
    func summaryText(_ summary:Row) -> String {
        if !M.truth(summary["ok"]) { return ctx.t("admin.failed",["error":M.coalesce(summary["error"],"?")]) }
        var parts=[ctx.t("admin.customerCounts",summary["customers"] as? Row ?? [:])]
        if var catalog=summary["catalog"] as? Row { catalog["listsMissing"]=(catalog["listsMissing"] as? [Any] ?? []).map(M.string).joined(separator:", ");parts.append(ctx.t("admin.catalogCounts",catalog)) }
        if let orders=summary["orders"] as? Row { parts.append(ctx.t("admin.orderCounts",orders)) };return parts.joined(separator:" · ")
    }
    func runSync(_ now:Date) async throws -> Row {
        let dry=M.truth(ctx.settings["dryRun"]),run=CustomerRun(dry:dry,now:now)
        var summary:Row=["at":stamp(now),"dryRun":dry]
        guard try ctx.store.claim("meta:lock",ms:600000) else { ctx.log("info","Sync skipped: another run is in progress");summary.merge(["ok":false,"error":ctx.t("admin.running"),"customers":run.counts,"rows":run.rows]){_,b in b};return summary }
        var catalog:Row?,orders:Row=["checked":0,"moved":0,"imported":0,"updated":0,"pending":0]
        do {
            do {
                let customersTop=try await syncCustomers(run),cat=try await syncCatalog(dry:dry,now:now);catalog=cat.counts;var ordersTop:String?
                do { orders.merge(try await syncOrderStatuses(dry:dry,now:now)){_,b in b} }
                catch { try cancelled(error);if (error as? NativeOXOError)?.isAuthentication == true { throw error };ctx.log("error","Order statuses failed: "+message(error)) }
                do { var incoming=try await syncOrdersIn(dry:dry,now:now);ordersTop=incoming.removeValue(forKey:"top") as? String;orders.merge(incoming){_,b in b} }
                catch { try cancelled(error);if (error as? NativeOXOError)?.isAuthentication == true { throw error };ctx.log("error","Orders from OXO ERP failed: "+message(error)) }
                if !dry { for (kind,top) in [("customers",customersTop),("products",cat.top),("orders",ordersTop)] { if let top { try ctx.store.set("meta:cursor:"+kind,["at":top]) } } }
                summary["ok"]=true;try ctx.store.set("meta:failures",["count":0]);ctx.log("info","Sync finished"+(dry ? " (dry run)":""),run.counts)
            } catch {
                try cancelled(error);let reason=message(error);summary["ok"]=false;summary["error"]=reason;ctx.log("error","Sync failed: "+reason)
                let failures=M.number(try stored("meta:failures")?["count"] ?? 0)+1;try ctx.store.set("meta:failures",["count":failures])
                if failures==3 { await tell(ctx.t("mail.failingSubject"),ctx.t("mail.failingText",["error":reason])) }
            }
            try ctx.store.delete("meta:lock")
        } catch { try ctx.store.delete("meta:lock");throw error }
        summary["customers"]=run.counts;summary["catalog"]=catalog;summary["orders"]=orders;summary["rows"]=run.rows
        try ctx.store.set("meta:lastRun",summary);if dry { try ctx.store.set("meta:report",summary) };return summary
    }
    func scheduledSync(_ now:Date) async throws -> Bool {
        if M.truth(ctx.settings["dryRun"]) { return false }
        if let last=try stored("meta:lastRun"),let at=last["at"] as? String,let parsed=try? NativePluginJSON.date(at),now.timeIntervalSince(parsed)*1000<M.number(ctx.settings["syncMinutes"])*60000-30000 { return false }
        _ = try await runSync(now);return true
    }
}
