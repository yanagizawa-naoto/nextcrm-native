import Foundation

enum NativeReportMailBodyTests {
    static func run(root:URL)throws->Int {
        var checks=0
        func check(_ value:@autoclosure()throws->Bool,_ name:String)throws {guard try value()else{throw NativeDBError.message("FAIL report mail body: "+name)};checks+=1}
        func rejects(_ name:String,_ run:()throws->Void)throws {do{try run()}catch{checks+=1;return};throw NativeDBError.message("FAIL report mail body accepted: "+name)}
        let pdf=root.appendingPathComponent("添付.pdf"),csv=root.appendingPathComponent("添付.csv")
        let pdfBytes=Data("%PDF-".utf8)+Data((0..<150_001).map{UInt8($0%256)}),csvBytes=Data([0xef,0xbb,0xbf])+Data("\"項目\",\"件数\"\r\n\"日本語😀\",\"5\"\r\n".utf8)
        try pdfBytes.write(to:pdf);try csvBytes.write(to:csv)
        let text=String(repeating:"日本語😀\n\r\t\"\\\u{0}",count:6000),id=UUID().uuidString.lowercased()
        let body=try NativeReportMailBody.prepare(root:root,id:id,from:" from@example.invalid ",to:["one@example.invalid","two@example.invalid"],subject:"定期レポートの検証",message:text,attachments:[.init(filename:"売上.csv",url:csv),.init(filename:"売上.pdf",url:pdf)])
        let bytes=try Data(contentsOf:body.url),json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any],attachments=json["attachments"] as! [[String:String]]
        try check(json["text"] as? String==text,"streamed escaped text roundtrip")
        try check(json["to"] as? [String]==["one@example.invalid","two@example.invalid"],"all recipients")
        try check(json["from"] as? String=="from@example.invalid" && json["subject"] as? String=="定期レポートの検証","Japanese subject and sender")
        try check(attachments.count==2 && attachments.map{$0["filename"]!}==["売上.csv","売上.pdf"],"both attachments named")
        try check(Data(base64Encoded:attachments[0]["content"]!)==csvBytes && Data(base64Encoded:attachments[1]["content"]!)==pdfBytes,"base64 across chunk and trailing-byte boundaries")
        try check(body.bytes==bytes.count,"exact byte count")
        try InvoiceMail.verify(body.url,sha256:body.sha256,bytes:body.bytes);checks+=1
        let permissions=try FileManager.default.attributesOfItem(atPath:body.url.path)[.posixPermissions] as! NSNumber
        try check(permissions.intValue==0o600,"private staging body")
        try rejects("cannot replace existing frozen body"){_ = try NativeReportMailBody.prepare(root:root,id:id,from:"from@example.invalid",to:["one@example.invalid"],subject:"新規",message:"違う本文",attachments:[.init(filename:"売上.csv",url:csv)])}
        try check(try Data(contentsOf:body.url)==bytes,"existing body preserved")
        let linked=root.appendingPathComponent("linked.pdf");try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:pdf)
        for item in [NativeReportMailAttachment(filename:"linked.pdf",url:linked),.init(filename:"../invalid.csv",url:csv)] {
            let next=UUID().uuidString.lowercased()
            try rejects("invalid attachment"){_ = try NativeReportMailBody.prepare(root:root,id:next,from:"from@example.invalid",to:["one@example.invalid"],subject:"検証",message:"本文",attachments:[item])}
            try check(try !FileManager.default.fileExists(atPath:InvoiceMail.bodyURL(root:root,id:next).path),"failed preparation removes partial body")
        }
        let huge=root.appendingPathComponent("huge.pdf");FileManager.default.createFile(atPath:huge.path,contents:Data());let handle=try FileHandle(forWritingTo:huge);try handle.truncate(atOffset:31_000_000);try handle.close()
        let next=UUID().uuidString.lowercased()
        try rejects("oversized sparse attachment preflight"){_ = try NativeReportMailBody.prepare(root:root,id:next,from:"from@example.invalid",to:["one@example.invalid"],subject:"検証",message:"本文",attachments:[.init(filename:"huge.pdf",url:huge)])}
        try check(try !FileManager.default.fileExists(atPath:InvoiceMail.bodyURL(root:root,id:next).path),"oversize failure cleanup")
        for control in ["\r\n","\r","\n","\u{0}"] {
            try rejects("header injection"){_ = try NativeReportMailBody.prepare(root:root,id:UUID().uuidString,from:"from@example.invalid",to:["one@example.invalid"],subject:"検証"+control+"Bcc:bad",message:"本文",attachments:[.init(filename:"売上.csv",url:csv)])}
        }
        return checks
    }
}
