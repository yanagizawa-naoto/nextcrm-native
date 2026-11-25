import Foundation

private final class WorkerDrainMailReceiver:NativeMailReceiving {
    let syncGate:RuntimeDrainGate,bodyGate:RuntimeDrainGate
    init(sync:RuntimeDrainGate,body:RuntimeDrainGate){syncGate=sync;bodyGate=body}
    func status(mailbox:String)async throws->(validity:UInt32,next:UInt32){await syncGate.hold();return(77,1)}
    func discover(mailbox:String,validity:UInt32,after:UInt32,through:UInt32,since:Date?)async throws->NativeMailUIDSpool {throw NativeDBError.message("unexpected discover after cancelled status")}
    func headers(mailbox:String,validity:UInt32,uids:[UInt32])async throws->[NativeMailIMAPHeader]{throw NativeDBError.conflict}
    func body(mailbox:String,validity:UInt32,uid:UInt32)async throws->NativeMailBody? {await bodyGate.hold();return .init(text:"late body")}
}

@MainActor enum NativeRuntimeWorkerDrainTests {
    static func run(_ resources:URL)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRMRuntimeWorkerDrain-"+UUID().uuidString.lowercased())
        defer{try? FileManager.default.removeItem(at:root)}
        func fixture(_ name:String)throws->(NativeDatabase,CRMService,RuntimeDrainSecrets){
            let db=try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            return(db,CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))),RuntimeDrainSecrets())
        }
        let check=NativeRuntimeDrainTests.check
        func response(_ request:URLRequest,_ body:[String:Any],_ status:Int=200)throws->(Data,HTTPURLResponse){(try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)}
        do {
            let(db,service,secrets)=try fixture("mail"),sync=RuntimeDrainGate(),body=RuntimeDrainGate(),send=RuntimeDrainGate()
            defer{sync.release();body.release();send.release()}
            let settings=NativeMailAccountSettings(label:"停止検証",username:"owner@example.invalid",imap:.init(host:"imap.example.invalid",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.invalid",port:587,tls:.startTLS),sentFolder:"Sent")
            let account=try service.createMailAccount(settings,password:"synthetic-only",store:secrets)
            let header=NativeMailIMAPHeader(uid:1,seen:false,headers:try NativeMailMIME.headers(Data("Message-ID: <drain@example.invalid>\r\nSubject: 停止検証\r\nFrom: other@example.invalid\r\nTo: owner@example.invalid\r\n\r\n".utf8)))
            let emailID=try service.importMailHeaders(account:account,folder:.inbox,uidValidity:77,headers:[header])[0]
            let bodyID=try service.requestMailBody(service.mailMessage(emailID))!,syncID=try service.requestMailSync(account)
            let draft=NativeMailDraft(to:["other@example.invalid"],subject:"停止検証",body:"合成データ")
            let sendID=try service.queueMailSend(account:account,draft:draft),pendingID=try service.queueMailSend(account:account,draft:draft)
            let receiver=WorkerDrainMailReceiver(sync:sync,body:body)
            let runtime=NativeMailRuntime(db:db,store:secrets,makeClient:{_,_ in receiver},send:{_ in await send.hold()},recoverTemporary:{});defer{runtime.stop()}
            runtime.resume();try await NativeRuntimeDrainTests.until("actual mail workers waiting"){sync.hasEntered && body.hasEntered && send.hasEntered}
            var done=false;let draining=Task{@MainActor in await runtime.stopAndDrain();done=true};try await NativeRuntimeDrainTests.settle()
            try check(!done && runtime.isRunning,"actual mail drain covers sync/content/SMTP")
            sync.release();body.release();try await NativeRuntimeDrainTests.settle();try check(!done,"actual SMTP keeps drain pending after other workers finish")
            send.release();await draining.value
            try check(try db.job(id:syncID)?.status=="retry" && db.job(id:bodyID)?.status=="retry","cancelled actual mail reads retain retryable jobs")
            try check(try db.job(id:sendID)?.status=="done" && db.job(id:sendID)?.result["smtpAccepted"]=="true","late actual SMTP acceptance and local sent receipt complete before drain")
            try check(try db.job(id:pendingID)?.status=="pending" && service.mailMessage(emailID)["bodyText"] == .null,"actual stopped mail neither sends next message nor publishes cancelled read")
            let before=try db.job(id:sendID);try await NativeRuntimeDrainTests.settle();try check(try db.job(id:sendID)==before && !runtime.isRunning,"actual SMTP state stable after drain")
        }
        do {
            let(db,service,secrets)=try fixture("google"),inbound=RuntimeDrainGate(),outbound=RuntimeDrainGate(),now=Date()
            defer{inbound.release();outbound.release()}
            try service.saveGoogleCalendarClient(clientID:"drain.apps.googleusercontent.com",clientSecret:"synthetic-client",store:secrets)
            let ticket=try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:secrets)
            let connection=try service.completeGoogleCalendarAuthorization(ticket,grant:.init(accountEmail:"owner@example.invalid",accessToken:"synthetic-access",refreshToken:"synthetic-refresh",expiresAt:now.addingTimeInterval(3600),grantedScopes:GoogleCalendarScope.readwrite.requested),store:secrets)
            let syncID=try service.requestGoogleCalendarSync(connection)
            let activity=try db.insert("crm_Activities",values:["type":.text("meeting"),"title":.text("停止検証"),"date":.text(try NativeCalendarEvents.stamp(now.addingTimeInterval(86400))),"status":.text("scheduled"),"createdBy":.text(service.identity.id),"duration":.integer(30)],actor:service.identity.id)
            let pushID=try db.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":activity["id"].string,"operation":"upsert"])
            let runtime=GoogleCalendarRuntime(db:db,store:secrets,request:{request in
                if request.httpMethod=="POST" {await outbound.hold();throw CancellationError()}
                if request.url!.lastPathComponent=="events" {await inbound.hold();return try response(request,["items":[],"nextSyncToken":"late-cursor"])}
                return try response(request,["error":[:]],404)
            });defer{runtime.stop()}
            runtime.resume();try await NativeRuntimeDrainTests.until("actual Google inbound and push waiting"){inbound.hasEntered && outbound.hasEntered}
            var done=false;let draining=Task{@MainActor in await runtime.stopAndDrain();done=true};try await NativeRuntimeDrainTests.settle()
            try check(!done && runtime.isRunning,"actual Google drain includes outbound mutation")
            inbound.release();try await NativeRuntimeDrainTests.settle();try check(!done,"actual Google push blocks drain after inbound cancellation")
            outbound.release();await draining.value
            try check(try db.job(id:syncID)?.status=="retry" && service.googleCalendarConnection(connection["id"].string)["syncToken"] == .null,"cancelled Google read preserves previous cursor")
            try check(try db.job(id:pushID)?.status=="retry" && db.job(id:pushID)?.result["requestOutcome"]=="unknown" && db.job(id:pushID)?.result["plan"] != nil,"unknown Google mutation intent preserved for reconciliation")
            try check(try db.calendarOutboundMapping(activityID:activity["id"].string)==nil && !runtime.isRunning,"unknown Google push not invented as successful mapping")
        }
        for subscription in [false,true] {
            let(db,service,secrets)=try fixture(subscription ? "calendly-create":"calendly-sync"),gate=RuntimeDrainGate()
            defer{gate.release()}
            let clientID=try CalendlyRelayBinding.clientID(db:db),instanceID=UUID().uuidString.lowercased(),credentialID=UUID().uuidString.lowercased(),operationID=UUID().uuidString.lowercased()
            let publicURL="https://relay.example.invalid",callback=publicURL+"/api/crm/calendar/webhooks/calendly?subscription="+operationID
            let binding=CalendlyRelayBinding(publicURL:publicURL,clientID:clientID,instanceID:instanceID,cursor:23);try binding.save(db:db)
            let auth=Data(repeating:7,count:32).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            let secret=CalendlyCredentials(publicURL:publicURL,clientID:clientID,instanceID:instanceID,authKey:auth,apiToken:"synthetic-api",signingKey:"synthetic-signing")
            try secrets.save(id:credentialID,data:JSONEncoder().encode(secret))
            let before=try CalendlyControlState.load(db);var state=before;state.credentialID=credentialID
            if subscription {state.operation = .init(id:operationID,mode:.subscribe,callbackURL:callback,actorID:service.identity.id,credentialID:credentialID,phase:.creating,organization:"https://api.calendly.com/organizations/fixture",receiverGeneration:nil)}
            else {state.registration = .init(uri:"https://api.calendly.com/webhook_subscriptions/fixture",organization:"https://api.calendly.com/organizations/fixture",callbackURL:callback,credentialID:credentialID,actorID:service.identity.id)}
            try state.save(db,expected:before)
            let jobID=try service.requestCalendlyJob(subscription ? CalendlyJobs.subscription:CalendlyJobs.sync)
            let runtime=CalendlyRuntime(db:db,store:secrets,apiRequest:{_ in await gate.hold();throw CancellationError()},relayRequest:{_ in await gate.hold();throw CancellationError()});defer{runtime.stop()}
            runtime.resume(forceSync:false);try await NativeRuntimeDrainTests.until("actual Calendly request waiting"){gate.hasEntered}
            var done=false;let draining=Task{@MainActor in await runtime.stopAndDrain();done=true};try await NativeRuntimeDrainTests.settle()
            try check(!done && runtime.isRunning,"actual Calendly \(subscription ? "registration":"relay") request awaited")
            gate.release();await draining.value
            try check(try db.job(id:jobID)?.status=="retry" && CalendlyRelayBinding.load(db:db)?.cursor==23,"Calendly cancellation preserves queue and relay cursor")
            let current=try CalendlyControlState.load(db)
            try check(current.credentialID==credentialID && (subscription ? current.operation?.phase == .creating : current.registration==state.registration),"Calendly unknown registration/credential identity preserved")
            let snapshot=try db.job(id:jobID);runtime.resume(forceSync:true);NotificationCenter.default.post(name:InvoiceJobRunner.didProcess,object:nil,userInfo:["database":db.url.path]);try await NativeRuntimeDrainTests.settle()
            try check(try db.job(id:jobID)==snapshot && !runtime.isScanning && !runtime.isRunning,"Calendly stopped callback cannot force a retry")
        }
    }
}
