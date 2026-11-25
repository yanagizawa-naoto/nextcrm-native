import Foundation

@main struct NativeMailTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool,_ name: String) throws { guard value else { throw NSError(domain:"NativeMailTests",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }; checks += 1 }
        func rejects(_ name: String,_ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw NSError(domain:"NativeMailTests",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected rejection: "+name])
        }
        let native = URL(fileURLWithPath:CommandLine.arguments[1])
        let fixtures = try JSONSerialization.jsonObject(with:Data(contentsOf:native.appendingPathComponent("build/native-mail-transport-verification.json"))) as! [String:Any]
        let samples = fixtures["syntheticProtocolSamples"] as! [String:[String:Any]]
        func sample(_ name:String,_ field:String) -> Data { Data((samples[name]![field] as! String).utf8) }
        struct AddressReference:Decodable { struct Sample:Decodable { let input:String, mime:String; let expected:[NativeMailAddress] }; let samples:[Sample] }
        let reference = try JSONDecoder().decode(AddressReference.self,from:Data(contentsOf:native.appendingPathComponent("build/native-mail-address-reference.json")))
        func domainCase(_ values:[NativeMailAddress]) -> [NativeMailAddress] {
            values.map { value in
                guard let at = value.email.lastIndex(of:"@") else { return value }
                return .init(email:String(value.email[...at])+value.email[value.email.index(after:at)...].lowercased(),name:value.name)
            }
        }
        for item in reference.samples {
            let headers = try NativeMailMIME.headers(Data(base64Encoded:item.mime)!)
            try check(NativeMailMIME.addresses(headers["to"]) == item.expected,"incoming matches original Nodemailer/mailparser: "+item.input)
            try check(try domainCase(NativeMailAddress.list([item.input])) == domainCase(item.expected),"composer matches original mailboxes/names ignoring domain letter case: "+item.input)
        }

        let japanese = "~peter/mail/台北/日本語"
        try check(try NativeMailUTF7.encode(japanese) == "~peter/mail/&U,BTFw-/&ZeVnLIqe-","RFC3501 modified UTF7 example")
        try check(try NativeMailUTF7.decode("~peter/mail/&U,BTFw-/&ZeVnLIqe-") == japanese,"RFC3501 modified UTF7 decoding")
        try check(try NativeMailUTF7.decode("A&-B") == "A&B","literal ampersand")
        for name in ["受信トレイ","送信済み","顧客/😀","a\"b\\c&d"] { try check(try NativeMailUTF7.decode(NativeMailUTF7.encode(name)) == name,"folder round trip "+name) }
        try rejects("folder newline") { _ = try NativeMailUTF7.encode("INBOX\r\nDELETE other") }
        try rejects("unterminated modified UTF7") { _ = try NativeMailUTF7.decode("&ZeVnLIqe") }
        try rejects("invalid UTF16 in folder") { _ = try NativeMailUTF7.decode("&AA-") }
        try check(try NativeMailIMAP.quotedMailbox("a\"b\\c") == "\"a\\\"b\\\\c\"","quoted folder commands")
        let endpoint = NativeMailEndpoint(host:"mail.example.test",port:993,tls:.implicitTLS)
        try endpoint.validate(smtp:false)
        try check(try endpoint.url(smtp:false,mailbox:"a/;UID=42") == "imaps://mail.example.test:993/a%2F%3BUID%3D42","folder cannot inject URL parameters")
        try check(try NativeMailEndpoint(host:"::1",port:143,tls:.plain).url(smtp:false)=="imap://[::1]:143/","IPv6 literal URL syntax")
        try NativeMailEndpoint(host:"mail.example.test",port:1993,tls:.implicitTLS).validate(smtp:false)
        try NativeMailEndpoint(host:"mail.example.test",port:2587,tls:.startTLS).validate(smtp:true)
        try check(true,"custom mail ports retain original account compatibility")
        try rejects("out-of-range port") { try NativeMailEndpoint(host:"mail.example.test",port:65536,tls:.implicitTLS).validate(smtp:false) }

        let status = try NativeMailIMAP.status(sample("status","body"),mailbox:"INBOX")
        try check(status.validity==77 && status.next==3,"real libcurl STATUS response")
        try check(try NativeMailIMAP.searchUIDs(sample("search","body"),after:0) == [1,2],"real libcurl UID SEARCH response")
        try check(try NativeMailIMAP.searchUIDs(Data("* SEARCH 2 2 1\r\n".utf8),after:1) == [2],"deduplicate and reject backward UID range")
        try check(try NativeMailIMAP.selectedValidity(sample("fetch","headers")) == 77,"actual SELECT generation")
        let headers = try NativeMailIMAP.fetchedHeaders(sample("fetch","body"),expected:[1])
        try check(headers.count==1 && headers[0].uid==1 && headers[0].seen && headers[0].headers.subject=="日本語","actual custom FETCH literal and flags")
        try check(headers[0].headers.messageID == "<fixture-1@test>","stable incoming RFC ID")
        try rejects("unrequested UID") { _ = try NativeMailIMAP.fetchedHeaders(sample("fetch","body"),expected:[2]) }
        try rejects("duplicate FETCH UID") { _ = try NativeMailIMAP.fetchedHeaders(sample("fetch","body")+sample("fetch","body"),expected:[1]) }
        try rejects("duplicate UIDVALIDITY") { _ = try NativeMailIMAP.selectedValidity(sample("fetch","headers")+sample("fetch","headers")) }
        try rejects("wrong STATUS mailbox") { _ = try NativeMailIMAP.status(sample("status","body"),mailbox:"Sent") }
        try rejects("zero UIDVALIDITY") { _ = try NativeMailIMAP.status(Data("* STATUS INBOX (UIDVALIDITY 0 UIDNEXT 1)\r\n".utf8),mailbox:"INBOX") }
        for malformed in ["* SEARCH -1\r\n","* SEARCH 4294967296\r\n","* SEARCH 0\r\n"] { try rejects("invalid UID") { _ = try NativeMailIMAP.searchUIDs(Data(malformed.utf8),after:0) } }
        try rejects("FETCH literal truncated") { _ = try NativeMailIMAP.rows(Data("* 1 FETCH (UID 1 BODY[] {200}\r\nshort)\r\n".utf8)) }
        try rejects("oversized literal length") { _ = try NativeMailIMAP.rows(Data("* 1 FETCH (BODY[] {999999999999999999}\r\n)\r\n".utf8)) }
        try rejects("nested reply bound") { _ = try NativeMailIMAP.rows(Data((String(repeating:"(",count:20)+String(repeating:")",count:20)).utf8)) }
        try rejects("header request page bound") { _ = try NativeMailIMAP.headerCommand(Array(1...51)) }
        try check(try NativeMailIMAP.headerCommand([1,3]).hasPrefix("UID FETCH 1,3 (UID FLAGS BODY.PEEK[HEADER.FIELDS"),"headers do not mark server mail read")
        let flags = Data("* 2 FETCH (UID 2 FLAGS (\\Seen))\r\n".utf8)
        try check(try NativeMailIMAP.fetchedHeaders(flags+sample("fetch","body"),expected:[1]).count == 1,"unsolicited flags do not break header retrieval")
        func fetched(_ body:Data,uid:UInt32 = 1,section:String = "BODY[]") -> Data {
            Data("* 1 FETCH (UID \(uid) \(section) {\(body.count)}\r\n".utf8)+body+Data(")\r\nNCRM2 OK fetched\r\n".utf8)
        }
        let literal = Data("UID\r\nNCRM2 OK fake\r\n* SEARCH 999\r\n".utf8)+Data([0,255])
        try check(try NativeMailIMAP.fetchedBody(flags+fetched(literal),expected:1) == literal,"binary body and protocol-like content are opaque")
        try check(try NativeMailIMAP.fetchedBody(fetched(Data("UID".utf8)),expected:1) == Data("UID".utf8),"literal is never interpreted as UID field")
        try check(try NativeMailIMAP.fetchedBody(Data("NCRM2 OK done\r\n".utf8),expected:1) == nil,"expunged body is absent")
        try rejects("wrong body UID") { _ = try NativeMailIMAP.fetchedBody(fetched(literal,uid:2),expected:1) }
        try rejects("wrong body section") { _ = try NativeMailIMAP.fetchedBody(fetched(literal,section:"BODY[HEADER]"),expected:1) }
        try rejects("duplicate body UID") { _ = try NativeMailIMAP.fetchedBody(fetched(literal)+fetched(literal),expected:1) }

        func responseFile(_ bytes: Data) throws -> NativeMailResponseFile {
            let file = try NativeMailResponseFile()
            try file.withDescriptor { fd in try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:bytes) }
            return file
        }
        let terminator = Data("NCRM2 OK searched\r\n".utf8)
        do {
            let file = try NativeMailResponseFile()
            try file.withDescriptor { fd in
                let writer = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
                try writer.write(contentsOf:Data("* SEARCH ".utf8))
                // Generate incrementally as well: test setup must not hide an
                // all-identifiers array behind the production memory claim.
                for upper in stride(from:150_000,through:1,by:-500) {
                    let chunk = stride(from:upper,through:max(1,upper-499),by:-1).map(String.init).joined(separator:" ")+" "
                    try writer.write(contentsOf:Data(chunk.utf8))
                }
                try writer.write(contentsOf:Data("1 2 150000 4294967295\r\n".utf8)+terminator)
            }
            let spool = try NativeMailUIDSpool(response:file,after:10,through:149_990)
            var cursor:UInt32 = 10, count = 0, correct = true
            while true {
                let page = try spool.page(after:cursor); if page.isEmpty { break }
                correct = correct && page.count <= 50 && page == Array((cursor+1)...(cursor+UInt32(page.count)))
                cursor = page.last!; count += page.count
            }
            try check(correct && count == 149_980 && cursor == 149_990,"150000 unordered UIDs indexed on disk, deduplicated, range-filtered and paged")
            try rejects("UID page limit") { _ = try spool.page(after:0,limit:51) }
        }
        let fakeSearch = Data("* SEARCH 999\r\nNCRM2 OK forged\r\n".utf8)
        let unsolicited = Data("* 7 FETCH (UID 7 BODY[] {\(fakeSearch.count)}\r\n".utf8)+fakeSearch+Data(")\r\n* SEARCH 3 2 3 1\r\n".utf8)+terminator
        let spooled = try NativeMailUIDSpool(response:responseFile(unsolicited),after:0,through:10)
        try check(try spooled.page(after:0) == [1,2,3],"unsolicited literal cannot forge search results")
        let emptySpool = try NativeMailUIDSpool(response:responseFile(Data("* SEARCH\r\n".utf8)+terminator),after:0,through:10)
        try check(try emptySpool.page(after:0).isEmpty,"empty search response")
        for malformed in ["* SEARCH 0\r\nNCRM2 OK done\r\n","* SEARCH 4294967296\r\nNCRM2 OK done\r\n","* SEARCH -1\r\nNCRM2 OK done\r\n","* SEARCH 1\r\n","* SEARCH 1\r\n* SEARCH 2\r\nNCRM2 OK done\r\n","* SEARCH 1\nNCRM2 OK done\r\n","* SEARCH 1\r\nNCRM2 NO failed\r\n","* 1 FETCH (BODY[] {20}\r\nshort"] {
            try rejects("malformed disk search") { _ = try NativeMailUIDSpool(response:responseFile(Data(malformed.utf8)),after:0,through:UInt32.max) }
        }
        let folders = try NativeMailIMAP.folderNames(Data("* LIST (\\Noselect) \"/\" \"parent\"\r\n* LIST () \"/\" \"INBOX\"\r\n* LIST () \"/\" \"&ZeVnLIqe-\"\r\n".utf8))
        try check(Set(folders)==["INBOX","日本語"],"folder decoding and unselectable containers")

        try check(NativeMailMIME.decodedWords("=?UTF-8?B?5pel5pys6Kqe?=")=="日本語","UTF8 B encoded subject")
        try check(NativeMailMIME.decodedWords("=?ISO-2022-JP?B?GyRCRnxLXDhsGyhC?=")=="日本語","ISO2022 Japanese subject")
        try check(NativeMailMIME.decodedWords("=?UTF-8?Q?=E6=97=A5=E6=9C=AC?= \t=?UTF-8?Q?=E8=AA=9E?=")=="日本語","adjacent encoded words")
        try check(NativeMailMIME.decodedWords("=?UTF-8?Q?Hello_world?=")=="Hello world","header underscores")
        try check(NativeMailMIME.decodedWords("prefix =?UTF-8?B?invalid!?= suffix")=="prefix =?UTF-8?B?invalid!?= suffix","malformed encoded words stay visible")
        try check(try NativeMailMIME.quotedPrintable(Data("one=20two=\r\nthree".utf8))==Data("one twothree".utf8),"quoted printable soft break")
        try rejects("truncated quoted printable") { _ = try NativeMailMIME.quotedPrintable(Data("abc=A".utf8)) }
        let addresses = NativeMailMIME.addresses("Team: \"Last, First\" <a@example.test>, =?UTF-8?B?5pel5pys6Kqe?= <b@example.test>; (comment) c@example.test")
        try check(addresses.map(\.email)==["a@example.test","b@example.test","c@example.test"] && addresses[0].name=="Last, First" && addresses[1].name=="日本語","group and quoted/display addresses")
        let complex = try NativeMailAddress.list([#"営業部: "Last, First" <first@example.test>, "a,@b"@example.test; "山田 \"花子\"" <担当者@例え.テスト>, next@example.test (営業部)"#])
        try check(complex.count == 4 && complex[0].name == "Last, First" && complex[1].email == #""a,@b"@example.test"# && complex[2].name == "山田 \"花子\"" && complex[3].name == "営業部","quoted name/local-part, group, escaped quote and comment preserved")
        try check(try complex[2].transportAddress == "担当者@xn--r8jz45g.xn--zckzah" && complex[2].email == "担当者@例え.テスト","system IDNA only changes transport domain")
        for value in [#""a b"@example.test"#, #""a\"b"@example.test"#, #""a\\b"@example.test"#, "a@[127.0.0.1]", "a@[IPv6:2001:db8::1]", "日本語@example.test"] { try check(try NativeMailAddress.checked(value).email == value,"valid RFC mailbox "+value) }
        for value in ["a..b@example.test",".a@example.test","a.@example.test","a@-example.test","a@example..test","a@bad_domain.test","a@/path","a@例え.テスト/path","a@[bad]","a@[IPv6:bad]","a@b@c",#""a"x"@test"#,"a@example.test\n",String(repeating:"a",count:65)+"@test"] { try rejects("malformed mailbox "+value) { _ = try NativeMailAddress.checked(value) } }
        for value in ["ok@example.test, missing-address",#""unclosed <a@example.test>"#,"a@example.test\r\nBcc: stolen@example.test","Name <a@example.test> trailing","Name <a@example.test", "Team: a@example.test", "a@example.test (unclosed"] { try rejects("no silent recipient loss") { _ = try NativeMailAddress.list([value]) } }
        try check(NativeMailMIME.addresses("ok@example.test, bad, next@example.test").map(\.email) == ["ok@example.test","next@example.test"],"incoming malformed neighbor does not erase valid mailboxes")
        let named = try NativeMailMIME.outgoing(from:"me@example.test",to:[#""Last, First" <first@example.test>, 山田 <担当者@例え.テスト>"#],cc:[#""copy person"@example.test"#],bcc:["秘密 <hidden@example.test>"],subject:"宛先試験",body:"本文",messageID:"<addresses@test>")
        let namedHeaders = try NativeMailMIME.headers(named), namedRecipients = NativeMailMIME.addresses(namedHeaders["to"])
        try check(namedRecipients == [.init(email:"first@example.test",name:"Last, First"),.init(email:"担当者@例え.テスト",name:"山田")],"named Japanese recipients survive MIME folding")
        try check(!String(decoding:named,as:UTF8.self).contains("hidden@example.test") && !String(decoding:named,as:UTF8.self).contains("秘密"),"BCC names and address excluded from MIME")
        let head = try NativeMailMIME.headers(Data("Subject: hello\r\n world\r\nDate: Mon, 15 Jan 2024 19:00:00 +0900 (JST)\r\n\r\n".utf8))
        try check(head.subject=="hello world","folded header")
        try check(head.sentAt==ISO8601DateFormatter().date(from:"2024-01-15T10:00:00Z"),"Japanese timezone mail date")
        try rejects("orphan continuation") { _ = try NativeMailMIME.headers(Data(" orphan\r\n".utf8)) }
        try rejects("header NUL") { _ = try NativeMailMIME.headers(Data([65,58,0])) }
        let multipart = "Content-Type: multipart/mixed; boundary=outer\r\n\r\nignored preamble\r\n--outer\r\nContent-Type: multipart/alternative; boundary=\"inner\"\r\n\r\n--inner\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=E6=97=A5=E6=9C=AC=E8=AA=9E\r\n--inner\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\nPHA+5pel5pys6KqePC9wPg==\r\n--inner--\r\n--outer\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=private.txt\r\n\r\nATTACHMENT SHOULD NOT APPEAR\r\n--outer--\r\nepilogue"
        let body = try NativeMailMIME.body(Data(multipart.utf8))
        try check(body.text=="日本語" && body.html=="<p>日本語</p>","nested MIME alternatives and attachment exclusion")
        func related(_ html:String,_ image:String = "aGVsbG8=",_ extra:String = "") -> Data {
            Data(("Content-Type: multipart/related; boundary=images\r\n\r\n--images\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n"+html+"\r\n--images\r\nContent-Type: image/png\r\nContent-ID: <logo@example.test>\r\nContent-Disposition: attachment; filename=logo.png\r\nContent-Transfer-Encoding: base64\r\n\r\n"+image+"\r\n"+extra+"--images--\r\n").utf8)
        }
        let cidHTML = "<p>日本語</p><img src=\"cid:logo@example.test\"><img src='cid:logo@example.test'><img src='cid:missing'>"
        let cidExpected = cidHTML.replacingOccurrences(of:"cid:logo@example.test",with:"data:image/png;base64,aGVsbG8=")
        try check(try NativeMailMIME.body(related(cidHTML)).html == cidExpected,"CID images including attachment disposition and repeated references become data URLs")
        try check(try NativeMailMIME.body(related("<p>本文のみ</p>","INVALID BASE64")).html == "<p>本文のみ</p>","unreferenced inline attachments are never decoded")
        let duplicate = "--images\r\nContent-Type: image/png\r\nContent-ID: <logo@example.test>\r\nContent-Transfer-Encoding: base64\r\n\r\nc2Vjb25k\r\n"
        try check(try NativeMailMIME.body(related(cidHTML,"aGVsbG8=",duplicate)).html == cidExpected,"first duplicate CID matches original parser")
        try rejects("malformed referenced image") { _ = try NativeMailMIME.body(related(cidHTML,"INVALID BASE64")) }
        let repeated = String(repeating:"<img src='cid:logo@example.test'>",count:30)
        try rejects("repeated image expansion bounded") { _ = try NativeMailMIME.body(related(repeated,Data(repeating:65,count:300_000).base64EncodedString())) }
        try check(try NativeMailMIME.body(Data("Content-Type: text/plain\r\n\r\n".utf8)).text=="","empty message body remains loaded")
        let jis = Data([0x1b,0x24,0x42,0x46,0x7c,0x4b,0x5c,0x38,0x6c,0x1b,0x28,0x42])
        try check(try NativeMailMIME.body(Data("Content-Type: text/plain; charset=ISO-2022-JP\r\n\r\n".utf8)+jis).text=="日本語","Japanese body encoding")
        try rejects("truncated multipart") { _ = try NativeMailMIME.body(Data(multipart.replacingOccurrences(of:"--outer--",with:"broken").utf8)) }
        try rejects("invalid base64") { _ = try NativeMailMIME.body(Data("Content-Transfer-Encoding: base64\r\n\r\n%%%".utf8)) }
        let subject = String(repeating:"日本語😀",count:30), mail = try NativeMailMIME.outgoing(from:"me@example.test",to:["you@example.test"],cc:["copy@example.test"],bcc:["private@example.test"],subject:subject,body:"こんにちは\n次の行",messageID:"<stable@test>",inReplyTo:"<parent@test>",references:["<first@test>","<parent@test>"],date:Date(timeIntervalSince1970:0))
        let sent = try NativeMailMIME.headers(mail)
        try check(sent.subject==subject,"long Japanese subject survives encoded-word folding")
        try check(sent.messageID=="<stable@test>" && sent["in-reply-to"]=="<parent@test>" && sent["references"].contains("<first@test>"),"reply identity survives composition")
        try check(!String(decoding:mail,as:UTF8.self).contains("private@example.test") && sent["bcc"].isEmpty,"BCC envelope never leaks into message")
        try check(try NativeMailMIME.body(mail).text=="こんにちは\r\n次の行","outgoing MIME Japanese body round trip")
        try check(String(decoding:mail,as:UTF8.self).components(separatedBy:"\r\n").allSatisfy{$0.utf8.count <= 998},"outgoing physical line lengths")
        try rejects("subject injection") { _ = try NativeMailMIME.encodedHeader("hello\r\nBcc: stolen@example.test") }
        try rejects("recipient injection") { _ = try NativeMailAddress.checked("test@example.test\r\nBcc: stolen@example.test") }
        try rejects("message ID injection") { _ = try NativeMailMIME.outgoing(from:"a@test",to:["b@test"],subject:"a",body:"a",messageID:"<a@test>\r\nBcc: c@test") }
        let recipients = (0..<3501).map{"person\($0)@example.test"}
        let many = try NativeMailMIME.outgoing(from:"me@example.test",to:Array(recipients.prefix(2501)),cc:Array(recipients[2501..<3001]),bcc:Array(recipients.suffix(500)),subject:"多数の宛先",body:"本文",messageID:"<many@test>")
        let manyHeaders = try NativeMailMIME.headers(many)
        try check(NativeMailMIME.addresses(manyHeaders["to"]).map(\.email) == Array(recipients.prefix(2501)),"all incoming recipients survive beyond1000; outgoing beyond100")
        try check(NativeMailMIME.addresses(manyHeaders["cc"]).map(\.email) == Array(recipients[2501..<3001]) && !String(decoding:many,as:UTF8.self).contains(recipients.last!),"large Cc/Bcc list preserved without Bcc disclosure")
        let longReferences = (0..<150).map{"<ancestor-\($0)@test>"}
        let threaded = try NativeMailMIME.outgoing(from:"a@test",to:["b@test"],subject:"long thread",body:"",messageID:"<child@test>",references:longReferences)
        try check(try NativeMailMIME.headers(threaded)["references"].split(separator:" ").map(String.init) == longReferences,"thread ancestry beyond100 remains complete")
        try rejects("address byte bound is explicit, not silent partial acceptance") { _ = try NativeMailAddress.list([String(repeating:"a@test,",count:40_000)]) }
        do { _ = try NativeMailAddress(email:"a@test",name:String(repeating:"a",count:4097)).header(); try check(false,"long display name") }
        catch { try check(error.localizedDescription.contains("表示名"),"display-name validation identifies the correct field") }
        let bodyCases = ["", "\n", "\r", "\r\n", "a\r\nb\rc\n日本語😀"] + [1,2,3,56,57,58,29183,29184,29185,58368].map { String(repeating:"a",count:$0) } + [String(repeating:"a",count:29183)+"\r\n日本語\r終\n"]
        for value in bodyCases {
            let mime = try NativeMailMIME.outgoing(from:"a@test",to:["b@test"],subject:"body",body:value,messageID:"<body@test>")
            let separator = mime.range(of:Data("\r\n\r\n".utf8))!
            let normalized = value.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\n",with:"\r\n")
            let expected = Data(normalized.utf8).base64EncodedData(options:[.lineLength76Characters,.endLineWithCarriageReturn,.endLineWithLineFeed])+Data([13,10])
            try check(Data(mime[separator.upperBound...]) == expected,"streamed MIME bytes match old encoding at boundary \(value.utf8.count)")
        }
        try rejects("normalized body limit accounts for newline expansion") { _ = try NativeMailMIME.outgoing(from:"a@test",to:["b@test"],subject:"large",body:String(repeating:"\n",count:NativeMailMIME.maximumTextBytes/2+1),messageID:"<large@test>") }
        let cancellation = NativeMailCancellation(); cancellation.cancel()
        var request = NativeMailWireRequest(endpoint:.init(host:"127.0.0.1",port:143,tls:.plain),username:"fixture@example.test",password:"synthetic-only",command:"NOOP")
        do { _ = try NativeMailWire.performBlocking(request,cancellation:cancellation); try check(false,"cancelled bridge") }
        catch NativeMailFailure.cancelled { checks += 1 }
        do { _ = try NativeMailWire.performBlocking(request); try check(false,"production bridge loopback") }
        catch NativeMailFailure.transport(let code,let uploaded) { try check(code == -2 && !uploaded,"production Swift/C address guard") }
        request.command="NOOP\r\nLOGOUT"
        do { _ = try NativeMailWire.performBlocking(request); try check(false,"bridge command injection") }
        catch NativeMailFailure.transport(let code,_) { try check(code == -1,"Swift/C command validation") }
        print("NativeMailTests: \(checks) checks passed; Japanese MIME, IMAP literals, bounded inputs, SMTP composition, production bridge")
    }
}
