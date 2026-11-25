import Foundation
import CryptoKit

@main enum GooglePayloadTests {
    static func main()async {do{try await run()}catch{print("Calendar payload failed: \(error)");exit(1)}}
    static func run()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
        var checks=0,comparisons:[[String:Any]]=[]
        func check(_ value:Bool,_ message:String)throws{guard value else{throw NativeDBError.message(message)};checks += 1}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CalendarPayload-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:root)}
        let url=URL(string:"https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        func response(_ text:String,status:Int=200)throws->NativeCalendarResponse{try .init(data:Data(text.utf8),response:HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!,temporaryRoot:root)}
        for raw in ["{\"items\":[],\"nextSyncToken\":\"ok\"}","{\"items\":null,\"nextSyncToken\":\"ok\"}","{\"ignored\":{\"a\":[1,true,null,\"escaped\\\"}[]\"]},\"items\":[{\"id\":\"old\"}],\"items\":[{\"id\":\"new\"}],\"nextSyncToken\":\"ok\"}"] {
            let spool=try GoogleCalendarSpool(temporaryRoot:root),fields=try spool.appendPage(response(raw));var rows:[[String:Any]]=[]
            try spool.forEach{rows.append(try JSONSerialization.jsonObject(with:$0) as! [String:Any])}
            try check(fields["nextSyncToken"] as? String=="ok","envelope token")
            try check(rows.isEmpty || (rows.count==1 && rows[0]["id"] as? String=="new"),"duplicate key and unknown metadata semantics")
        }
        let malformed=["{\"items\":[{}],}","{\"items\":[{},]}","{\"items\":[{},1]}","{\"items\":[],\"extra\":{bad}}","{\"items\":[]}garbage","{\"items\":[],\"extra\":\"bad\n\"}","{\"items\":[],\"extra\":[1,,]}","{\"items\":{},\"nextSyncToken\":\"bad\"}"]
        for raw in malformed {
            let spool=try GoogleCalendarSpool(temporaryRoot:root);try spool.append([["id":"prior"]])
            var failed=false;do{_ = try spool.appendPage(response(raw))}catch{failed=true}
            var count=0;try spool.forEach{_ in count += 1};try check(failed && count==1,"malformed page rolls staging back: \(raw) failed=\(failed) count=\(count)")
        }
        do {
            let spool=try GoogleCalendarSpool(temporaryRoot:root);var failure:GoogleCalendarHTTPError?
            do{_ = try spool.appendPage(response("{\"error\":{\"message\":\"secret must not enter error\",\"errors\":[{\"reason\":\"rateLimitExceeded\"}]}}",status:403))}catch let e as GoogleCalendarHTTPError{failure=e}
            try check(failure?.retryable==true && failure?.revoked==false && failure?.reason=="ratelimitexceeded","provider status/reason retained without raw secret")
        }
        do {
            let spool=try GoogleCalendarSpool(temporaryRoot:root);var failure:GoogleCalendarHTTPError?
            do{_ = try spool.appendPage(response("<html>Unavailable</html>",status:503))}catch let e as GoogleCalendarHTTPError{failure=e}
            try check(failure?.status==503 && failure?.retryable==true,"non-JSON provider503 remains retryable")
        }
        for size in [1_048_575,1_048_576,1_048_577] {
            let f=try GoogleCalendarSyncTests.Fixture(resources);var value=GoogleCalendarSyncTests.event("size-\(size)");value["description"]=""
            let base=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).count;value["description"]=String(repeating:"x",count:size-base)
            let raw=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys);try check(raw.count==size,"event fixture exact boundary")
            let job=try f.enqueue(),worker=GoogleCalendarSyncWorker(db:f.db,store:f.store,pageRequest:{_ in
                try response("{\"items\":["+String(decoding:raw,as:UTF8.self)+"],\"nextSyncToken\":\"large\"}")
            },clock:{f.now});_ = try await worker.runNext()
            let saved=try f.db.page("crm_CalendarEvents",fields:["rawPayload"]).rows
            try check(saved.count==1 && (try f.db.job(id:job))?.status=="done","large event persisted via disk worker")
            let normalized=try JSONSerialization.jsonObject(with:Data(saved[0]["rawPayload"].string.utf8)) as! NSDictionary
            try check(normalized==value as NSDictionary,"all raw event values retained")
            let description=normalized["description"] as! String;comparisons.append(["id":"size-\(size)","bytes":size,"descriptionBytes":description.utf8.count,"descriptionSHA256":SHA256.hash(data:Data(description.utf8)).map{String(format:"%02x",$0)}.joined()])
        }
        do {
            let f=try GoogleCalendarSyncTests.Fixture(resources),job=try f.enqueue();let count=17,padding=String(repeating:"z",count:1_048_576)
            let worker=GoogleCalendarSyncWorker(db:f.db,store:f.store,pageRequest:{_ in
                let file=try NativeMailResponseFile(temporaryRoot:root)
                try file.withDescriptor{fd in
                    let h=FileHandle(fileDescriptor:fd,closeOnDealloc:false);try h.write(contentsOf:Data("{\"items\":[".utf8))
                    for i in 0..<count {try autoreleasepool {var event=GoogleCalendarSyncTests.event("page-\(i)");event["description"]=padding;if i>0{try h.write(contentsOf:Data(",".utf8))};try h.write(contentsOf:JSONSerialization.data(withJSONObject:event))}}
                    try h.write(contentsOf:Data("],\"nextSyncToken\":\"over16MiB\"}".utf8))
                }
                return .init(file:file,response:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
            },clock:{f.now});_ = try await worker.runNext()
            try check(try f.count()==17 && f.db.job(id:job)?.status=="done","17MiB page streamed into SQLite")
            try check(try f.current()["syncToken"] == .text("over16MiB"),"large page cursor published")
        }
        do {
            let f=try GoogleCalendarSyncTests.Fixture(resources),job=try f.enqueue()
            let worker=GoogleCalendarSyncWorker(db:f.db,store:f.store,pageRequest:{_ in
                _ = try f.db.update(try f.db.get("Users",key:["id":.text(f.service.identity.id)])!,changes:["banned":.integer(1)],actor:"test")
                return try response("{\"items\":[{}],\"nextSyncToken\":\"no\"}")
            },clock:{f.now});_ = try await worker.runNext()
            try check(try f.count()==0 && f.db.job(id:job)?.status != "done","fresh authority after disk download")
        }
        let result:[String:Any]=["comparisons":comparisons,"checks":checks,"normalData":false,"networkCalls":0,"realKeychain":false]
        try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:out.appendingPathComponent("google-result.json"));print("Google payload \(checks) checks")
    }
}
