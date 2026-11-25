@testable import NextCRMR2Integrated
import Foundation
import SQLite3

@main enum HoldTests {
    typealias F=GoogleCalendarPushTests.Fixture
    static var checks=0
    static func check(_ value:Bool,_ name:String)throws {
        guard value else{throw NativeDBError.message("Hold FAIL: "+name)};checks += 1
    }
    static func reject(_ name:String,_ body:()throws->Void)throws {
        do {try body()}catch{checks += 1;return};throw NativeDBError.message("Hold failed to reject: "+name)
    }
    struct Old {
        let job:NativeJob,storage:NativeRestoredMailReviewSnapshot,scope:NativePersonalCalendarHold.Scope,marker:String
    }
    static func old(_ f:F,status:String="running",plan:Bool=true,mapping:Bool=false)throws->Old {
        let id=try f.enqueue(),claimed=try f.db.claimCalendarOutboundJob(now:f.now)!
        try check(claimed.id==id,"exact fixture claim")
        let prepared=try f.service.prepareGoogleCalendarPush(claimed,now:f.now)!
        var result=try f.db.job(id:id)!.result;result["requestOutcome"]="unknown"
        if !plan{result.removeValue(forKey:"plan")}
        try f.db.recordJobResult(claimed,result:result);_ = try f.db.markJobDeliveryStarted(claimed,now:f.now)
        if status != "running"{try f.sql("UPDATE native_outbox SET status='"+status+"' WHERE id='"+id+"'")}
        if mapping {_ = try addMapping(f,activity:f.activity,event:"mapped-old")}
        let job=try f.db.job(id:id)!,storage=try f.db.restoredMailReviewSnapshot(job)
        // A synthetic *attached* authority exercises the real DB fence without
        // claiming this focused test is a complete activation/OS IPC proof.
        let marker="{\"fixture\":\""+UUID().uuidString+"\",\"phase\":\"complete\"}"
        try f.db.setMetadata(NativeDatabase.restoredJobQuarantineMarkerKey,value:marker)
        let binding=String(repeating:"a",count:64),row=String(repeating:"b",count:64)
        try f.db.putRestoredJobQuarantine(id:id,bindingSHA256:binding,rowSHA256:row)
        try f.db.attachRestoredJobQuarantine(marker:marker,authorize:{try f.service.authenticated()})
        let scope=try NativePersonalCalendarHold.prepare(service:f.service,job:job,storage:storage,quarantineValue:binding+":"+row)
        if plan{try check(scope.remoteEventID==prepared.eventID,"old stable remote identity")}
        return .init(job:job,storage:storage,scope:scope,marker:marker)
    }
    static func addActivity(_ f:F)throws->NativeRecord {
        try f.db.insert("crm_Activities",values:["type":.text("meeting"),"title":.text("新しい予定"),
            "date":f.activity["date"],"status":.text("scheduled"),"createdBy":.text(f.service.identity.id)],actor:f.service.identity.id)
    }
    @discardableResult static func addMapping(_ f:F,activity:NativeRecord,event:String)throws->NativeRecord {
        try f.db.insert("crm_CalendarEvents",values:["source":.text("google"),"externalId":.text(event),
            "activityId":activity["id"],"connectionId":f.connection["id"],"startAt":f.activity["date"],
            "status":.text("scheduled"),"attendeeEmails":.text("[]")],actor:f.service.identity.id)
    }
    static func record(_ f:F,_ old:Old)throws {
        try NativePersonalCalendarHold.record(service:f.service,job:old.job,storage:old.storage,scope:old.scope,authorize:{try f.service.authenticated()})
    }
    static func unchanged(_ f:F,_ old:Old)throws {
        try check(try f.db.restoredMailReviewSnapshot(old.job).digestMaterial==old.storage.digestMaterial,"all old outbox storage bytes unchanged")
    }
    static func main()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1])
        do {
            let f=try F(resources),server=GoogleCalendarPushTests.Server()
            try f.db.setMetadata(NativePersonalCalendarHold.lookupPrefix+"malformed",value:"bad")
            let id=try f.enqueue();try check(try await f.worker(server).runNext(),"ordinary worker progresses")
            try check(server.inserts==1 && (try f.db.job(id:id)?.status)=="done","ordinary no-marker is no-op")
        }
        do {
            let f=try F(resources),o=try old(f),key=NativePersonalCalendarHold.receiptPrefix+o.job.id
            try check(try f.db.metadata(key)==nil,"prepare zero writes")
            try reject("outer rollback"){try f.db.transaction{try record(f,o);throw NativeDBError.conflict}}
            try check(try f.db.metadata(key)==nil,"receipt rolls back")
            try check(try f.db.metadata(NativePersonalCalendarHold.lookupPrefix+o.job.id+".remote")==nil,"lookup rolls back")
            try record(f,o);try record(f,o)
            try check(try NativePersonalCalendarHold.validate(service:f.service,job:o.job,storage:o.storage,scope:o.scope),"stored scope validates idempotently")
            try unchanged(f,o)
            let same=try f.enqueue(),other=try addActivity(f),newID=try f.enqueue(activityID:other["id"].string)
            let server=GoogleCalendarPushTests.Server()
            try check(try await f.worker(server).runNext(),"unrelated new job progresses")
            try check(server.inserts==1 && (try f.db.job(id:newID)?.status)=="done","unrelated outbound sent once")
            try check(try f.db.job(id:same)?.status=="pending","same activity remains queued")
            try check(try f.db.nextCalendarOutboundJobDate(now:f.now)==nil,"blocked rows do not spin next-date")
            try check(!(try await f.worker(server).runNext()),"held claim yields no work")
            try unchanged(f,o)
            let db=try NativeDatabase(url:f.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            try reject("cold un-attached fence"){_ = try db.claimCalendarOutboundJob(now:f.now)}
            let service=CRMService(db:db,identity:f.service.identity)
            try db.attachRestoredJobQuarantine(marker:o.marker,authorize:{try service.authenticated()})
            try check(try NativePersonalCalendarHold.validate(service:service,job:o.job,storage:o.storage,scope:o.scope),"reopen validates durable receipt")
            try check(try db.claimCalendarOutboundJob(now:f.now)==nil,"reopen preserves hold")
        }
        do {
            let f=try F(resources)
            let user=try f.db.get("Users",key:["id":.text(f.service.identity.id)])!
            _ = try f.db.update(user,changes:["email":.text("rep@example.invalid")],actor:f.service.identity.id)
            let o=try old(f,status:"failed")
            let imported=try NativeCalendarImporter(db:f.db).apply(.init(source:.google,externalID:o.scope.remoteEventID!,
                connectionID:f.connection["id"].string,title:"同期から取り込まれた予定",startAt:try NativeCalendarEvents.date(f.activity["date"].string),
                counterpartyEmails:["client@external.invalid"],hostEmail:"rep@example.invalid"),authorizedBy:f.service.identity)
            guard let aliasID=imported.activityID,let alias=try f.db.get("crm_Activities",key:["id":.text(aliasID)]) else{throw NativeDBError.conflict}
            try check(imported.action=="created" && aliasID != f.activity["id"].string,"actual inbound importer creates another activity")
            try check(alias["createdBy"] == .text(f.service.identity.id),"alias has a legitimate outbound owner")
            // The actual inbound consumer created a second activity/mapping.
            try record(f,o)
            let id=try f.enqueue(activityID:alias["id"].string),server=GoogleCalendarPushTests.Server()
            try check(!(try await f.worker(server).runNext()),"remote alias excluded from claim")
            try check(server.calls.isEmpty && (try f.db.job(id:id)?.status)=="pending","alias causes zero provider requests")
            try reject("remote alias HTTP fence"){try f.db.requirePersonalCalendarOutboundAllowed(activityID:alias["id"].string,connectionID:f.connection["id"].string,accountEmail:"REP@example.invalid",eventID:o.scope.remoteEventID!)}
            try unchanged(f,o)
        }
        do {
            let f=try F(resources),o=try old(f,status:"failed"),server=GoogleCalendarPushTests.Server()
            let newID=try f.enqueue()
            server.beforeGET={try record(f,o)}
            try check(try await f.worker(server).runNext(),"in-flight operation is joined")
            try check(server.calls==["GET"] && server.inserts==0 && server.updates==0 && server.deletes==0,"hold published during GET prevents every mutation")
            try check(try f.db.job(id:newID)?.status=="needs_review","new blocked work remains honest")
            try unchanged(f,o)
        }
        for mapping in [true,false] {
            let f=try F(resources),o=try old(f,plan:false,mapping:mapping)
            try check(o.scope.kind == (mapping ? .connection:.allOutbound),"incomplete evidence selects conservative scope")
            try check(o.scope.explanation.contains(mapping ? "このGoogle接続":"すべて保留"),"scope disclosed in Japanese")
            try record(f,o)
            let other=try addActivity(f);_ = try f.enqueue(activityID:other["id"].string)
            try check(try f.db.claimCalendarOutboundJob(now:f.now)==nil,"fallback blocks new outbound scope")
            let sync=try f.service.requestGoogleCalendarSync(f.connection,now:f.now);var requests=0
            let worker=GoogleCalendarSyncWorker(db:f.db,store:f.store,request:{request in
                requests += 1
                return (Data("{\"items\":[],\"nextSyncToken\":\"fixture-next\"}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            },clock:{f.now})
            try check(try await worker.runNext(),"read sync remains admitted")
            try check(requests==1 && (try f.db.job(id:sync)?.status)=="done","read sync completed without event writes")
            try unchanged(f,o)
        }
        do {
            let f=try F(resources),o=try old(f)
            _ = try f.db.update(f.connection,changes:["accountEmail":.text("changed@example.invalid")],actor:f.service.identity.id)
            try reject("changed source references"){try record(f,o)}
            try check(try f.db.metadata(NativePersonalCalendarHold.receiptPrefix+o.job.id)==nil,"failed CAS publishes nothing")
            try unchanged(f,o)
        }
        do {
            let f=try F(resources),o=try old(f);var calls=0
            try reject("late authority loss rolls back"){try NativePersonalCalendarHold.record(service:f.service,job:o.job,storage:o.storage,scope:o.scope,authorize:{
                calls += 1;if calls==2{throw NativeDBError.conflict}
            })}
            try check(calls==2,"authority checked on both sides of publication")
            try check(try f.db.metadata(NativePersonalCalendarHold.receiptPrefix+o.job.id)==nil,"authority failure leaves no receipt")
            try check(try f.db.metadata(NativePersonalCalendarHold.lookupPrefix+o.job.id+".activity")==nil,"authority failure leaves no lookup")
            try unchanged(f,o)
            try f.db.setMetadata(NativeDatabase.restoredJobQuarantineMarkerKey,value:"different-root-marker")
            try reject("root marker changed"){try record(f,o)}
            try unchanged(f,o)
        }
        print("{\"checks\":\(checks),\"scope\":\"actual SQLite/fake Google; synthetic attached quarantine authority\",\"externalNetwork\":false}")
    }
}
