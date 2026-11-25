import Foundation
import SQLite3

@main enum NativeUserAdministrationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func rejects(_ label: String, _ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: " + label) }
    static func id(_ n: Int) -> String { String(format: "b1000000-0000-4000-8000-%012d", n) }
    static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.fragmentsAllowed]), as: UTF8.self) }
    static func value(_ x: Any) -> SQLValue { if x is NSNull { return .null }; if let n = x as? NSNumber { return .integer(n.int64Value) }; return .text(x as! String) }
    static func all(_ db: NativeDatabase, _ model: String, _ fields: [String]) throws -> [NativeRecord] {
        var out: [NativeRecord] = [], offset = 0
        while true { let rows = try db.page(model, fields: fields, includeDeleted: true, offset: offset).rows; out += rows; if rows.count < 100 { return out }; offset += rows.count }
    }
    static func state(_ db: NativeDatabase) throws -> [String: Any] {
        let fields = ["id","name","email","username","account_name","avatar","role","userLanguage","userStatus","partnerAccountId"]
        let users = try all(db,"Users",fields)
        let newIDs = Dictionary(uniqueKeysWithValues: users.filter { !$0["id"].string.hasPrefix("b100") }.map { ($0["id"].string,"new:"+$0["email"].string) })
        func pick(_ row: NativeRecord, _ fields: [String]) -> [String: Any] { Dictionary(uniqueKeysWithValues: fields.map { field in (field,newIDs[row[field].string].map { $0 as Any } ?? row[field].json) }) }
        return ["users": users.map { pick($0,fields) }.sorted { ($0["id"] as! String) < ($1["id"] as! String) },
                "accounts": try all(db,"crm_Accounts",["assigned_to","partnerUserId"]).map { pick($0,["id","assigned_to","partnerUserId"]) },
                "sessions": try all(db,"Session",[]).map { $0["id"].string },
                "tokens": try all(db,"ApiToken",["revokedAt"]).map { ["id":$0["id"].string,"revoked":$0["revokedAt"] != .null] as [String:Any] }]
    }
    static func main() async {
        do { try await run(); print("NativeUserAdministrationTests: \(checks) original contract / isolated SQLite checks passed") }
        catch { fputs("After \(checks): \(error.localizedDescription)\n",stderr); exit(1) }
    }
    static func run() async throws {
        let n = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-UserAdmin-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:n.appendingPathComponent("build/user-administration-reference.json"))) as! [String:Any]
        let now = ISO8601DateFormatter().date(from:"2026-11-20T03:00:00Z")!
        func database(_ name:String)throws->NativeDatabase { try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql")) }
        func seed(_ db:NativeDatabase,_ initial:[String:Any])throws { for model in ["Users","crm_Accounts","Session","ApiToken","Boards","tasksComments"] { for row in initial[model] as? [[String:Any]] ?? [] { _ = try db.insert(model,values:row.mapValues(value),actor:id(1)) } } }
        func svc(_ db:NativeDatabase,_ actor:String)throws->CRMService { let row = try db.get("Users",key:["id":.text(actor)]); return CRMService(db:db,identity:.init(id:actor,role:row?["role"].string ?? "admin",partnerAccountID:row?["partnerAccountId"] == .null ? nil : row?["partnerAccountId"].string)) }
        let scenarios = reference["scenarios"] as! [[String:Any]]
        for (number,s) in scenarios.enumerated() {
            let db=try database("source\(number)"), initial=s["initial"] as! [String:Any], name=s["name"] as! String
            try seed(db,initial); let actor=s["actor"] as! String, mode=s["mail"] as! String
            var sent: [[String:Any]]=[]
            let gateway=NativeUserAdministrationMailGateway(applicationName:"NextCRM",applicationURL:"https://fixture.invalid/login",from:"crm@fixture.invalid",isConfigured:mode != "unconfigured",send:{ message in
                var row:[String:Any] = ["kind":message.kind.rawValue,"to":message.to,"from":message.from,"subject":message.subject]
                if message.kind == .activation { row["text"] = message.text }
                sent.append(row)
                if mode == "fail" { throw NativeDBError.message("synthetic mail rejected") }
            })
            let manager=NativeUserAdministration(service:try svc(db,actor),clock:{now},mail:gateway)
            let calls=s["calls"] as! [[String:Any]], steps=s["steps"] as! [[String:Any]]
            try check(calls.count == steps.count,"source step count")
            for (index,call) in calls.enumerated() {
                let op=call["op"] as! String, target=call["id"] as? String ?? ""
                var result:[String:Any]
                do {
                    var row:NativeUserAdministrationRow?
                    switch op {
                    case "list": result=["ids":try manager.list().rows.map(\.id)]
                    case "role": row=try manager.setRole(target,role:call["role"] as! String);result=[:]
                    case "partner": row=try manager.setPartnerAccount(target,accountID:call["accountID"] as? String);result=[:]
                    case "delete": row=try manager.delete(target);result=[:]
                    case "deactivate": row=try manager.deactivate(target);result=[:]
                    case "revoke": result=["revoked":try manager.revokeAPITokens(target)]
                    case "profile": row=try manager.updateProfile(target,name:call["name"] as! String,username:call["username"] as! String,accountName:call["accountName"] as! String);result=[:]
                    case "language": result=["language":try manager.setLanguage(target,language:call["language"] as! String)]
                    case "photo": try manager.setProfilePhoto(call["avatar"] as! String);result=["ok":true]
                    case "activate": let r=try await manager.activate(target); row=r.user;result=[:]; try check(r.delivery == (mode == "fail" ? .failed : .sent),name+" delivery")
                    case "invite": row=try await manager.invite(name:call["name"] as! String,email:call["email"] as! String,language:call["language"] as! String).user;result=[:]
                    default: throw NativeDBError.message("unknown fixture action")
                    }
                    if let row { result=["id":row.id.hasPrefix("b100") ? row.id : "new:"+row["email"].string]; try check(row.values["password"] == nil && row.values["token"] == nil,name+" safe projection") }
                } catch { result=["error":error.localizedDescription] }
                var expected=steps[index]["result"] as! [String:Any]
                // UI translates the directory's thrown AuthenticationError.
                if expected["error"] as? String == "Unauthenticated" { expected["error"]="ログインが必要です" }
                try check(try json(result)==json(expected),name+" step\(index) result actual="+(try json(result))+" expected="+(try json(expected)))
                try check(try json(state(db))==json(steps[index]["state"]!),name+" step\(index) state")
                try check(try json(sent)==json(steps[index]["mail"]!),name+" step\(index) mail actual="+(try json(sent))+" expected="+(try json(steps[index]["mail"]!)))
            }
        }
        // Native-specific security, paging, atomicity, exact FK side effects.
        let db=try database("native"), initial=scenarios[0]["initial"] as! [String:Any]
        try seed(db,initial); let admin=try svc(db,id(1)), management=NativeUserAdministration(service:admin,clock:{now})
        var raw:OpaquePointer?;try check(sqlite3_open(root.appendingPathComponent("native/crm.sqlite").path,&raw)==SQLITE_OK,"fixture sqlite")
        guard let raw else { throw NativeDBError.conflict };defer{sqlite3_close(raw)}
        func sql(_ text:String)throws{guard sqlite3_exec(raw,text,nil,nil,nil)==SQLITE_OK else{throw NativeDBError.message(String(cString:sqlite3_errmsg(raw)))}}
        func row(_ model:String,_ target:String)throws->NativeRecord{guard let r=try db.get(model,key:["id":.text(target)])else{throw NativeDBError.conflict};return r}
        for i in 100..<305 { _ = try db.insert("crm_Accounts",values:["id":.text(id(i)),"v":.integer(0),"name":.text("関連\(i)"),"partnerUserId":.text(id(3)),"assigned_to":.text(id(2)),"deletedAt":i == 304 ? .text("2026-01-01T00:00:00Z"):.null],actor:id(1)) }
        _ = try management.setPartnerAccount(id(3),accountID:id(10));let oldPartner=try svc(db,id(3))
        try sql("CREATE TRIGGER test_role_failure BEFORE UPDATE ON crm_Accounts WHEN OLD.id='\(id(250))' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        let before=try state(db), audits=try db.auditCount("crm_Accounts")
        try rejects("partner cleanup rollback"){_ = try management.setRole(id(3),role:"user")}
        try check(try json(state(db))==json(before),"all batches rollback")
        try check(try db.auditCount("crm_Accounts")==audits,"audit rollback")
        try sql("DROP TRIGGER test_role_failure")
        _ = try management.setRole(id(3),role:"user")
        try check(try db.page("crm_Accounts",fields:[],equal:["partnerUserId":.text(id(3))],includeDeleted:true).total==0,"all 207 partner refs removed")
        try check(try row("Users",id(3))["partnerAccountId"] == .null,"partner home cleared")
        try rejects("stale partner identity"){try oldPartner.authenticated()}
        let tokenOwner=try svc(db,id(2)), token=try NativeAPITokens(service:tokenOwner,clock:{now}).issue(name:"retained")
        let api=try NativeAPITokens.authenticate(token.rawToken,db:db,clock:{now})
        _ = try management.setRole(id(2),role:"manager")
        try check(try api.withAccess{$0.identity.role} == "manager","token current role reloaded")
        try rejects("old user identity"){try tokenOwner.authenticated()}
        _ = try management.setRole(id(2),role:"user")
        let optionalBefore=try row("crm_Accounts",id(100)), accountAudit=try db.auditCount("crm_Accounts")
        _ = try db.insert("crm_Report_Config",values:["id":.text(id(400)),"name":.text("削除制限"),"category":.text("accounts"),"filters":.text("{}"),"createdBy":.text(id(2))],actor:id(1))
        let tokenCount=try db.page("ApiToken",fields:[]).total
        try rejects("required report restrict"){_ = try management.delete(id(2))}
        try check(try row("crm_Accounts",id(100)).values == optionalBefore.values,"restrict nullification rollback")
        try check(try db.page("ApiToken",fields:[]).total == tokenCount,"restrict cascade rollback")
        try db.remove(row("crm_Report_Config",id(400)),actor:id(1))
        var hookCalls=0;db.beforeRecordWrite={model,op,before,changes,actor in if model != "Users" { hookCalls += 1 };return changes};db.afterRecordWrite={model,op,before,after,changes,actor in if model != "Users" { hookCalls += 1 }}
        _ = try management.delete(id(2))
        let optionalAfter=try row("crm_Accounts",id(100))
        try check(optionalAfter["assigned_to"] == .null,"optional FK null")
        try check(optionalAfter["updatedAt"] == optionalBefore["updatedAt"] && optionalAfter.revision == optionalBefore.revision+1,"FK timestamp unchanged revision increment")
        try check(try db.auditCount("crm_Accounts") == accountAudit,"FK audit unchanged")
        try check(hookCalls==0,"FK delete no related hooks")
        try check(try db.page("Session",fields:[]).total==0 && db.page("ApiToken",fields:[]).total==0,"session and token cascade")
        try rejects("deleted token rejected"){try api.withAccess{_ in}}
        try rejects("Users-only helper"){try db.deleteAdministrativeUser(optionalAfter,actor:id(1))}
        try rejects("stale delete helper"){try db.deleteAdministrativeUser(NativeRecord(model:"Users",values:try row("Users",id(4)).values,revision:0),actor:id(1))}
        for i in 500..<705 {_ = try db.insert("Users",values:["id":.text(id(i)),"email":.text("page\(i)@fixture.invalid"),"name":.text("ページ\(i)"),"role":.text("user"),"userStatus":.text("ACTIVE"),"created_on":.text("2026-11-19T00:00:00Z")],actor:id(1))}
        let page=try management.list(search:"ページ",role:"user",status:"ACTIVE",offset:100)
        try check(page.total==205 && page.rows.count==100,"bounded filtered users")
        try check(try management.list(search:"must-not-leak").total==0,"no secret search side channel")
        let activated=try await management.activate(id(6));try check(activated.delivery == .notConfigured && activated.user["userStatus"] == .text("ACTIVE"),"unconfigured activation explicit notice")
        let beforeInvite=try db.page("Users",fields:[]).total
        do {_ = try await management.invite(name:"x",email:"x@fixture.invalid",language:"ja");throw NativeDBError.message("FAIL unconfigured invite")}catch NativeUserAdministrationError.message(let e){try check(e.contains("not configured"),"invite configuration rejection")}
        try check(try db.page("Users",fields:[]).total==beforeInvite,"unconfigured no new user")
        let stale=NativeUserAdministration(service:admin)
        _ = try db.update(row("Users",id(1)),changes:["banned":.integer(1)],actor:id(5))
        try rejects("banned admin"){_ = try stale.detail(id(4))}
        _ = try db.update(row("Users",id(1)),changes:["banned":.integer(0),"role":.text("user")],actor:id(5))
        try rejects("current admin revoked"){_ = try stale.setRole(id(4),role:"admin")}
        let implicit=(reference["implicitSetNull"] as! [[String]]).map{$0.joined(separator:".")}.sorted()
        let actual=NativeDatabase.administrativeUserSetNullReferences.map{$0.0+"."+$0.1}.sorted()
        try check(implicit==actual,"all schema optional FK defaults covered")
        let authDB=try database("await-authority");try seed(authDB,initial)
        let authService=try svc(authDB,id(1))
        let changingGateway=NativeUserAdministrationMailGateway(applicationName:"NextCRM",applicationURL:"https://fixture.invalid/login",from:"crm@fixture.invalid",isConfigured:true,send:{_ in
            let current=try authDB.get("Users",key:["id":.text(id(1))])!
            _ = try authDB.update(current,changes:["role":.text("user")],actor:id(5))
        })
        do {_ = try await NativeUserAdministration(service:authService,mail:changingGateway).activate(id(6));throw NativeDBError.message("FAIL authority after await")}
        catch NativeUserAdministrationError.message(let error){try check(error=="ログインが必要です","mail completion reauth")}
        try check(try authDB.get("Users",key:["id":.text(id(6))])?["userStatus"] == .text("ACTIVE"),"committed activation retained after authority loss")
        let auditText=try json(authDB.history(authDB.get("Users",key:["id":.text(id(6))])!).map{$0.mapValues(\.json)})
        try check(!auditText.contains("must-not-leak") && !auditText.contains("browser-must-not-leak"),"native audit hides credentials")
        try check(scenarios.count==52,"all source scenarios executed")
    }
}
