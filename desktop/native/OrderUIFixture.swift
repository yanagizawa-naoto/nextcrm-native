import Foundation

/// Explicitly restricted to the isolated GUI verification database, never normal user data.
@main enum OrderUIFixture {
    static func main() {
        do {
            let resources = URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
            let folder = URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL
            guard folder.resolvingSymlinksInPath() == resources.appendingPathComponent("../artifacts/native-crm-ui-data").standardizedFileURL.resolvingSymlinksInPath() else { throw NativeDBError.message("検証専用の保存先を指定してください。") }
            let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
            let output = try db.transaction { () -> [[String:String]] in
                let email = "order-approval-ui@example.invalid"
                guard try db.page("Users",fields:[],equal:["email":.text(email)]).total == 0 else { throw NativeDBError.message("受注UI検証データは作成済みです。") }
                let user = try db.insert("Users",values:["name":.text("受注承認の確認担当"),"email":.text(email),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
                let account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("受注承認UI検証株式会社"),"assigned_to":user["id"]],actor:identity.id)
                guard let product = try db.page("crm_Products",fields:[],equal:["sku":.text("JP-CRM-SETUP"),"status":.text("ACTIVE")]).rows.first else { throw NativeDBError.message("検証用の有効商品がありません。") }
                let service = CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:"user",partnerAccountID:nil))
                return try [1,103].map { count in
                    let order = try service.saveOrder(original:nil,accountID:account["id"].string,header:["note":.text(count == 1 ? "UI承認の確認" : "UI却下・103件ページングの確認")],lines:{ offset in
                        (0..<max(0,min(100,count-offset))).map { _ in OrderLineInput(productID:product["id"].string,quantity:"1",unitPrice:"1.01") }
                    },submit:true)
                    guard order["status"] == .text("PENDING_APPROVAL") else { throw NativeDBError.message("承認待ちになりませんでした。") }
                    return ["id":order["id"].string,"number":order["number"].string,"lines":String(count),"total":order["grandTotal"].string]
                }
            }
            print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
        } catch { FileHandle.standardError.write(Data("OrderUIFixture: \(error)\n".utf8)); exit(1) }
    }
}
