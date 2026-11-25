import Foundation
@main enum Tests {
 static func reply(_ raw:String,uid:UInt32=1,validity:UInt32=1)->NativeMailReply{let data=Data(raw.utf8);let body=Data("* 1 FETCH (UID \(uid) BODY[] {\(data.count)}\r\n".utf8)+data+Data(")\r\nNCRM2 OK fetched\r\n".utf8);return .init(body:body,protocolHeaders:Data("* OK [UIDVALIDITY \(validity)] selected\r\n".utf8),serverCode:200,responseBytes:body.count)}
 static func main()async throws {
  let dir=URL(fileURLWithPath:CommandLine.arguments[1]),ref=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("source-reference.json"))) as! [String:Any];var rows:[[String:Any]]=[],received:[[String:Any]]=[],multipart:[[String:Any]]=[]
  for c in ref["cases"] as! [[String:Any]] {
   let html=c["html"] as! String
   do{rows.append(["name":c["name"]!,"text":try NativeMailHTMLText.convert(html)])}catch{rows.append(["name":c["name"]!,"error":error.localizedDescription])}
   do{let body=try NativeMailClient.decodeBodyReply(reply("Content-Type: text/html; charset=utf-8\r\n\r\n"+html),validity:1,uid:1);received.append(["name":c["name"]!,"text":body?.text ?? NSNull() as Any,"html":body?.html ?? NSNull() as Any])}catch{received.append(["name":c["name"]!,"error":error.localizedDescription])}
  }
  for c in ref["multipart"] as! [[String:Any]] {let body=try NativeMailClient.decodeBodyReply(reply(c["raw"] as! String),validity:1,uid:1);multipart.append(["type":c["type"]!,"plain":c["plain"]!,"text":body?.text ?? NSNull() as Any,"html":body?.html ?? NSNull() as Any])}
  var checks=0
  func rejects(_ action:()throws->Void)throws{do{try action()}catch{checks += 1;return};throw NativeMailFailure.invalid("Expected rejection")}
  try rejects{_ = try NativeMailClient.decodeBodyReply(reply("Content-Type: text/html\r\n\r\n<p>x</p>",validity:2),validity:1,uid:1)}
  try rejects{_ = try NativeMailClient.decodeBodyReply(reply("Content-Type: text/html\r\n\r\n<p>x</p>",uid:2),validity:1,uid:1)}
  try rejects{_ = try NativeMailHTMLText.convert("<p>abcd</p>",maximumBytes:3)}
  let temp=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-HTMLCancel-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:temp)}
  let input="<ol>"+String(repeating:"<li>value</li>",count:100000)+"</ol>"
  let work=Task.detached{try NativeMailHTMLText.convert(input,temporaryRoot:temp)}
  var observed=false
  for _ in 0..<1000 {
   let all=FileManager.default.enumerator(at:temp,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
   if all.contains(where:{$0.lastPathComponent=="response"}){observed=true;break}
   try await Task.sleep(nanoseconds:1_000_000)
  }
  work.cancel()
  var wasCancelled=false;do{_ = try await work.value}catch is CancellationError{wasCancelled=true}
  guard observed,wasCancelled else{throw NativeMailFailure.invalid("Expected active spooled conversion cancellation")};checks += 2
  let leftovers=FileManager.default.enumerator(at:temp,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
  guard !leftovers.contains(where:{$0.lastPathComponent=="response" || UUID(uuidString:$0.lastPathComponent) != nil}) else{throw NativeMailFailure.invalid("Cancelled HTML list file retained")};checks += 1
  try rejects{_ = try NativeMailHTMLText.convert("<ol><li>too large</li></ol>",maximumBytes:3,temporaryRoot:temp)}
  let failureLeftovers=FileManager.default.enumerator(at:temp,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
  guard !failureLeftovers.contains(where:{UUID(uuidString:$0.lastPathComponent) != nil}) else{throw NativeMailFailure.invalid("Failed HTML list file retained")};checks += 1
  try JSONSerialization.data(withJSONObject:["pure":rows,"received":received,"multipart":multipart,"checks":checks],options:[.sortedKeys,.prettyPrinted]).write(to:dir.appendingPathComponent("native-result.json"));print("HTML finite cases: \(rows.count); receive: \(received.count); multipart: \(multipart.count)")
 }
}
