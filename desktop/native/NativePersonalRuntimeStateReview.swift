import Foundation

extension NativePersonalRuntimePrerequisites {
    func effectEvents(_ r:Requirement)->(events:[String],prefixes:[String]) {
        switch r {
        case .imapSMTPAccountsAndCursors:return (["native.mail.send"],[])
        case .resendSender:return (["invoice.email_requested","crm.automation.kill.notice","crm.automation.recycle.notice","crm.lead_assigned"],["orders.","projects.","crm.task_","crm.account_"])
        case .reportSchedules:return (["reports.scheduled"],[])
        case .campaignSchedules,.campaignRelay:return (["native.campaign-relay.sync"],["campaigns/"])
        case .googleConnectionsAndCursors:return (["calendar/outbound"],[])
        case .calendlySubscriptionsAndRelay:return ([],["calendly/","native.calendly"])
        case .allEnabledPluginsAndSchedules:return ([],["plugin/","plugins/"])
        default:return ([],[])
        }
    }
    func relates(_ event:String,to r:Requirement)->Bool {let scope=effectEvents(r);return scope.events.contains(event) || scope.prefixes.contains(where:event.hasPrefix)}
    func hasAmbiguous(_ r:Requirement)throws->Bool {
        if r == .imapSMTPAccountsAndCursors {return try NativePersonalSMTPReview.hasAmbiguous(service:service,startup:startup,record:personal)}
        if r == .googleConnectionsAndCursors {
            var after=""
            while true {
                try Task.checkCancellation();let page=try db.personalPrerequisiteOldJobs(after:after)
                for row in page where row.event==GoogleCalendarOutbound.event && row.ambiguous {
                    if try !NativePersonalProviderReview.googleHeldAcknowledged(service:service,startup:startup,record:personal,jobID:row.id){return true}
                }
                if page.count<100{return false};after=page.last!.id
            }
        }
        let scope=effectEvents(r);return try db.personalPrerequisiteAmbiguous(events:scope.events,prefixes:scope.prefixes,excludingDisabledConnectors:r == .allEnabledPluginsAndSchedules)
    }
    func oldJobs(_ requirement:Requirement)throws->(count:Int64,ambiguous:Int64) {
        var after="",count:Int64=0,ambiguous:Int64=0
        while true {
            try Task.checkCancellation();let page=try db.personalPrerequisiteOldJobs(after:after)
            for row in page where relates(row.event,to:requirement){count += 1;if row.ambiguous{ambiguous += 1}}
            if page.count<100{return(count,ambiguous)};after=page.last!.id
        }
    }
    @discardableResult func archivePointer(_ key:String)throws->Int64 {
        guard let id=try db.metadata(key),!id.isEmpty,try db.personalPrerequisiteOldJob(id) else{return 0}
        return try db.personalPrerequisiteArchive(key:key,value:nil,generation:personal.authority.selection.generation) ? 1:0
    }
    @discardableResult func archiveCleanup(_ key:String)throws->Int64 {
        guard let raw=try db.metadata(key),!raw.isEmpty,raw != "{}" else{return 0}
        // These native maps contain UUID references and deadlines, never secret
        // values. Reject unexpected JSON rather than copying it into a receipt.
        guard let values=try? JSONDecoder().decode([String:Double].self,from:Data(raw.utf8)),values.allSatisfy({(UUID(uuidString:$0.key) != nil || (key==NativePluginCredentialVault.cleanupKey && NativePluginCredentialVault.valid($0.key))) && $0.value.isFinite}) else{throw NativeDBError.message("認証情報の整理予約を確認できません。この機能を停止したまま設定を確認してください。")}
        return try db.personalPrerequisiteArchive(key:key,value:"{}",generation:personal.authority.selection.generation) ? Int64(values.count):0
    }
    func apply(_ r:Requirement,choice:Choice)throws->Int64 {
        var archived:Int64=0
        switch r {
        case .imapSMTPAccountsAndCursors:
            try rows("EmailAccount",fields:["isActive","userId"]){row in
                guard row["isActive"] == .integer(1) else{return}
                let current=try service.mailAccount(row["id"].string)
                if choice == .pauseSources {_ = try db.update(current,changes:["isActive":.integer(0)],actor:service.identity.id,action:"restore_pause_mail")}
                else {archived += try archivePointer("mail.sync.job."+row["id"].string)}
            }
        case .googleConnectionsAndCursors:
            try rows("CalendarConnection",fields:["isActive","provider"],filter:.equal("provider",.text("google"))){row in
                guard row["isActive"] == .integer(1) else{return}
                let current=try service.googleCalendarConnection(row["id"].string)
                if choice == .pauseSources{_ = try db.update(current,changes:["isActive":.integer(0)],actor:service.identity.id,action:"restore_pause_calendar")}
                else{archived += try archivePointer("calendar.google.syncJob."+row["id"].string)}
            }
        case .reportSchedules:
            try rows("crm_Report_Schedule",fields:["isActive","createdBy"],filter:reportScope){row in
                guard row["isActive"] == .integer(1) else{return}
                // Existing domain access, audited CAS and generation publication.
                // The candidate DB cancellation helper excludes quarantined IDs.
                if choice == .futureOnly {
                    let schedules=NativeReportSchedules(service:service),current=try schedules.load(row["id"].string)
                    let configuration=try NativeReportConfigurations(service:service).load(current.record["reportConfigId"].string)
                    guard configuration.category != .users || service.identity.elevated else{throw NativeDBError.message("利用者レポートの定期送信には管理者またはマネージャーの権限が必要です。")}
                    _ = try configuration.filters.period();_ = try configuration.filters.currency
                    _ = try current.settings.next(after:clock())
                    let fresh=try db.update(current.record,changes:[:],actor:service.identity.id,action:"restore_rebind_future_report")
                    let generation=UUID().uuidString.lowercased()
                    try db.setMetadata("reportSchedule.timezone."+current.id,value:current.settings.timeZone.identifier)
                    try db.setMetadata("reportSchedule.generation."+current.id,value:generation)
                    try NativeReportQueue.replace(db:db,schedule:.init(record:fresh,settings:current.settings),generation:generation,now:clock())
                } else {
                    try service.authenticated()
                    guard let current=try db.get("crm_Report_Schedule",key:["id":row["id"]]),current.revision==row.revision,
                          service.identity.elevated || current["createdBy"] == .text(service.identity.id) else{throw NativeDBError.conflict}
                    _ = try db.update(current,changes:["isActive":.integer(0)],actor:service.identity.id,action:"restore_pause_report")
                }
            }
        case .campaignSchedules:
            try rows("crm_campaigns",fields:["status"],filter:.every([service.scope("crm_campaigns",write:true),.any([.equal("status",.text("scheduled")),.equal("status",.text("sending"))])])){row in
                _ = try service.pauseCampaign(service.campaign(row["id"].string))
            }
        case .campaignRelay:
            archived += try archivePointer(CampaignRelayJobs.pointer)
        case .allEnabledPluginsAndSchedules:
            archived += try archiveCleanup(NativePluginCredentialVault.cleanupKey)
            // Known read/sync requests are explicit restored source reservations,
            // not delivery evidence. Keep their exact non-secret row before
            // removing the request that the next cron would otherwise execute.
            try rows("PluginData",fields:["pluginId","entityType","entityId","key","value","updatedAt"],filter:.any([.equal("key",.text("job:sync")),.equal("key",.text("job:compare"))])){row in
                guard row["entityType"].string.isEmpty,row["entityId"].string.isEmpty,
                      ["odoo-connector","oxo-erp-connector"].contains(row["pluginId"].string),
                      let value=try NativePluginJSON.parse(row["value"].string) as? NativePluginRecord,
                      Set(value.keys)==["requestedAt"],let at=value["requestedAt"] as? String,(try? NativePluginJSON.date(at)) != nil else{throw NativeDBError.message("プラグインの旧実行予約を確認できません。処理状況を確認してください。")}
                let archive=Self.prefix+"plugin-state."+personal.authority.selection.generation+"."+row["id"].string
                let saved=Dictionary(uniqueKeysWithValues:["id","pluginId","entityType","entityId","key","value","updatedAt"].map{($0,row[$0].string)})
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                let encoded=String(decoding:try encoder.encode(saved),as:UTF8.self)
                if let old=try db.metadata(archive){guard old==encoded else{throw NativeDBError.conflict}}else{try db.setMetadata(archive,value:encoded)}
                try db.remove(row,actor:service.identity.id,action:"restore_hold_plugin_request");archived += 1
            }
            if choice == .pauseSources {
                try rows("InstalledPlugin",fields:["status"],filter:.equal("status",.text("ENABLED"))){row in
                    guard let current=try db.get("InstalledPlugin",key:["id":row["id"]]),current.revision==row.revision else{throw NativeDBError.conflict}
                    _ = try db.update(current,changes:["status":.text("DISABLED")],actor:service.identity.id,action:"restore_pause_plugin")
                }
            }
        case .crmAutomationSchedules:
            for (key,date) in [(NativeCRMRenewalJobs.cursorKey,NativeCRMRenewalJobs.nextScheduledDate(after:clock())),(NativeCRMSweepJobs.killScan+".next.v1",NativeCRMSweepJobs.nextScheduledDate(after:clock(),recycle:false)),(NativeCRMSweepJobs.recycleScan+".next.v1",NativeCRMSweepJobs.nextScheduledDate(after:clock(),recycle:true))] {
                let value=try NativeCRMAutomationDates.stamp(date)
                if try db.personalPrerequisiteArchive(key:key,value:value,generation:personal.authority.selection.generation){archived += 1}
                else{try db.setMetadata(key,value:value)}
            }
        case .credentialCleanupOwnership:
            var after=""
            while true {
                let page=try db.personalPrerequisiteAIKeys(after:after)
                for id in page {
                    guard UUID(uuidString:id) != nil else{throw NativeDBError.conflict}
                    let key=NativeUserCredentialCleanup.markerKey(.ai,id)
                    if try db.metadata(key)==nil{try db.setMetadata(key,value:String(decoding:JSONEncoder().encode(NativeUserCredentialCleanup.Hold(version:1,state:"reviewHeld",credentialID:id)),as:UTF8.self));archived += 1}
                }
                if page.count<100{break};after=page.last!
            }
        case .mcpCredentialsAndListener:
            archived += try archiveCleanup(NativeMCPSettingsStore.cleanupKey)
            if choice == .pauseSources {
                let store=NativeMCPSettingsStore(service:service,secretStore:stores.mcp,clock:clock),current=try store.snapshot()
                // disabled save does not load/delete/generate a signing key.
                _ = try store.save(expected:current,enabled:false,port:current.port,maximumConnections:current.maximumConnections)
            }
        case .ecbSettings:
            if choice == .pauseSources{let settings=NativeCurrencyAdministration(service:service);try settings.setECBEnabled(false,expected:settings.settings())}
        case .documentPendingWork:
            let files=try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent())
            try rows("Documents",fields:["key","size","content_hash","document_file_mimeType"],filter:service.scope("Documents")){row in
                let resolved=try NativeDocumentFiles.resolve(row,db:db)
                _ = try files.verifiedURL(key:resolved.fileKey,bytes:resolved.bytes,sha256:resolved.sha256)
            }
        case .aiOutstandingWork:
            try db.personalPrerequisiteValidateLocalWork()
        case .maintenanceOwnership:
            try requirePrivateRecoveryRoot()
        case .resendSender,.calendlySubscriptionsAndRelay,.openAI,.e2b:break
        }
        return archived
    }
}
