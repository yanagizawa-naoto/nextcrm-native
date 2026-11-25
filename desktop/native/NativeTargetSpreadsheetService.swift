import Foundation

struct NativeTargetSpreadsheetService {
    struct ImportResult { let imported: Int64; let skipped: Int64; let suppressed: Int64 }
    struct ExportSelection {
        // IDs are explicit selections across pages/searches. Empty means every row
        // matching the current filter/search, across all UI pages.
        var selectedIDs: [String] = []
        var filter: RecordFilter = .all
        var search = ""
    }
    let service: CRMService
    /// Mandatory caller fence: session/held-mode/close admission. It must be
    /// safe on the owning worker and rechecked inside the final transaction.
    let admission: () throws -> Void
    var clock: () -> Date = Date.init
    private func check(_ checkpoint: () throws -> Void) throws {
        try admission(); try service.authenticated(); try checkpoint()
        guard !service.db.isReadOnly else { throw NativeTargetSpreadsheetFailure(message: "閲覧専用では取り込み・書き出しを実行できません。") }
    }
    func preview(_ draft: NativeTargetSpreadsheetDraft, mapping: NativeTargetSpreadsheetMapping, after: Int64 = -1,
                 checkpoint: () throws -> Void = {}) throws -> [(position:Int64, values:[String:String], valid:Bool)] {
        try check(checkpoint); var result: [(Int64,[String:String],Bool)] = []
        try draft.rows(after: after) { position,row in
            try check(checkpoint); let values = try mapping.values(row)
            let valid = !(values["last_name"] ?? "").isEmpty || !(values["company"] ?? "").isEmpty
            let visible = values.mapValues { text in let prefix = text.unicodeScalars.prefix(500); return String(String.UnicodeScalarView(prefix)) + (text.unicodeScalars.count > 500 ? "…" : "") }
            result.append((position,visible,valid))
        }
        return result
    }
    func importRows(_ draft: NativeTargetSpreadsheetDraft, mapping: NativeTargetSpreadsheetMapping,
                    checkpoint: () throws -> Void = {}, progress: (Int64) -> Void = {_ in}, willCommit: () throws -> Void = {}) throws -> ImportResult {
        try check(checkpoint)
        try draft.execute("CREATE TABLE IF NOT EXISTS suppression(email TEXT PRIMARY KEY COLLATE BINARY); DELETE FROM suppression; DELETE FROM notes")
        // One native transaction matches createMany atomicity. Paging controls
        // memory; it does not partially commit an otherwise cancelled import.
        return try service.db.transaction {
            try check(checkpoint)
            var after: String?
            while true {
                let page = try service.db.keysetPage("crm_Targets", fields: ["email"], after: after,
                    filter: .equal("do_not_email",.integer(1)), includeDeleted: true)
                for row in page {
                    try check(checkpoint)
                    if row["email"] != .null {
                        try draft.execute("INSERT OR IGNORE INTO suppression(email) VALUES(?)",[.text(NativeTargetSpreadsheetFields.lower(row["email"].string))])
                    }
                }
                if page.count < 100 { break }; after = page.last!["id"].string
            }
            let stamp = ISO8601DateFormatter(); stamp.formatOptions.insert(.withFractionalSeconds)
            var imported: Int64 = 0, skipped: Int64 = 0, suppressed: Int64 = 0, position: Int64 = -1
            while position < draft.rowCount - 1 {
                try draft.rows(after: position) { index,row in
                    try check(checkpoint); position = index
                    let raw = try mapping.values(row)
                    guard !(raw["last_name"] ?? "").isEmpty || !(raw["company"] ?? "").isEmpty else {
                        skipped += 1
                        try draft.execute("INSERT INTO notes(position,message) VALUES(?,?)",[.integer(index),.text("\(index + 2)行目：姓または会社名を入力してください。")]); progress(index + 1); return
                    }
                    var values: [String:SQLValue] = ["last_name":.text(raw["last_name"] ?? ""),"created_by":.text(service.identity.id)]
                    for key in NativeTargetSpreadsheetFields.keys where key != "last_name" {
                        values[key] = raw[key].flatMap { $0.isEmpty ? nil : SQLValue.text($0) } ?? .null
                    }
                    if let email = raw["email"], !email.isEmpty,
                       try draft.one("SELECT 1 FROM suppression WHERE email=?",[.text(NativeTargetSpreadsheetFields.lower(email))]) != nil {
                        values["do_not_email"] = .integer(1); values["do_not_email_at"] = .text(stamp.string(from:clock())); suppressed += 1
                    }
                    // The original source creates new UUIDs and has no unique
                    // email constraint, so duplicate email rows remain rows.
                    // Native audit history is deliberately retained. Targets
                    // have no original plugin entity/after-event registration.
                    _ = try service.db.insert("crm_Targets",values:values,actor:service.identity.id)
                    imported += 1; progress(index + 1)
                }
            }
            try check(checkpoint)
            try willCommit()
            return .init(imported:imported,skipped:skipped,suppressed:suppressed)
        }
    }
    func exportSnapshot(_ selection: ExportSelection, into draft: NativeTargetSpreadsheetDraft,
                        checkpoint: () throws -> Void = {}, progress: (Int64) -> Void = {_ in}) throws -> Int64 {
        try check(checkpoint)
        guard draft.rowCount == 0 else { throw NativeTargetSpreadsheetFailure(message: "書き出し用の作業場所が既に使用されています。") }
        try draft.setHeaders(NativeTargetSpreadsheetFields.keys)
        return try service.db.transaction {
            try check(checkpoint)
            let fields = NativeTargetSpreadsheetFields.keys
            try draft.execute("CREATE TABLE export_sort(id TEXT PRIMARY KEY,missing INTEGER NOT NULL,instant INTEGER NOT NULL,fraction INTEGER NOT NULL,json TEXT NOT NULL); CREATE INDEX export_order ON export_sort(missing DESC,instant DESC,fraction DESC,id)")
            var copied:Int64 = 0
            func stage(_ row:NativeRecord)throws {
                try check(checkpoint)
                let value=NativeTargetSpreadsheetRow(entries:fields.map{.init($0,row[$0] == .null ? "":row[$0].string)})
                let missing=row["created_on"] == .null
                let instant = missing ? (seconds:Int64(0),fraction:Int64(0)):try Self.sortInstant(row["created_on"].string)
                try draft.execute("INSERT INTO export_sort VALUES(?,?,?,?,?)",[.text(row["id"].string),.integer(missing ? 1:0),.integer(instant.seconds),.integer(instant.fraction),.text(String(decoding:try JSONEncoder().encode(value),as:UTF8.self))])
                copied += 1;progress(copied)
            }
            if !selection.selectedIDs.isEmpty {
                // Only explicit IDs are retained in RAM. One scoped/live query
                // per 100 IDs; the current search does not erase prior selections.
                var seen=Set<String>(),ids:[String]=[]
                for id in selection.selectedIDs where seen.insert(id).inserted { ids.append(id) }
                var offset=0
                while offset<ids.count {
                    try check(checkpoint);let end=min(offset+100,ids.count),chunk=Array(ids[offset..<end])
                    let rows=try service.db.keysetPage("crm_Targets",fields:fields+["created_on"],filter:.every([service.scope("crm_Targets"),.any(chunk.map{.equal("id",.text($0))})]))
                    guard rows.count==chunk.count else { throw NativeDBError.message("選択した対象が削除されたか、表示権限が変更されています。一覧を更新してください。") }
                    for row in rows {try stage(row)};offset=end
                }
            } else {
                var after:String?
                while true {
                    try check(checkpoint)
                    let rows=try service.db.keysetPage("crm_Targets",fields:fields+["created_on"],after:after,filter:.every([service.scope("crm_Targets"),selection.filter]),search:selection.search)
                    for row in rows {try stage(row)}
                    if rows.count<100 {break};after=rows.last!["id"].string
                }
            }
            // Prisma orders by created_on DESC: PostgreSQL places NULL first.
            // Equal timestamps have no source tie order; use ID ascending.
            // The index sorts on disk and this cursor visits one row at a time.
            try draft.each("SELECT json FROM export_sort ORDER BY missing DESC,instant DESC,fraction DESC,id") { row in
                try check(checkpoint);try draft.append(JSONDecoder().decode(NativeTargetSpreadsheetRow.self,from:Data(row[0]!.utf8)))
            }
            try draft.execute("DROP TABLE export_sort")
            try check(checkpoint); return draft.rowCount
        }
    }
    private static let timestamp = try! NSRegularExpression(pattern:#"^([+-]?[0-9]{4,6})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:[0-9]{2})$"#)
    static func sortInstant(_ text:String)throws->(seconds:Int64,fraction:Int64) {
        let ns=text as NSString
        guard let match=timestamp.firstMatch(in:text,range:NSRange(location:0,length:ns.length)) else {throw NativeTargetSpreadsheetFailure(message:"作成日時を並べ替えできません。元データを確認してください。")}
        func part(_ index:Int)->String {let range=match.range(at:index);return range.location == NSNotFound ? "":ns.substring(with:range)}
        let year=Int64(part(1))!,month=Int64(part(2))!,day=Int64(part(3))!,hour=Int64(part(4))!,minute=Int64(part(5))!,second=Int64(part(6))!
        let leap=year%4==0 && (year%100 != 0 || year%400==0),lengths:[Int64]=[31,leap ? 29:28,31,30,31,30,31,31,30,31,30,31]
        guard (1...12).contains(month),(1...lengths[Int(month)-1]).contains(day),hour<24,minute<60,second<60 else {throw NativeTargetSpreadsheetFailure(message:"作成日時が不正です。")}
        let y=year-(month<=2 ? 1:0),era=(y>=0 ? y:y-399)/400,yoe=y-era*400
        let m=month+(month>2 ? -3:9),doy=(153*m+2)/5+day-1,doe=yoe*365+yoe/4-yoe/100+doy
        let days=era*146097+doe-719468,fraction=Int64((part(7)+"000000000").prefix(9))!
        let zone=part(8);var offset:Int64=0
        if zone != "Z" {let pieces=zone.dropFirst().split(separator:":");let h=Int64(pieces[0])!,m=Int64(pieces[1])!;guard h<=23,m<60 else{throw NativeTargetSpreadsheetFailure(message:"作成日時の時差が不正です。")};offset=(h*3600+m*60)*(zone.first=="-" ? -1:1)}
        return ((days*86400+hour*3600+minute*60+second)-offset,fraction)
    }

}
