import Foundation

final class NativePluginHTTPResponse: HTTPURLResponse, NativePluginHTTPStatusText, @unchecked Sendable {
    let statusText:String
    init?(url:URL,status:Int,headers:[String:String],statusText:String) { self.statusText=statusText;super.init(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers) }
    required init?(coder:NSCoder) { statusText=coder.decodeObject(forKey:"nativeStatusText") as? String ?? "";super.init(coder:coder) }
    override func encode(with coder:NSCoder) { super.encode(with:coder);coder.encode(statusText,forKey:"nativeStatusText") }
}

enum NativePluginHTTP {
    typealias Transport=(URLRequest) async throws -> (Data,HTTPURLResponse)
    static func origin(_ url:URL)->String {
        let scheme=url.scheme?.lowercased() ?? "",host=url.host?.lowercased() ?? "",port=url.port ?? (scheme=="https" ? 443:80)
        return scheme+"://"+host+":"+String(port)
    }
    static func safeLogURL(_ url:URL)->String {
        let scheme=url.scheme?.lowercased() ?? "",port=url.port,defaultPort=scheme=="https" ? 443:80
        return scheme+"://"+(url.host ?? "")+(port==nil || port==defaultPort ? "":":"+String(port!))+(url.path.isEmpty ? "/":url.path)
    }
    /// Transport validates/resolves/pins on each call and returns redirects
    /// without following them. This mirrors the original six-request limit.
    static func fetch(_ initial:URLRequest,transport:Transport,log:(String,String,NativePluginRecord?)->Void={_,_,_ in}) async throws -> (Data,HTTPURLResponse) {
        var request=initial;let started=ProcessInfo.processInfo.systemUptime
        if request.timeoutInterval==60 { request.timeoutInterval=15 }
        do {
            for hop in 0...5 {
                try Task.checkCancellation()
                guard let url=request.url,["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil,url.user==nil,url.password==nil else { throw NativePluginError(message:"Invalid HTTP URL") }
                let result=try await transport(request),response=result.1
                guard (300..<400).contains(response.statusCode),let location=response.value(forHTTPHeaderField:"location"),!location.isEmpty else {
                    log("debug","http",["url":safeLogURL(url),"status":response.statusCode,"ms":Int((ProcessInfo.processInfo.systemUptime-started)*1000)]);return result
                }
                guard hop<5 else { throw NativePluginError(message:"Too many redirects (max 5)") }
                guard let next=URL(string:location,relativeTo:url)?.absoluteURL else { throw NativePluginError(message:"Invalid redirect URL") }
                if origin(next) != origin(url) { for key in ["authorization","cookie","proxy-authorization"] { request.setValue(nil,forHTTPHeaderField:key) } }
                let method=(request.httpMethod ?? "GET").uppercased()
                if method != "HEAD" && (response.statusCode==303 || ([301,302].contains(response.statusCode) && method=="POST")) {
                    request.httpMethod="GET";request.httpBody=nil;request.httpBodyStream=nil
                    for key in ["content-type","content-length"] { request.setValue(nil,forHTTPHeaderField:key) }
                }
                request.url=next
            }
            throw NativePluginError(message:"Too many redirects (max 5)")
        } catch {
            // Provider errors can contain URLs or credentials. Keep the reason
            // category here; the sanitized path and timing remain diagnostic.
            log("warn","http failed",["url":request.url.map(safeLogURL) ?? "","ms":Int((ProcessInfo.processInfo.systemUptime-started)*1000),"error":error is CancellationError ? "Cancelled":"HTTP request failed"])
            throw error
        }
    }
}
