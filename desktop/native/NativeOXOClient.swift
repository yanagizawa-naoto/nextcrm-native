import Foundation

struct NativeOXOError: Error, LocalizedError {
    let message: String, status: Int
    var code: String? = nil
    var errorDescription: String? { message }
    var isAuthentication: Bool { status == 401 || status == 403 }
}
struct NativeOXOFinalError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
protocol NativeOXOClient {
    func get(_ path: String, _ parameters: [(String,String)]) async throws -> Any
    func all(_ path: String, _ parameters: [(String,String)]) async throws -> [NativePluginRecord]
    func post(_ path: String, _ body: NativePluginRecord) async throws -> (status:Int,body:Any)
}
extension NativeOXOClient {
    func get(_ path:String) async throws -> Any { try await get(path,[]) }
    func all(_ path:String) async throws -> [NativePluginRecord] { try await all(path,[]) }
}

/// No automatic retry: an uncertain order response is retained by the sender
/// for a later idempotent retry. Tests inject transport without external I/O.
final class NativeOXOHTTPClient: NativeOXOClient {
    typealias Transport = (URLRequest) async throws -> (Data,HTTPURLResponse)
    private let base:String, key:String, transport:Transport, statusText:(HTTPURLResponse)->String
    init(url:String,apiKey:String,transport:@escaping Transport,statusText:@escaping (HTTPURLResponse)->String = { ($0 as? NativePluginHTTPStatusText)?.statusText ?? HTTPURLResponse.localizedString(forStatusCode:$0.statusCode) }) {
        base=url.replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression);key=apiKey;self.transport=transport;self.statusText=statusText
    }
    convenience init(_ context:NativePluginContext) {
        self.init(url:NativePluginJSON.string(context.settings["url"]),apiKey:NativePluginJSON.string(context.secrets["apiKey"]),transport:{try await context.http($0)})
    }
    static func form(_ text:String) -> String {
        text.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [42,45,46,95].contains(byte) { return String(UnicodeScalar(byte)) }
            if byte == 32 { return "+" };return String(format:"%%%02X",byte)
        }.joined()
    }
    private func call(_ method:String,_ path:String,_ parameters:[(String,String)],_ body:NativePluginRecord? = nil) async throws -> (status:Int,body:Any) {
        try Task.checkCancellation()
        let query=parameters.map { Self.form($0.0)+"="+Self.form($0.1) }.joined(separator:"&")
        let target=base+"/api/v1"+path+(query.isEmpty ? "":"?"+query)
        guard let url=URL(string:target) else { throw NativeOXOError(message:"OXO ERP unreachable: Failed to parse URL",status:0) }
        var request=URLRequest(url:url);request.httpMethod=method;request.timeoutInterval=30
        request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let body { request.httpBody=try NativePluginJSON.data(body) }
        let data:Data,response:HTTPURLResponse
        do { (data,response)=try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw NativeOXOError(message:"OXO ERP unreachable: "+error.localizedDescription,status:0) }
        try Task.checkCancellation()
        let value=(try? NativePluginJSON.parse(String(decoding:data,as:UTF8.self))) ?? NSNull()
        if !(200...299).contains(response.statusCode) {
            let fields=value as? NativePluginRecord
            let message=NativeOXOMap.string(NativeOXOMap.coalesce(fields?["message"],statusText(response)))
            let code=fields?["error"] as? String
            throw NativeOXOError(message:"OXO ERP error \(response.statusCode): "+message,status:response.statusCode,code:code)
        }
        return (response.statusCode,value)
    }
    func get(_ path:String,_ parameters:[(String,String)] = []) async throws -> Any { try await call("GET",path,parameters).body }
    func all(_ path:String,_ parameters:[(String,String)] = []) async throws -> [NativePluginRecord] {
        var output:[NativePluginRecord]=[],cursor:String? = nil
        repeat {
            try Task.checkCancellation()
            // Object spread overrides limit/cursor while retaining key order.
            var query=parameters
            func set(_ key:String,_ value:String) { if let i=query.firstIndex(where:{$0.0 == key}) { query[i].1=value } else { query.append((key,value)) } }
            set("limit","500");if let cursor,!cursor.isEmpty { set("cursor",cursor) }
            let value=try await get(path,query)
            guard let page=value as? NativePluginRecord,let items=page["items"] as? [NativePluginRecord] else { throw NativePluginError(message:"Invalid OXO ERP page") }
            output.append(contentsOf:items)
            cursor=NativeOXOMap.truth(page["nextCursor"]) ? NativeOXOMap.string(page["nextCursor"]) : nil
        } while cursor != nil
        return output
    }
    func post(_ path:String,_ body:NativePluginRecord) async throws -> (status:Int,body:Any) { try await call("POST",path,[],body) }
}
