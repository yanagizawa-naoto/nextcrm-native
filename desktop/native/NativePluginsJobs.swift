import Foundation

extension NativePluginHost {
    static let jobEvents=["plugin/installed","plugin/after","plugin/event","plugin/event-dispatch","plugin/cron"]
    func runJob(_ job:NativeJob) async throws -> [String:String] {
        if job.event=="plugin/event" {
            let event=job.payload["event"] ?? "",data=try NativePluginJSON.record(job.payload["data"] ?? "{}")
            try db.transaction {
                try NativePluginExecutionScope.check("__native-plugin-dispatch")
                for definition in try enabled() where data["source"] as? String != definition.id && definition.events.contains(where:{$0.event==event}) {
                    try db.enqueue("plugin/event-dispatch",payload:["pluginId":definition.id,"event":event,"data":try NativePluginJSON.text(data)],now:clock())
                }
            }
            return ["status":"completed"]
        }
        guard let id=job.payload["pluginId"],let definition=definition(id),try state(id)?["status"] == .text("ENABLED") else { return ["status":"skipped"] }
        if job.event=="plugin/installed" {
            guard let hook=definition.onInstall else { return ["status":"completed"] }
            do { try await run(definition,logFailure:false,hook);return ["status":"completed"] }
            catch {
                try NativePluginExecutionScope.check(id)
                log(id,"error","onInstall failed")
                try db.transaction { try NativePluginExecutionScope.check(id);if let state=try state(id) { try db.update(state,changes:["status":.text("DISABLED")],actor:"system");NativePluginData(db:db,pluginId:id,permissions:[]).audit(entity:"plugin",id:id,action:"disabled",changes:nil) } }
                return ["status":"failed"]
            }
        }
        if job.event=="plugin/after" {
            let input=try JSONDecoder().decode(NativePluginAfterInput.self,from:Data((job.payload["input"] ?? "{}").utf8))
            try await run(definition) { context in for hook in definition.afters where hook.entity==input.entity && hook.operation==input.operation { try await hook.handler(input,context) } }
        } else if job.event=="plugin/event-dispatch" {
            let data=try NativePluginJSON.record(job.payload["data"] ?? "{}")
            guard data["source"] as? String != id else { return ["status":"skipped"] }
            try await run(definition) { ctx in for handler in definition.events where handler.event==job.payload["event"] { try await handler.handler(data,ctx) } }
        } else if job.event=="plugin/cron",let cron=definition.crons.first(where:{$0.id==job.payload["cronId"]}) { try await run(definition,cron.handler) }
        return ["status":"completed"]
    }
    private func run(_ definition:NativePluginDefinition,logFailure:Bool=true,_ handler:(NativePluginContext) async throws -> Void) async throws {
        guard try state(definition.id)?["status"] == .text("ENABLED") else { return }
        let context=try context(definition,actor:.plugin(definition.id))
        do { try await NativePluginActorScope.withActor(.plugin(definition.id)) { try await handler(context) } }
        catch { if logFailure { context.log("error","Plugin job failed: "+error.localizedDescription) };throw error }
    }
    func enqueueDueCrons(_ now:Date) throws {
        let minute=Int64(floor(now.timeIntervalSince1970/60)),store=NativePluginStore(db:db,pluginId:"__native-plugin-host",clock:clock)
        for definition in try enabled() {
            for cron in definition.crons where NativePluginCronSchedule.matches(cron.schedule,at:now) {
                try db.transaction {
                    let key="cron:"+definition.id+":"+cron.id
                    if let last=try store.get(key) as? NSNumber,last.int64Value>=minute { return }
                    try db.enqueue("plugin/cron",payload:["pluginId":definition.id,"cronId":cron.id],now:now);try store.set(key,minute)
                }
            }
        }
        if NativePluginCronSchedule.matches("30 3 * * *",at:now) {
            let cutoff=NativePluginJSON.stamp(now.addingTimeInterval(-30*86_400))
            while true { let rows=try db.page("PluginLog",fields:[],filter:.beforeDate("createdAt",cutoff)).rows;if rows.isEmpty { break };for row in rows { try db.remove(row,actor:"system") } }
        }
    }
}

enum NativePluginCronSchedule {
    static func matches(_ schedule:String,at date:Date)->Bool {
        let fields=schedule.split(separator:" ").map(String.init);guard fields.count==5 else { return false }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let values=[calendar.component(.minute,from:date),calendar.component(.hour,from:date),calendar.component(.day,from:date),calendar.component(.month,from:date),calendar.component(.weekday,from:date)-1]
        let ranges=[0...59,0...23,1...31,1...12,0...7]
        func match(_ text:String,_ value:Int,_ bounds:ClosedRange<Int>)->Bool {
            text.split(separator:",").contains { term in
                let pieces=term.split(separator:"/"),step=pieces.count==2 ? Int(pieces[1]) ?? 0:1;guard step>0 else { return false }
                let interval=pieces[0].split(separator:"-");let low:Int,high:Int
                if pieces[0]=="*" { low=bounds.lowerBound;high=bounds.upperBound }
                else if interval.count==2,let a=Int(interval[0]),let b=Int(interval[1]) { low=a;high=b }
                else if let a=Int(pieces[0]) { low=a;high=pieces.count==2 ? bounds.upperBound:a }
                else { return false }
                return bounds.contains(low) && bounds.contains(high) && value>=low && value<=high && (value-low)%step==0
            }
        }
        let tests=zip(fields.indices,values).map { match(fields[$0.0],$0.1,ranges[$0.0]) || ($0.0==4 && $0.1==0 && match(fields[4],7,ranges[4])) }
        let dayMatches=fields[2] != "*" && fields[4] != "*" ? tests[2] || tests[4]:tests[2] && tests[4]
        return tests[0] && tests[1] && tests[3] && dayMatches
    }
}
