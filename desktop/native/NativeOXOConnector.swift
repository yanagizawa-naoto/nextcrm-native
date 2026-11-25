import Foundation

/// OXO's SDK-facing operations. All durable state uses the host's scoped store;
/// provider requests are injected so isolated tests never contact a real ERP.
final class NativeOXOConnector {
    typealias Row = NativePluginRecord
    typealias M = NativeOXOMap
    let ctx: NativePluginContext, client: NativeOXOClient
    init(_ ctx:NativePluginContext,client:NativeOXOClient?=nil) { self.ctx=ctx;self.client=client ?? NativeOXOHTTPClient(ctx) }
    func stored(_ key:String) throws -> Row? { try ctx.store.get(key) as? Row }
    func entries(_ prefix:String) throws -> [(key:String,value:Row)] { try ctx.store.list(prefix).map { ($0.key,$0.value as? Row ?? [:]) } }
    func stamp(_ date:Date) -> String { NativePluginJSON.stamp(date) }
    func key(_ prefix:String,_ value:Any?) -> String { prefix+":"+M.string(value) }
    func message(_ error:Error) -> String { (error as? LocalizedError)?.errorDescription ?? String(describing:error) }
    func cancelled(_ error:Error) throws { if error is CancellationError || Task.isCancelled { throw CancellationError() } }
    func keepLock() throws { try ctx.store.set("meta:lock",["until":stamp(ctx.clock().addingTimeInterval(600))]) }
    func tell(_ subject:String,_ text:String) async {
        do { try await ctx.notify(.init(roles:["admin"],subject:subject,text:text)) }
        catch { ctx.log("warn","Email \""+subject+"\" not sent: "+message(error)) }
    }
    func findAll(_ name:String,where filter:Row,orderBy:Row=["id":"asc"]) throws -> [Row] {
        var out:[Row]=[],skip=0
        while true { let rows=try ctx.data.find(name,["where":filter,"orderBy":orderBy,"take":100,"skip":skip]);out += rows;if rows.count<100 { return out };skip += 100 }
    }
    func since(_ kind:String) throws -> (String?,[(String,String)]) {
        let top=try stored("meta:cursor:"+kind)?["at"] as? String
        return (top,try top.map { [("updatedSince",stamp(try NativePluginJSON.date($0).addingTimeInterval(-120)))] } ?? [])
    }
    func testConnection() async throws -> String {
        let body=try await client.get("/price-lists",[]) as? Row ?? [:]
        try ctx.store.delete("meta:sendPaused")
        return ctx.t("admin.connected",["lists":(body["items"] as? [Any] ?? []).count])
    }
    func queueJob(_ now:Date) throws -> String { try ctx.store.set("job:sync",["requestedAt":stamp(now)]);return ctx.t("admin.queued") }
    func runQueued(_ now:Date) async throws {
        guard try M.truth(ctx.store.get("job:sync")) else { return }
        do { _ = try await runSync(now) } catch { try ctx.store.delete("job:sync");throw error }
        try ctx.store.delete("job:sync")
    }
    func loadPriceLists() async throws -> String {
        let body=try await client.get("/price-lists",[]) as? Row ?? [:]
        let lists=(body["items"] as? [Row] ?? []).map { row -> Row in var r:Row=[:];for k in ["id","odooId","name","currency"] { r[k]=row[k] };r["rules"]=(row["rules"] as? [Any] ?? []).count;return r }
        try ctx.store.set("meta:oxoLists",["at":stamp(ctx.clock()),"lists":lists]);return ctx.t("admin.listsLoaded",["count":lists.count])
    }
    static func errorString(_ error:Error) -> String {
        let name=error is NativePluginStoreError ? "PluginStoreError":error is NativeOXOError ? "OxoError":error is NativeOXOFinalError ? "FinalError":"Error"
        return name+": "+((error as? LocalizedError)?.errorDescription ?? String(describing:error))
    }
    static let permissions=["http","accounts:read","accounts:write","users:read","notify","products:read","products:write","priceLists:read","priceLists:write","orders:read","orders:write"]
    static func definition() -> NativePluginDefinition {
        var d=NativePluginDefinition(id:"oxo-erp-connector",name:"OXO ERP連携",version:"0.1.0",sdk:"^0.2.6",description:"OXO ERPの取引先・商品・価格表を取り込み、受注の送信と納品状況の同期を行います。")
        d.permissions=permissions;d.settings = .connector(oxo:true);d.secrets = .connectorSecrets(oxo:true)
        d.afters=[.init(entity:.order,operation:.updated,handler:{ event,ctx in try await NativeOXOConnector(ctx).onOrderUpdated(event) })]
        d.crons=[.init(id:"sync",schedule:"*/5 * * * *",handler:{ ctx in let c=NativeOXOConnector(ctx),now=ctx.clock();try await c.runQueued(now);_ = try await c.sweepOrders(now);_ = try await c.scheduledSync(now) })]
        d.actions=["test":{_,ctx in try await NativeOXOConnector(ctx).testConnection()},"sync":{_,ctx in try NativeOXOConnector(ctx).queueJob(ctx.clock())},"lists":{_,ctx in try await NativeOXOConnector(ctx).loadPriceLists()}]
        d.slots=[.init(kind:.accountTab,id:"oxo-erp",title:"tab.title"),.init(kind:.accountPanel,id:"oxo-erp"),.init(kind:.productPanel,id:"oxo-erp"),.init(kind:.orderPanel,id:"oxo-erp"),.init(kind:.page,id:"needs-owner",title:"needsOwner.title",roles:["manager","admin"],nav:"needsOwner.nav"),.init(kind:.adminSection,id:"oxo-erp"),.init(kind:.adminAction,id:"test",title:"admin.test"),.init(kind:.adminAction,id:"sync",title:"admin.syncNow"),.init(kind:.adminAction,id:"lists",title:"admin.loadLists")]
        d.onInstall={ ctx in do { _ = try await NativeOXOConnector(ctx).runSync(ctx.clock()) } catch { ctx.log("error","Install sync failed: "+Self.errorString(error)) } }
        return d
    }
}
