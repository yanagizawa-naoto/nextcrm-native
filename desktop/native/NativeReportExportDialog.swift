import AppKit
import UniformTypeIdentifiers

struct NativeReportExportChoice {let sectionID:String,url:URL}
enum NativeReportExportDialog {
    typealias Present=(NSWindow,NativeReportSnapshot,NativeReportExportFormat,@escaping(NativeReportExportChoice?)->Void)->Void
    static func show(parent:NSWindow,snapshot:NativeReportSnapshot,format:NativeReportExportFormat,completion:@escaping(NativeReportExportChoice?)->Void) {
        guard !snapshot.sections.isEmpty else{completion(nil);return}
        let panel=NSSavePanel();panel.title=format == .csv ? "CSVでレポートを保存" : "PDFでレポートを保存"
        panel.allowedContentTypes=[format == .csv ? .commaSeparatedText : .pdf];panel.allowsOtherFileTypes=false;panel.canCreateDirectories=true
        panel.nameFieldStringValue=snapshot.category.title+"-レポート."+format.rawValue
        let accessory=NSView(frame:NSRect(x:0,y:0,width:480,height:65))
        let label=NSTextField(labelWithString:"出力する集計項目");label.frame=NSRect(x:0,y:38,width:480,height:20)
        let section=NSPopUpButton(frame:NSRect(x:0,y:4,width:480,height:28));section.addItems(withTitles:snapshot.sections.map(\.title));section.setAccessibilityLabel("レポートの出力項目")
        if let standard=NativeReportExport.standardSection(snapshot.category),let index=snapshot.sections.firstIndex(where:{$0.id==standard}){section.selectItem(at:index)}
        accessory.addSubview(label);accessory.addSubview(section);panel.accessoryView=accessory
        panel.beginSheetModal(for:parent){response in
            guard response == .OK,let url=panel.url,snapshot.sections.indices.contains(section.indexOfSelectedItem) else{completion(nil);return}
            completion(.init(sectionID:snapshot.sections[section.indexOfSelectedItem].id,url:url))
        }
    }
}
