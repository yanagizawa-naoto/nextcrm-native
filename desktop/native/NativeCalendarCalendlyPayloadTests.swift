import Foundation
import CryptoKit

@main enum CalendlyPayloadTests {
    static func main()async{do{try await run()}catch{print("Calendly payload failed: \(error)");exit(1)}}
    static func run()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]);var checks=0,comparisons:[[String:Any]]=[]
        func check(_ value:Bool,_ label:String)throws{guard value else{throw NativeDBError.message(label)};checks += 1}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CalendlyPayload-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
        let clientID=try CalendlyRelayBinding.clientID(db:db),instance=UUID().uuidString.lowercased(),url=URL(string:"https://calendar.fixture.invalid")!
        var binding=CalendlyRelayBinding(publicURL:url.absoluteString,clientID:clientID,instanceID:instance,cursor:0);try binding.save(db:db)
        let key=CalendlyRelayTests.key,auth=CalendlyRelayTests.authKey
        func body(_ id:String,size:Int)throws->Data {
            var object:[String:Any]=["event":"invitee.created","payload":["uri":id,"name":"検証 予約","email":"client@external.invalid","scheduled_event":["name":"面談","start_time":"2027-01-15T10:00:00Z"]],"padding":""]
            let base=try JSONSerialization.data(withJSONObject:object).count;object["padding"]=String(repeating:"x",count:max(0,size-base));return try JSONSerialization.data(withJSONObject:object)
        }
        func event(_ raw:Data,seq:Int64)->[String:Any]{["seq":seq,"body":raw.base64EncodedString(),"bodySHA256":SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined(),"signature":"original receiver checked signature","receivedAt":"2027-01-15T10:00:00Z"]}
        func envelope(_ events:[[String:Any]],cursor:Int64)->[String:Any]{["version":1,"instanceId":instance,"clientId":clientID,"head":cursor,"events":events,"cursor":cursor,"hasMore":false]}
        func signed(_ request:URLRequest,raw:Data)throws->NativeCalendarResponse {
            let nonce=request.value(forHTTPHeaderField:"X-NextCRM-Nonce")!
            var h=HMAC<SHA256>(key:SymmetricKey(data:key));h.update(data:Data(("nextcrm-calendar-v1-response\n"+nonce+"\n200\n").utf8));h.update(data:raw)
            return try .init(data:raw,response:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["X-NextCRM-Signature":Data(h.finalize()).base64EncodedString()])!,temporaryRoot:root)
        }
        for size in [1_048_575,1_048_576,1_048_577,2_097_153] {
            let raw=try body("large-\(size)",size:size),seq=binding.cursor+1
            try check(raw.count==size,"exact large event byte size")
            let client=try CalendlyRelayClient(baseURL:url,authKey:auth,clientID:clientID,expectedInstanceID:instance,fileRequest:{request in try signed(request,raw:JSONSerialization.data(withJSONObject:envelope([event(raw,seq:seq)],cursor:seq)))})
            let sync=try CalendlyRelaySync(service:service,client:client,binding:binding);let changed=try await sync.run()
            try check(changed==1,"large signed event imported")
            let saved=try db.page("crm_CalendarEvents",fields:["rawPayload"],equal:["externalId":.text("large-\(size)")]).rows[0]
            let actual=try JSONSerialization.jsonObject(with:Data(saved["rawPayload"].string.utf8)) as! NSDictionary,expected=try JSONSerialization.jsonObject(with:raw) as! NSDictionary
            try check(actual==expected,"all source raw fields preserved")
            let padding=actual["padding"] as! String;comparisons.append(["id":"large-\(size)","bytes":size,"paddingBytes":padding.utf8.count,"paddingSHA256":SHA256.hash(data:Data(padding.utf8)).map{String(format:"%02x",$0)}.joined()])
            binding=try CalendlyRelayBinding.load(db:db)!;try check(binding.cursor==seq,"cursor commits with body")
        }
        for size in [2_097_151,2_097_152,2_097_153] {
            var object=envelope([],cursor:binding.cursor);object["padding"]="";let base=try JSONSerialization.data(withJSONObject:object).count;object["padding"]=String(repeating:"p",count:size-base)
            let data=try JSONSerialization.data(withJSONObject:object);try check(data.count==size,"exact relay page boundary")
            let client=try CalendlyRelayClient(baseURL:url,authKey:auth,clientID:clientID,expectedInstanceID:instance,fileRequest:{try signed($0,raw:data)})
            let page=try await client.eventBatch(after:binding.cursor);var count=0;try page.forEach{_ in count += 1};try check(count==0 && page.state.cursor==binding.cursor,"oversize page metadata does not lose cursor")
        }
        do {
            let raw=try body("duplicate-last",size:500),seq=binding.cursor+1,encoded=String(decoding:try JSONSerialization.data(withJSONObject:envelope([event(raw,seq:seq)],cursor:seq)),as:UTF8.self)
            let wire="{\"events\":[0],"+encoded.dropFirst()
            let client=try CalendlyRelayClient(baseURL:url,authKey:auth,clientID:clientID,expectedInstanceID:instance,fileRequest:{try signed($0,raw:Data(wire.utf8))})
            let sync=try CalendlyRelaySync(service:service,client:client,binding:binding);try check(try await sync.run()==1,"only last duplicate events array consumed")
            binding=try CalendlyRelayBinding.load(db:db)!
        }
        for kind in ["late-digest","late-normalizer","revoked","cancelled"] {
            let before=binding,first=try body("abandoned-\(kind)",size:1_048_577),second=try body("bad-\(kind)",size:600)
            var bad=event(second,seq:before.cursor+2)
            if kind=="late-digest"{bad["bodySHA256"]=String(repeating:"0",count:64)}
            if kind=="late-normalizer"{let broken=Data("{\"event\":\"invitee.created\",\"payload\":{\"uri\":\"bad-date\",\"scheduled_event\":{\"start_time\":\"not-a-date\"}}}".utf8);bad=event(broken,seq:before.cursor+2)}
            let wire=try JSONSerialization.data(withJSONObject:envelope([event(first,seq:before.cursor+1),bad],cursor:before.cursor+2))
            let client=try CalendlyRelayClient(baseURL:url,authKey:auth,clientID:clientID,expectedInstanceID:instance,fileRequest:{request in
                let result=try signed(request,raw:wire)
                if kind=="revoked"{let actor=try db.get("Users",key:["id":.text(service.identity.id)])!;_ = try db.update(actor,changes:["banned":.integer(1)],actor:"test")}
                if kind=="cancelled"{withUnsafeCurrentTask{$0?.cancel()}}
                return result
            })
            let sync=try CalendlyRelaySync(service:service,client:client,binding:binding)
            let rejected=await Task.detached{do{_ = try await sync.run();return false}catch{return true}}.value
            try check(rejected,"reject invalidated large page")
            try check(try CalendlyRelayBinding.load(db:db)==before && db.page("crm_CalendarEvents",fields:["id"],equal:["externalId":.text("abandoned-\(kind)")]).total==0,"failed page effects and cursor rollback together")
            if kind=="revoked"{let actor=try db.get("Users",key:["id":.text(service.identity.id)])!;_ = try db.update(actor,changes:["banned":.integer(0)],actor:"test")}
        }
        // Existing finite authentication checks, no loopback/real provider call.
        try await CalendlyRelayTests.transportGuards()
        do {
            let local=try NativeDatabase(url:root.appendingPathComponent("local/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let owner=CRMService(db:local,identity:try CRMService.bootstrap(local,resources:resources.appendingPathComponent("../../prisma")))
            let harness=try CalendlyRelayTests.Harness(resources:resources,root:root.appendingPathComponent("server"),script:resources.appendingPathComponent("calendar-payload-harness.cjs"));defer{harness.stop()}
            let live=try CalendlyRelayClient(baseURL:harness.url,authKey:auth,clientID:CalendlyRelayBinding.clientID(db:local),allowLoopbackHTTP:true)
            let binding=try await CalendlyRelayBinding.connect(service:owner,client:live),pinned=try live.expecting(binding.instanceID)
            _ = try await pinned.configure(signingKey:"native-calendly-fixture-key",expectedGeneration:nil)
            _ = try harness.command(["action":"seed","count":2,"bytes":2_097_153])
            let sync=try CalendlyRelaySync(service:owner,client:pinned,binding:binding);let changed=try await sync.run()
            try check(changed==2 && (try CalendlyRelayBinding.load(db:local))?.cursor==2,"actual loopback oversized pages use file network and commit")
            let identities=try local.page("crm_CalendarEvents",fields:["id"]).rows
            for identity in identities {
                let row=try local.get("crm_CalendarEvents",key:["id":identity["id"]])!,object=try JSONSerialization.jsonObject(with:Data(row["rawPayload"].string.utf8)) as! [String:Any]
                try check((object["padding"] as? String)?.count ?? 0>2_000_000,"actual network payload complete")
            }
            let cancelRoot=root.appendingPathComponent("cancel-network")
            try FileManager.default.createDirectory(at:cancelRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let slow=URL(string:"http://127.0.0.1:\(harness.url.port!)/slow")!
            let task=Task.detached{try await NativeCalendarResponse.network(URLRequest(url:slow),temporaryRoot:cancelRoot)}
            var received=false
            for _ in 0..<1000 {
                let urls=FileManager.default.enumerator(at:cancelRoot,includingPropertiesForKeys:[.fileSizeKey])?.allObjects as? [URL] ?? []
                if urls.contains(where:{$0.lastPathComponent=="response" && ((try? $0.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>=65_536}){received=true;break}
                try await Task.sleep(nanoseconds:2_000_000)
            }
            task.cancel();var cancelled=false;do{_ = try await task.value}catch{cancelled=error is CancellationError || (error as? URLError)?.code == .cancelled}
            try check(received && cancelled,"active file download cancellation joined")
            let leftovers=FileManager.default.enumerator(at:cancelRoot,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
            try check(!leftovers.contains(where:{$0.lastPathComponent=="response" || UUID(uuidString:$0.lastPathComponent) != nil}),"cancelled network owned file recovered")
            harness.stop();try check(harness.process.terminationStatus==0,"owned relay process reaped")
        }
        try JSONSerialization.data(withJSONObject:["comparisons":comparisons,"checks":checks,"existingAuthenticationChecks":CalendlyRelayTests.checks,"externalNetworkCalls":0,"loopbackTransportTest":true,"normalData":false,"realKeychain":false],options:.sortedKeys).write(to:out.appendingPathComponent("calendly-result.json"))
        print("Calendly payload \(checks) + \(CalendlyRelayTests.checks) checks")
    }
}
