import Foundation

enum NativeOdooPlugin {
    typealias Row = NativePluginRecord
    static let permissions=["http","accounts:read","accounts:write","contacts:read","contacts:write","users:read","notify","products:read","products:write","priceLists:read","priceLists:write","orders:read","orders:write"]
    static var definition:NativePluginDefinition {
        var value=NativePluginDefinition(id:"odoo-connector",name:"Odoo連携",version:"0.4.2",sdk:"^0.2.5",description:"Odooの取引先・担当者・商品・価格表を取り込み、受注・請求・入金状況を同期します。",permissions:permissions,settings:.connector(oxo:false),secrets:.connectorSecrets(oxo:false))
        value.crons=[.init(id:"sync",schedule:"*/5 * * * *",handler: { ctx in
            let now=ctx.clock(),client=NativeOdooClient.json(ctx);try await runQueued(ctx,client,now:now);_=try await NativeOdooOrdersOut.sweep(ctx,client,now:now);_=try await NativeOdooSync.scheduled(ctx,client,now:now)
        })]
        value.afters=[.init(entity:.order,operation:.updated,handler:NativeOdooOrdersOut.onUpdated)]
        value.actions=["test":{ _,ctx in try await NativeOdooClient.json(ctx).testConnection(ctx) },"sync":{ _,ctx in try queue(ctx,name:"sync",now:ctx.clock()) },"lists":{ _,ctx in try await loadLists(ctx,.json(ctx)) },"compare":{ _,ctx in try queue(ctx,name:"compare",now:ctx.clock()) }]
        value.slots=[.init(kind:.adminAction,id:"test",title:"admin.test",roles:["admin"]),.init(kind:.adminAction,id:"sync",title:"admin.syncNow",roles:["admin"]),.init(kind:.adminAction,id:"lists",title:"admin.loadLists",roles:["admin"]),.init(kind:.adminAction,id:"compare",title:"admin.compare",roles:["admin"]),.init(kind:.accountPanel,id:"odoo"),.init(kind:.accountTab,id:"odoo",title:"tab.title"),.init(kind:.productPanel,id:"odoo"),.init(kind:.orderPanel,id:"odoo"),.init(kind:.page,id:"needs-owner",title:"needsOwner.title",roles:["manager","admin"],nav:"needsOwner.nav"),.init(kind:.adminSection,id:"odoo")]
        value.onInstall={ ctx in do { _=try await NativeOdooSync.run(ctx,.json(ctx),now:ctx.clock()) } catch { ctx.log("error","Install sync failed: "+NativeOdooError.jsString(error)) } }
        return value
    }
    static func queue(_ ctx:NativePluginContext,name:String,now:Date)throws->String {
        guard ["sync","compare"].contains(name) else { throw NativePluginError(message:"Unknown Odoo job") }
        try ctx.store.set("job:"+name,["requestedAt":NativePluginJSON.stamp(now)]);return ctx.t("admin.queued")
    }
    static func runQueued(_ ctx:NativePluginContext,_ client:NativeOdooClient,now:Date) async throws {
        if let lock=try NativeOdooSupport.stored(ctx,"meta:lock"),let until=try? NativePluginJSON.date(NativePluginJSON.string(lock["until"])),until>now { return }
        for name in ["sync","compare"] where try ctx.store.get("job:"+name) != nil {
            try await NativeOdooSupport.cleanup(ctx,key:"job:"+name) {
                if name == "sync" { _=try await NativeOdooSync.run(ctx,client,now:now) } else { try await NativeOdooCompare.run(ctx,client,now:now) }
            }
        }
    }
    static func loadLists(_ ctx:NativePluginContext,_ client:NativeOdooClient) async throws -> String {
        let rows=try await client.rows("product.pricelist","search_read",["domain":[Any](),"fields":["id","name","currency_id","item_ids","active"],"order":"name asc"])
        let lists=try rows.map { row -> Row in
            var value:Row=["id":row["id"] ?? NSNull(),"name":row["name"] ?? NSNull(),"currency":NativeOdooMap.label(row["currency_id"]) ?? "","active":row["active"] ?? NSNull()]
            if let items=row["item_ids"] as? [Any] { value["rules"]=items.count }
            else if let text=row["item_ids"] as? String { value["rules"]=text.utf16.count }
            else if let object=row["item_ids"] as? Row,let length=object["length"] { value["rules"]=length }
            else if row["item_ids"] == nil || row["item_ids"] is NSNull { throw NativePluginError(message:"Cannot read properties of "+(row["item_ids"] == nil ? "undefined":"null")+" (reading 'length')") }
            return value
        }
        try ctx.store.set("meta:odooLists",["at":NativePluginJSON.stamp(ctx.clock()),"lists":lists]);return ctx.t("admin.listsLoaded",["count":lists.count])
    }
}
