import Foundation
import CryptoKit

struct CalendlyRelayError: LocalizedError {
    let message: String, retryable: Bool
    var errorDescription: String? { message }
}
private final class CalendlyNoRedirects: NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct CalendlyRelayClient {
    static let maximumResponseBytes = 2*1_048_576
    typealias Request = (URLRequest) async throws -> (Data,HTTPURLResponse)
    struct Event: Decodable {
        let seq: Int64, body: Data, bodySHA256: String, signature: String, receivedAt: String
    }
    struct State: Decodable {
        let version: Int, instanceId: String, clientId: String?, head: Int64
        let keyGeneration: String?, signingKeyFingerprint: String?, callbackReady: Bool?
        let events: [Event]?, cursor: Int64?, hasMore: Bool?
    }
    let baseURL: URL, clientID: String
    private var expectedInstanceID: String?
    private let key: SymmetricKey, fileRequest: NativeCalendarResponse.Request, clock: () -> Date
    init(baseURL: URL,authKey: String,clientID: String,expectedInstanceID: String? = nil,allowLoopbackHTTP: Bool = false,request: Request? = nil,fileRequest: NativeCalendarResponse.Request? = nil,clock: @escaping () -> Date = Date.init) throws {
        guard var parts = URLComponents(url:baseURL,resolvingAgainstBaseURL:false), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme == "https" || (allowLoopbackHTTP && parts.scheme == "http" && ["127.0.0.1","localhost","::1","[::1]"].contains(host)),
              !parts.path.split(separator:"/").contains(".."), UUID(uuidString:clientID) != nil,
              expectedInstanceID == nil || UUID(uuidString:expectedInstanceID!) != nil,
              authKey.utf8.count == 43, authKey.range(of:#"^[A-Za-z0-9_-]{43}$"#,options:.regularExpression) != nil,
              let bytes = Data(base64Encoded:authKey.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+"="), bytes.count == 32 else { throw Self.failure("予約通知の受信URL・接続ID・認証キーを確認してください。") }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw Self.failure("予約通知の受信URLが不正です。") }
        self.baseURL = url; self.clientID = clientID; self.expectedInstanceID = expectedInstanceID; key = SymmetricKey(data:bytes); self.clock = clock
        if let fileRequest{self.fileRequest=fileRequest}
        else if let request{self.fileRequest={query in let(data,response)=try await request(query);return try NativeCalendarResponse(data:data,response:response)}}
        else{self.fileRequest={try await NativeCalendarResponse.network($0)}}
    }
    static func failure(_ message: String,retryable: Bool = false) -> CalendlyRelayError { .init(message:message,retryable:retryable) }
    func expecting(_ instanceID: String) throws -> Self { guard UUID(uuidString:instanceID) != nil else { throw Self.failure("受信窓口の識別子が不正です。") }; var copy = self; copy.expectedInstanceID = instanceID; return copy }
    static func network(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration:config,delegate:CalendlyNoRedirects(),delegateQueue:nil); defer{session.invalidateAndCancel()}
        let (bytes,response) = try await session.bytes(for:request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= maximumResponseBytes else { throw failure("予約通知の応答が大きすぎるか、不正です。") }
        var data = Data(); data.reserveCapacity(64*1024)
        for try await byte in bytes { guard data.count < maximumResponseBytes else { throw failure("予約通知の応答が大きすぎます。") }; data.append(byte) }
        return (data,response)
    }
    private func download(_ method: String,_ endpoint: String,namespace: String = "api/native-calendly/v1/",query: [URLQueryItem] = [],body: [String:Any]? = nil,allowUnbound: Bool = false) async throws -> NativeCalendarResponse {
        guard var parts = URLComponents(url:baseURL.appendingPathComponent(namespace+endpoint),resolvingAgainstBaseURL:false) else { throw Self.failure("受信URLが不正です。") }
        if !query.isEmpty { parts.queryItems = query }; guard let url = parts.url else { throw Self.failure("受信URLが不正です。") }
        let bytes = try body.map{try JSONSerialization.data(withJSONObject:$0,options:.sortedKeys)} ?? Data(), time = clock().timeIntervalSince1970
        guard bytes.count <= 1_048_576, time.isFinite, time >= 0, time < 253_402_300_800 else { throw Self.failure("送信内容またはMacの日時が不正です。") }
        let nonce = UUID().uuidString.lowercased(), timestamp = String(Int64(floor(time))), target = parts.percentEncodedPath+(parts.percentEncodedQuery.map{"?"+$0} ?? "")
        var authenticated = Data(("nextcrm-calendar-v1-request\n"+method+"\n"+target+"\n"+timestamp+"\n"+nonce+"\n").utf8); authenticated.append(bytes)
        var query = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData); query.httpMethod = method
        query.setValue(nonce,forHTTPHeaderField:"X-NextCRM-Nonce"); query.setValue(timestamp,forHTTPHeaderField:"X-NextCRM-Timestamp"); query.setValue(Data(HMAC<SHA256>.authenticationCode(for:authenticated,using:key)).base64EncodedString(),forHTTPHeaderField:"X-NextCRM-Signature"); query.setValue("application/json",forHTTPHeaderField:"Content-Type"); query.setValue("application/json",forHTTPHeaderField:"Accept")
        if method != "GET" { query.httpBody = bytes }; try Task.checkCancellation()
        let response:NativeCalendarResponse
        do{response=try await fileRequest(query)}catch is CancellationError{throw CancellationError()}catch{if Task.isCancelled{throw CancellationError()};throw Self.failure("予約通知の受信窓口へ接続できません。",retryable:true)}
        try Task.checkCancellation()
        var mac=HMAC<SHA256>(key:key);mac.update(data:Data(("nextcrm-calendar-v1-response\n"+nonce+"\n"+String(response.response.statusCode)+"\n").utf8))
        try response.forEachChunk{mac.update(data:$0)}
        guard let encoded=response.response.value(forHTTPHeaderField:"X-NextCRM-Signature"),let code=Data(base64Encoded:encoded),code.count==32 else{throw Self.failure("予約通知の応答を認証できません。")}
        let calculated=Array(mac.finalize()),provided=Array(code);var difference:UInt8=0
        for i in 0..<32{difference |= calculated[i] ^ provided[i]}
        guard difference==0 else{throw Self.failure("予約通知の応答を認証できません。受信URL・認証キー・Macの日時を確認してください。",retryable:response.response.statusCode>=500)}
        guard (200..<300).contains(response.response.statusCode) else{throw Self.failure(response.response.statusCode==409 ? "予約通知の接続先・設定または履歴が変更されています。状態を確認してください。":"予約通知の受信窓口が処理を完了できませんでした。",retryable:response.response.statusCode==429 || response.response.statusCode>=500)}
        return response
    }
    private func validated(_ data:Data,allowUnbound:Bool=false)throws->State {
        guard let state = try? JSONDecoder().decode(State.self,from:data), state.version == 1, UUID(uuidString:state.instanceId) != nil,
              state.head >= 0, state.head <= 9_007_199_254_740_991, expectedInstanceID == nil || expectedInstanceID == state.instanceId,
              state.clientId == clientID || (allowUnbound && state.clientId == nil),
              (state.keyGeneration == nil && state.signingKeyFingerprint == nil) || (state.keyGeneration.flatMap(UUID.init(uuidString:)) != nil && state.signingKeyFingerprint?.utf8.count == 64 && state.signingKeyFingerprint?.range(of:#"^[a-f0-9]{64}$"#,options:.regularExpression) != nil) else { throw Self.failure("予約通知の応答・接続先を確認できません。") }
        return state
    }
    private func perform(_ method:String,_ endpoint:String,namespace:String="api/native-calendly/v1/",query:[URLQueryItem]=[],body:[String:Any]?=nil,allowUnbound:Bool=false)async throws->State {
        let response=try await download(method,endpoint,namespace:namespace,query:query,body:body,allowUnbound:allowUnbound)
        return try validated(response.data(maximumBytes:Self.maximumResponseBytes),allowUnbound:allowUnbound)
    }
    func health() async throws -> State { try await perform("GET","health",allowUnbound:true) }
    func bind() async throws -> State { try await perform("POST","bind",body:["clientId":clientID]) }
    func configure(signingKey: String,expectedGeneration: String?) async throws -> State {
        guard !signingKey.isEmpty, signingKey.utf8.count <= 16_384, !signingKey.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}), expectedGeneration == nil || UUID(uuidString:expectedGeneration!) != nil else { throw Self.failure("Calendlyの署名キーを確認してください。") }
        let state = try await perform("POST","signing-key",body:["clientId":clientID,"signingKey":signingKey,"expectedGeneration":expectedGeneration as Any? ?? NSNull()])
        guard state.signingKeyFingerprint == SHA256.hash(data:Data(signingKey.utf8)).map({String(format:"%02x",$0)}).joined(), state.keyGeneration != nil else { throw Self.failure("受信窓口に保存された署名キーを確認できません。") }; return state
    }
    func checkCallback() async throws {
        let state = try await perform("GET","calendly",namespace:"api/crm/calendar/webhooks/",query:[.init(name:"check",value:"ready"),.init(name:"clientId",value:clientID)])
        guard state.callbackReady == true, state.keyGeneration != nil else { throw Self.failure("Calendlyの通知を受信する設定が完了していません。") }
    }
    struct EventBatch {
        let state:State
        fileprivate let response:NativeCalendarResponse,after:Int64
        func forEach(_ consume:(Event)throws->Void)throws {
            var prior=after
            _ = try response.project(array:"events",metadata:[],maximumItems:100,requireArray:true,begin:{prior=after},element:{data in
                let event=try JSONDecoder().decode(Event.self,from:data)
                try CalendlyRelayClient.validateEvent(event,prior:prior,cursor:state.cursor!);prior=event.seq
                try consume(event)
            })
            guard prior==state.cursor! else{throw CalendlyRelayClient.failure("予約通知の同期位置と内容が一致しません。")}
        }
    }
    private static func validateEvent(_ event:Event,prior:Int64,cursor:Int64)throws {
        guard event.seq>prior,event.seq<=cursor,event.bodySHA256.utf8.count==64,
              SHA256.hash(data:event.body).map({String(format:"%02x",$0)}).joined()==event.bodySHA256,
              event.signature.utf8.count<=8192,(try? NativeCalendarEvents.date(event.receivedAt)) != nil else{throw failure("保存済みの予約通知が不正です。")}
    }
    func eventBatch(after:Int64)async throws->EventBatch {
        guard after>=0,after<=9_007_199_254_740_991 else{throw Self.failure("予約通知の同期位置が不正です。")}
        let response=try await download("GET","events",query:[.init(name:"clientId",value:clientID),.init(name:"after",value:String(after))])
        // Validate the entire signed page before exposing any import callback.
        // Only a hundred integer sequence numbers are retained, no event bodies.
        var sequence:[Int64]=[]
        let metadata=try response.project(array:"events",metadata:["version","instanceId","clientId","head","keyGeneration","signingKeyFingerprint","cursor","hasMore"],maximumItems:100,requireArray:true,begin:{sequence=[]},element:{data in
            let event=try JSONDecoder().decode(Event.self,from:data)
            try Self.validateEvent(event,prior:sequence.last ?? after,cursor:9_007_199_254_740_991);sequence.append(event.seq)
        })
        let state=try validated(JSONSerialization.data(withJSONObject:metadata)),last=sequence.last ?? after
        guard state.head>=after,let cursor=state.cursor,let more=state.hasMore,cursor>=after,cursor<=state.head,
              more==(cursor<state.head),!sequence.isEmpty || (!more && cursor==after),last==cursor else{throw Self.failure("予約通知のページ順序を確認できません。")}
        return .init(state:state,response:response,after:after)
    }
    /// Compatibility for existing small callers; the production sync consumes
    /// EventBatch one event at a time and never materializes this array.
    func events(after:Int64)async throws->State {
        let batch=try await eventBatch(after:after);var events:[Event]=[];try batch.forEach{events.append($0)};let state=batch.state
        return .init(version:state.version,instanceId:state.instanceId,clientId:state.clientId,head:state.head,keyGeneration:state.keyGeneration,signingKeyFingerprint:state.signingKeyFingerprint,callbackReady:state.callbackReady,events:events,cursor:state.cursor,hasMore:state.hasMore)
    }
}
