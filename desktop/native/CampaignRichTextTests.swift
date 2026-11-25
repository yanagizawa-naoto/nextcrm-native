import AppKit

@main enum CampaignRichTextTests {
    static var checks = 0
    static func check(_ ok: @autoclosure () throws -> Bool, _ name: String) throws { guard try ok() else { throw NativeDBError.message("FAIL: "+name) }; checks += 1 }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignRichTextTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        func convert(_ html: String) throws -> CampaignRichText.Serialized { try CampaignRichText.serialize(CampaignRichText.load(html).text) }
        let cases: [(String,String)] = [
            ("","<p></p>"),
            ("<p>日本語 &amp; 😀 <strong>太字</strong><em>斜体</em><u>下線</u><s>取消</s><code>x&lt;y</code></p>","日本語 &amp; 😀"),
            ("<h1>見出し</h1><h2><strong>強調</strong></h2><p></p><p>次<br>の行</p>","<p></p><p>次<br>の行</p>"),
            ("<ol start=\"3\"><li><p>一</p><ul><li><p>子</p></li></ul></li><li><p>二</p></li></ol>","<ol start=\"3\"><li><p>一</p><ul><li><p>子</p></li></ul></li><li><p>二</p></li></ol>"),
            ("<blockquote><p>引用</p><p>二段落</p></blockquote><p>続き</p>","<blockquote><p>引用</p><p>二段落</p></blockquote><p>続き</p>"),
            ("<pre><code class=\"language-swift\">let x = 1\n  print(x)\n日本語😀</code></pre>","class=\"language-swift\""),
            ("<p><a href=\"https://example.invalid/?a=1&amp;b=2\">リンク</a></p>","href=\"https://example.invalid/?a=1&amp;b=2\""),
            ("<hr><p>後</p>","<hr><p>後</p>"),
            ("前<strong>強調</strong>後","<p>前<strong>強調</strong>後</p>"),
            ("<ul><li>前<strong>強調</strong><ul><li>子</li></ul>後</li></ul>","<li><p>前<strong>強調</strong></p><ul><li><p>子</p></li></ul><p>後</p></li>")
        ]
        for (i,c) in cases.enumerated() {
            let loaded = try CampaignRichText.load(c.0), out = try CampaignRichText.serialize(loaded.text)
            try check(loaded.protectedBlocks == 0,"supported fixture \(i)")
            try check(out.html.contains(c.1),"HTML fidelity \(i): "+out.html)
            let round = try convert(out.html)
            try check(round.html == out.html,"HTML fixed point \(i): "+round.html)
            try check(round.json == out.json,"JSON fixed point \(i): "+out.json+" -> "+round.json)
        }
        let heading = try convert("<h1>題</h1><h2><strong>強調</strong></h2>")
        try check(heading.html == "<h1>題</h1><h2><strong>強調</strong></h2>","structural and explicit bold")
        let pre = try convert(cases[5].0)
        try check(pre.html.contains("let x = 1\n  print(x)\n日本語😀") && pre.json.contains("language"),"code whitespace/language")
        for html in ["<p style=\"color:red\">色</p>","<table><tr><td>表😀</td></tr></table>","<p>前<img src=\"https://example.invalid/image.png\">後</p>","<p><a href=\"javascript:alert(1)\">危険</a></p>","<html><head><style>p {color:red}</style></head><body><p>文</p></body></html>","<!DOCTYPE html [<!ENTITY local SYSTEM 'file:///etc/passwd'>]><p>&local;</p>"] {
            let loaded = try CampaignRichText.load(html), out = try CampaignRichText.serialize(loaded.text)
            try check(loaded.protectedBlocks > 0 && !loaded.text.string.contains("root:"),"protected and no entity expansion")
            try check(out.html.contains(html.contains("<table") ? "表😀" : html.contains("<img") ? "image.png" : html.contains("javascript") ? "javascript:" : html.contains("<!DOCTYPE") ? "<!ENTITY" : html.contains("<style") ? "<style>" : "color:red"),"protected source retained")
            let altered = NSMutableAttributedString(attributedString:loaded.text); altered.replaceCharacters(in:NSRange(location:0,length:1),with:"x")
            do { _ = try CampaignRichText.serialize(altered); throw NativeDBError.message("changed protected label accepted") } catch NativeDBError.message(let m) where m.contains("保護されたHTML") { checks += 1 }
        }
        for url in ["https://example.invalid/日本語", "http://example.invalid", "mailto:test@example.invalid"] { try check(CampaignRichText.safeLink(url) != nil,"safe URL") }
        for url in ["javascript:alert(1)","file:///tmp/x","data:text/html,abc","//example.invalid","https:","https://exa\nmple.invalid"] { try check(CampaignRichText.safeLink(url) == nil,"unsafe URL") }
        let bad = NSMutableAttributedString(string:"bad",attributes:CampaignRichText.attributes(CampaignTextBlock())); bad.addAttribute(.link,value:"file:///tmp/x",range:NSRange(location:0,length:3))
        do { _ = try CampaignRichText.serialize(bad); throw NativeDBError.message("unsafe attributed link accepted") } catch NativeDBError.message(let m) where m.contains("リンクには") { checks += 1 }
        for source in ["<p><a href=\"https://example.invalid\" target=\"_self\">既存リンク</a></p>","<p><!--[if mso]>古いレイアウト<![endif]-->本文</p>","<script>alert(1)</script><p>本文</p>"] { let loaded = try CampaignRichText.load(source); try check(source.contains("_self") ? loaded.protectedBlocks == 0 : loaded.protectedBlocks > 0,"source-supported _self link editable; unsupported markup protected"); try check(try CampaignRichText.serialize(loaded.text).html.contains(source.contains("_self") ? "_self" : source.contains("mso") ? "mso" : "script"),"special HTML retained") }
        // NSTextView editing without invoking the HTML importer or touching the user's pasteboard.
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:500,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        let view = CampaignTextView(frame:NSRect(x:0,y:0,width:500,height:400)); view.isRichText = true; view.allowsUndo = true; window.contentView = view; window.makeFirstResponder(view)
        func load(_ source: String) throws { view.textStorage!.setAttributedString(try CampaignRichText.load(source).text); view.undoManager?.removeAllActions(); view.setSelectedRange(NSRange(location:0,length:0)); view.typingAttributes = view.textStorage!.attributes(at:0,effectiveRange:nil) }
        try load("<ul><li><p>最初</p></li></ul>"); view.setSelectedRange(NSRange(location:2,length:0)); view.insertNewline(nil); view.insertText("次",replacementRange:view.selectedRange())
        let newList = try CampaignRichText.serialize(view.attributedString()).html
        try check(newList == "<ul><li><p>最初</p></li><li><p>次</p></li></ul>","list return: "+newList)
        view.breakUndoCoalescing(); RunLoop.current.run(until:Date().addingTimeInterval(0.02)); try check(view.undoManager?.canUndo == true,"native undo available")
        view.undoManager?.undo(); try check(view.string.contains("最初"),"undo retains existing content")
        try load("<p>日本語😀</p>"); view.setSelectedRange(NSRange(location:0,length:2)); view.setMarkedText("にほん",selectedRange:NSRange(location:3,length:0),replacementRange:view.selectedRange()); try check(view.hasMarkedText(),"IME marked text")
        view.insertText("日本",replacementRange:view.markedRange()); try check(!view.hasMarkedText() && view.string == "日本語😀\n","IME commit and emoji")
        try load("<p>前</p>"); view.setSelectedRange(NSRange(location:0,length:0)); view.insertText(try CampaignRichText.load("<p><strong>貼付</strong></p>").text,replacementRange:view.selectedRange()); view.breakUndoCoalescing(); RunLoop.current.run(until:Date().addingTimeInterval(0.02)); view.undoManager?.undo(); try check(view.string == "前\n","rich insertion undo")
        try load("<ul><li><p>最初</p></li><li><p></p></li></ul>"); view.setSelectedRange(NSRange(location:3,length:0)); view.insertNewline(nil)
        try check(try CampaignRichText.serialize(view.attributedString()).html == "<ul><li><p>最初</p></li></ul><p></p>","empty list return exits list")
        window.orderOut(nil)
        print("CampaignRichTextTests: \(checks) checks passed")
    }
}
