import AppKit

struct CampaignContainer: Codable, Equatable {
    var tag: String; var id: String; var start: Int?
}
struct CampaignTextBlock: Codable, Equatable {
    var tag = "p"
    var path: [CampaignContainer] = []
    var rawHTML: String?
    var marker: String?
    var language: String?
    static let key = NSAttributedString.Key("NextCRMCampaignBlock")
    var encoded: String { String(decoding:try! JSONEncoder().encode(self),as:UTF8.self) }
    static func read(_ value: Any?) -> CampaignTextBlock {
        guard let s = value as? String, let block = try? JSONDecoder().decode(Self.self,from:Data(s.utf8)) else { return Self() }; return block
    }
}

enum CampaignRichText {
    static let codeKey = NSAttributedString.Key("NextCRMCampaignCode")
    static let boldKey = NSAttributedString.Key("NextCRMCampaignBold")
    static let linkAttributesKey = NSAttributedString.Key("NextCRMCampaignLinkAttributes")
    static let rawLabel = "［既存のHTMLを保持：表・画像・詳細な書式］"
    static let baseFont = NSFont.systemFont(ofSize:14)
    static let base: [NSAttributedString.Key:Any] = [.font:baseFont,.foregroundColor:NSColor.labelColor]
    struct Loaded { let text: NSAttributedString; let protectedBlocks: Int }
    struct Serialized { let html: String; let json: String }
    static func safeLink(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}), let url = URL(string:text), let scheme = url.scheme?.lowercased(), ["http","https","mailto"].contains(scheme) else { return nil }
        if scheme != "mailto", url.host?.isEmpty != false { return nil }
        return text
    }
    static func style(_ block: CampaignTextBlock) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 8
        let indent = CGFloat(block.path.filter{["li","blockquote"].contains($0.tag)}.count)*24
        p.headIndent = indent; p.firstLineHeadIndent = indent
        return p
    }
    static func attributes(_ block: CampaignTextBlock) -> [NSAttributedString.Key:Any] {
        var a = base; a[CampaignTextBlock.key] = block.encoded; a[.paragraphStyle] = style(block)
        if block.tag.hasPrefix("h"), let level = Int(block.tag.dropFirst()), (1...6).contains(level) { a[.font] = NSFont.systemFont(ofSize:CGFloat(max(15,30-level*3)),weight:.bold) }
        if block.tag == "pre" { a[.font] = NSFont.monospacedSystemFont(ofSize:13,weight:.regular) }
        if block.rawHTML != nil { a[.foregroundColor] = NSColor.secondaryLabelColor; a[.backgroundColor] = NSColor.quaternaryLabelColor }
        return a
    }
    /// Use numeric references with XMLDocument's string initializer to retain
    /// Japanese/emoji; its data initializer misdecodes these on our SDK. No WebKit,
    /// external entities, network resources, or HTML text-import machinery.
    static func load(_ html: String) throws -> Loaded {
        let result = NSMutableAttributedString(string:""); var protected = 0; var counter = 0
        func append(_ content: NSAttributedString, _ block: CampaignTextBlock) {
            let text = NSMutableAttributedString(attributedString:content)
            if block.tag != "pre", block.rawHTML == nil {
                // Collapse across inline-node boundaries, keeping the first
                // space's attributes as the upstream DOM parser does.
                let collapsed = NSMutableAttributedString(string: "")
                var previousSpace = false
                let originalText = text.string as NSString
                text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                    var run = ""
                    for scalar in originalText.substring(with: range).unicodeScalars {
                        if scalar == " " {
                            if !previousSpace { run.unicodeScalars.append(scalar) }
                            previousSpace = true
                        } else { run.unicodeScalars.append(scalar); previousSpace = false }
                    }
                    if !run.isEmpty { collapsed.append(NSAttributedString(string: run, attributes: attributes)) }
                }
                text.setAttributedString(collapsed)
                // HTML collapses whitespace at block boundaries; tidy may add
                // formatting line breaks there. Keep NBSP and explicit <br>.
                let whitespace = CharacterSet(charactersIn:" \t\r\n")
                while text.length > 0, let last = text.string.unicodeScalars.last, whitespace.contains(last) { text.deleteCharacters(in:NSRange(location:text.length-1,length:1)) }
                while text.length > 0, let first = text.string.unicodeScalars.first, whitespace.contains(first) { text.deleteCharacters(in:NSRange(location:0,length:1)) }
            }
            let start = result.length; result.append(text); result.append(NSAttributedString(string:"\n",attributes:attributes(block)))
            result.addAttributes([CampaignTextBlock.key:block.encoded,.paragraphStyle:style(block)],range:NSRange(location:start,length:result.length-start))
        }
        func protect(_ source: String) { protected += 1; var b = CampaignTextBlock(); b.rawHTML = source; append(NSAttributedString(string:rawLabel,attributes:attributes(b)),b) }
        if html.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { let b = CampaignTextBlock(); append(NSAttributedString(string:"",attributes:attributes(b)),b); return Loaded(text:result,protectedBlocks:0) }
        let lower = html.lowercased()
        // A full email can carry styles in its head. Keep it whole rather than
        // silently extracting its body and losing layout or style definitions.
        if lower.contains("<html") || lower.contains("<head") || lower.contains("<style") || lower.contains("<!entity") || lower.contains("<!doctype") || lower.contains("<!--") || html.utf8.count > 4*1024*1024 {
            protect(html); return Loaded(text:result,protectedBlocks:protected)
        }
        // This is only a quote-aware text/markup boundary walk for encoding;
        // XMLDocument remains the sole HTML tree parser. Never inject tokens
        // into a quoted attribute that happens to contain tag-looking text.
        func scanText(_ source: String, _ visit: (Unicode.Scalar, Int, Bool) -> Void) {
            var iterator = source.unicodeScalars.makeIterator()
            var scalar = iterator.next(), following = iterator.next(), offset = 0
            var inTag = false, quote: Unicode.Scalar?
            while let current = scalar {
                visit(current, offset, !inTag)
                if inTag {
                    if let active = quote { if current == active { quote = nil } }
                    else if current == "\"" || current == "'" { quote = current }
                    else if current == ">" { inTag = false }
                } else if current == "<", let next = following,
                          (65...90).contains(next.value) || (97...122).contains(next.value) || next == "/" || next == "!" || next == "?" { inTag = true }
                offset += current.value > 0xffff ? 2 : 1
                scalar = following; following = iterator.next()
            }
        }
        func textPositions(_ source: String, _ proposed: Set<Int>) -> [Int] {
            var positions: [Int] = []
            scanText(source) { _, offset, isText in if isText && proposed.contains(offset) { positions.append(offset) } }
            return positions.reversed()
        }
        // Tidy removes empty nodes and moves spaces outside inline marks.
        // Input-absent tokens protect only those boundaries during parsing;
        // they are removed before constructing attributed text or persisting.
        var tokenPrefix: String
        repeat { tokenPrefix = "NextCRMPreserve" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while html.contains(tokenPrefix)
        let emptyToken = tokenPrefix + "E", spaceToken = tokenPrefix + "S", preEndToken = tokenPrefix + "P"
        let emptyPattern = try NSRegularExpression(pattern: #"(?is)<(h[1-6]|pre|code|li|blockquote)(?:\s[^>]*)?>[\t\r\n ]*(</\1\s*>)"#)
        let prepared = NSMutableString(string: html)
        let emptyPositions = Set(emptyPattern.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)).map { $0.range(at: 2).location })
        for position in textPositions(html, emptyPositions) { prepared.insert(emptyToken, at: position) }
        let markedSource = prepared as String
        let markStart = try NSRegularExpression(pattern: #"(?is)<(?:strong|b|em|i|u|s|strike|del|code|a)(?:[\t\r\n\f ]+(?:[^>"']|"[^"]*"|'[^']*')*)?>([\t\r\n\f ]+)"#)
        let markEnd = try NSRegularExpression(pattern: #"(?is)([\t\r\n\f ]+)</(?:strong|b|em|i|u|s|strike|del|code|a)[\t\r\n\f ]*>"#)
        let markedRange = NSRange(location: 0, length: prepared.length)
        var boundaries = Set(markStart.matches(in: markedSource, range: markedRange).map { $0.range(at: 1).location })
        boundaries.formUnion(markEnd.matches(in: markedSource, range: markedRange).map { NSMaxRange($0.range(at: 1)) })
        for boundary in textPositions(markedSource, boundaries) { prepared.insert(spaceToken, at: boundary) }
        // Tidy appends a formatting newline to a bare <pre>. Mark the original
        // end inside text so only parser-added trailing text is discarded.
        let preSource=prepared as String, preEnd=try NSRegularExpression(pattern:#"(?is)</pre[\t\r\n\f ]*>"#)
        let ends=Set(preEnd.matches(in:preSource,range:NSRange(location:0,length:prepared.length)).map{$0.range.location})
        for end in textPositions(preSource,ends) {prepared.insert(preEndToken,at:end)}
        var ascii = ""; ascii.reserveCapacity(html.utf8.count)
        scanText(prepared as String) { scalar, _, isText in
            // A character reference avoids tidy's tab-stop expansion in pre.
            // Attribute separators/quoted values stay unchanged.
            if scalar.value > 127 || (scalar.value == 9 && isText) { ascii += "&#\(scalar.value);" }
            else { ascii.unicodeScalars.append(scalar) }
        }
        let document: XMLDocument
        do { document = try XMLDocument(xmlString:"<html><head></head><body>"+ascii+"</body></html>",options:[.documentTidyHTML,.nodeLoadExternalEntitiesNever]) }
        catch { protect(html); return Loaded(text:result,protectedBlocks:protected) }
        guard let root = document.rootElement(), let body = root.elements(forName:"body").first else { protect(html); return Loaded(text:result,protectedBlocks:protected) }
        if root.elements(forName:"head").first?.children?.contains(where:{$0.kind == .element && !($0.name == "title" && ($0.stringValue ?? "").isEmpty)}) == true { protect(html); return Loaded(text:result,protectedBlocks:protected) }
        let tags: Set<String> = ["p","h1","h2","h3","h4","h5","h6","strong","b","em","i","u","s","strike","del","code","pre","ul","ol","li","blockquote","hr","br","a"]
        func supported(_ node: XMLNode, depth: Int = 0) -> Bool {
            guard depth < 64 else { return false }
            guard let e = node as? XMLElement else { return node.kind == .text || node.kind == .comment }
            let tag = (e.localName ?? e.name ?? "").lowercased(); guard tags.contains(tag) else { return false }
            for a in e.attributes ?? [] {
                if tag == "a" && ["href","target","rel","class","title"].contains(a.name ?? "") {
                    if a.name == "href", safeLink(a.stringValue ?? "") == nil { return false }
                    continue
                }
                if tag == "ol" && a.name == "start", Int(a.stringValue ?? "") != nil { continue }
                if tag == "code" && e.parent?.name?.lowercased() == "pre" && a.name == "class", (a.stringValue ?? "").range(of:#"^language-[A-Za-z0-9_+-]+$"#,options:.regularExpression) != nil { continue }
                return false
            }
            return (e.children ?? []).allSatisfy { supported($0,depth:depth+1) }
        }
        // Once tidy has normalized an unsupported element, its XML string no
        // longer preserves the source (table cell spaces are one example).
        // Keep the original fragment rather than serialize altered raw HTML.
        guard (body.children ?? []).allSatisfy({ supported($0) }) else {
            protect(html); return Loaded(text: result, protectedBlocks: protected)
        }
        func inline(_ node: XMLNode, _ attrs: [NSAttributedString.Key:Any], pre: Bool) -> NSAttributedString {
            if node.kind == .text {
                var original=node.stringValue ?? ""
                if pre,let end=original.range(of:preEndToken) {original=String(original[..<end.lowerBound])}
                var text = original.replacingOccurrences(of: emptyToken, with: "").replacingOccurrences(of: spaceToken, with: "")
                if !pre { text = text.replacingOccurrences(of:#"[\t\r\n ]+"#,with:" ",options:.regularExpression) }
                else { text = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n") }
                return NSAttributedString(string:text.replacingOccurrences(of:"\n",with:"\u{2028}"),attributes:attrs)
            }
            guard let e = node as? XMLElement else { return NSAttributedString(string:"") }
            var a = attrs; let tag = (e.localName ?? e.name ?? "").lowercased()
            switch tag {
            case "strong","b": a[boldKey] = true; a[.font] = NSFontManager.shared.convert((a[.font] as? NSFont) ?? baseFont,toHaveTrait:.boldFontMask)
            case "em","i": a[.obliqueness] = 0.18
            case "u": a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "s","strike","del": a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "code": if !pre { a[codeKey] = true; a[.font] = NSFont.monospacedSystemFont(ofSize:13,weight:.regular) }
            case "a": if let link = safeLink(e.attribute(forName:"href")?.stringValue ?? "") {
                a[.link] = link; a[.foregroundColor] = NSColor.linkColor
                let values:[String:Any] = ["target":e.attribute(forName:"target")?.stringValue ?? "_blank", "rel":e.attribute(forName:"rel")?.stringValue ?? "noopener noreferrer nofollow", "class":e.attribute(forName:"class")?.stringValue as Any? ?? NSNull(), "title":e.attribute(forName:"title")?.stringValue as Any? ?? NSNull()]
                if let data=try? JSONSerialization.data(withJSONObject:values,options:.sortedKeys) {a[linkAttributesKey]=String(decoding:data,as:UTF8.self)}
            }
            case "br": return NSAttributedString(string:"\u{2028}",attributes:a)
            default: break
            }
            let out = NSMutableAttributedString(string:""); for child in e.children ?? [] { out.append(inline(child,a,pre:pre)) }; return out
        }
        func walk(_ node: XMLNode, path: [CampaignContainer], marker: String? = nil) {
            if node.kind == .text {
                if !(node.stringValue ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { let b = CampaignTextBlock(path:path,marker:marker); append(inline(node,attributes(b),pre:false),b) }; return
            }
            guard let e = node as? XMLElement else { return }
            let tag = (e.localName ?? e.name ?? "").lowercased()
            guard supported(e) else {
                protected += 1; let b = CampaignTextBlock(path:path,rawHTML:e.xmlString,marker:marker); append(NSAttributedString(string:rawLabel,attributes:attributes(b)),b); return
            }
            if ["ul","ol","li","blockquote"].contains(tag) {
                counter += 1; let part = CampaignContainer(tag:tag,id:"import-\(counter)",start:tag == "ol" ? Int(e.attribute(forName:"start")?.stringValue ?? "1") : nil)
                let next = path+[part]
                // Source listItem requires a paragraph first. ProseMirror's
                // HTML parser closes an empty item/list when the first child
                // is another block, then fits that block outside the list.
                // Reuse the existing tree; no separate HTML parser is added.
                if tag == "li", let first=(e.children ?? []).first(where:{$0.kind == .element || ($0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}),
                   ["h1","h2","h3","h4","h5","h6","pre","blockquote","hr","ul","ol"].contains((first.name ?? "").lowercased()), let list=path.last, ["ul","ol"].contains(list.tag) {
                    let b=CampaignTextBlock(path:next);append(NSAttributedString(string:"",attributes:attributes(b)),b)
                    walkChildren(e.children ?? [],path:Array(path.dropLast()),marker:marker);return
                }
                walkChildren(e.children ?? [],path:next,marker:marker)
                if tag == "li", (e.children ?? []).isEmpty { let b = CampaignTextBlock(path:next); append(NSAttributedString(string:"",attributes:attributes(b)),b) }
                return
            }
            var block = CampaignTextBlock(tag:tag == "hr" ? "hr" : ["p","pre","h1","h2","h3","h4","h5","h6"].contains(tag) ? tag : "p",path:path,marker:marker)
            if tag == "pre", let value = e.elements(forName:"code").first?.attribute(forName:"class")?.stringValue { block.language = String(value.dropFirst("language-".count)) }
            append(tag == "hr" ? NSAttributedString(string:"────────",attributes:attributes(block)) : inline(e,attributes(block),pre:tag == "pre"),block)
        }
        func walkChildren(_ children: [XMLNode], path: [CampaignContainer], marker: String?) {
            let inlineTags: Set<String> = ["strong","b","em","i","u","s","strike","del","code","br","a"]
            var group: [XMLNode] = []
            func flush() {
                guard !group.isEmpty else { return }; defer { group.removeAll(keepingCapacity:true) }
                let b = CampaignTextBlock(path:path,marker:marker), text = NSMutableAttributedString(string:"")
                for node in group { text.append(inline(node,attributes(b),pre:false)) }
                if !text.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.string.contains("\u{2028}") || group.contains(where: { ($0.stringValue ?? "").contains(emptyToken) }) { append(text,b) }
            }
            for node in children {
                if node.kind == .text || node.kind == .comment || (inlineTags.contains((node.name ?? "").lowercased()) && supported(node)) { group.append(node) }
                else { flush(); walk(node,path:path,marker:marker) }
            }
            flush()
        }
        walkChildren(body.children ?? [],path:[],marker:nil)
        if result.length == 0 { let b = CampaignTextBlock(); append(NSAttributedString(string:"",attributes:attributes(b)),b) }
        return Loaded(text:result,protectedBlocks:protected)
    }
    static func paragraphs(_ text: NSAttributedString) -> [NSRange] {
        let s = text.string as NSString; var ranges: [NSRange] = []; var offset = 0
        while offset < s.length { let match = s.range(of:"\n",range:NSRange(location:offset,length:s.length-offset)); let end = match.location == NSNotFound ? s.length : match.location; ranges.append(NSRange(location:offset,length:end-offset)); offset = end+1 }
        return ranges.isEmpty ? [NSRange(location:0,length:0)] : ranges
    }
    private final class JSONNode {
        let type: String; var attrs: [String:Any]; var content: [JSONNode] = []; var text: String?; var marks: [[String:Any]] = []
        init(_ type: String, attrs: [String:Any] = [:]) { self.type = type; self.attrs = attrs }
        var object: [String:Any] { var r: [String:Any] = ["type":type]; if !attrs.isEmpty { r["attrs"] = attrs }; if !content.isEmpty { r["content"] = content.map(\.object) }; if let text { r["text"] = text }; if !marks.isEmpty { r["marks"] = marks }; return r }
    }
    static func serialize(_ text: NSAttributedString) throws -> Serialized {
        var html = ""; var path: [CampaignContainer] = []; let root = JSONNode("doc"); var nodes = [root]
        func escape(_ s: String) -> String { CampaignMergeTags.htmlEscape(s) }
        for range in paragraphs(text) {
            let block = text.length > range.location ? CampaignTextBlock.read(text.attribute(CampaignTextBlock.key,at:range.location,effectiveRange:nil)) : CampaignTextBlock()
            var shared = 0; while shared < min(path.count,block.path.count) && path[shared] == block.path[shared] { shared += 1 }
            for item in path.dropFirst(shared).reversed() { html += "</\(item.tag)>"; nodes.removeLast() }
            for item in block.path.dropFirst(shared) {
                guard ["ul","ol","li","blockquote"].contains(item.tag) else { throw NativeDBError.message("本文の段落情報が不正です。") }
                html += "<\(item.tag)"+(item.tag == "ol" ? " start=\"\(item.start ?? 1)\"" : "")+">"
                let name = ["ul":"bulletList","ol":"orderedList","li":"listItem","blockquote":"blockquote"][item.tag]!
                let child = JSONNode(name,attrs:item.tag == "ol" ? ["start":item.start ?? 1] : [:]); nodes.last!.content.append(child); nodes.append(child)
            }; path = block.path
            let string = (text.string as NSString).substring(with:range)
            if let raw = block.rawHTML {
                guard string == rawLabel else { throw NativeDBError.message("保護されたHTMLの内容を変更するには「HTMLを編集」を使ってください。") }
                html += raw
                let node = JSONNode("paragraph",attrs:["nativeRawHTML":raw]); let label = JSONNode("text"); label.text = rawLabel; node.content = [label]; nodes.last!.content.append(node); continue
            }
            let tag = ["p","h1","h2","h3","h4","h5","h6","pre","hr"].contains(block.tag) ? block.tag : "p"
            let node = JSONNode(tag == "pre" ? "codeBlock" : tag == "hr" ? "horizontalRule" : tag == "p" ? "paragraph" : "heading",attrs:tag == "pre" ? ["language":block.language as Any? ?? NSNull()] : tag.hasPrefix("h") && tag != "hr" ? ["level":Int(tag.dropFirst())!] : [:])
            nodes.last!.content.append(node)
            if tag == "hr" { guard string == "────────" || string.isEmpty else { throw NativeDBError.message("区切り線の文字を編集する場合は段落の書式を解除してください。") }; html += "<hr>"; continue }
            if tag == "pre" { html += "<pre><code"+(block.language.map{" class=\"language-"+escape($0)+"\""} ?? "")+">"+escape(string.replacingOccurrences(of:"\u{2028}",with:"\n"))+"</code></pre>"; if !string.isEmpty { let t = JSONNode("text"); t.text = string.replacingOccurrences(of:"\u{2028}",with:"\n"); node.content = [t] }; continue }
            html += "<\(tag)>"
            var invalidLink = false
            text.enumerateAttributes(in:range) { a,r,_ in
                let raw = (text.string as NSString).substring(with:r); var open = "", close = ""; var marks: [[String:Any]] = []
                func mark(_ type: String, _ tag: String, attrs: [String:Any] = [:]) { var m: [String:Any] = ["type":type]; if !attrs.isEmpty { m["attrs"] = attrs }; marks.append(m); open += "<\(tag)>"; close = "</\(tag.components(separatedBy:" ")[0])>"+close }
                let font = a[.font] as? NSFont ?? baseFont
                // TipTap's code mark excludes every other mark. Keep the HTML
                // and JSON representations consistent with that actual schema.
                if a[codeKey] as? Bool == true { mark("code","code") }
                else {
                // A heading's own bold font is structural, not a new bold mark.
                if a[boldKey] as? Bool == true || (NSFontManager.shared.traits(of:font).contains(.boldFontMask) && tag == "p") { mark("bold","strong") }
                if (a[.obliqueness] as? NSNumber)?.doubleValue != nil || NSFontManager.shared.traits(of:font).contains(.italicFontMask) { mark("italic","em") }
                if (a[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 { mark("underline","u") }
                if (a[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0 { mark("strike","s") }
                if let link = a[.link] {
                    let value = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
                    if let safe = safeLink(value) {
                        var attrs:[String:Any] = ["target":"_blank","rel":"noopener noreferrer nofollow","class":NSNull(),"title":NSNull()]
                        if let encoded=a[linkAttributesKey] as? String, let data=encoded.data(using:.utf8), let stored=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                            for key in ["target","rel","class","title"] {if let value=stored[key], value is String || value is NSNull {attrs[key]=value}}
                        }
                        attrs["href"]=safe
                        var tag="a href=\""+escape(safe)+"\""
                        for key in ["target","rel","class","title"] {if let value=attrs[key] as? String {tag += " \(key)=\""+escape(value)+"\""}}
                        mark("link",tag,attrs:attrs)
                    } else { invalidLink = true }
                }
                }
                let parts = raw.components(separatedBy:"\u{2028}")
                for (i,part) in parts.enumerated() { if i > 0 { html += open+"<br>"+close; let lineBreak = JSONNode("hardBreak"); lineBreak.marks = marks; node.content.append(lineBreak) }; if !part.isEmpty { html += open+escape(part)+close; let child = JSONNode("text"); child.text = part; child.marks = marks; node.content.append(child) } }
            }
            guard !invalidLink else { throw NativeDBError.message("リンクにはhttp・https・mailtoのURLを指定してください。") }
            html += "</\(tag)>"
        }
        for item in path.reversed() { html += "</\(item.tag)>" }
        func checkLists(_ node: JSONNode) throws {
            if node.type == "listItem", node.content.first?.type != "paragraph" {
                throw NativeDBError.message("箇条書きの先頭は「本文」の段落にしてください。")
            }
            for child in node.content { try checkLists(child) }
        }
        try checkLists(root)
        return Serialized(html:html,json:String(decoding:try JSONSerialization.data(withJSONObject:root.object,options:[.sortedKeys]),as:UTF8.self))
    }
}

/// Paragraph markers are drawn in the margin; they are never editable text
/// that could leak into HTML, receive IME input, or be duplicated on paste.
final class CampaignTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with:event)
        // A sole newline stores the empty paragraph's formatting. Clicking
        // below it should begin that paragraph, not create a blank first line.
        if isEditable && string == "\n" { setSelectedRange(NSRange(location:0,length:0)) }
    }
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        if let html = pasteboard.string(forType:.html), let loaded = try? CampaignRichText.load(html) {
            // Insert our own native rendering, never NSTextView's HTML importer.
            insertText(loaded.text,replacementRange:selectedRange())
        } else if let plain = pasteboard.string(forType:.string) { insertText(plain,replacementRange:selectedRange()) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        let visible = layout.glyphRange(forBoundingRect:visibleRect.offsetBy(dx:-textContainerOrigin.x,dy:-textContainerOrigin.y),in:container)
        let chars = layout.characterRange(forGlyphRange:visible,actualGlyphRange:nil)
        var numbered: [String:Int] = [:]; var seen: Set<String> = []
        for r in CampaignRichText.paragraphs(storage) {
            guard r.location < storage.length else { continue }
            let b = CampaignTextBlock.read(storage.attribute(CampaignTextBlock.key,at:r.location,effectiveRange:nil))
            guard let item = b.path.last(where:{$0.tag == "li"}), let list = b.path.last(where:{$0.tag == "ul" || $0.tag == "ol"}) else { continue }
            let first = seen.insert(item.id).inserted
            if first { numbered[list.id] = (numbered[list.id] ?? ((list.start ?? 1)-1))+1 }
            guard first, NSIntersectionRange(NSRange(location:r.location,length:max(1,r.length)),chars).length > 0 else { continue }
            let glyph = layout.glyphRange(forCharacterRange:NSRange(location:r.location,length:min(1,storage.length-r.location)),actualCharacterRange:nil)
            let rect = layout.boundingRect(forGlyphRange:glyph,in:container)
            let marker = list.tag == "ul" ? "•" : "\(numbered[list.id] ?? 1)."
            let indent = CampaignRichText.style(b).headIndent
            (marker as NSString).draw(at:NSPoint(x:textContainerOrigin.x+indent-20,y:textContainerOrigin.y+rect.minY),withAttributes:CampaignRichText.base)
        }
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else { super.insertNewline(sender); return }
        let position = min(selectedRange().location,max(0,storage.length-1))
        var b = storage.length > 0 ? CampaignTextBlock.read(storage.attribute(CampaignTextBlock.key,at:position,effectiveRange:nil)) : CampaignTextBlock()
        if b.tag == "pre" { insertText("\u{2028}",replacementRange:selectedRange()); return }
        if selectedRange().length == 0, let r = CampaignRichText.paragraphs(storage).first(where:{$0.location == selectedRange().location && $0.length == 0}), let listIndex = b.path.lastIndex(where:{$0.tag == "ul" || $0.tag == "ol"}) {
            b.path = Array(b.path.prefix(listIndex)); b.tag = "p"
            let attrs = CampaignRichText.attributes(b)
            insertText(NSAttributedString(string:"\n",attributes:attrs),replacementRange:NSRange(location:r.location,length:min(1,storage.length-r.location)))
            setSelectedRange(NSRange(location:r.location,length:0)); typingAttributes = attrs; return
        }
        let selection = selectedRange(), tailStart = NSMaxRange(selectedRange())
        let end = (storage.string as NSString).range(of:"\n",range:NSRange(location:tailStart,length:storage.length-tailStart))
        let tailEnd = end.location == NSNotFound ? storage.length : end.location+1
        let nextText = NSMutableAttributedString(attributedString:storage.attributedSubstring(from:NSRange(location:tailStart,length:tailEnd-tailStart)))
        let insertion = NSMutableAttributedString(string:"\n",attributes:typingAttributes)
        if let i = b.path.lastIndex(where:{$0.tag == "li"}) { b.path[i].id = UUID().uuidString; b.path = Array(b.path.prefix(i+1)) }
        if b.tag.hasPrefix("h") { b.tag = "p" }; b.rawHTML = nil
        let a = CampaignRichText.attributes(b)
        nextText.addAttributes([CampaignTextBlock.key:b.encoded,.paragraphStyle:CampaignRichText.style(b)],range:NSRange(location:0,length:nextText.length))
        insertion.append(nextText)
        insertText(insertion,replacementRange:NSRange(location:selection.location,length:tailEnd-selection.location))
        setSelectedRange(NSRange(location:selection.location+1,length:0)); typingAttributes = a
    }
}
