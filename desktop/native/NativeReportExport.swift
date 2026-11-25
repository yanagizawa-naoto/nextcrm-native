import Foundation
import CoreGraphics
import CoreText
import Darwin

enum NativeReportExportFormat: String {case csv,pdf}

/// Each output uses a private file descriptor and is published atomically only
/// after the final current-permission/snapshot check. Failed exports leave any
/// previous destination intact. No document-sized Data is retained.
enum NativeReportExport {
    static func standardSection(_ category:NativeReportCategory)->String? {
        [.sales:"oppsByMonth",.leads:"newLeads",.accounts:"newAccounts",.activity:"tasksByAssignee",.campaigns:"performance",.users:"userGrowth"][category]
    }
    static func headers(_ section:NativeReportSection)->[String] {
        if section.secondaryTitle != nil {return ["年月","作成数","完了数"]}
        return ["項目",section.id == "topByRevenue" ? "年間売上高" : "件数"]
    }
    @discardableResult static func write(_ snapshot:NativeReportSnapshot,section id:String,format:NativeReportExportFormat,to destination:URL,title:String?=nil) throws -> Int {
        try snapshot.requireCurrent();try Task.checkCancellation()
        if let title {guard !title.isEmpty,title.unicodeScalars.count<=256 else {throw NativeDBError.message("レポートの表題を1〜256文字で指定してください。")}}
        guard destination.isFileURL,let section=snapshot.sections.first(where:{$0.id==id}) else {throw NativeDBError.message("出力する集計項目を確認してください。")}
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".nextcrm-report-"+UUID().uuidString+".tmp")
        let descriptor=open(temporary.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
        guard descriptor>=0 else {throw NativeDBError.message("レポートの保存先を開けません。")}
        let sink=NativeReportFileSink(handle:FileHandle(fileDescriptor:descriptor,closeOnDealloc:true))
        var published=false
        defer {try? sink.handle.close();if !published {try? FileManager.default.removeItem(at:temporary)}}
        let headings=headers(section),pdf:NativeReportPDF?
        if format == .csv {
            pdf=nil;try sink.write(Data([0xef,0xbb,0xbf]));try sink.write(Data((headings.map(csvQuoted).joined(separator:",")+"\r\n").utf8))
        } else {pdf=try NativeReportPDF(sink:sink,snapshot:snapshot,section:section,headers:headings,title:title)}
        var offset=0
        while true {
            try Task.checkCancellation();let page=try snapshot.page(id,offset:offset)
            for row in page.rows {
                try Task.checkCancellation()
                func nameChunks(_ visit:(Data)throws->Void)throws {
                    let translated=NativeReportPresentation.label(row.name,section:id)
                    if !row.truncated && translated != row.name {try visit(Data(translated.utf8))}
                    else {try snapshot.labelChunks(rowID:row.id,visit:visit)}
                }
                if let pdf {
                    try pdf.beginRow(values:[row.value]+(row.secondary.map{[$0]} ?? []))
                    var decoder=NativeReportUTF8()
                    try nameChunks{bytes in try pdf.label(decoder.feed(bytes))}
                    try pdf.label(decoder.finish());try pdf.endRow()
                } else {
                    try sink.write(Data([34]))
                    try nameChunks{bytes in
                        var escaped=Data();escaped.reserveCapacity(bytes.count+16)
                        for byte in bytes {escaped.append(byte);if byte==34 {escaped.append(byte)}}
                        try sink.write(escaped)
                    }
                    let values=[row.value]+(row.secondary.map{[$0]} ?? [])
                    try sink.write(Data(("\","+values.map(csvQuoted).joined(separator:",")+"\r\n").utf8))
                }
            }
            offset+=page.rows.count
            if offset>=page.total {break}
            guard !page.rows.isEmpty else {throw NativeDBError.conflict}
        }
        if offset==0 {pdf?.empty()};try pdf?.finish();if let error=sink.error {throw error};try sink.handle.synchronize();try sink.handle.close()
        try snapshot.service.db.transaction {
            try snapshot.requireCurrent();try Task.checkCancellation()
            guard rename(temporary.path,destination.path)==0 else {throw NativeDBError.message("レポートの保存を完了できません。")}
            published=true
        }
        return offset
    }
    private static func csvQuoted(_ value:String)->String {"\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
}

private final class NativeReportFileSink {
    let handle:FileHandle
    var error:Error?
    init(handle:FileHandle){self.handle=handle}
    func write(_ bytes:Data)throws{try Task.checkCancellation();if let error{throw error};try handle.write(contentsOf:bytes)}
    func consumer()throws->CGDataConsumer {
        let retained=Unmanaged.passRetained(self).toOpaque()
        var callbacks=CGDataConsumerCallbacks(putBytes:{info,bytes,count in
            guard let info else{return 0};let sink=Unmanaged<NativeReportFileSink>.fromOpaque(info).takeUnretainedValue()
            do {try sink.write(Data(bytes:bytes,count:count));return count}catch{sink.error=error;return 0}
        },releaseConsumer:{info in if let info {Unmanaged<NativeReportFileSink>.fromOpaque(info).release()}})
        guard let consumer=CGDataConsumer(info:retained,cbks:&callbacks) else {Unmanaged<NativeReportFileSink>.fromOpaque(retained).release();throw NativeDBError.message("PDFの出力を開始できません。")}
        return consumer
    }
}

/// Decode full SQLite labels across arbitrary UTF-8 byte boundaries; retain at
/// most the current 16-KiB input chunk plus the unfinished scalar.
struct NativeReportUTF8 {
    private var pending=Data()
    mutating func feed(_ data:Data)throws->String {
        pending.append(data);guard !pending.isEmpty else{return ""}
        let bytes=[UInt8](pending);var start=bytes.count-1
        while start>0 && bytes[start]&0xc0==0x80 {start-=1}
        let lead=bytes[start],required=lead<0x80 ? 1 : lead&0xe0==0xc0 ? 2 : lead&0xf0==0xe0 ? 3 : lead&0xf8==0xf0 ? 4 : 1
        let end=bytes.count-start<required ? start : bytes.count
        guard let text=String(bytes:bytes[..<end],encoding:.utf8) else{throw NativeDBError.message("レポートの文字列を読み込めません。")}
        pending=Data(bytes[end...]);return text
    }
    mutating func finish()throws->String {guard pending.isEmpty else{throw NativeDBError.message("レポートの文字列が途中で終了しています。")};return ""}
}

private final class NativeReportPDF {
    private let context:CGContext,sink:NativeReportFileSink,title:String,subtitle:String,headers:[String]
    private let pageWidth:CGFloat=595.28,pageHeight:CGFloat=841.89,margin:CGFloat=36,bottom:CGFloat=786
    private let font=CTFontCreateWithName("HiraginoSans-W3" as CFString,10,nil)
    private var page=0,y:CGFloat=0,buffer="",rowValues:[String]=[],firstLine=true,closed=false
    private var nameWidth:CGFloat {headers.count==3 ? 335 : 385}
    private var valueWidth:CGFloat {(pageWidth-2*margin-nameWidth)/CGFloat(headers.count-1)}
    init(sink:NativeReportFileSink,snapshot:NativeReportSnapshot,section:NativeReportSection,headers:[String],title:String?)throws {
        self.sink=sink;self.title=title ?? (snapshot.category.title+" - "+section.title);self.headers=headers
        let date=DateFormatter();date.locale=Locale(identifier:"ja_JP");date.dateFormat="yyyy/MM/dd HH:mm:ss"
        subtitle=date.string(from:snapshot.filters.from)+" - "+date.string(from:snapshot.filters.to)
        var box=CGRect(x:0,y:0,width:595.28,height:841.89)
        guard let context=CGContext(consumer:try sink.consumer(),mediaBox:&box,[kCGPDFContextTitle:self.title,kCGPDFContextCreator:"NextCRM Native"] as CFDictionary) else{throw NativeDBError.message("レポートPDFを作成できません。")}
        self.context=context;nextPage()
    }
    deinit {if !closed {context.closePDF()}}
    private func attributed(_ text:String,size:CGFloat=10,bold:Bool=false)->NSAttributedString {
        let font=size==10 && !bold ? self.font : CTFontCreateWithName((bold ? "HiraginoSans-W6" : "HiraginoSans-W3") as CFString,size,nil)
        return NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.12,alpha:1)])
    }
    private func draw(_ text:NSAttributedString,x:CGFloat,top:CGFloat,width:CGFloat,right:Bool=false) {
        let line=CTLineCreateWithAttributedString(text),size=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
        context.textMatrix = .identity;context.textPosition=CGPoint(x:right ? x+max(0,width-size) : x,y:pageHeight-top-11);CTLineDraw(line,context)
    }
    private func footer(){
        draw(attributed("NextCRM | \(page) ページ",size:8),x:margin,top:813,width:pageWidth-2*margin,right:true);context.endPDFPage()
    }
    private func nextPage(){
        if page>0 {footer()};page+=1;context.beginPDFPage(nil)
        let heading=attributed(title,size:15,bold:true),setter=CTTypesetterCreateWithAttributedString(heading)
        var position=0,lines=0
        while position<heading.length {
            let count=max(1,CTTypesetterSuggestLineBreak(setter,position,Double(pageWidth-2*margin)))
            let line=CTTypesetterCreateLine(setter,CFRange(location:position,length:min(count,heading.length-position)))
            context.textMatrix = .identity;context.textPosition=CGPoint(x:margin,y:pageHeight-43-CGFloat(lines)*20);CTLineDraw(line,context)
            position+=count;lines+=1
        }
        let extra=CGFloat(max(0,lines-1))*20
        draw(attributed(subtitle,size:9),x:margin,top:60+extra,width:pageWidth-2*margin)
        y=86+extra;context.setFillColor(CGColor(gray:0.93,alpha:1));context.fill(CGRect(x:margin,y:pageHeight-y-24,width:pageWidth-2*margin,height:24))
        draw(attributed(headers[0],bold:true),x:margin+6,top:y+5,width:nameWidth-12)
        for i in 1..<headers.count {draw(attributed(headers[i],bold:true),x:margin+nameWidth+CGFloat(i-1)*valueWidth+6,top:y+5,width:valueWidth-12,right:true)}
        y+=32
    }
    func beginRow(values:[String])throws{try Task.checkCancellation();rowValues=values;firstLine=true;buffer=""}
    func label(_ text:String)throws{buffer+=text;try flush(final:false)}
    private func flush(final:Bool)throws {
        let value=attributed(buffer),setter=CTTypesetterCreateWithAttributedString(value),text=value.string as NSString
        var position=0
        while position<value.length {
            try Task.checkCancellation()
            var count=CTTypesetterSuggestLineBreak(setter,position,Double(nameWidth-12))
            if count==0 {count=CTTypesetterSuggestClusterBreak(setter,position,Double(nameWidth-12))}
            guard count>0 else{throw NativeDBError.message("PDFの項目名を改行できません。")}
            let end=position+count,last=end==value.length,tail=text.substring(with:NSRange(location:end-1,length:1))
            if last && !final && tail != "\n" && tail != "\r" {break}
            if y+18>bottom {nextPage()}
            let line=CTTypesetterCreateLine(setter,CFRange(location:position,length:count));context.textMatrix = .identity;context.textPosition=CGPoint(x:margin+6,y:pageHeight-y-11);CTLineDraw(line,context)
            if firstLine {drawValues();firstLine=false};y+=17;position=end
        }
        buffer=text.substring(from:position)
        guard buffer.utf16.count<=32_768 else{throw NativeDBError.message("PDFの項目名を分割できません。CSV形式で出力してください。")}
    }
    private func drawValues(){
        for (i,value) in rowValues.enumerated(){
            let text=NativeReportPresentation.number(value),content=attributed(text),width=valueWidth-12
            let measured=CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(content),nil,nil,nil))
            draw(measured>width ? attributed(text,size:max(5,10*width/measured)) : content,x:margin+nameWidth+CGFloat(i)*valueWidth+6,top:y,width:width,right:true)
        }
    }
    func endRow()throws{
        try flush(final:true);if firstLine {if y+18>bottom {nextPage()};drawValues();y+=17}
        context.setStrokeColor(CGColor(gray:0.85,alpha:1));context.setLineWidth(0.4);context.move(to:CGPoint(x:margin,y:pageHeight-y-4));context.addLine(to:CGPoint(x:pageWidth-margin,y:pageHeight-y-4));context.strokePath();y+=10
    }
    func finish()throws{guard !closed else{return};footer();context.closePDF();closed=true;if let error=sink.error {throw error}}
    func empty(){draw(attributed("該当するデータはありません。"),x:margin+6,top:y,width:pageWidth-2*margin)}
}
