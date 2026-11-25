import Foundation

private final class NativePersonalLocalHostReference { weak var value:NativePersonalLocalPluginHost? }

/// Existing rule interpreter + actual pure account-protection after handler.
/// No credential vault, plugin runtime, cron, install hook, HTTP or mail adapter.
final class NativePersonalLocalPluginHost {
    struct Status {
        let blockedModels:[String],message:String?
        var hasBlockedWrites:Bool{!blockedModels.isEmpty}
    }
    static let dirtyKey="personal.local-protection.dirty.v1"
    private static let known:Set<String>=["account-protection","registry-ares","odoo-connector","oxo-erp-connector"]
    let host:NativePluginHost
    private let db:NativeDatabase,transitionID:String
    private var authorize:()throws->Void
    private var inspectedRevision:Int64?,protectionStateValid=false
    init(db:NativeDatabase,definitions:[NativePluginDefinition],transitionID:String,
         authorize:@escaping ()throws->Void,clock:@escaping ()->Date=Date.init)throws {
        guard !db.isReadOnly,UUID(uuidString:transitionID) != nil else{throw NativeRestoreActivationFailure("personal.localRules")}
        self.db=db;self.transitionID=transitionID;self.authorize=authorize
        let reference=NativePersonalLocalHostReference()
        host=try NativePluginHost(db:db,definitions:definitions,clock:clock,
            sendNotification:{_,_,_ in throw NativePluginError(message:"復元した通知の送信は確認待ちです。")},
            transport:{_,_ in throw NativePluginError(message:"復元した連携先への接続は確認待ちです。")},
            capabilities:.init(allowSecretRead:false,allowExternalEffects:false,
                beforeWrite:{model,operation,existing,input in
                    guard let owner=reference.value else{throw NativeRestoreActivationFailure("personal.localRulesLost")}
                    try owner.before(model,operation,existing,input)
                },after:{definition,event in
                    guard let owner=reference.value else{throw NativeRestoreActivationFailure("personal.localRulesLost")}
                    return try owner.after(definition,event)
                }))
        reference.value=self;try validate();host.attach()
    }
    func replaceAuthority(_ value:@escaping ()throws->Void){authorize=value}
    func validate()throws {try authorize();guard !db.isReadOnly else{throw NativeRestoreActivationFailure("personal.readOnlyRules")};_ = try status()}
    private func installed()throws->[NativeRecord] {
        // There are four supported built-ins; a fifth enabled row is unknown.
        try db.mcpPage("InstalledPlugin",fields:["id","version","status"],filter:.equal("status",.text("ENABLED")),limit:5,offset:0,order:[("id",false)],includeDeleted:true).rows
    }
    private func valid(_ rows:[NativeRecord])->Bool {
        rows.count<=4 && rows.allSatisfy { row in
            guard Self.known.contains(row["id"].string),let definition=host.definition(row["id"].string),
                  definition.version==row["version"].string else{return false}
            return definition.id==NativeAccountProtection.id || definition.rules.isEmpty
        }
    }
    func status()throws->Status {try db.transaction{try statusLocked()}}
    private func statusLocked()throws->Status {
        try authorize();let rows=try installed()
        guard valid(rows) else{return .init(blockedModels:NativePluginEntity.allCases.map(\.model),
            message:"確認できない連携の保護ルールがあります。取引先・連絡先・リード・商談・受注の編集は確認待ちです。")}
        let dirty = !(try db.metadata(Self.dirtyKey) ?? "").isEmpty
        let pending = try db.personalLocalProtectionPending()
        if rows.contains(where:{$0["id"] == .text(NativeAccountProtection.id)}), dirty || pending {
            return .init(blockedModels:["crm_Accounts","crm_Orders"],
                message:"保存は完了していますが、担当保護の反映を確認できません。確認が終わるまで取引先と受注の編集を停止しています。")
        }
        if let protection=rows.first(where:{$0["id"] == .text(NativeAccountProtection.id)}) {
            if inspectedRevision != protection.revision {
                protectionStateValid=(try? NativePersonalProtectionInspection.valid(host:host))==true
                inspectedRevision=protection.revision
            }
            if !protectionStateValid{return .init(blockedModels:["crm_Accounts","crm_Orders"],message:"復元した担当保護の索引・履歴を確認できません。元の状態を保持し、取引先と受注の編集を停止しています。")}
        }
        return .init(blockedModels:[],message:nil)
    }
    private func before(_ model:String,_ operation:String,_ existing:NativeRecord?,_ input:[String:SQLValue])throws {
        try authorize()
        guard NativePluginEntity(model:model) != nil else{return}
        let state=try status()
        guard !state.blockedModels.contains(model) else{throw NativePluginError(message:state.message!)}
        guard try installed().contains(where:{$0["id"] == .text(NativeAccountProtection.id)}) else{return}
        let deleted=operation=="delete" || input["deletedAt"].map{$0 != .null && existing?["deletedAt"] == .null}==true
        if model=="crm_Accounts" || model=="crm_Orders" && !deleted {
            // This is inside the original record transaction. Rejection/outer
            // rollback removes it; enqueue/I/O failure cannot silently lose it.
            try db.setMetadata(Self.dirtyKey,value:transitionID)
        }
    }
    private func after(_ definition:NativePluginDefinition,_ event:NativePluginAfterInput)throws->Bool {
        guard definition.id==NativeAccountProtection.id else{return false}
        try authorize()
        let payload=["pluginId":definition.id,"input":String(decoding:try JSONEncoder().encode(event),as:UTF8.self),
                     "personalLocalTransition":transitionID]
        let id=try db.enqueue("plugin/after",payload:payload,now:host.clock())
        let job=try db.claimPersonalLocalProtection(id:id,transitionID:transitionID,now:host.clock())
        do {
            try db.transaction {
                try authorize()
                let context=try host.context(definition,actor:.plugin(definition.id))
                // Synchronous and entirely inside this transaction: no accepted
                // asynchronous job needs a TaskLocal lease closure. The host's
                // capability beforeWrite fence checks every actual DB mutation.
                try NativePluginActorScope.withActor(.plugin(definition.id)) {
                    try NativeAccountProtection.after(event,context)
                }
                try authorize()
                try db.finishJob(job,result:["status":"completed","localOnly":"true"],now:host.clock())
                try db.setMetadata(Self.dirtyKey,value:"")
            }
        } catch {
            // Preserve the original after-hook save-success contract. The
            // original record and exact failed intent stay, subsequent affected
            // writes are fenced, and the UI can present status().
            try? db.failJob(job,message:"担当保護の反映を確認できません。",needsReview:true)
            host.log(definition.id,"error","担当保護の反映を確認できません。",["recordId":event.recordId])
        }
        return true
    }
}
