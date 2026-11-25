import Foundation

enum NativeAccountProtectionPresentation {
    typealias Cell=NativePluginPresentation.Cell
    typealias Section=NativePluginPresentation.Section

    /// A single read snapshot keeps authorization and the displayed store state
    /// consistent. No lifecycle callback, provider, Keychain or worker runs here.
    static func build(service:CRMService,host:NativePluginHost,location:NativePluginLocation) throws -> NativePluginPresentation? {
        guard service.db === host.db else { throw NativePluginError(message:"表示するデータベースが一致しません") }
        return try service.db.transaction {
            try service.authenticated()
            guard let definition=host.definition(NativeAccountProtection.id),let state=try host.state(definition.id),state["status"] == .text("ENABLED") else {return nil}
            let kind:NativePluginSlot.Kind,slotID:String?
            switch location {
            case .account:kind = .accountTab;slotID="protection"
            case .admin:kind = .adminSection;slotID="conflicts"
            case .page(let path):guard path=="expiring" || path=="account-protection/expiring" else {return nil};kind = .page;slotID="expiring"
            default:return nil
            }
            guard let slot=definition.slots.first(where:{$0.kind==kind && $0.id==slotID}),slot.roles.contains(service.identity.role) else {throw NativePluginError(message:"担当保護の情報を表示する権限がありません")}
            if kind == .adminSection,service.identity.role != "admin" {throw NativePluginError(message:"重複する取引先の確認には管理者権限が必要です")}
            let context=try displayContext(definition:definition,state:state,service:service,host:host)
            switch location {
            case .account(let id):
                guard let account=try service.db.get("crm_Accounts",key:["id":.text(id)]),account["deletedAt"] == .null else {return nil}
                try service.assertAccess("crm_Accounts",id:id)
                return try accountView(id,context,service)
            case .admin:return try conflicts(context,service)
            case .page:return try expiring(context,service)
            default:return nil
            }
        }
    }
    private static func displayContext(definition:NativePluginDefinition,state:NativeRecord,service:CRMService,host:NativePluginHost) throws -> NativePluginContext {
        var display=definition;display.permissions=definition.permissions.filter{$0.hasSuffix(":read")}
        let settings=definition.settings.stored(try NativePluginJSON.parse(state["settings"].string)) {_,_ in}
        return NativePluginContext(definition:display,actor:.init(type:.user,userId:service.identity.id,role:service.identity.role),locale:"ja",settings:settings,secrets:[:],store:NativePluginStore(db:service.db,pluginId:definition.id,clock:host.clock),data:NativePluginData(db:service.db,pluginId:definition.id,permissions:display.permissions,clock:host.clock),clock:host.clock,logger:{_,_,_ in},translator:{NativePluginMessages.translate(definition.id,$0,$1,"ja")},notification:{_ in throw NativePluginError(message:"表示処理から通知は送信できません")},transport:{_ in throw NativePluginError(message:"表示処理から外部通信は実行できません")},persistAfterTransaction:{_ in})
    }
    private static func date(_ value:String?) -> String {
        guard let value,let date=try? NativePluginJSON.date(value) else {return "日付不明"}
        let parts=NativePluginJSON.civilDay(Int(floor(date.timeIntervalSince1970/86_400)))
        return "\(parts.year)年\(parts.month)月\(parts.day)日"
    }
    /// Decode one bounded page at a time. Only final text cells are retained by
    /// the table DTO, not a second copy of the plugin's JSON history/indexes.
    private static func entries(_ prefix:String,_ ctx:NativePluginContext,_ service:CRMService,descending:Bool=false,_ body:(String,NativePluginRecord)throws->Void) throws {
        var offset=0
        while true {
            try Task.checkCancellation()
            let rows=try service.db.mcpPage("PluginData",fields:["key","value"],filter:.every([.equal("pluginId",.text(ctx.plugin.id)),.equal("entityType",.text("")),.equal("entityId",.text("")),.scalar("key","startsWith",[.text(prefix)],false)]),limit:100,offset:offset,order:[("key",descending)],includeDeleted:true).rows
            for row in rows {if let value=try NativePluginJSON.parse(row["value"].string) as? NativePluginRecord {try body(row["key"].string,value)}}
            offset+=rows.count;if rows.count<100 {break}
        }
    }
    private static func visibleAccount(_ id:String,_ ctx:NativePluginContext,_ service:CRMService) throws -> Cell? {
        guard (try? service.assertAccess("crm_Accounts",id:id)) != nil,let row=try ctx.data.get("accounts",id) else {return nil}
        let name=(row["name"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? "名称未設定"
        return Cell(name,record:.init(model:"crm_Accounts",id:id))
    }
    private static func user(_ value:Any?,_ ctx:NativePluginContext,_ service:CRMService) throws -> String {
        guard let id=value as? String,!id.isEmpty else {return ctx.t("tab.nobody")}
        guard (try? service.assertAccess("Users",id:id)) != nil else {return "利用者情報を表示できません"}
        guard let row=try ctx.data.get("users",id) else {return "削除済みの利用者"}
        return (row["name"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? (row["email"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? "名称未設定"
    }
    private static func liveContact(_ id:String,_ registration:NativePluginRecord,_ ctx:NativePluginContext,_ service:CRMService) throws -> String? {
        if let cached=registration["contactAt"] as? String,!cached.isEmpty {return cached}
        var skip=0
        while true {
            let rows=try ctx.data.activitiesForRecord("account",id,["types":NativeAccountProtectionState.contactTypes(ctx.settings["contactTypes"] as? String ?? "visit,meeting"),"status":"completed","since":String((registration["registeredAt"] as? String ?? "").prefix(10))+"T00:00:00.000Z","take":100,"skip":skip])
            for row in rows {
                if let activity=row["id"] as? String,(try? service.assertAccess("crm_Activities",id:activity)) != nil {return row["date"] as? String}
            }
            skip+=rows.count;if rows.count<100 {return nil}
        }
    }
    private static func accountView(_ id:String,_ ctx:NativePluginContext,_ service:CRMService) throws -> NativePluginPresentation {
        let account=try ctx.data.get("accounts",id)!,registration=try NativeAccountProtection.dictionary(ctx.store,"reg:"+id)
        let contact=try registration.flatMap{try liveContact(id,$0,ctx,service)}
        let summary=NativeAccountProtectionState.summarize(hasKey:NativeAccountProtection.key(account,ctx) != nil,reg:registration,contactAt:contact)
        let key="tab."+(summary["kind"] as! String),status=ctx.t(key,(summary["date"] as? String).map{["date":date($0)]})
        var rows:[[Cell]]=[[Cell(ctx.t("tab.status")),Cell(status)]]
        if let registration {
            rows.append([Cell("保護期限"),Cell(date(registration["protectedUntil"] as? String))])
            rows.append([Cell("連絡期限"),Cell(date(registration["contactDeadline"] as? String))])
            rows.append([Cell(ctx.t("tab.contact")),Cell(contact.map{ctx.t("tab.contactYes",["date":date($0)])} ?? ctx.t("tab.contactNo"))])
            if let last=registration["lastOrderAt"] as? String {rows.append([Cell(ctx.t("tab.order")),Cell(ctx.t("tab.lastOrder",["date":date(last)]))])}
            else if (NativePluginJSON.number(ctx.settings["orderMonths"]) ?? 12)>0 {rows.append([Cell(ctx.t("tab.order")),Cell(ctx.t("tab.noOrder"))])}
        }
        var history:[[Cell]]=[]
        try entries("hist:"+id+":",ctx,service,descending:true) {_,entry in
            let reason=entry["reason"] as? String ?? "",known=["created","assigned","released","expired","expired-no-contact","install"].contains(reason)
            history.append([Cell(date(entry["at"] as? String)),Cell(try user(entry["from"],ctx,service)),Cell(try user(entry["to"],ctx,service)),Cell(entry["byUserId"] is String ? try user(entry["byUserId"],ctx,service):ctx.t("tab.system")),Cell(known ? ctx.t("tab.reason."+reason):"変更")])
        }
        return .init(title:ctx.t("tab.title"),sections:[.init(title:"担当保護の状況",columns:["項目","内容"],rows:rows),.init(title:ctx.t("tab.history"),columns:["日付","変更前の担当者","変更後の担当者","操作した利用者","理由"],rows:history,empty:ctx.t("tab.historyEmpty"))])
    }
    private static func conflicts(_ ctx:NativePluginContext,_ service:CRMService) throws -> NativePluginPresentation {
        var rows:[[Cell]]=[]
        try entries("conflict:",ctx,service) {key,value in
            let id=String(key.dropFirst(9))
            guard let other=value["otherAccountId"] as? String,let number=value["key"] as? String,let account=try visibleAccount(id,ctx,service),let holder=try visibleAccount(other,ctx,service) else {return}
            rows.append([Cell(number),account,holder])
        }
        return .init(title:ctx.t("admin.conflicts"),sections:[.init(title:ctx.t("admin.conflicts"),columns:[ctx.t("admin.key"),ctx.t("admin.account"),"先に登録された取引先"],rows:rows,empty:ctx.t("admin.conflictsEmpty"))])
    }
    private static func expiring(_ ctx:NativePluginContext,_ service:CRMService) throws -> NativePluginPresentation {
        let days=NativePluginJSON.number(ctx.settings["warnDays"]) ?? 7,horizon=String(NativePluginJSON.stamp(ctx.clock().addingTimeInterval(days*86_400)).prefix(10))
        var due:[[Cell]]=[],freed:[[Cell]]=[]
        for prefix in ["due:","freed:"] {
            try entries(prefix,ctx,service) {key,_ in
                let rest=String(key.dropFirst(prefix.count)),parts=rest.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)
                guard parts.count==2 else {return};let day=String(parts[0]),id=String(parts[1])
                if prefix=="due:",day>horizon {return}
                guard let account=try visibleAccount(id,ctx,service) else {return}
                let row=[Cell(date(day)),account];if prefix=="due:" {due.append(row)}else{freed.append(row)}
            }
        }
        return .init(title:ctx.t("expiring.title"),sections:[.init(title:ctx.t("expiring.due",["days":days]),columns:["期限","取引先"],rows:due,empty:ctx.t("expiring.empty")),.init(title:ctx.t("expiring.freed"),columns:["解除日","取引先"],rows:freed,empty:ctx.t("expiring.empty"))])
    }
}
