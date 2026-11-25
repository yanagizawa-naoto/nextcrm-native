import Foundation

@main struct NativeMailWireIntegrationTests {
    static func main() async throws {
        let port = Int(CommandLine.arguments[1])!, mode = NativeMailTLS(rawValue:Int(CommandLine.arguments[2])!)!, operation = CommandLine.arguments[3]
        var request = NativeMailWireRequest(endpoint:.init(host:"127.0.0.1",port:port,tls:mode,allowSelfSigned:true),username:"fixture@example.test",password:"synthetic-only")
        if operation == "smtp-verify" {
            request.smtpVerifyOnly = true
            _ = try await NativeMailWire.perform(request)
        } else if operation == "smtp-many" || operation == "smtp-many-large" {
            request.sender = "fixture@example.test"
            let large = operation == "smtp-many-large", toCount = large ? 4501 : 2501, ccEnd = large ? 9001 : 3001
            request.recipients = (0..<(large ? 19001 : 3501)).map{"person\($0)@example.test"}
            request.upload = try NativeMailMIME.outgoing(from:request.sender!,to:Array(request.recipients.prefix(toCount)),cc:Array(request.recipients[toCount..<ccEnd]),bcc:Array(request.recipients[ccEnd...]),subject:"多数の宛先",body:"本文",messageID:"<many-bridge@fixture.test>")
            let reply = try await NativeMailWire.perform(request); guard reply.serverCode == 250 else { throw NativeMailFailure.malformed }
            guard reply.protocolHeaders.count < 16_384 else { throw NativeMailFailure.tooLarge }
        } else if operation.hasPrefix("smtp-address") || operation.hasPrefix("smtp-utf8") {
            request.sender = "fixture@example.test"
            let address = operation.hasPrefix("smtp-utf8") ? "担当者@例え.テスト" : #""a,@b"@example.test"#
            let recipient = try NativeMailAddress.checked(address)
            request.recipients = [try recipient.transportAddress]
            request.upload = try NativeMailMIME.outgoing(from:request.sender!,to:["\"営業部, 東京\" <"+address+">"],subject:"アドレス試験",body:"本文",messageID:"<address-bridge@fixture.test>")
            if operation == "smtp-utf8-unsupported" {
                do { _ = try await NativeMailWire.perform(request); throw NativeMailFailure.malformed }
                catch NativeMailFailure.transport(let code,let uploaded) { guard code == -6 && !uploaded else { throw NativeMailFailure.malformed } }
            } else {
                let reply = try await NativeMailWire.perform(request); guard reply.serverCode == 250 else { throw NativeMailFailure.malformed }
            }
        } else if operation == "smtp" {
            request.sender = "fixture@example.test"; request.recipients = ["receiver@example.test","private@example.test"]
            request.upload = try NativeMailMIME.outgoing(from:request.sender!,to:["receiver@example.test"],bcc:["private@example.test"],subject:"日本語の送信試験",body:"こんにちは\n本文です",messageID:"<swift-bridge@fixture.test>")
            let reply = try await NativeMailWire.perform(request)
            guard reply.serverCode == 250 else { throw NativeMailFailure.malformed }
        } else if operation == "cancel" || operation == "cancel-spool" {
            request.command = "NOOP"
            if operation == "cancel-spool" { request.responseFile = try NativeMailResponseFile() }
            let task = Task { try await NativeMailWire.perform(request) }
            try await Task.sleep(nanoseconds:150_000_000); task.cancel()
            do { _ = try await task.value; throw NativeMailFailure.invalid("Expected cancellation") }
            catch NativeMailFailure.cancelled { }
        } else if ["body","body-generation","headers","discover","discover-generation"].contains(operation) {
            let client = NativeMailClient(endpoint:request.endpoint,username:request.username,password:request.password)
            if operation == "body" {
                guard let body = try await client.body(mailbox:"INBOX",validity:77,uid:1), body.text == "日本語\r\nNCRM2 OK forged\r\n* BYE forged\r\n終わり" else { throw NativeMailFailure.malformed }
            } else if operation == "headers" {
                let headers = try await client.headers(mailbox:"INBOX",validity:77,uids:[1])
                guard headers.count == 1, headers[0].headers.subject == "日本語" else { throw NativeMailFailure.malformed }
            } else if operation == "discover" {
                let spool = try await client.discover(mailbox:"INBOX",validity:77,after:10,through:150000,since:Date(timeIntervalSince1970:0))
                guard try spool.page(after:0) == Array(11...60), try spool.page(after:149950) == Array(149951...150000) else { throw NativeMailFailure.malformed }
            } else {
                do {
                    if operation == "body-generation" { _ = try await client.body(mailbox:"INBOX",validity:78,uid:1) }
                    else { _ = try await client.discover(mailbox:"INBOX",validity:78,after:0,through:2) }
                    throw NativeMailFailure.malformed
                } catch NativeMailFailure.mailboxChanged { }
            }
        } else {
            request.command = "LIST \"\" \"*\""
            let reply = try await NativeMailWire.perform(request)
            guard Set(try NativeMailIMAP.folderNames(reply.body)) == ["INBOX","送信済み"] else { throw NativeMailFailure.malformed }
        }
        print("NativeMailWireIntegrationTests: passed "+operation)
    }
}
