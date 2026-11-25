import Foundation

/// Retention has no time threshold. Only terminal proofs for known producers
/// permit a bounded page to be deleted, in the same DB transaction as the fence.
enum NativeCRMSweepSnapshotRetention {
    struct Result: Equatable {
        let scanned: Int, deleted: Int, held: Int, hasMore: Bool, readOnly: Bool, oversizedKey: Bool
    }
    static let cursorKey = "crm.automation.snapshot.retention.cursor.v1"
    private struct Key {
        let owner: String,kind: String,ordinal: String,index: Int
        init?(_ key: String) {
            let prefix="crm.automation.snapshot.v1."
            guard key.hasPrefix(prefix) else { return nil }
            let parts=key.dropFirst(prefix.count).split(separator:".",omittingEmptySubsequences:false).map(String.init)
            guard parts.count==3,let uuid=UUID(uuidString:parts[0]),uuid.uuidString.lowercased()==parts[0],
                  ["recycleTarget","recipient"].contains(parts[1]),parts[2].utf8.count==12,
                  parts[2].utf8.allSatisfy({(48...57).contains($0)}),let n=Int(parts[2]) else { return nil }
            owner=parts[0];kind=parts[1];ordinal=parts[2];index=n
        }
    }
    private static func natural(_ value:String?,positive:Bool=false)->Int? {
        guard let value,let n=Int(value),value==String(n),n >= (positive ? 1:0) else { return nil };return n
    }
    private static func uuid(_ value:String?)->Bool { value.flatMap(UUID.init(uuidString:)) != nil }
    private static func date(_ value:String?)->Bool { value.flatMap { try? NativeCRMAutomationDates.parse($0) } != nil }
    /// Returned count also proves the ordinal was part of this producer's
    /// bounded snapshot. A missing old-format consumer link stays held.
    private static func releasableCount(_ key:Key,db:NativeDatabase)throws->Int? {
        guard let owner=try db.crmAutomationSnapshotOwnerProof(key.owner),owner["validJSON"]=="1" else{return nil}
        if key.kind=="recycleTarget" {
            guard owner["event"]==NativeCRMSweepJobs.recycleScan,owner["status"]=="done",owner["begun"]=="0",
                  let count=natural(owner["recycled"],positive:true),let applyID=owner["applyJobId"],uuid(applyID),
                  let apply=try db.crmAutomationSnapshotOwnerProof(applyID),apply["validJSON"]=="1",apply["event"]==NativeCRMSweepJobs.recycleApply,
                  apply["scanId"]==key.owner,natural(apply["count"])==count,apply["begun"]=="0" else{return nil}
            if apply["status"]=="cancelled",apply["hasProvider"]=="0" { return count }
            if apply["status"]=="done",natural(apply["recycled"])==count,uuid(apply["listId"]),natural(apply["recipients"]) != nil,apply["hasProvider"]=="0" {return count}
            return nil
        }
        // Only recycle digest currently creates recipient metadata. Kill uses
        // one frozen payload recipient, so fabricated kill metadata stays held.
        guard owner["event"]==NativeCRMSweepJobs.recycleNotice,let count=natural(owner["recipientCount"],positive:true) else{return nil}
        if owner["status"]=="cancelled",owner["begun"]=="0",owner["hasProvider"]=="0" {return count}
        guard owner["status"]=="done" else{return nil}
        if owner["hasReview"]=="1" {
            guard owner["begun"]=="1",!(owner["reviewedBy"] ?? "").isEmpty,date(owner["reviewedAt"]),owner["note"]=="1",
                  ["needs_review","failed","retry"].contains(owner["reviewPreviousStatus"] ?? "") else{return nil}
            switch owner["reviewOutcome"] {
            case "accepted": return owner["outcome"]=="sent" && uuid(owner["providerID"]) ? count:nil
            case "notSent": return owner["outcome"]=="not_sent" && owner["hasProvider"]=="0" ? count:nil
            case "unknown": return owner["outcome"]=="unconfirmed" && owner["hasProvider"]=="0" ? count:nil
            default:return nil
            }
        }
        if owner["outcome"]=="sent",owner["begun"]=="1",uuid(owner["providerID"]),date(owner["acceptedAt"]) {return count}
        if owner["outcome"]=="skipped",owner["begun"]=="0",owner["hasProvider"]=="0",owner["reason"]=="1" {return count}
        return nil
    }
    @discardableResult static func runPage(db:NativeDatabase,checkpoint:(Int)throws->Void={_ in})throws->Result {
        guard !db.isReadOnly else{return .init(scanned:0,deleted:0,held:0,hasMore:false,readOnly:true,oversizedKey:false)}
        try Task.checkCancellation()
        return try db.transaction {
            let raw=try db.crmAutomationSnapshotRetentionCursor()
            let after=raw?.hasPrefix("crm.automation.snapshot.v1.")==true ? raw:nil
            let page=try db.crmAutomationSnapshotRetentionPage(after:after)
            guard !page.contains(where:{$0==nil}) else{return .init(scanned:page.count,deleted:0,held:page.count,hasMore:false,readOnly:false,oversizedKey:true)}
            let keys=page.compactMap{$0};var deleted=0
            // At most 100 tiny cache entries. Never retain job/body data.
            var known:Set<String>=[],counts:[String:Int]=[:]
            for (index,rawKey) in keys.enumerated() {
                try Task.checkCancellation()
                if let key=Key(rawKey) {
                    let cache=key.owner+"."+key.kind
                    if !known.contains(cache) {known.insert(cache);counts[cache]=try releasableCount(key,db:db)}
                    if let count=counts[cache],key.index<count {try db.removeCRMAutomationSnapshot(ownerID:key.owner,kind:key.kind,ordinal:key.ordinal);deleted += 1}
                }
                try checkpoint(index+1)
            }
            try Task.checkCancellation()
            // End of one finite namespace pass. Held rows are reconsidered at a
            // future ordinary owner resume, never polled endlessly in this pass.
            try db.setMetadata(cursorKey,value:keys.count==100 ? keys.last! : "")
            return .init(scanned:keys.count,deleted:deleted,held:keys.count-deleted,hasMore:keys.count==100,readOnly:false,oversizedKey:false)
        }
    }
}
