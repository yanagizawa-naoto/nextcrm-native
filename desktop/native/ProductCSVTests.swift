import Foundation
import SQLite3

@main enum ProductCSVTests {
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("ProductCSVTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CSV-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity)
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
        func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
        func file(_ string: String,_ encoding: String.Encoding = .utf8) throws -> URL { let url = folder.appendingPathComponent(UUID().uuidString+".csv"); try string.write(to:url,atomically:true,encoding:encoding); return url }
        func parse(_ string: String) throws -> [[String]] { let reader = try ProductCSVReader(url:file(string),encoding:.utf8); var rows: [[String]] = []; while let row = try reader.next() { rows.append(row) }; return rows }
        try check(try parse("a,b,\r\n1,2,\r\n") == [["a","b",""],["1","2",""]],"CRLF and trailing columns")
        try check(try parse("a,b,\n1,2,") == [["a","b",""],["1","2",""]],"EOF trailing comma")
        try check(try parse("\u{feff}\"a\",b\n\"日本語,引用\"\"\n次行\",x\n") == [["a","b"],["日本語,引用\"\n次行","x"]],"BOM quoted header and multiline quotes")
        try check(try parse("\n\r\na,b\rc,d\r\n") == [["a","b"],["c","d"]],"blank rows and CR")
        try check(try parse("\"a\"") == [["a"]],"quoted EOF")
        let long = String(repeating:"日",count:6000)
        try check(try parse("\""+long+"\",end")[0] == [long,"end"],"UTF8 spanning 16 KiB buffer")
        for malformed in ["a,\"not closed","\"a\"x,b","un\"quoted,b",String(repeating:"x",count:1_048_577),Array(repeating:"a",count:65).joined(separator:",")] { try rejects("malformed CSV") { _ = try parse(malformed) } }
        let header = CRMService.productCSVColumns.joined(separator:",")+"\n"
        func row(_ name: String,_ sku: String,_ category: String = "Support",_ price: String = "123.45",_ tax: String = "10",_ recurring: String = "false",_ period: String = "") -> String {
            [name,sku,"service",category,"メモ",price,"50","jpy",tax,"件",recurring,period].joined(separator:",")+"\n"
        }
        let category = try db.insert("crm_ProductCategories",values:["name":.text("Support"),"isActive":.integer(1)],actor:identity.id)
        _ = try db.insert("crm_ProductCategories",values:["name":.text("Inactive"),"isActive":.integer(0)],actor:identity.id)
        let mixed = try file(header+row("日本語導入","UTF-1","support")+row("欠落カテゴリ","BAD-CAT","Missing")+row("税率超過","BAD-TAX","Support","1","100.01")+row("周期不足","BAD-PERIOD","Support","1","10","true")+row("継続","UTF-2","Support","9999999999999999.99","10","true","MONTHLY"))
        let preview = try service.previewProductsCSV(url:mixed,encoding:.utf8)
        try check(preview.count == 5 && preview.rows.count == 5,"preview count and first five")
        try check(try db.page("crm_Products",fields:[]).total == 0,"preview cannot save")
        let imported = try service.importProductsCSV(url:mixed,encoding:.utf8)
        try check(imported.imported == 2 && imported.skipped == 3 && imported.errors[0].hasPrefix("3行目"),"partial valid import and row errors")
        let product = try db.page("crm_Products",fields:["name","status","categoryId","unit_price","billing_period"],equal:["sku":.text("UTF-1")]).rows[0]
        try check(product["name"] == .text("日本語導入") && product["status"] == .text("DRAFT") && product["categoryId"] == category["id"] && product["unit_price"] == .text("123.45") && product["billing_period"] == .null,"exact draft/category/default fields")
        let duplicate = try service.importProductsCSV(url:file(header+row("既存","utf-1")+row("新規","SAME")+row("重複","same")+row("無効","RETRY","Inactive")+row("有効","retry")),encoding:.utf8)
        try check(duplicate.imported == 2 && duplicate.skipped == 3,"case insensitive duplicates; invalid row does not reserve SKU")
        let deleted = try db.get(product.model,key:["id":product["id"]])!; _ = try db.setDeleted(deleted,deleted:true,actor:identity.id)
        try check(try service.importProductsCSV(url:file(header+row("削除済","UtF-1")),encoding:.utf8).skipped == 1,"deleted SKU also reserved")
        let sjis = try file(header+row("日本語サービス","SJIS"),.shiftJIS)
        try check(try service.previewProductsCSV(url:sjis,encoding:.shiftJIS).rows[0]["name"] == "日本語サービス","Shift JIS preview")
        try check(try service.importProductsCSV(url:sjis,encoding:.shiftJIS).imported == 1,"Shift JIS import")
        try rejects("wrong encoding") { _ = try service.previewProductsCSV(url:sjis,encoding:.utf8) }
        for text in ["","name,type,currency\nA,SERVICE,JPY","name,name,type,unit_price,currency\nA,A,SERVICE,1,JPY",header+"a,b,c,d,e,f,g,h,i,j,k,l,m\n"] { try rejects("header/column validation") { _ = try service.importProductsCSV(url:file(text),encoding:.utf8) } }
        let invalidValues = "name,type,unit_price,currency,unit_cost,tax_rate\nA,SERVICE,1oops,JPY,,\nB,SERVICE,1,XXX,,\nC,BAD,1,JPY,,\nD,SERVICE,1,JPY,-1,\nE,SERVICE,10000000000000000,JPY,,\nF,SERVICE,1,JPY,,101\n"
        try check(try service.importProductsCSV(url:file(invalidValues),encoding:.utf8).skipped == 6,"strict numeric/type/currency/decimal storage limits")
        func count() throws -> Int { try db.page("crm_Products",fields:[],includeDeleted:true).total }
        var before = try count(); var audit = try db.auditCount("crm_Products")
        try rejects("late parse error rollback") { _ = try service.importProductsCSV(url:file(header+row("先行正常","ROLLBACK")+"\"unterminated"),encoding:.utf8) }
        try check(try count() == before && db.auditCount("crm_Products") == audit,"late parse rolls back rows and audit")
        let tooMany = header+(0...500).map { row("大量\($0)","OVER-\($0)") }.joined()
        try rejects("501 rows rejected") { _ = try service.importProductsCSV(url:file(tooMany),encoding:.utf8) }
        try check(try count() == before && db.auditCount("crm_Products") == audit,"501 rolls back valid first 500 and audit")
        try rejects("501 preview rejected") { _ = try service.previewProductsCSV(url:file(tooMany),encoding:.utf8) }
        let fiveHundred = try file(header+(0..<500).map { row("大量\($0)","MANY-\($0)") }.joined())
        try check(try service.previewProductsCSV(url:fiveHundred,encoding:.utf8).rows.count == 5,"large preview bounded")
        try check(try service.importProductsCSV(url:fiveHundred,encoding:.utf8).imported == 500,"500 permitted")
        try check(try service.importProductsCSV(url:file(header+row("ページ越し","many-499")),encoding:.utf8).skipped == 1,"SKU lookup crosses pages")
        for role in ["user","partner"] {
            let user = try db.insert("Users",values:["name":.text(role),"email":.text(role+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            let denied = CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:role,partnerAccountID:nil))
            try rejects("role denied import") { _ = try denied.importProductsCSV(url:mixed,encoding:.utf8) }
            try rejects("role denied preview") { _ = try denied.previewProductsCSV(url:mixed,encoding:.utf8) }
        }
        // Inject a real storage failure after one valid record. No partial import or audit may survive.
        var raw: OpaquePointer?; guard sqlite3_open(db.url.path,&raw) == SQLITE_OK else { throw NativeDBError.message("test DB open") }; defer { sqlite3_close(raw) }
        guard sqlite3_exec(raw,"CREATE TRIGGER fail_csv BEFORE INSERT ON crm_Products WHEN NEW.sku='FAIL-DB' BEGIN SELECT RAISE(ABORT,'injected failure'); END;",nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("test trigger") }
        before = try count(); audit = try db.auditCount("crm_Products")
        try rejects("storage failure aborts") { _ = try service.importProductsCSV(url:file(header+row("一件目","BEFORE-FAIL")+row("二件目","FAIL-DB")),encoding:.utf8) }
        try check(try count() == before && db.auditCount("crm_Products") == audit,"storage failure fully atomic")
        try check(try db.integrityCheck(),"integrity and foreign keys")
        print("{\"ok\":true,\"suite\":\"ProductCSV\",\"checks\":\(checks)}")
    }
}
