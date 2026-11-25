import Foundation
@main enum Tests {
 static func main()async throws {
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);if CommandLine.arguments.count==4{try LargeTests.run(out:out,kind:CommandLine.arguments[2],size:Int(CommandLine.arguments[3])!);return}
  let source=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("reference.json"))) as! [String:Any];var rows:[[String:Any]]=[]
  for c in source["cases"] as! [[String:Any]] {
   do {let raw=Data((c["raw"] as! String).utf8),reply=NativeMailReply(body:Data("* 1 FETCH (UID 1 BODY[] {\(raw.count)}\r\n".utf8)+raw+Data(")\r\nA OK done\r\n".utf8),protocolHeaders:Data("* OK [UIDVALIDITY 1] selected\r\n".utf8),serverCode:200,responseBytes:raw.count)
    let result=try NativeMailClient.decodeBodyReply(reply,validity:1,uid:1);let divider=raw.range(of:Data("\r\n\r\n".utf8))!;let header=try NativeMailMIME.headers(raw[..<divider.lowerBound],allowLargeIncoming:true)
    rows.append(["name":c["name"]!,"text":result?.text as Any? ?? NSNull(),"html":result?.html as Any? ?? NSNull(),"subject":header.fields["subject"]==nil ? NSNull():header.subject as Any])
   }catch{rows.append(["name":c["name"]!,"error":error.localizedDescription])}
  }
  print("File reader checks: \(try await FileTests.run(out:out))")
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("native.json"));print("Native structure rows: \(rows.count)")
 }
}
