import Foundation
import SQLite3

@main enum NativeCRMContractLinkTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws {guard try value() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
    static func rejects(_ label:String,_ action:()throws->Void)throws {do{try action()}catch{try check(!error.localizedDescription.contains("PRIVATE_MARKER"),"error omits source URL");checks+=1;return};throw NativeDBError.message("FAIL accepted: "+label)}
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("NativeCRMContractLinkTests: \(error)\n".utf8));exit(1)}}
    static func run()throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ContractLink-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let id="01234567-89ab-cdef-8123-456789abcdef",link=try NativeCRMContractLink(contractID:id.uppercased())
        try check(link.string=="nextcrm-native://contracts/"+id,"canonical lower UUID")
        try check(try NativeCRMContractLink(text:" \nNEXTCRM-NATIVE://CONTRACTS/"+id.uppercased()+"\t ")==link,"pasted whitespace and case")
        try check(try NativeCRMContractLink(text:link.string+String(repeating:" ",count:4096-link.string.utf8.count))==link,"4096 byte bound inclusive")
        let invalid=["","contracts/"+id,"https://example.invalid/contracts/"+id,"file:///tmp/"+id,"nextcrm-native://orders/"+id,"nextcrm-native://contracts","nextcrm-native://contracts/","nextcrm-native://contracts/"+id+"/","nextcrm-native://contracts/"+id+"/approve","nextcrm-native://contracts/../"+id,"nextcrm-native://contracts//"+id,"nextcrm-native://contracts/"+id+"?","nextcrm-native://contracts/"+id+"?token=PRIVATE_MARKER","nextcrm-native://contracts/"+id+"#","nextcrm-native://contracts/"+id+"#PRIVATE_MARKER","nextcrm-native://user:PRIVATE_MARKER@contracts/"+id,"nextcrm-native://contracts:80/"+id,"nextcrm-native://contracts:invalid/"+id,"nextcrm-native://contracts/%30"+id.dropFirst(),"nextcrm-native://contracts/"+id+"%00","nextcrm-native://contracts/"+id+"%2Fother","nextcrm-native://contracts/{"+id+"}","nextcrm-native://contracts/"+id.replacingOccurrences(of:"-",with:""),"nextcrm-native://contracts/'OR1=1--","nextcrm-native://contracts/"+id+"\nother",link.string+String(repeating:" ",count:4097-link.string.utf8.count)]
        for text in invalid {try rejects("strict URL"){_ = try NativeCRMContractLink(text:text)}}
        for bad in ["",id+" "," "+id,"{"+id+"}",id.replacingOccurrences(of:"-",with:""),"PRIVATE_MARKER"] {try rejects("strict ID"){_ = try NativeCRMContractLink(contractID:bad)}}
        var inbox=NativeCRMContractLinkInbox()
        try check(!inbox.hasPending && (try inbox.take(ready:true))==nil,"empty inbox")
        inbox.receive(link.string);try check(try inbox.take(ready:false)==nil && inbox.hasPending,"startup/sheet retains one intent")
        try check(try inbox.take(ready:true)==link && !inbox.hasPending,"consume once")
        for n in 1...1000 {inbox.receive(try NativeCRMContractLink(contractID:String(format:"01234567-89ab-cdef-8123-%012d",n)).string)}
        try check(try inbox.take(ready:true)?.contractID.hasSuffix("000000001000")==true,"1000 arrivals keep latest only")
        try check(try inbox.take(ready:true)==nil,"no replay")
        inbox.receive("nextcrm-native://contracts/"+id+"?token=PRIVATE_MARKER")
        try check(try inbox.take(ready:false)==nil && inbox.hasPending,"invalid URL also waits")
        try rejects("invalid consumed without secret"){_ = try inbox.take(ready:true)}
        try check(!inbox.hasPending,"invalid result consumed once")
        inbox.receive(link.string);inbox=NativeCRMContractLinkInbox();try check(!inbox.hasPending,"other-kind arrival can clear pending contract")
        let db=try NativeDatabase(url:root.appendingPathComponent("db.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")),admin=CRMService(db:db,identity:identity)
        func user(_ name:String,_ role:String="user")throws->NativeRecord{try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)}
        var owner=try user("owner");let stranger=try user("stranger"),watcher=try user("watcher"),manager=try user("manager","manager");var partner=try user("partner","partner")
        func service(_ user:NativeRecord)->CRMService{CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))}
        let a=service(owner),b=service(stranger),w=service(watcher),m=service(manager)
        func account(_ title:String,ownerID:SQLValue,partnerID:SQLValue = .null)throws->NativeRecord{try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text(title),"assigned_to":ownerID,"createdBy":.text(identity.id),"partnerUserId":partnerID],actor:identity.id)}
        var ownAccount=try account("契約先",ownerID:owner["id"]);let otherAccount=try account("別契約先",ownerID:stranger["id"])
        let partnerAccount=try account("パートナー本人",ownerID:owner["id"],partnerID:partner["id"]),managedAccount=try account("パートナー顧客",ownerID:owner["id"],partnerID:partner["id"])
        partner=try db.update(partner,changes:["partnerAccountId":partnerAccount["id"]],actor:identity.id);let partnerService=service(partner)
        func contract(_ title:String,account:SQLValue,creator:SQLValue,assignee:SQLValue = .null)throws->NativeRecord{try db.insert("crm_Contracts",values:["v":.integer(0),"title":.text(title),"value":.text("1234.50"),"account":account,"createdBy":creator,"assigned_to":assignee,"currency":.text("JPY")],actor:identity.id)}
        var inherited=try contract("アカウント経由",account:ownAccount["id"],creator:.text(identity.id))
        let owned=try contract("作成者",account:otherAccount["id"],creator:owner["id"]),assigned=try contract("担当者",account:otherAccount["id"],creator:.text(identity.id),assignee:owner["id"])
        let managed=try contract("顧客契約",account:managedAccount["id"],creator:.text(identity.id)),selfPartner=try contract("本人契約",account:partnerAccount["id"],creator:.text(identity.id))
        var hooks=0;db.beforeRecordWrite={_,_,_,values,_ in hooks+=1;return values}
        func auditCount()throws->Int64 {var c:OpaquePointer?,s:OpaquePointer?;guard sqlite3_open_v2(db.url.path,&c,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_finalize(s);sqlite3_close(c)};guard sqlite3_prepare_v2(c,"SELECT COUNT(*) FROM native_audit",-1,&s,nil)==SQLITE_OK,sqlite3_step(s)==SQLITE_ROW else{throw NativeDBError.conflict};return sqlite3_column_int64(s,0)}
        func access(_ service:CRMService,_ record:NativeRecord,allowed:Bool,_ label:String)throws {
            let before=hooks,audit=try auditCount(),original=try db.get(record.model,key:["id":record["id"]])!
            let locator=try NativeCRMContractLink(contractID:record["id"].string)
            if allowed {try check(try service.contractFromLink(locator).values==original.values,label)}else{try rejects(label){_ = try service.contractFromLink(locator)}}
            let after=try db.get(record.model,key:["id":record["id"]])!
            try check(before==hooks && (try auditCount())==audit && original.values==after.values && original.revision==after.revision,"read/denial leaves records, audit and hooks unchanged")
        }
        try access(a,inherited,allowed:true,"account owner reads contract")
        try access(a,owned,allowed:true,"creator reads contract")
        try access(a,assigned,allowed:true,"assignee reads contract")
        try access(b,inherited,allowed:false,"stranger cannot use locator as credential")
        try access(admin,inherited,allowed:true,"admin reads")
        try access(m,inherited,allowed:true,"manager reads")
        try rejects("inherited read does not grant write"){try a.assertAccess("crm_Contracts",id:inherited["id"].string,write:true)}
        let watch=try db.insert("AccountWatchers",values:["account_id":ownAccount["id"],"user_id":watcher["id"]],actor:identity.id)
        try access(w,inherited,allowed:true,"watcher reads parent contract")
        try db.remove(watch,actor:identity.id);try access(w,inherited,allowed:false,"watcher revoked before link open")
        ownAccount=try db.update(ownAccount,changes:["assigned_to":stranger["id"]],actor:identity.id);try access(a,inherited,allowed:false,"account assignment revoked")
        ownAccount=try db.update(ownAccount,changes:["assigned_to":owner["id"]],actor:identity.id)
        ownAccount=try db.setDeleted(ownAccount,deleted:true,actor:identity.id);try access(a,inherited,allowed:false,"deleted parent does not grant inherited access")
        ownAccount=try db.setDeleted(ownAccount,deleted:false,actor:identity.id)
        try access(partnerService,managed,allowed:true,"partner customer contract readable")
        try access(partnerService,selfPartner,allowed:false,"partner own-account contract not in source scope")
        try access(partnerService,inherited,allowed:false,"partner unrelated contract denied")
        try rejects("partner contract read-only"){try partnerService.assertAccess("crm_Contracts",id:managed["id"].string,write:true)}
        inherited=try db.setDeleted(inherited,deleted:true,actor:identity.id)
        try access(a,inherited,allowed:false,"soft-deleted contract denied")
        try access(admin,inherited,allowed:false,"admin link excludes trash")
        inherited=try db.setDeleted(inherited,deleted:false,actor:identity.id)
        for status in ["PENDING","INACTIVE"] {owner=try db.update(owner,changes:["userStatus":.text(status)],actor:identity.id);try access(a,inherited,allowed:false,"fresh status "+status)}
        owner=try db.update(owner,changes:["userStatus":.text("ACTIVE"),"banned":.integer(1)],actor:identity.id);try access(a,inherited,allowed:false,"fresh banned user")
        owner=try db.update(owner,changes:["banned":.integer(0),"role":.text("manager")],actor:identity.id);try access(a,inherited,allowed:false,"stale identity role rejected")
        owner=try db.update(owner,changes:["role":.text("user")],actor:identity.id);try access(a,inherited,allowed:true,"restored active current role works")
        partner=try db.update(partner,changes:["partnerAccountId":otherAccount["id"]],actor:identity.id);try access(partnerService,managed,allowed:false,"stale partner identity rejected")
        try rejects("missing local contract"){_ = try admin.contractFromLink(NativeCRMContractLink(contractID:UUID().uuidString))}
        let absent=CRMService(db:db,identity:CRMIdentity(id:UUID().uuidString,role:"admin",partnerAccountID:nil));try access(absent,inherited,allowed:false,"missing current user denied")
        let locator=try NativeCRMContractLink(contractID:inherited["id"].string)
        let sealed=root.appendingPathComponent("sealed.sqlite");var source:OpaquePointer?,destination:OpaquePointer?
        guard sqlite3_open_v2(db.url.path,&source,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&destination)==SQLITE_OK,let copy=sqlite3_backup_init(destination,"main",source,"main") else{throw NativeDBError.conflict}
        let copied=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(source);sqlite3_close(destination);try check(copied==SQLITE_DONE,"sealed fixture backup")
        let sealedBytes=try Data(contentsOf:sealed)
        let readonly=try NativeDatabase(readOnlyURL:sealed,schemaURL:resources.appendingPathComponent("schema.json"))
        let readService=CRMService(db:readonly,identity:a.identity)
        try check(try readService.contractFromLink(locator)["title"]==inherited["title"],"read-only sealed snapshot service access")
        try check(try Data(contentsOf:sealed)==sealedBytes && !FileManager.default.fileExists(atPath:sealed.path+"-wal") && !FileManager.default.fileExists(atPath:sealed.path+"-shm"),"read-only lookup writes no database or sidecars")
        print("NativeCRMContractLinkTests: \(checks) checks passed")
    }
}
