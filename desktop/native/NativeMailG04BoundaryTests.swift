import Foundation
import AppKit
import CryptoKit
final class G04Secrets:NativeMailSecretStore { var values:[String:Data]=[:]; func load(id:String,interactive:Bool)throws->Data?{values[id]};func save(id:String,data:Data)throws{values[id]=data};func remove(id:String)throws{values.removeValue(forKey:id)} }
actor G04Sender { var counts:[Int]=[];func send(_ request:NativeMailWireRequest) { counts.append(request.recipients.count) } }
final class G04Completion: @unchecked Sendable {let lock=NSLock();var value:Result<[Int],Error>?;func store(_ result:Result<[Int],Error>){lock.lock();value=result;lock.unlock()};func load()->Result<[Int],Error>?{lock.lock();defer{lock.unlock()};return value}}
@main enum G04Tests {
 static func main() throws {
  _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
  var checks=0
  func check(_ value:Bool,_ name:String)throws{guard value else{throw NativeDBError.message(name)};checks += 1}
  let native=URL(fileURLWithPath:CommandLine.arguments[1]), output=URL(fileURLWithPath:CommandLine.arguments[2]); let ref=try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("source-reference.json"))) as! [String:Any]
  var result:[String:Any]=[:], mime:[[String:Any]]=[]
  for c in ref["mime"] as! [[String:Any]] { var r:[String:Any]=["name":c["name"]!];do { let v=try NativeMailMIME.body(Data((c["raw"] as! String).utf8),recoverIncoming:true,deriveHTMLText:{try NativeMailHTMLText.convert($0)});r["text"]=v.text ?? NSNull() as Any;r["html"]=v.html ?? NSNull() as Any }catch{r["error"]=error.localizedDescription};mime.append(r) };result["mime"]=mime
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-G04-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
  let user=try db.insert("Users",values:["name":.text("検証"),"email":.text("a@example.com"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"test")
  let service=CRMService(db:db,identity:.init(id:user["id"].string,role:"admin",partnerAccountID:nil)), secrets=G04Secrets()
  let settings=NativeMailAccountSettings(label:"検証",username:"a@example.com",imap:.init(host:"imap.example.com",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.com",port:587,tls:.startTLS),sentFolder:"Sent")
  let account=try service.createMailAccount(settings,password:"synthetic",store:secrets);var recipients:[[String:Any]]=[]
  for n in [3000,4000,5000,5035,5036,6000] {
   let to=(0..<n).map{String(format:"r%05d@example.com",$0)}, summary=NativeMailSendSummary(endpoint:settings.smtp,from:settings.username,to:to,cc:[],bcc:[],subject:"s",messageID:"<test@example.com>",date:Date(timeIntervalSince1970:0),toAddresses:to.map{NativeMailAddress(email:$0)},ccAddresses:[],bccAddresses:[])
   var r:[String:Any]=["count":n,"summaryBytes":try JSONEncoder().encode(summary).count];do{let id=try service.queueMailSend(account:account,draft:.init(to:to,subject:"s",body:"body"),now:Date(timeIntervalSince1970:0));let job=try db.job(id:id)!;r["accepted"] = try service.mailSendSummary(job).to.count==n;r["mimeBytes"] = try NativeMailDelivery.payload(db:db,job:job).1.count;r["storedSummaryBytes"] = try db.mailSendPayload(id,includeMIME:false)!["summary"]!.string.utf8.count;let preview=try service.mailSendPreview(job);r["previewCount"]=preview.recipientCount;r["previewAddresses"]=preview.to.count;r["previewBytes"]=preview.recipientsText.utf8.count }catch{r["accepted"]=false;r["error"]=error.localizedDescription};recipients.append(r)
  };result["recipients"]=recipients
  try check(recipients.allSatisfy{$0["accepted"] as? Bool == true},"all valid composed recipients preserved")
  try check(recipients.allSatisfy{$0["previewAddresses"] as? Int == 3 && ($0["previewBytes"] as? Int ?? 1000)<100},"history projection bounded")
  let contact=try db.insert("crm_Contacts",values:["last_name":.text("確認"),"email":.text("person@bücher.de")],actor:user["id"].string)
  var legacy:[[String:Any]]=[]
  for address in ["person@xn--bcher-kva.de","person@bücher.de"] {
   let mail=try db.insert("Email",values:["emailAccountId":account["id"],"userId":user["id"],"rfcMessageId":.text("<"+UUID().uuidString+"@test>"),"folder":.text("INBOX"),"fromEmail":.text(address),"toRecipients":.text("[]"),"ccRecipients":.text("[]"),"bccRecipients":.text("[]")],actor:user["id"].string)
   legacy.append(["stored":address,"linked":try service.linkMailToCRM(mail)])
  }
  result["legacy"]=legacy;try check(legacy[0]["linked"] as? Int == 0 && legacy[1]["linked"] as? Int == 1,"old raw A-label requires explicit repair; Unicode links")
  try check(NativeMailMIME.addresses("person@xn--bcher-kva.de").first?.email == contact["email"].string,"current ingress produces Unicode")
  var bounds:[[String:Any]]=[]
  for c in ref["bounds"] as! [[String:Any]] {
   var r=c;let kind=c["kind"] as! String;var raw=""
   if kind=="header"{raw="X-Test: "+String(repeating:"x",count:(c["bytes"] as! Int)-8)+"\r\n\r\nbody"}
   if kind=="parts"{raw="Content-Type: multipart/mixed; boundary=x\r\n\r\n"+String(repeating:"--x\r\nContent-Type: text/plain\r\n\r\na\r\n",count:c["count"] as! Int)+"--x--\r\n"}
   if kind=="depth"{raw="Content-Type: text/plain\r\n\r\nx";for i in 0..<(c["depth"] as! Int){raw="Content-Type: multipart/mixed; boundary=b\(i)\r\n\r\n--b\(i)\r\n"+raw+"\r\n--b\(i)--\r\n"}}
   do{let b=try NativeMailMIME.body(Data(raw.utf8),recoverIncoming:true,deriveHTMLText:{try NativeMailHTMLText.convert($0)});r["nativeAccepted"]=true;r["nativeTextBytes"]=b.text?.utf8.count ?? 0}catch{r["nativeAccepted"]=false;r["nativeError"]=error.localizedDescription};bounds.append(r)
  };result["bounds"]=bounds
  // New tolerant ingress does not change frozen outbound payload reconstruction.
  let outgoing=try NativeMailMIME.outgoing(from:"a@example.com",to:["b@example.com"],subject:"s",body:"一行\n二行",messageID:"<test@example.com>")
  try check(try NativeMailMIME.body(outgoing).text == "一行\r\n二行","outbound strict decoder unchanged")
  do{_ = try NativeMailMIME.body(Data("Content-Transfer-Encoding: base64\r\n\r\n%%%".utf8));throw NativeDBError.message("strict accepted malformed") }catch NativeMailFailure.malformed{checks += 1}
  let sender=G04Sender(),worker=NativeMailSendWorker(db:db,store:secrets,send:{await sender.send($0)}),completion=G04Completion()
  let count=recipients.count
  let task=Task.detached {do{for _ in 0..<count{guard try await worker.runNext() else{throw NativeDBError.conflict}};completion.store(.success(await sender.counts))}catch{completion.store(.failure(error))}}
  let workerDeadline=Date().addingTimeInterval(10)
  while completion.load()==nil && Date()<workerDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
  guard let completed=completion.load() else{task.cancel();throw NativeDBError.message("fake worker timeout")}
  let sentCounts=try completed.get();try check(sentCounts.sorted()==[3000,4000,5000,5035,5036,6000],"no recipient omitted by native delivery")
  let jobs=try service.mailSendJobs(account["id"].string);try check(jobs.allSatisfy{$0.status=="done"},"fake accepted copies are committed")
  for job in jobs {try check(try service.mailSendSummary(job).to.count >= 3000 && service.mailSendBody(job)=="body","terminal metadata remains and lazy body uses saved Email")}
  result["fakeTransportRecipientCounts"]=sentCounts
  let history=try NativeMailHistoryWindow(service:service,accountID:account["id"].string)
  func descendants(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(descendants)}
  let views=descendants(history.window.contentView!),table=views.compactMap{$0 as? NSTableView}.first!,detail=views.compactMap{$0 as? NSTextView}.first!
  let deadline=Date().addingTimeInterval(5);while table.numberOfRows != recipients.count && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
  try check(table.numberOfRows == recipients.count,"actual history receives compact rows")
  table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
  let detailDeadline=Date().addingTimeInterval(5);while !detail.string.contains("r05999@example.com") && Date()<detailDeadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
  try check(detail.string.contains("r05999@example.com") && detail.string.contains("body"),"selected detail loads full 6000 recipients")
  let close=views.compactMap{$0 as? NSButton}.first{$0.title=="閉じる"}!;close.performClick(nil);RunLoop.current.run(until:Date().addingTimeInterval(0.05));try check(detail.string.isEmpty,"close invalidates selected detail")
  history.window.orderOut(nil)
  let firstJob=try service.mailSendJobs(account["id"].string).first!
  _ = try db.update(user,changes:["userStatus":.text("INACTIVE")],actor:"test")
  do{_ = try service.mailSendPreview(firstJob);throw NativeDBError.message("revoked history accepted") }catch NativeDBError.message(let message){try check(message != "revoked history accepted","history checks fresh authority")}
  result["checks"]=checks
  func padded(_ base:[String:Any],_ bytes:Int)throws->Data{var b=base;b["padding"]="";let raw=try JSONSerialization.data(withJSONObject:b,options:[.sortedKeys,.withoutEscapingSlashes]);b["padding"]=String(repeating:"x",count:bytes-raw.count);return try JSONSerialization.data(withJSONObject:b,options:[.sortedKeys,.withoutEscapingSlashes])}
  var calendar:[[String:Any]]=[]
  for bytes in [1048575,1048576,1048577] {
   var r:[String:Any]=["bytes":bytes];let google=try padded(["id":"g","summary":"Meeting","start":["dateTime":"2026-01-01T00:00:00Z"],"attendees":[["email":"outside@example.net"]]],bytes)
   do{if case .event = try NativeCalendarEvents.normalizeGoogle(google,connectionID:"c",accountEmail:"self@example.com"){r["googleAccepted"]=true}else{r["googleAccepted"]=false}}catch{r["googleAccepted"]=false;r["googleError"]=error.localizedDescription}
   let body=try padded(["event":"invitee.created","payload":["uri":"c","email":"outside@example.net","scheduled_event":["name":"Meeting","start_time":"2026-01-01T00:00:00Z"]]],bytes), stamp="1795000000";let signature=HMAC<SHA256>.authenticationCode(for:Data((stamp+".").utf8)+body,using:SymmetricKey(data:Data("synthetic".utf8))).map{String(format:"%02x",$0)}.joined()
   do{if case .event = try CalendlyWebhook.receive(body,signature:"t=\(stamp),v1=\(signature)",key:"synthetic",receivedAt:Date(timeIntervalSince1970:1795000000)){r["calendlyAccepted"]=true}else{r["calendlyAccepted"]=false}}catch{r["calendlyAccepted"]=false;r["calendlyError"]=error.localizedDescription};calendar.append(r)
  };result["calendar"]=calendar
  try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("native-result.json"));print("G04 isolated MIME/SQLite/calendar fixture finished")
 }
}
