import Foundation

struct NativeOdooError: Error, LocalizedError {
    let message: String
    let status: Int
    var authentication = false
    var final = false
    var errorDescription: String? { message }
    static func auth(_ status: Int) -> Self { .init(message:"Odoo rejected the API key",status:status,authentication:true) }
    static func final(_ message: String) -> Self { .init(message:message,status:-1,final:true) }
    static func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? String(describing:error) }
    static func jsString(_ error: Error) -> String {
        let name=(error as? Self).map { $0.authentication ? "OdooAuthError" : $0.final ? "Error":"OdooError" } ?? (error is NativePluginStoreError ? "PluginStoreError":error is NativePluginRuleError ? "PluginRuleError":"Error")
        return name+": "+message(error)
    }
    static func kind(_ error: Error) -> String {
        guard let error=error as? Self else { return "refused" }
        if error.authentication || error.status == 403 { return "denied" }
        if error.status == 0 || error.status == 429 || error.status >= 500 { return "unreachable" }
        return "refused"
    }
}

/// Every repeatable read gets three attempts. Mutations use `once` and recover by
/// searching their stable external identity on the next worker invocation.
struct NativeOdooClient {
    typealias Row = NativePluginRecord
    let call: (_ model:String,_ method:String,_ body:Row,_ once:Bool) async throws -> Any
    let version: () async throws -> String
    static func json(_ ctx: NativePluginContext,
                     sleep: @escaping (Int) async throws -> Void = { try await Task.sleep(nanoseconds:UInt64($0)*1_000_000) },
                     statusText: @escaping (HTTPURLResponse)->String = { ($0 as? NativePluginHTTPStatusText)?.statusText ?? "" }) -> Self {
        let base=NativeOdooMap.replace(NativePluginJSON.string(ctx.settings["url"]),#"/+$"#,""),key=NativePluginJSON.string(ctx.secrets["apiKey"]),database=NativePluginJSON.string(ctx.settings["database"])
        func post(_ path:String,_ body:Row,_ once:Bool) async throws -> Any {
            var attempt=0
            while true {
                try Task.checkCancellation()
                let response:(Data,HTTPURLResponse)
                do {
                    guard let url=URL(string:base+path) else { throw NativePluginError(message:"Invalid URL") }
                    var request=URLRequest(url:url,timeoutInterval:30);request.httpMethod="POST"
                    request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("bearer "+key,forHTTPHeaderField:"Authorization");request.setValue(database,forHTTPHeaderField:"X-Odoo-Database")
                    request.httpBody=try NativePluginJSON.data(body);response=try await ctx.http(request)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if once || attempt >= 2 { throw NativeOdooError(message:"Odoo unreachable: "+NativeOdooError.jsString(error),status:0) }
                    try await sleep(attempt == 0 ? 2000:4000);attempt += 1;continue
                }
                let status=response.1.statusCode
                if status == 401 { throw NativeOdooError.auth(status) }
                if status >= 500 {
                    if once || attempt >= 2 { throw NativeOdooError(message:"Odoo error \(status)",status:status) }
                    try await sleep(attempt == 0 ? 2000:4000);attempt += 1;continue
                }
                let value=(try? JSONSerialization.jsonObject(with:response.0,options:.fragmentsAllowed)) ?? NSNull()
                let message=NativeOdooMap.coalesce((value as? Row)?["message"],statusText(response.1))
                if status == 403 { throw NativeOdooError(message:"Odoo denied access: "+NativePluginJSON.string(message),status:403) }
                if !(200..<300).contains(status) { throw NativeOdooError(message:"Odoo error \(status): "+NativePluginJSON.string(message),status:status) }
                return value
            }
        }
        return Self(call: { try await post("/json/2/"+$0+"/"+$1,$2,$3) },version: {
            let value=try await post("/web/webclient/version_info",["jsonrpc":"2.0","method":"call","params":Row()],false)
            return ((value as? Row)?["result"] as? Row)?["server_version"] as? String ?? "unknown"
        })
    }
    func rows(_ model:String,_ method:String,_ body:Row=[:],once:Bool=false) async throws -> [Row] {
        guard let rows=try await call(model,method,body,once) as? [Row] else { throw NativePluginError(message:"Odoo returned an invalid row list") };return rows
    }
    func object(_ model:String,_ method:String,_ body:Row=[:]) async throws -> Row {
        guard let row=try await call(model,method,body,false) as? Row else { throw NativePluginError(message:"Odoo returned an invalid object") };return row
    }
    func ids(_ model:String,_ method:String,_ body:Row=[:],once:Bool=false) async throws -> [Double] {
        guard let values=try await call(model,method,body,once) as? [Any] else { throw NativePluginError(message:"Odoo returned an invalid identifier list") }
        return try values.map { guard let n=NativePluginJSON.number($0) else { throw NativePluginError(message:"Odoo returned an invalid identifier") };return n }
    }
    func availableFields(_ model:String,_ wanted:[String]) async throws -> [String] {
        let found=try await object(model,"fields_get",["attributes":["type"]]);return wanted.filter { found[$0] != nil }
    }
    func price(pricelistID:Double,currencyID:Double,productID:Double,quantity:Double) async throws -> Double {
        let result=try await call("sale.order.line","onchange",[
            "values":["order_id":["id":false,"pricelist_id":pricelistID,"currency_id":currencyID],"product_id":productID,"product_uom_qty":quantity],
            "field_names":["product_id"],"fields_spec":["order_id":["fields":["pricelist_id":Row()]],"product_id":Row(),"product_uom_qty":Row(),"price_unit":Row()]
        ],false)
        guard let price=NativePluginJSON.number(((result as? Row)?["value"] as? Row)?["price_unit"]) else { throw NativeOdooError(message:"Odoo cannot price sale lines over the API",status:0) };return price
    }
    func testConnection(_ ctx:NativePluginContext) async throws -> String {
        let context=try await object("res.users","context_get"),uid=context["uid"]
        let user=NativeOdooMap.truth(uid) ? try await rows("res.users","read",["ids":[uid!],"fields":["name"]]).first : nil
        let text=ctx.t("admin.connected",["version":try await version(),"user":user?["name"] ?? "?"])
        try ctx.store.delete("meta:sendPaused");return text
    }
}

enum NativeOdooSupport {
    /// Swift equivalent of JS finally: cleanup runs exactly once, including if
    /// the body or its error bookkeeping throws; cleanup failure takes priority.
    static func cleanup<T>(_ ctx: NativePluginContext, key: String, _ body: () async throws -> T) async throws -> T {
        let result: Result<T, Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        try ctx.store.delete(key)
        return try result.get()
    }

    static func tell(_ ctx:NativePluginContext,_ input:NativePluginNotification) async {
        do { try await ctx.notify(input) } catch { ctx.log("warn","Email \"\(input.subject)\" not sent: "+NativeOdooError.message(error)) }
    }
    static func localTime(_ ctx:NativePluginContext,_ iso:String)throws->String {
        try NativeOdooMap.localParts(NativePluginJSON.date(iso),zone:NativePluginJSON.string(ctx.settings["timeZone"])).time
    }
    static func key(_ prefix:String,_ id:Any)->String { prefix+":"+NativePluginJSON.string(id) }
    static func stored(_ ctx:NativePluginContext,_ key:String)throws->NativePluginRecord? { try ctx.store.get(key) as? NativePluginRecord }
}
