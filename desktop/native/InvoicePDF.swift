import Foundation
import CoreGraphics
import CoreText

struct InvoicePDFData {
    let title: String; let number: String; let currency: String
    let issueDate: String; let dueDate: String; let supplyDate: String
    let customer: String; let supplier: String; let payment: String
    let publicNotes: String; let footer: String
    let subtotal: String; let vat: String; let total: String
}

/// Vector PDF, written directly to a private file. Only one 100-row page of invoice
/// records and one description's text layout are retained; no PDF-sized Data buffer.
final class InvoicePDF {
    private let context: CGContext; private let data: InvoicePDFData
    private var page = 0; private var y: CGFloat = 0; private var tableMode = false
    private let width: CGFloat = 595.28; private let height: CGFloat = 841.89
    private let margin: CGFloat = 36; private let bottom: CGFloat = 788
    private var columns: [CGFloat] = [221,46,76,46,46,88]
    private let ink = CGColor(gray:0.12,alpha:1); private let muted = CGColor(gray:0.38,alpha:1)
    private var bodyWidth: CGFloat { width-2*margin }
    init(url: URL, data: InvoicePDFData) throws {
        self.data = data
        guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]), let consumer = CGDataConsumer(url:url as CFURL) else { throw NativeDBError.message("請求書PDFの保存先を開けません。") }
        var box = CGRect(x:0,y:0,width:595.28,height:841.89)
        guard let context = CGContext(consumer:consumer,mediaBox:&box,[kCGPDFContextTitle:data.title+" "+data.number,kCGPDFContextCreator:"NextCRM Native"] as CFDictionary) else { throw NativeDBError.message("請求書PDFを作成できません。") }; self.context = context
    }
    private func attributed(_ text: String, size: CGFloat = 10, bold: Bool = false, right: Bool = false, color: CGColor? = nil) -> NSAttributedString {
        let font = CTFontCreateWithName((bold ? "HiraginoSans-W6" : "HiraginoSans-W3") as CFString,size,nil)
        var alignment: CTTextAlignment = right ? .right : .left; var spacing: CGFloat = 3
        let paragraph = withUnsafePointer(to:&alignment) { alignment in withUnsafePointer(to:&spacing) { spacing in
            let settings = [CTParagraphStyleSetting(spec:.alignment,valueSize:MemoryLayout<CTTextAlignment>.size,value:alignment),CTParagraphStyleSetting(spec:.lineSpacingAdjustment,valueSize:MemoryLayout<CGFloat>.size,value:spacing)]
            return CTParagraphStyleCreate(settings,settings.count)
        } }
        return NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color ?? ink,NSAttributedString.Key(kCTParagraphStyleAttributeName as String):paragraph])
    }
    private func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(text),CFRange(),nil,CGSize(width:width,height:1000000),nil).height)+2
    }
    @discardableResult private func draw(_ text: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, start: Int = 0) -> Int {
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),CFRange(location:start,length:0),CGPath(rect:CGRect(x:x,y:self.height-top-height,width:width,height:height),transform:nil),nil)
        context.saveGState(); context.textMatrix = .identity; CTFrameDraw(frame,context); context.restoreGState()
        return CTFrameGetVisibleStringRange(frame).length
    }
    private func rule(_ top: CGFloat, color: CGFloat = 0.82) {
        context.setStrokeColor(CGColor(gray:color,alpha:1)); context.setLineWidth(0.5); context.move(to:CGPoint(x:margin,y:height-top)); context.addLine(to:CGPoint(x:width-margin,y:height-top)); context.strokePath()
    }
    private func finishPage() {
        let shortNumber = String(data.number.prefix(40))+(data.number.count > 40 ? "…" : "")
        rule(804); draw(attributed("NextCRM  |  "+shortNumber,size:8,color:muted),x:margin,top:813,width:bodyWidth-80,height:17)
        draw(attributed("\(page) ページ",size:8,right:true,color:muted),x:width-margin-80,top:813,width:80,height:17)
        context.endPDFPage()
    }
    private func nextPage() {
        if page > 0 { finishPage() }; page += 1; context.beginPDFPage(nil)
        draw(attributed(data.title+(page > 1 ? "（続き）" : ""),size:22,bold:true),x:margin,top:32,width:240,height:36)
        let number = attributed("請求書番号  "+data.number,size:10,right:true)
        let numberHeight = max(28,measure(number,width:bodyWidth-245))
        draw(number,x:margin+245,top:40,width:bodyWidth-245,height:numberHeight)
        y = max(82,40+numberHeight+14); rule(y-8)
        if tableMode { tableHeader() }
    }
    private func ensure(_ space: CGFloat) { if y+space > bottom { nextPage() } }
    private func tableHeader() {
        let labels = ["品名・内容","数量","単価","値引%","税率%","金額"]
        context.setFillColor(CGColor(gray:0.93,alpha:1)); context.fill(CGRect(x:margin,y:height-y-26,width:bodyWidth,height:26))
        var x = margin
        for (i,title) in labels.enumerated() { draw(attributed(title,size:9,bold:true,right:i>0),x:x+5,top:y+6,width:columns[i]-10,height:18); x += columns[i] }
        y += 28
    }
    private func flow(_ text: String, size: CGFloat = 10, bold: Bool = false) throws {
        guard !text.isEmpty else { return }; let content = attributed(text,size:size,bold:bold); var position = 0
        while position < content.length {
            ensure(32); let remaining = bottom-y
            let used = draw(content,x:margin,top:y,width:bodyWidth,height:remaining,start:position)
            guard used > 0 else { throw NativeDBError.message("PDFの文字を配置できません。") }
            let fragment = content.attributedSubstring(from:NSRange(location:position,length:used)); y += measure(fragment,width:bodyWidth)+6
            position += used; if position < content.length { nextPage() }
        }
    }
    private func row(_ row: InvoiceDraftRow, index: Int) throws {
        let description = attributed(row.input.description.isEmpty ? " " : row.input.description,size:10); var position = 0; var first = true
        let amounts = [row.input.quantity,row.input.unitPrice,row.input.discountPercent,row.quote.rate,row.quote.amounts.lineTotal]
        let numberHeights = amounts.enumerated().map { measure(attributed($0.element,size:9,right:true),width:columns[$0.offset+1]-8) }
        let minimumHeight = max(30,(numberHeights.max() ?? 0)+12)
        let fullHeight = max(minimumHeight,measure(description,width:columns[0]-12)+12)
        if fullHeight < bottom-130 { ensure(fullHeight) }
        while position < description.length {
            ensure(first ? max(38,minimumHeight) : 38); let available = min(fullHeight,bottom-y); let startY = y
            let fragmentHeight = max(26,available-12)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(description),CFRange(location:position,length:0),CGPath(rect:CGRect(x:margin+6,y:height-y-6-fragmentHeight,width:columns[0]-12,height:fragmentHeight),transform:nil),nil)
            let used = CTFrameGetVisibleStringRange(frame).length
            guard used > 0 else { throw NativeDBError.message("明細の文章をPDFに配置できません。") }
            let usedHeight = max(first ? minimumHeight : 30,measure(description.attributedSubstring(from:NSRange(location:position,length:used)),width:columns[0]-12)+12)
            if index%2 == 1 { context.setFillColor(CGColor(gray:0.975,alpha:1)); context.fill(CGRect(x:margin,y:height-y-usedHeight,width:bodyWidth,height:usedHeight)) }
            context.saveGState(); context.textMatrix = .identity; CTFrameDraw(frame,context); context.restoreGState()
            if first {
                var x = margin+columns[0]
                for i in amounts.indices {
                    let value = attributed(amounts[i],size:9,right:true)
                    draw(value,x:x+4,top:y+6,width:columns[i+1]-8,height:max(24,measure(value,width:columns[i+1]-8))); x += columns[i+1]
                }
                first = false
            }
            y = startY+usedHeight; rule(y, color:0.9); position += used
            if position < description.length { nextPage() }
        }
    }
    func render(lines: (Int) throws -> [InvoiceDraftRow]) throws -> Int {
        // Preflight numeric widths in bounded pages, so a large quantity is never
        // split into several unrelated-looking numbers. Normal invoices keep the
        // wider description column; only the required numeric columns grow.
        var widths: [CGFloat] = [46,76,46,46,88]; var measuringOffset = 0
        while true {
            let page = try lines(measuringOffset); guard page.count <= 100 else { throw NativeDBError.message("PDF明細は100件ずつ読み込んでください。") }
            for row in page { autoreleasepool {
                let amounts = [row.input.quantity,row.input.unitPrice,row.input.discountPercent,row.quote.rate,row.quote.amounts.lineTotal]
                for i in amounts.indices {
                    let line = CTLineCreateWithAttributedString(attributed(amounts[i],size:9))
                    widths[i] = max(widths[i],ceil(CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil)))+12)
                }
            } }
            measuringOffset += page.count; if page.count < 100 { break }
        }
        let descriptionWidth = bodyWidth-widths.reduce(0,+)
        guard descriptionWidth >= 120 else { throw NativeDBError.message("PDFに収まらない数値が含まれています。明細の金額・数量を確認してください。") }
        columns = [descriptionWidth]+widths
        nextPage()
        try flow("発行日：\(data.issueDate)　支払期限：\(data.dueDate)\n取引日：\(data.supplyDate)　通貨：\(data.currency)",size:9)
        let customer = attributed("請求先\n"+data.customer,size:10); let supplier = attributed("発行元\n"+data.supplier,size:10)
        let half = (bodyWidth-24)/2; let partyHeight = max(measure(customer,width:half),measure(supplier,width:half))
        if partyHeight <= 230 {
            ensure(partyHeight+20); draw(customer,x:margin,top:y+4,width:half,height:partyHeight+4); draw(supplier,x:margin+half+24,top:y+4,width:half,height:partyHeight+4); y += partyHeight+24
        } else { try flow("請求先\n"+data.customer); try flow("発行元\n"+data.supplier) }
        ensure(62); tableMode = true; tableHeader()
        var offset = 0; var buckets: [String:(Decimal,Decimal)] = [:]; var rates:[String] = []
        while true {
            let page = try lines(offset); guard page.count <= 100 else { throw NativeDBError.message("PDF明細は100件ずつ読み込んでください。") }
            for (i,line) in page.enumerated() { try autoreleasepool {
                try row(line,index:offset+i)
                let rate = line.quote.rate; if buckets[rate] == nil { rates.append(rate); buckets[rate] = (0,0) }; let previous = buckets[rate]!
                buckets[rate] = try (PriceDecimal.calculate(previous.0,"+",PriceDecimal.parse(line.quote.amounts.lineSubtotal)),PriceDecimal.calculate(previous.1,"+",PriceDecimal.parse(line.quote.amounts.lineVat)))
            } }
            offset += page.count; if page.count < 100 { break }
        }
        tableMode = false; y += 18; ensure(102)
        for (label,value) in [("小計（税抜）",data.subtotal),("消費税",data.vat),("合計",data.total)] {
            draw(attributed(label,size:label == "合計" ? 13 : 10,bold:label == "合計"),x:margin+265,top:y,width:110,height:23)
            draw(attributed(value+" "+data.currency,size:label == "合計" ? 13 : 10,bold:label == "合計",right:true),x:margin+360,top:y,width:bodyWidth-360,height:23); y += 28
        }
        y += 8; try flow("税率別の内訳",bold:true)
        for rate in rates { let bucket = buckets[rate]!; try flow("税率 \(rate)%　対象額 \(PriceDecimal.string(bucket.0))　消費税 \(PriceDecimal.string(bucket.1)) \(data.currency)",size:9) }
        if !data.payment.isEmpty { y += 8; try flow("お支払い先",bold:true); try flow(data.payment) }
        if !data.publicNotes.isEmpty { y += 8; try flow("備考",bold:true); try flow(data.publicNotes) }
        if !data.footer.isEmpty { y += 8; try flow(data.footer,size:8) }
        finishPage(); context.closePDF(); return page
    }
}
