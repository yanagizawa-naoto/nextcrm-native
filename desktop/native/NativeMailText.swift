import Foundation

/// Text quotation is deliberately independent of HTML rendering. Never invokes
/// the HTML importer, loads images, or resolves external resources.
enum NativeMailText {
    private final class Collector {
        var text = "", bytes = 0, error:Error?
        func append(_ value:String) throws {
            guard bytes+value.utf8.count <= NativeMailMIME.maximumTextBytes else { throw NativeMailFailure.tooLarge }
            text += value; bytes += value.utf8.count
        }
        func event(_ kind:Int32,_ value:String) throws {
            if kind == 5 { try append(value) }
            else if (kind == 1 && ["br","hr"].contains(value)) || (kind == 6 && ["p","div","li","tr","blockquote","pre","h1","h2","h3","h4","h5","h6"].contains(value)) {
                if !text.hasSuffix("\n") { try append("\n") }
            } else if kind == 6 && ["td","th"].contains(value), !text.hasSuffix("\t") { try append("\t") }
        }
    }
    static func quote(html:String) throws -> String {
        guard html.utf8.count <= NativeMailMIME.maximumTextBytes else { throw NativeMailFailure.tooLarge }
        let output = Collector()
        guard let parser = nextcrm_html_create(Unmanaged.passUnretained(output).toOpaque(),{ context,kind,bytes,count in
            guard let context else { return 0 }; let output = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            do { let text = bytes.map{String(decoding:UnsafeRawBufferPointer(start:$0,count:count),as:UTF8.self)} ?? ""; try output.event(kind,text); return 1 }
            catch { output.error = error; return 0 }
        }) else { throw NativeMailFailure.malformed }
        defer { nextcrm_html_destroy(parser) }
        func feed(_ text:String,final:Bool = false) throws {
            let bytes = Array(text.utf8), code = bytes.withUnsafeBufferPointer{nextcrm_html_feed(parser,$0.baseAddress,$0.count,final ? 1 : 0)}
            if let error = output.error { throw error }; guard code == 0 else { throw NativeMailFailure.malformed }
        }
        try feed("<html><body><div>")
        try CampaignHTML.sanitize(html) { try feed($0) }
        try feed("</div></body></html>",final:true)
        return output.text.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func addresses(_ value:SQLValue) -> String {
        let parsed = (try? JSONDecoder().decode([NativeMailAddress].self,from:Data(value.string.utf8))) ?? []
        return parsed.map{ address in
            if let name = address.name, !name.isEmpty { return name+" <"+address.email+">" }
            return address.email
        }.joined(separator:", ")
    }
    static func date(_ value:String) -> String {
        guard let date = try? NativeCalendarEvents.date(value) else { return "日時不明" }
        let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm"; return f.string(from:date)
    }
}
