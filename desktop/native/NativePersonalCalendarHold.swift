import Foundation
import CryptoKit

/// Continued hold, not an external result or permission to replay.
enum NativePersonalCalendarHold {
    static let receiptPrefix = "personal.restore.google-hold.v1.receipt."
    static let lookupPrefix = "personal.restore.google-hold.v1.lookup."
    enum Kind:String,Codable { case activityAndRemote, connection, allOutbound }
    struct Scope:Codable,Equatable {
        let version:Int,kind:Kind
        let jobID:String,ownerID:String,activityID:String
        let connectionID:String?,accountEmail:String?,remoteEventID:String?
        let markerSHA256:String,quarantineValue:String,storageSHA256:String,referencesSHA256:String
        var explanation:String {
            switch kind {
            case .activityAndRemote:return "結果不明の予定と同じGoogle予定への書込みを保留します。無関係な新しい予定と読取り同期は再開できます。"
            case .connection:return "予定の識別情報が不足しているため、このGoogle接続（\(accountEmail ?? connectionID ?? "確認中")）への書込みをすべて保留します。他の接続と読取り同期は利用できます。"
            case .allOutbound:return "接続の識別情報が不足しているため、Googleへの書込みをすべて保留します。読取り同期は利用できます。"
            }
        }
    }
    private struct Stored:Codable,Equatable {let version:Int,marker:String,scope:Scope}
    private struct Lookup:Codable,Equatable {
        let version:Int,marker:String,scopeSHA256:String,receiptKey:String,kind:String
        let activityID:String?,connectionID:String?,accountEmail:String?,remoteEventID:String?
    }
    private struct PlanIdentity:Decodable {
        let activityID:String,ownerID:String,connectionID:String,accountEmail:String,eventID:String
    }
    private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func encoded<T:Encodable>(_ value:T)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return String(decoding:try encoder.encode(value),as:UTF8.self)
    }
    private static func validID(_ value:String)->Bool {UUID(uuidString:value) != nil}
    private static func bounded(_ value:String)->Bool {!value.isEmpty && value.utf8.count<=4096 && !value.unicodeScalars.contains{$0.value<32 || $0.value==127}}
    private static func marker(_ service:CRMService,_ job:NativeJob,_ storage:NativeRestoredMailReviewSnapshot,_ quarantine:String)throws->String {
        try service.authenticated();try service.db.requireRestoredJobQuarantineFence()
        guard !service.db.isReadOnly,job.event==GoogleCalendarOutbound.event,
              ["running","needs_review","retry","failed"].contains(job.status),
              try service.googleCalendarPushJob(job.id)==job,
              try service.db.restoredMailReviewSnapshot(job).digestMaterial==storage.digestMaterial,
              quarantine.utf8.count==129,quarantine.utf8.allSatisfy({$0==58 || (48...57).contains($0) || (97...102).contains($0)}),
              try service.db.metadata(NativeDatabase.restoredJobQuarantinePrefix+job.id)==quarantine,
              let marker=try service.db.restoredJobQuarantineMarker() else{throw NativeDBError.conflict}
        return marker
    }
    static func prepare(service:CRMService,job:NativeJob,storage:NativeRestoredMailReviewSnapshot,quarantineValue:String)throws->Scope {
        try service.db.transaction {
            let marker=try marker(service,job,storage,quarantineValue)
            guard let activityID=job.payload["activity_id"],validID(activityID),
                  let activity=try service.db.get("crm_Activities",key:["id":.text(activityID)]) else{throw NativeDBError.conflict}
            let mappings=try service.db.page("crm_CalendarEvents",fields:["activityId","connectionId","externalId"],equal:["activityId":.text(activityID)],limit:2).rows
            guard mappings.count<=1 else{throw NativeDBError.conflict}
            let mapping=mappings.first
            let plan=job.result["plan"].flatMap{try? JSONDecoder().decode(PlanIdentity.self,from:Data($0.utf8))}
            let known=plan.flatMap{p in p.activityID==activityID && p.ownerID==service.identity.id && validID(p.connectionID) && bounded(p.accountEmail) && bounded(p.eventID) ? p:nil}
            var connectionID=known?.connectionID,account=known?.accountEmail,remote=known?.eventID
            var kind:Kind = known == nil ? .allOutbound:.activityAndRemote
            // Mapping alone establishes a conservative connection-wide scope.
            if known==nil,let id=mapping?["connectionId"].string,validID(id),
               let row=try service.db.get("CalendarConnection",key:["id":.text(id)]),
               row["provider"] == .text("google"),row["userId"] == .text(service.identity.id),bounded(row["accountEmail"].string) {
                connectionID=id;account=row["accountEmail"].string;remote=nil;kind = .connection
            }
            let connection=try connectionID.flatMap{try service.db.get("CalendarConnection",key:["id":.text($0)])}
            let refs:[[String]]=[
                [activityID,String(activity.revision),activity["createdBy"].string],
                [mapping?["id"].string ?? "",mapping.map{String($0.revision)} ?? "",mapping?["connectionId"].string ?? "",mapping?["externalId"].string ?? ""],
                [connectionID ?? "",connection.map{String($0.revision)} ?? "",connection?["provider"].string ?? "",connection?["userId"].string ?? "",connection?["accountEmail"].string ?? ""]
            ]
            return Scope(version:1,kind:kind,jobID:job.id,ownerID:service.identity.id,activityID:activityID,
                connectionID:connectionID,accountEmail:account,remoteEventID:remote,markerSHA256:hash(Data(marker.utf8)),
                quarantineValue:quarantineValue,storageSHA256:hash(storage.digestMaterial),referencesSHA256:hash(try JSONEncoder().encode(refs)))
        }
    }
    private static func lookups(_ scope:Scope,_ marker:String)throws->[String:String] {
        let digest=hash(Data(try encoded(scope).utf8)),key=receiptPrefix+scope.jobID
        func row(_ kind:String)throws->String {
            try encoded(Lookup(version:1,marker:marker,scopeSHA256:digest,receiptKey:key,kind:kind,
                activityID:scope.activityID,connectionID:scope.connectionID,accountEmail:scope.accountEmail,remoteEventID:scope.remoteEventID))
        }
        var result=[lookupPrefix+scope.jobID+".activity":try row("activity")]
        switch scope.kind {
        case .activityAndRemote:result[lookupPrefix+scope.jobID+".remote"]=try row("remote")
        case .connection:result[lookupPrefix+scope.jobID+".connection"]=try row("connection")
        case .allOutbound:result[lookupPrefix+scope.jobID+".global"]=try row("global")
        }
        return result
    }
    static func record(service:CRMService,job:NativeJob,storage:NativeRestoredMailReviewSnapshot,scope:Scope,authorize:()throws->Void)throws {
        guard !service.db.isReadOnly else{throw NativeDBError.conflict}
        try service.db.transaction {
            try Task.checkCancellation();try authorize()
            guard try prepare(service:service,job:job,storage:storage,quarantineValue:scope.quarantineValue)==scope else{throw NativeDBError.conflict}
            let marker=try marker(service,job,storage,scope.quarantineValue),value=try encoded(Stored(version:1,marker:marker,scope:scope))
            let key=receiptPrefix+job.id
            if let prior=try service.db.metadata(key){guard prior==value else{throw NativeDBError.conflict}}
            else{try service.db.setMetadata(key,value:value)}
            for (key,value) in try lookups(scope,marker) {
                if let prior=try service.db.metadata(key){guard prior==value else{throw NativeDBError.conflict}}
                else{try service.db.setMetadata(key,value:value)}
            }
            try Task.checkCancellation();try authorize()
            guard try validate(service:service,job:job,storage:storage,scope:scope) else{throw NativeDBError.conflict}
        }
    }
    static func validate(service:CRMService,job:NativeJob,storage:NativeRestoredMailReviewSnapshot,scope:Scope)throws->Bool {
        try service.db.transaction {
            let marker=try marker(service,job,storage,scope.quarantineValue)
            guard scope.version==1,scope.jobID==job.id,scope.ownerID==service.identity.id,
                  scope.activityID==job.payload["activity_id"],scope.markerSHA256==hash(Data(marker.utf8)),scope.storageSHA256==hash(storage.digestMaterial),
                  let raw=try service.db.metadata(receiptPrefix+job.id),
                  let saved=try? JSONDecoder().decode(Stored.self,from:Data(raw.utf8)),saved==Stored(version:1,marker:marker,scope:scope) else{return false}
            for (key,value) in try lookups(scope,marker){guard try service.db.metadata(key)==value else{return false}}
            return true
        }
    }
}
