import Foundation
@main enum InvoicePDFTransactionTests {
 static var checks=0
 static func check(_ value:@autoclosure () throws->Bool,_ label:String)throws{guard try value()else{throw NativeDBError.message(label)};checks+=1}
 static func main(){do{try run();try InvoicePDFTests.run()}catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}}
 static func run()throws{
  let n=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("InvoicePDFRollback-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql")),actor=try CRMService.bootstrap(db,resources:n.appendingPathComponent("../../prisma")),s=CRMService(db:db,identity:actor)
  let a=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("合成請求先")],actor:actor.id)
  let series=try s.saveInvoiceSeries(original:nil,input:["name":.text("検証"),"prefixTemplate":.text("TEST-{YYYY}-{####}")])
  _=try s.saveInvoiceSettings(original:nil,input:["companyName":.text("合成会社"),"companyAddress":.text("検証住所"),"companyCity":.text("東京"),"companyZip":.text("1000000"),"companyCountry":.text("日本"),"companyRegNo":.text("1234567890123"),"defaultDueDays":.integer(30),"baseCurrency":.text("JPY"),"defaultSeriesId":series["id"]])
  let draft=try s.saveInvoice(original:nil,header:["accountId":a["id"],"currency":.text("JPY")],lines:{offset in offset>0 ? []:[InvoiceLineInput(productID:nil,description:"合成明細",quantity:"1",unitPrice:"100",discountPercent:"0",taxRateID:nil)]})
  let issued=try s.issueInvoice(draft,now:Date()),original=try s.generateInvoicePDF(issued),oldURL=try s.invoicePDFURL(original),oldBytes=try Data(contentsOf:oldURL)
  var newURL:URL?;var caught=false;var retainedDuringTransaction=false
  do{try db.transaction{let next=try s.generateInvoicePDF(original);newURL=try s.invoicePDFURL(next);retainedDuringTransaction=FileManager.default.fileExists(atPath:oldURL.path);throw NativeDBError.conflict}}catch{caught=true}
  let current=try db.get("Invoices",key:["id":original["id"]])!
  let restored=current["pdfStorageKey"]==original["pdfStorageKey"],oldExists=FileManager.default.fileExists(atPath:oldURL.path),newExists=newURL.map{FileManager.default.fileExists(atPath:$0.path)} ?? false
  try check(caught && restored,"PDF metadata rollback")
  try check(oldExists && (try? Data(contentsOf:oldURL))==oldBytes,"old PDF bytes preserved")
  try check(!newExists,"uncommitted PDF removed")
  try check(retainedDuringTransaction,"old PDF retained until commit")
  var committed:NativeRecord?;var committedURL:URL?
  try db.transaction{let next=try s.generateInvoicePDF(current);committed=next;committedURL=try s.invoicePDFURL(next);try check(FileManager.default.fileExists(atPath:oldURL.path),"old PDF deleted before commit")}
  try check(try !FileManager.default.fileExists(atPath:oldURL.path) && FileManager.default.fileExists(atPath:committedURL!.path) && s.invoicePDFURL(committed!)==committedURL,"PDF commit publication")
  var intermediate:[URL]=[]
  do{try db.transaction{let a=try s.generateInvoicePDF(committed!);intermediate.append(try s.invoicePDFURL(a));let b=try s.generateInvoicePDF(a);intermediate.append(try s.invoicePDFURL(b));throw NativeDBError.conflict}}catch{}
  try check(intermediate.count==2 && intermediate.allSatisfy({!FileManager.default.fileExists(atPath:$0.path)}),"both intermediate replacements removed")
  try check(try FileManager.default.fileExists(atPath:committedURL!.path) && db.get("Invoices",key:["id":original["id"]])!["pdfStorageKey"]==committed!["pdfStorageKey"],"nested replacements preserve committed PDF")
  print("{\"transactionChecks\":\(checks),\"originalCallersOuterTransaction\":false,\"network\":false}")
 }
}
