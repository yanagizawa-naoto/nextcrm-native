import Foundation

@main enum GooglePushPayloadTests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("Large calendar push: "+label)};checks += 1}
    static func main()async throws{
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
        for bytes in [1_048_575,1_048_576,1_048_577] {
            let f=try GoogleCalendarPushTests.Fixture(resources),server=GoogleCalendarPushTests.Server(),worker=f.worker(server)
            let first=try f.enqueue();_ = try await worker.runNext()
            try check(try f.db.job(id:first)?.status=="done","small create")
            let mapping=try f.mapping()!,eventID=mapping["externalId"].string
            var remote=server.events[eventID]!;remote["providerPayload"]=""
            let overhead=try JSONSerialization.data(withJSONObject:remote).count
            let padding=String(repeating:"x",count:bytes-overhead);remote["providerPayload"]=padding;server.events[eventID]=remote
            try check(try JSONSerialization.data(withJSONObject:remote).count==bytes,"exact GET boundary")
            _ = try f.db.update(f.current(),changes:["title":.text("更新した予定")],actor:f.service.identity.id)
            if bytes==1_048_577{try f.sql("CREATE TRIGGER large_push_mapping_failure BEFORE UPDATE ON crm_CalendarEvents BEGIN SELECT RAISE(ABORT,'injected mapping failure'); END")}
            let job=try f.enqueue();_ = try await worker.runNext()
            let saved=try f.db.job(id:job)!,confirmed=try JSONSerialization.jsonObject(with:Data(saved.result["remote"]?.utf8 ?? "".utf8)) as? [String:Any]
            try check(saved.result["requestOutcome"]=="confirmed" && confirmed?["providerPayload"] as? String==padding,"complete large mutation confirmation retained")
            try check(server.updates==1 && server.events[eventID]?["summary"] as? String=="更新した予定","large GET and PATCH succeed once")
            try check(try f.mapping()?["id"]==mapping["id"],"mapping identity retained")
            if bytes==1_048_577{
                try check(saved.status=="retry","local failure keeps confirmed result")
                try f.sql("DROP TRIGGER large_push_mapping_failure");let requests=server.calls.count;f.now=f.now.addingTimeInterval(6);_ = try await worker.runNext()
                try check(server.calls.count==requests && server.updates==1,"local recovery never repeats provider write")
            }
            try check(try f.db.job(id:job)?.status=="done","mapping commit succeeds")
        }
        let response=HTTPURLResponse(url:URL(string:"https://oauth2.googleapis.com/token")!,statusCode:200,httpVersion:nil,headerFields:nil)!
        let data=try JSONSerialization.data(withJSONObject:["padding":String(repeating:"x",count:1_048_577)])
        var refused=false;do{_ = try GoogleCalendarOAuth.json(data,response:response)}catch{refused=true}
        try check(refused,"OAuth control bound preserved")
        let result:[String:Any] = ["checks":checks,"fixtureChecks":GoogleCalendarPushTests.checks,"getReplyBytes":[1_048_575,1_048_576,1_048_577],"actualSQLite":true,"externalNetworkCalls":0]
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:output.appendingPathComponent("push-result.json"));print("large Google push \(checks) checks")
    }
}
