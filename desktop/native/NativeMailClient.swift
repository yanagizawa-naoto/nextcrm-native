import Foundation

/// A credential snapshot is supplied by the owner-scoped service. Workers
/// must revalidate the account, actor and lease before publishing results.
protocol NativeMailReceiving {
    func status(mailbox: String) async throws -> (validity:UInt32,next:UInt32)
    func discover(mailbox: String,validity: UInt32,after: UInt32,through: UInt32,since: Date?) async throws -> NativeMailUIDSpool
    func headers(mailbox: String,validity: UInt32,uids: [UInt32]) async throws -> [NativeMailIMAPHeader]
    func headerBatch(mailbox:String,validity:UInt32,uids:[UInt32]) async throws -> NativeMailHeaderBatch
    func body(mailbox: String,validity: UInt32,uid: UInt32) async throws -> NativeMailBody?
}
extension NativeMailReceiving {
    func headerBatch(mailbox:String,validity:UInt32,uids:[UInt32]) async throws -> NativeMailHeaderBatch {
        .memory(try await headers(mailbox:mailbox,validity:validity,uids:uids))
    }
}
struct NativeMailClient: NativeMailReceiving {
    let endpoint: NativeMailEndpoint
    let username: String, password: String
    var oauthBearer: String? = nil
    private func request(mailbox: String? = nil,command: String,maximum: Int = 1_048_576) -> NativeMailWireRequest {
        NativeMailWireRequest(endpoint:endpoint,username:username,password:password,mailbox:mailbox,command:command,maximumResponse:maximum,oauthBearer:oauthBearer)
    }
    func folders() async throws -> [String] {
        try NativeMailIMAP.folderNames(await NativeMailWire.perform(request(command:"LIST \"\" \"*\"")).body)
    }
    func status(mailbox: String) async throws -> (validity:UInt32,next:UInt32) {
        let command = "STATUS "+(try NativeMailIMAP.quotedMailbox(mailbox))+" (UIDVALIDITY UIDNEXT)"
        return try NativeMailIMAP.status(await NativeMailWire.perform(request(command:command)).body,mailbox:mailbox)
    }
    func discover(mailbox: String,validity: UInt32,after: UInt32,through: UInt32,since: Date? = nil) async throws -> NativeMailUIDSpool {
        guard validity > 0, through > after, after < UInt32.max else { throw NativeMailFailure.malformed }
        var command = "UID SEARCH UID \(after+1):\(through)"
        if let since {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "d-MMM-yyyy"
            command += " SINCE "+formatter.string(from:since)
        }
        let file = try NativeMailResponseFile()
        var query = request(mailbox:mailbox,command:command,maximum:268_435_456); query.responseFile = file
        let response = try await NativeMailWire.perform(query)
        guard try NativeMailIMAP.selectedValidity(response.protocolHeaders) == validity else { throw NativeMailFailure.mailboxChanged }
        return try NativeMailUIDSpool(response:file,after:after,through:through)
    }
    func headers(mailbox:String,validity:UInt32,uids:[UInt32]) async throws -> [NativeMailIMAPHeader] {
        let batch=try await headerBatch(mailbox:mailbox,validity:validity,uids:uids);var rows:[NativeMailIMAPHeader]=[];try batch.forEach{rows.append($0)};return rows
    }
    func headerBatch(mailbox:String,validity:UInt32,uids:[UInt32]) async throws -> NativeMailHeaderBatch {
        guard validity>0 else{throw NativeMailFailure.malformed}
        let file=try NativeMailResponseFile();var query=request(mailbox:mailbox,command:try NativeMailIMAP.headerCommand(uids),maximum:Int.max);query.responseFile=file
        let response=try await NativeMailWire.perform(query)
        guard try NativeMailIMAP.selectedValidity(response.protocolHeaders)==validity else{throw NativeMailFailure.mailboxChanged}
        return .file(NativeMailIMAPFile(file:file),expected:Set(uids))
    }
    func body(mailbox:String,validity:UInt32,uid:UInt32) async throws -> NativeMailBody? {
        guard uid>0,validity>0 else{throw NativeMailFailure.malformed}
        let file=try NativeMailResponseFile();var query=request(mailbox:mailbox,command:"UID FETCH \(uid) (UID BODY.PEEK[])",maximum:Int.max);query.responseFile=file
        return try Self.decodeBodyFile(await NativeMailWire.perform(query),file:file,validity:validity,uid:uid)
    }
    static func decodeBodyFile(_ response:NativeMailReply,file:NativeMailResponseFile,validity:UInt32,uid:UInt32,temporaryRoot:URL=FileManager.default.temporaryDirectory)throws->NativeMailBody? {
        guard uid>0,validity>0 else{throw NativeMailFailure.malformed}
        guard try NativeMailIMAP.selectedValidity(response.protocolHeaders)==validity else{throw NativeMailFailure.mailboxChanged}
        guard let bytes=try NativeMailIMAPFile(file:file).body(expected:uid) else{return nil}
        return normalizeIncoming(try NativeMailMIME.body(bytes,recoverIncoming:true,deriveHTMLText:{try NativeMailHTMLText.convert($0,temporaryRoot:temporaryRoot)},derivePlainHTML:{try NativeMailTextHTML.convert($0)},temporaryRoot:temporaryRoot))
    }
    static func decodeBodyReply(_ response:NativeMailReply,validity:UInt32,uid:UInt32) throws -> NativeMailBody? {
        guard uid > 0,validity > 0 else{throw NativeMailFailure.malformed}
        guard try NativeMailIMAP.selectedValidity(response.protocolHeaders) == validity else { throw NativeMailFailure.mailboxChanged }
        guard let bytes = try NativeMailIMAP.fetchedBody(response.body,expected:uid) else { return nil }
        return normalizeIncoming(try NativeMailMIME.body(bytes,recoverIncoming:true,deriveHTMLText:{try NativeMailHTMLText.convert($0)},derivePlainHTML:{try NativeMailTextHTML.convert($0)}))
    }
    private static func normalizeIncoming(_ body:NativeMailBody)->NativeMailBody {
        // fetchBodyByUid maps empty parser strings to undefined; the original
        // message/link consumers then persist null rather than an empty field.
        .init(text:body.text.flatMap{$0.isEmpty ? nil:$0},html:body.html.flatMap{$0.isEmpty ? nil:$0})
    }

}
