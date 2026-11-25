import Foundation
import CryptoKit
import Darwin
final class HTMLStoreSecrets:NativeMailSecretStore{var values:[String:Data]=[:];func load(id:String,interactive:Bool)throws->Data?{values[id]};func save(id:String,data:Data)throws{values[id]=data};func remove(id:String)throws{values.removeValue(forKey:id)}}
@main enum StoreTests {
 static func residentBytes()->UInt64 {
  var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
  let status=withUnsafeMutablePointer(to:&info){pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
  return status==KERN_SUCCESS ? UInt64(info.resident_size):0
 }
 static func digest(_ text:String)->String{SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
 static func reply(_ raw:Data,uid:UInt32=1)->NativeMailReply{let body=Data("* 1 FETCH (UID \(uid) BODY[] {\(raw.count)}\r\n".utf8)+raw+Data(")\r\nNCRM2 OK fetched\r\n".utf8);return .init(body:body,protocolHeaders:Data("* OK [UIDVALIDITY 1] selected\r\n".utf8),serverCode:200,responseBytes:body.count)}
 static func main()throws {
  let n=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments.last!,root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-HTMLStore-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  var checks=0;func check(_ value:Bool,_ name:String)throws{guard value else{throw NativeDBError.message(name)};checks += 1}
  let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql")),secrets=HTMLStoreSecrets()
  let user=try db.insert("Users",values:["name":.text("HTML本文検証"),"email":.text("self@example.com"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"test"),service=CRMService(db:db,identity:.init(id:user["id"].string,role:"admin",partnerAccountID:nil))
  let settings=NativeMailAccountSettings(label:"隔離検証",username:"self@example.com",imap:.init(host:"imap.example.com",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.com",port:587,tls:.startTLS),sentFolder:"Sent"),account=try service.createMailAccount(settings,password:"synthetic",store:secrets)
  func email(_ uid:UInt32)throws->NativeRecord{let headers=try NativeMailMIME.headers(Data("From: person@example.net\r\nTo: self@example.com\r\nSubject: HTML\r\nMessage-ID: <\(uid)@example.net>\r\n".utf8));let id=try service.importMailHeaders(account:account,folder:.inbox,uidValidity:1,headers:[.init(uid:uid,seen:false,headers:headers)]).first!;return try service.mailMessage(id)}
  if mode.hasPrefix("--large") {
   let beforeResident=residentBytes()
   var result=try autoreleasepool { ()throws->[String:Any] in
   let total=mode=="--large-limit" ? 8_388_608:4_718_592,block="0123456789012345678901234567890123456789 ";let count=(total-7)/block.utf8.count
   let html="<p>"+String(repeating:block,count:count)+String(repeating:"t",count:total-7-count*block.utf8.count)+"</p>",raw=Data(("Content-Type: text/html; charset=utf-8\r\n\r\n"+html).utf8),wire=reply(raw)
   let body:NativeMailBody
   if mode=="--large-baseline"{body=try NativeMailMIME.body(try NativeMailIMAP.fetchedBody(wire.body,expected:1)!,recoverIncoming:true)}else{body=try NativeMailClient.decodeBodyReply(wire,validity:1,uid:1)!}
   let row=try email(1),saved=try service.saveMailBody(row,location:service.mailLocation(row)!,body:body)
   try check(saved["bodyHtml"].string==html,"large original HTML exact")
   if mode != "--large-baseline"{try check(saved["bodyText"].string.utf8.count+saved["bodyHtml"].string.utf8.count>NativeMailMIME.maximumTextBytes,"combined former bound exceeded without truncating");try check(saved["bodyText"].string==body.text,"large derived body exact")}
   let result:[String:Any]=["mode":mode,"checks":checks,"htmlBytes":saved["bodyHtml"].string.utf8.count,"textBytes":saved["bodyText"] == .null ? 0:saved["bodyText"].string.utf8.count,"htmlSHA256":digest(saved["bodyHtml"].string),"textSHA256":digest(saved["bodyText"] == .null ? "":saved["bodyText"].string)]
   return result
   }
   result["beforeInputRSSBytes"]=beforeResident;result["afterReleaseRSSBytes"]=residentBytes()
   try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent(mode.dropFirst(2)+".json"));print("large storage \(checks) checks");return
  }
  let ref=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("source-reference.json"))) as! [String:Any]
  var index:UInt32=1
  for c in ref["cases"] as! [[String:Any]] {
   let html=c["html"] as! String,body=try NativeMailClient.decodeBodyReply(reply(Data(("Content-Type: text/html; charset=utf-8\r\n\r\n"+html).utf8),uid:index),validity:1,uid:index)!,row=try email(index);index += 1
   let saved=try service.saveMailBody(row,location:service.mailLocation(row)!,body:body),expected=(c["text"] as? String).flatMap{$0.isEmpty ? nil:$0}
   try check(saved["bodyText"] == expected.map(SQLValue.text) ?? .null,"derived text persisted \(c["name"]!)")
   try check(saved["bodyHtml"] == (c["normalizedHTML"] as? String).flatMap{$0.isEmpty ? nil:$0}.map(SQLValue.text) ?? .null,"original HTML retained \(c["name"]!)")
   try check(try service.mailBodyIsLoaded(saved),"body loaded marker")
  }
  let exact=try email(index),location=try service.mailLocation(exact)!,maximum=NativeMailMIME.maximumTextBytes
  let text=String(repeating:"x",count:maximum),html=String(repeating:"y",count:maximum)
  let saved=try service.saveMailBody(exact,location:location,body:.init(text:text,html:html));try check(saved["bodyText"].string.utf8.count==maximum && saved["bodyHtml"].string.utf8.count==maximum,"per-field exact limits retained")
  for (offset,size) in [maximum-1,maximum,maximum+1].enumerated() {
   let row=try email(index+UInt32(offset)+1),value=String(repeating:"z",count:size),saved=try service.saveMailBody(row,location:service.mailLocation(row)!,body:.init(text:value,html:"<p>kept</p>"))
   try check(saved["bodyText"].string.utf8.count==size,"former field boundary preserves full text")
   try check(saved["bodyHtml"].string=="<p>kept</p>","former field boundary preserves HTML")
  }
  let expandedHTML=String(repeating:"<hr>",count:102301),expanded=try NativeMailClient.decodeBodyReply(reply(Data(("Content-Type: text/html\r\n\r\n"+expandedHTML).utf8),uid:index+4),validity:1,uid:index+4)!,expandedRow=try email(index+4)
  let expandedSaved=try service.saveMailBody(expandedRow,location:service.mailLocation(expandedRow)!,body:expanded)
  try check(expandedSaved["bodyHtml"].string==expandedHTML,"expanding formatter cannot erase prior accepted HTML")
  try check(expandedSaved["bodyText"].string.utf8.count==8388680,"expanded text passes former field cap without truncation")
  try JSONSerialization.data(withJSONObject:["textBytes":expandedSaved["bodyText"].string.utf8.count,"textSHA256":digest(expandedSaved["bodyText"].string),"htmlBytes":expandedHTML.utf8.count,"htmlSHA256":digest(expandedHTML)],options:[.sortedKeys]).write(to:out.appendingPathComponent("expansion-result.json"))
  print("Receive/store assertions: \(checks)");try JSONSerialization.data(withJSONObject:["checks":checks,"sourceCases":(ref["cases"] as! [Any]).count],options:[.sortedKeys]).write(to:out.appendingPathComponent("store-result.json"))
 }
}
