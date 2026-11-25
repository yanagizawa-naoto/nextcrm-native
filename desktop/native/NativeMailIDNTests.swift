import Foundation
enum NativeMailIDNParseTests {
    struct Fixture: Decodable { struct Case: Decodable { let name:String,input:String,expected:String,expectedFromName:String,raw:String }; let cases:[Case] }
    static func run(reference:URL) throws {
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:reference))
        var checks=0,differences:[[String:String]]=[]
        func check(_ a:String,_ e:String,_ name:String) {checks+=1;if !a.utf16.elementsEqual(e.utf16){differences.append(["name":name,"actual":a,"expected":e])}}
        for item in fixture.cases {
            let headers = try NativeMailMIME.headers(Data(item.raw.utf8))
            for key in ["from","to","cc"] {check(NativeMailMIME.addresses(headers[key]).first?.email ?? "",item.expected,item.name+"/"+key)}
            check(NativeMailMIME.addresses(headers["from"]).first?.name ?? "",item.expectedFromName,item.name+"/name")
            check(try NativeMailAddress.checked(item.input).email,item.input,item.name+"/composer-keeps-spelling")
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"differences":differences,"differenceCount":differences.count],options:[.sortedKeys]),as:UTF8.self))
        if !differences.isEmpty {exit(1)}
    }
}

import Foundation

enum NativeMailIDNCRMTests {
    struct Fixture:Decodable {struct Case:Decodable {let name:String,raw:String,expected:String,crmAddress:String;let linked:Int};let cases:[Case]}
    static func run(resources:URL,reference:URL) throws {
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:reference))
        var checks=0,differences:[String]=[]
        func check(_ value:Bool,_ name:String){checks+=1;if !value{differences.append(name)}}
        for sample in fixture.cases {
            let f=try MailSyncFixture(resources:resources)
            func target(_ model:String,_ email:String,_ owner:NativeRecord) throws -> NativeRecord {
                var values:[String:SQLValue] = ["email":.text(email),"assigned_to":owner["id"],"createdBy":owner["id"]]
                if model == "crm_Contacts" {values["first_name"] = .text("連絡先"); values["last_name"] = .text("照合")}
                else {values["name"] = .text("取引先");values["v"] = .integer(0)}
                return try f.db.insert(model,values:values,actor:owner["id"].string)
            }
            let contact=try target("crm_Contacts",sample.crmAddress,f.owner),account=try target("crm_Accounts",sample.crmAddress,f.owner)
            let hidden=try target("crm_Contacts",sample.crmAddress,f.stranger),bcc=try target("crm_Contacts","secret@例え.テスト",f.owner)
            let ids=try f.service.importMailHeaders(account:f.account(),folder:.inbox,uidValidity:77,headers:[.init(uid:1,seen:false,headers:NativeMailMIME.headers(Data(sample.raw.utf8)))])
            let row=try f.service.mailMessage(ids[0])
            check(row["fromEmail"].string.utf16.elementsEqual(sample.expected.utf16),sample.name+"/saved-from")
            check(try f.service.linkMailToCRM(row)==sample.linked,sample.name+"/original-link-count")
            check(try f.db.get("EmailsToContacts",key:["emailId":row["id"],"contactId":contact["id"]]) != nil,sample.name+"/contact")
            check(try f.db.get("EmailsToAccounts",key:["emailId":row["id"],"accountId":account["id"]]) != nil,sample.name+"/account")
            check(try f.db.get("EmailsToContacts",key:["emailId":row["id"],"contactId":hidden["id"]]) == nil,sample.name+"/scope-preserved")
            check(try f.db.get("EmailsToContacts",key:["emailId":row["id"],"contactId":bcc["id"]]) == nil,sample.name+"/bcc-excluded")
            check(try f.service.linkMailToCRM(row)==0,sample.name+"/replay-idempotent")
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["suite":"IDNCRM","checks":checks,"cases":fixture.cases.count,"differences":differences,"differenceCount":differences.count],options:[.sortedKeys]),as:UTF8.self))
        if !differences.isEmpty {throw NativeDBError.message("IDN CRM source differences")}
    }
}
