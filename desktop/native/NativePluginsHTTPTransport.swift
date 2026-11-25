import Foundation

private final class NativePluginHTTPCancellation: @unchecked Sendable {
    private let lock=NSLock();private var value=false
    func cancel(){lock.lock();value=true;lock.unlock()}
    var cancelled:Bool { lock.lock();defer { lock.unlock() };return value }
}

enum NativePluginHTTPTransport {
    /// Source's private-host override is plugin-specific; MAIL_* never enables
    /// it. Tests inject resolver answers and connect only to isolated loopback.
    static func request(_ request:URLRequest,allowPrivate:Bool=false,maximumBytes:Int=32*1024*1024,resolvedAddresses:[String]?=nil) async throws -> (Data,HTTPURLResponse) {
        let cancellation=NativePluginHTTPCancellation()
        return try await withTaskCancellationHandler(operation:{
            try await Task.detached {
                guard let url=request.url,request.httpBodyStream==nil,maximumBytes>0,maximumBytes<=64*1024*1024 else { throw NativePluginError(message:"Invalid HTTP request") }
                if cancellation.cancelled { throw CancellationError() }
                let method=request.httpMethod ?? "GET",body=request.httpBody ?? Data(),timeout=request.timeoutInterval
                guard timeout.isFinite,timeout>0,timeout<=3600,method.range(of:#"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#,options:.regularExpression) != nil else { throw NativePluginError(message:"Invalid HTTP request") }
                var headers:[String]=[]
                for (key,value) in (request.allHTTPHeaderFields ?? [:]).sorted(by:{$0.key<$1.key}) {
                    guard key.range(of:#"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#,options:.regularExpression) != nil,!value.contains("\n"),!value.contains("\r"),!value.contains("\0") else { throw NativePluginError(message:"Invalid HTTP header") }
                    if key.lowercased()=="content-length",Int(value) != body.count { throw NativePluginError(message:"Content-Length does not match request body") }
                    headers.append(key+": "+value)
                }
                let strings=[url.absoluteString,method,headers.joined(separator:"\n")]+(resolvedAddresses.map { [$0.joined(separator:"\n")] } ?? [])
                let pointers=strings.map { strdup($0)! };defer { pointers.forEach { free($0) } }
                var result=body.withUnsafeBytes { bytes -> NativePluginHTTPResult in
                    var value=NativePluginHTTPRequest()
                    value.url=UnsafePointer(pointers[0]);value.method=UnsafePointer(pointers[1]);value.headers=UnsafePointer(pointers[2]);value.body=request.httpBody==nil ? nil:bytes.baseAddress?.assumingMemoryBound(to:UInt8.self);value.body_length=bytes.count;value.maximum_response=maximumBytes;value.timeout_ms=max(1,Int(timeout*1000));value.allow_private=allowPrivate ? 1:0
                    if pointers.count==4 { value.resolved_addresses=UnsafePointer(pointers[3]) }
                    value.context=Unmanaged.passUnretained(cancellation).toOpaque();value.cancelled={ pointer in guard let pointer else { return 1 };return Unmanaged<NativePluginHTTPCancellation>.fromOpaque(pointer).takeUnretainedValue().cancelled ? 1:0 }
                    return native_plugin_http_perform(&value)
                }
                defer { native_plugin_http_result_free(&result) }
                if result.code == -5 || cancellation.cancelled { throw CancellationError() }
                guard result.code==0 else {
                    let message=result.code == -2 ? "Host is not allowed":result.code == -3 ? "Host is not allowed":result.code == -4 ? "HTTP response exceeds the configured limit":result.code == 28 ? "HTTP request timed out":"HTTP transport failed (\(result.code))"
                    throw NativePluginError(message:message)
                }
                let responseBody=result.body.map { Data(bytes:$0,count:result.body_length) } ?? Data(),raw=result.headers.map { Data(bytes:$0,count:result.headers_length) } ?? Data()
                let text=String(data:raw,encoding:.isoLatin1) ?? "";var headerFields:[String:String]=[:],reason=""
                for line in text.components(separatedBy:"\r\n") {
                    if line.hasPrefix("HTTP/") { headerFields=[:];reason=line.split(separator:" ",maxSplits:2,omittingEmptySubsequences:false).dropFirst(2).map(String.init).joined(separator:" ");continue }
                    if let index=line.firstIndex(of:":") { let key=String(line[..<index]),value=line[line.index(after:index)...].trimmingCharacters(in:.whitespaces);headerFields[key]=headerFields[key].map { $0+", "+value } ?? value }
                }
                guard let response=NativePluginHTTPResponse(url:url,status:result.status,headers:headerFields,statusText:reason) else { throw NativePluginError(message:"Invalid HTTP response") }
                return (responseBody,response)
            }.value
        },onCancel:{cancellation.cancel()})
    }
}
