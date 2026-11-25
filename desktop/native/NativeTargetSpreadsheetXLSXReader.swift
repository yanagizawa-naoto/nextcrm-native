import Foundation
import Darwin

/// ZIP members are streamed by the existing OS unzip into caller-private files;
/// shared strings, styles, cells and merged ranges stay in the SQLite draft.
enum NativeTargetSpreadsheetXLSXReader {
    private final class XML: NSObject, XMLParserDelegate {
        let start: (String,[String:String]) throws -> Void
        let text: (String) throws -> Void
        let end: (String) throws -> Void
        let check: () throws -> Void
        var error: Error?, depth = 0
        init(check: @escaping () throws -> Void, start: @escaping (String,[String:String]) throws -> Void = {_,_ in}, text: @escaping (String) throws -> Void = {_ in}, end: @escaping (String) throws -> Void = {_ in}) {
            self.check = check; self.start = start; self.text = text; self.end = end
        }
        private func apply(_ parser: XMLParser, _ body: () throws -> Void) { do { try check(); try body() } catch { self.error = error; parser.abortParsing() } }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
            apply(parser) { depth += 1; guard depth <= 256 else { throw NativeTargetSpreadsheetFailure(message: "Excel内のXMLの入れ子が深すぎます。") }; try start(name.components(separatedBy: ":").last!, attributes) }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { apply(parser) { try text(string) } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { apply(parser) { try end(name.components(separatedBy: ":").last!); depth -= 1 } }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { apply(parser) { throw NativeTargetSpreadsheetFailure(message: "独自の実体宣言を含むExcelは読み込めません。") } }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { apply(parser) { throw NativeTargetSpreadsheetFailure(message: "外部の実体参照を含むExcelは読み込めません。") } }
        func run(_ url: URL) throws {
            guard let stream = InputStream(url: url) else { throw NativeTargetSpreadsheetFailure(message: "Excelの内容を開けません。") }
            let parser = XMLParser(stream: stream); parser.delegate = self; parser.shouldResolveExternalEntities = false
            guard parser.parse(), error == nil else { throw error ?? NativeTargetSpreadsheetFailure(message: "Excel内のXMLを読み取れません。") }
        }
    }
    private final class Archive {
        let source: URL, draft: NativeTargetSpreadsheetDraft, check: () throws -> Void
        var serial = 0
        init(source: URL, draft: NativeTargetSpreadsheetDraft, check: @escaping () throws -> Void) { self.source = source; self.draft = draft; self.check = check }
        func member(_ name: String, required: Bool = false) throws -> URL? {
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.utf8.contains(0), !name.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0 == ".." || $0 == "."}) else { throw NativeTargetSpreadsheetFailure(message: "Excel内の参照先が不正です。") }
            serial += 1; let output = draft.directory.appendingPathComponent("xml-\(serial)"), diagnostic = draft.directory.appendingPathComponent("zip-diagnostic-\(serial)")
            FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            FileManager.default.createFile(atPath: diagnostic.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let writer = try FileHandle(forWritingTo: output), errorWriter = try FileHandle(forWritingTo: diagnostic)
            defer { try? writer.close(); try? errorWriter.close(); try? FileManager.default.removeItem(at: diagnostic) }
            // Escape Info-ZIP wildcard syntax; no shell or archive paths are extracted.
            var literal = name.replacingOccurrences(of:"[",with:"\\[")
            literal = literal.replacingOccurrences(of:"*",with:"\\*").replacingOccurrences(of:"?",with:"\\?")
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments = ["-p",source.path,literal]
            process.standardOutput = writer; process.standardError = errorWriter
            try check(); try process.run()
            do {
                while process.isRunning { try check(); Thread.sleep(forTimeInterval:0.01) }
                process.waitUntilExit(); try check()
            } catch {
                if process.isRunning { process.terminate() }
                let until = Date().addingTimeInterval(1)
                while process.isRunning && Date() < until { Thread.sleep(forTimeInterval:0.01) }
                if process.isRunning { kill(process.processIdentifier,SIGKILL) }
                process.waitUntilExit(); throw error
            }
            if process.terminationStatus == 11 && !required { try? FileManager.default.removeItem(at:output); return nil }
            guard process.terminationStatus == 0 else { throw NativeTargetSpreadsheetFailure(message:"ExcelのZIP内容を読み取れません。暗号化や破損を確認してください。") }
            return output
        }
    }
    private static func coordinates(_ text: String) throws -> (Int64,Int64) {
        var col: Int64 = 0, rowText = "", letters = true
        for byte in text.utf8 {
            if letters && byte >= 65 && byte <= 90 { let (v,overflow) = col.multipliedReportingOverflow(by:26); guard !overflow else { throw invalidAddress }; let (sum,over) = v.addingReportingOverflow(Int64(byte - 64)); guard !over else { throw invalidAddress }; col = sum }
            else if byte >= 48 && byte <= 57 { letters = false; rowText.append(Character(UnicodeScalar(byte))) }
            else { throw invalidAddress }
        }
        guard col > 0, col <= 16384, let row = Int64(rowText), row > 0 else { throw invalidAddress }; return (row,col)
    }
    private static var invalidAddress: NativeTargetSpreadsheetFailure { .init(message:"Excelのセル位置を読み取れません。") }
    private static func decoded(_ value: String) -> String {
        // One OOXML decode pass preserves escaped literal `_xHHHH_` strings.
        let a = Array(value.utf16); var out: [UInt16] = [], i = 0
        while i < a.count {
            if i + 6 < a.count, a[i] == 95, a[i+1] == 120, a[i+6] == 95,
               let code = UInt16(String(decoding:a[(i+2)...(i+5)],as:UTF16.self),radix:16) { out.append(code); i += 7 }
            else { out.append(a[i]); i += 1 }
        }
        return String(decoding:out,as:UTF16.self)
    }
    private static func dateText(_ serial: Double, epoch1904: Bool, zone: TimeZone) -> String {
        let milliseconds = floor((serial - 25569 + (epoch1904 ? 1462 : 0)) * 86_400_000 + 0.5)
        guard milliseconds.isFinite, abs(milliseconds) <= 8.64e15 else { return "Invalid Date" }
        let date = Date(timeIntervalSince1970:milliseconds/1000)
        // JS Date uses the proleptic Gregorian calendar, including year zero;
        // NSDateFormatter's historical cutover/era formatting does not.
        let offset=zone.secondsFromGMT(for:date),local=Int64(floor(milliseconds/1000))+Int64(offset)
        let days=local>=0 ? local/86400:(local-86399)/86400,seconds=local-days*86400
        let z=days+719468,era=(z>=0 ? z:z-146096)/146097,doe=z-era*146097
        let yoe=(doe-doe/1460+doe/36524-doe/146096)/365,baseYear=yoe+era*400
        let doy=doe-(365*yoe+yoe/4-yoe/100),mp=(5*doy+2)/153
        let day=doy-(153*mp+2)/5+1,month=mp+(mp<10 ? 3:-9),year=baseYear+(month<=2 ? 1:0)
        let weekday=Int(((days+4)%7+7)%7),months=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let years=(year<0 ? "-":"")+String(repeating:"0",count:max(0,4-String(abs(year)).count))+String(abs(year))
        let calendarText=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][weekday]+" "+months[Int(month)-1]+String(format:" %02lld ",day)+years+String(format:" %02lld:%02lld:%02lld GMT",seconds/3600,seconds/60%60,seconds%60)
        let zoneText=(offset<0 ? "-":"+")+String(format:"%02d%02d",abs(offset)/3600,abs(offset)/60%60)
        let name = ["GMT","UTC","Etc/UTC","Etc/GMT"].contains(zone.identifier) ? "Coordinated Universal Time" : zone.localizedName(for: zone.isDaylightSavingTime(for:date) ? .daylightSaving : .standard, locale:Locale(identifier:"en_US")) ?? zone.identifier
        return calendarText+zoneText+" ("+name+")"
    }
    static func parse(url: URL, draft: NativeTargetSpreadsheetDraft, timeZone: TimeZone = .current,
                      numberText: (Double) -> String,
                      checkpoint: @escaping () throws -> Void = {}) throws {
        let archive = Archive(source:url,draft:draft,check:checkpoint)
        guard let workbook = try archive.member("xl/workbook.xml",required:true) else { throw invalidAddress }
        var firstID: String?, epoch1904 = false
        try XML(check:checkpoint,start:{ name,a in
            if name == "workbookPr" { epoch1904 = a["date1904"] == "1" || a["date1904"] == "true" }
            if name == "sheet",firstID == nil { firstID = a["r:id"] }
        }).run(workbook)
        guard let firstID else { try draft.setHeaders([]); return }
        var target: String?
        if let rels = try archive.member("xl/_rels/workbook.xml.rels") {
            try XML(check:checkpoint,start:{ name,a in if name == "Relationship",a["Id"] == firstID { guard a["TargetMode"] != "External" else { throw invalidAddress }; target = a["Target"] } }).run(rels)
        }
        guard let target else { throw NativeTargetSpreadsheetFailure(message:"Excelの最初のシートが見つかりません。") }
        var components = target.hasPrefix("/") ? [] : ["xl"]
        for part in target.split(separator:"/") { if part == "." { continue }; if part == ".." { guard !components.isEmpty else { throw invalidAddress }; components.removeLast() } else { components.append(String(part)) } }
        guard let sheet = try archive.member(components.joined(separator:"/"),required:true) else { throw invalidAddress }
        try draft.execute("BEGIN")
        do {
            if let strings = try archive.member("xl/sharedStrings.xml") {
                var index: Int64 = 0, text = "", rich = false, inside = false, inText = false, phonetic = 0
                try XML(check:checkpoint,start:{name,_ in
                    if name == "si" { inside = true; text = ""; rich = false }
                    if name == "rPh" { phonetic += 1 }; if inside && name == "r" { rich = true }; if name == "t" { inText = true }
                },text:{if inside && inText && phonetic == 0 { text += $0 }},end:{name in
                    if name == "t" { inText = false }; if name == "rPh" { phonetic = max(0,phonetic-1) }
                    if name == "si" { try draft.execute("INSERT INTO shared VALUES(?,?,?)",[.integer(index),.text(decoded(text)),.integer(rich ? 1:0)]); index += 1; inside = false }
                }).run(strings)
            }
            if let styles = try archive.member("xl/styles.xml") {
                var cellXfs = false, index: Int64 = 0
                try XML(check:checkpoint,start:{name,a in
                    if name == "numFmt",let id=a["numFmtId"].flatMap(Int64.init),let code=a["formatCode"] { try draft.execute("INSERT OR REPLACE INTO formats VALUES(?,?)",[.integer(id),.text(code)]) }
                    if name == "cellXfs" { cellXfs = true }
                    if cellXfs && name == "xf" { try draft.execute("INSERT INTO styles VALUES(?,?)",[.integer(index),.integer(a["numFmtId"].flatMap(Int64.init) ?? 0)]); index += 1 }
                },end:{if $0 == "cellXfs" { cellXfs = false }}).run(styles)
            }
            var position: (Int64,Int64)?, kind = "n", raw = "", inline = "", style: Int64 = 0, formula = false, rich = false, inValue = false, inText = false, inInline = false, inPhonetic = 0
            try XML(check:checkpoint,start:{name,a in
                if name == "row",let r=a["r"].flatMap(Int64.init) { try draft.execute("INSERT OR IGNORE INTO raw_rows VALUES(?)",[.integer(r)]) }
                if name == "c" { position = try coordinates(a["r"] ?? ""); kind=a["t"] ?? "n";style=a["s"].flatMap(Int64.init) ?? 0;raw="";inline="";formula=false;rich=false }
                if name == "rPh" {inPhonetic += 1};if name == "v" { inValue=true };if name == "is" { inInline=true };if name == "t" && inInline { inText=true };if name == "r" && inInline { rich=true };if name == "f" { formula=true }
                if name == "hyperlink",let ref=a["ref"] {let p=try coordinates(ref);try draft.execute("INSERT OR IGNORE INTO hyperlinks VALUES(?,?)",[.integer(p.0),.integer(p.1)])}
                if name == "mergeCell",let range=a["ref"] { let pieces=range.split(separator:":");guard pieces.count==2 else {throw invalidAddress};let lo=try coordinates(String(pieces[0])),hi=try coordinates(String(pieces[1]));guard hi.0>=lo.0,hi.1>=lo.1 else {throw invalidAddress};try draft.execute("INSERT INTO merges VALUES(?,?,?,?)",[.integer(lo.0),.integer(hi.0),.integer(lo.1),.integer(hi.1)]) }
            },text:{if inValue {raw += $0};if inText && inPhonetic == 0 {inline += $0}},end:{name in
                if name == "rPh" {inPhonetic=max(0,inPhonetic-1)};if name == "v" {inValue=false};if name == "t" {inText=false};if name == "is" {inInline=false}
                if name == "c",let pos=position {try draft.execute("INSERT OR REPLACE INTO cells VALUES(?,?,?,?,?,?,?)",[.integer(pos.0),.integer(pos.1),.text(kind),.text(kind == "inlineStr" ? inline:raw),.integer(style),.integer(formula ? 1:0),.integer(rich ? 1:0)]);position=nil}
            }).run(sheet)
            // ExcelJS merge reconciliation creates the affected rows. Stream
            // this expansion on disk; no rectangle of cells is materialized.
            try draft.each("SELECT first_row,last_row FROM merges") { range in
                var r=Int64(range[0]!)!;let last=Int64(range[1]!)!
                while r<=last {try checkpoint();try draft.execute("INSERT OR IGNORE INTO raw_rows VALUES(?)",[.integer(r)]);if r==Int64.max {break};r += 1}
            }
            func text(row:Int64,col:Int64,header:Bool) throws -> String {
                var r=row,c=col
                try draft.each("SELECT first_row,first_col FROM merges WHERE first_row<=? AND last_row>=? AND first_col<=? AND last_col>=? LIMIT 1",[.integer(row),.integer(row),.integer(col),.integer(col)]) {r=Int64($0[0]!)!;c=Int64($0[1]!)!}
                var cell: [String?]?
                try draft.each("SELECT kind,raw,style,formula,rich FROM cells WHERE row=? AND col=?",[.integer(r),.integer(c)]) {cell=$0}
                guard let cell else {return ""};let k=cell[0]!,v=cell[1]!,formula=cell[3]=="1"
                if try header && (formula || (draft.one("SELECT 1 FROM hyperlinks WHERE row=? AND col=?",[.integer(r),.integer(c)])) != nil) {return "[object Object]"}
                if k == "s" {
                    var value="",rich=false
                    if let index=Int64(v) {try draft.each("SELECT text,rich FROM shared WHERE position=?",[.integer(index)]) {value=$0[0]!;rich=$0[1]=="1"}}
                    return header && rich ? "[object Object]":value
                }
                if k == "inlineStr" {return header && cell[4]=="1" ? "[object Object]":v}
                if k == "str" {return decoded(v)}
                if k == "e" {return header || formula ? "[object Object]":v}
                if k == "b" {let b=v == "1";return formula && !b ? "":b ? "true":"false"}
                if v.isEmpty {return ""}
                let number=Double(v) ?? .nan
                let format=try draft.one("SELECT format FROM styles WHERE position=?",[.integer(Int64(cell[2]!) ?? 0)]).flatMap(Int64.init) ?? 0
                var date = [14,15,16,17,18,19,20,21,22,45,46,47].contains(format)
                if let custom=try draft.one("SELECT code FROM formats WHERE id=?",[.integer(format)]) {
                    let stripped=custom.replacingOccurrences(of:#"\[[^\]]*]|"[^"]*""#,with:"",options:.regularExpression)
                    date=stripped.range(of:"[ymdhMsb]+",options:.regularExpression) != nil
                }
                if date {return dateText(number,epoch1904:epoch1904,zone:timeZone)}
                return formula && (number==0 || number.isNaN) ? "":numberText(number)
            }
            let maximumCell=Int64(try draft.one("SELECT COALESCE(MAX(col),0) FROM cells WHERE row=1") ?? "0") ?? 0
            let maximumMerge=Int64(try draft.one("SELECT COALESCE(MAX(last_col),0) FROM merges WHERE first_row<=1 AND last_row>=1") ?? "0") ?? 0
            let maximum=max(maximumCell,maximumMerge);var headers:[String]=[]
            if maximum>0 {for col in 1...maximum {try checkpoint();headers.append(NativeTargetSpreadsheetFields.trim(try text(row:1,col:col,header:true)))}}
            try draft.setHeaders(headers)
            try draft.each("SELECT position FROM raw_rows WHERE position>1 ORDER BY position") { value in
                try checkpoint();let row=Int64(value[0]!)!;var entries:[NativeTargetSpreadsheetRow.Entry]=[];var indices:[Data:Int]=[:],hasValue=false
                for (i,header) in headers.enumerated() where !header.isEmpty {
                    let value=NativeTargetSpreadsheetFields.trim(try text(row:row,col:Int64(i+1),header:false));if !value.isEmpty {hasValue=true}
                    if header=="__proto__" {continue};let key=Data(header.utf8),entry=NativeTargetSpreadsheetRow.Entry(header,value)
                    if let old=indices[key] {entries[old]=entry}else{indices[key]=entries.count;entries.append(entry)}
                }
                if hasValue {try draft.append(.init(entries:entries))}
            }
            try checkpoint();try draft.execute("COMMIT")
        } catch {try? draft.execute("ROLLBACK");throw error}
    }
}
