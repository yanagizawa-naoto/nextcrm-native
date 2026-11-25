from pathlib import Path
import json, zipfile, sys

root = Path(sys.argv[1]).resolve() / 'fixtures'
root.mkdir(exist_ok=True)
ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
paragraph = lambda text: '<w:p><w:r><w:t>' + text + '</w:t></w:r></w:p>'
cases = {
    'paragraphs': paragraph('日本語😀の見出し') + paragraph('本文 &amp; 段落'),
    'table': '<w:tbl><w:tr><w:tc>'+paragraph('左上')+'</w:tc><w:tc>'+paragraph('右上')+'</w:tc></w:tr><w:tr><w:tc>'+paragraph('左下')+'</w:tc><w:tc>'+paragraph('右下')+'</w:tc></w:tr></w:tbl>',
    'numbering': '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>箇条書き一</w:t></w:r></w:p>'+paragraph('二'),
    'hyperlink': '<w:p><w:hyperlink r:id="link1"><w:r><w:t>リンクの表示文字</w:t></w:r></w:hyperlink></w:p>',
    'tabs_breaks': '<w:p><w:r><w:t>甲</w:t><w:tab/><w:t>乙</w:t><w:br/><w:t>丙</w:t><w:br w:type="page"/><w:t>丁</w:t><w:cr/><w:t>戊</w:t></w:r></w:p>',
    'fields': '<w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText> DATE </w:instrText><w:fldChar w:fldCharType="separate"/><w:t>2026年11月20日</w:t><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    'tracked': '<w:p><w:del><w:r><w:delText>削除された本文</w:delText></w:r></w:del><w:ins><w:r><w:t>挿入された本文</w:t></w:r></w:ins></w:p>',
    'hidden': '<w:p><w:r><w:rPr><w:vanish/></w:rPr><w:t>非表示の本文</w:t></w:r></w:p>',
    'notes': '<w:p><w:r><w:t>本文</w:t><w:footnoteReference w:id="1"/><w:endnoteReference w:id="1"/></w:r></w:p>',
    'header_footer': paragraph('本文だけ'),
    'textbox': '<w:p><w:r><w:pict><v:shape><v:textbox><w:txbxContent>'+paragraph('テキストボックス')+'</w:txbxContent></v:textbox></v:shape></w:pict></w:r></w:p>',
    'alternate': '<mc:AlternateContent><mc:Choice Requires="wps">'+paragraph('新形式')+'</mc:Choice><mc:Fallback>'+paragraph('互換表示')+'</mc:Fallback></mc:AlternateContent>',
    'empty': '<w:p/>'+paragraph('末尾'),
    'alternate_without_fallback': '<mc:AlternateContent><mc:Choice Requires="wps">'+paragraph('原典も無視')+'</mc:Choice></mc:AlternateContent>'+paragraph('次の段落'),
    'alternate_nested': '<mc:AlternateContent><mc:Fallback>'+paragraph('外側')+'<mc:AlternateContent><mc:Choice Requires="wps">'+paragraph('二重にしない')+'</mc:Choice><mc:Fallback>'+paragraph('内側')+'</mc:Fallback></mc:AlternateContent></mc:Fallback></mc:AlternateContent>',
    'alternate_duplicate_fallback': '<mc:AlternateContent><mc:Fallback>'+paragraph('最初だけ')+'</mc:Fallback><mc:Fallback>'+paragraph('後の互換表示')+'</mc:Fallback></mc:AlternateContent>',
    'textbox_order': '<w:p><w:r><w:t>前</w:t><w:pict><v:shape><v:textbox><w:txbxContent>'+paragraph('箱')+'</w:txbxContent></v:textbox></v:shape></w:pict><w:t>後</w:t></w:r></w:p>',

}
files = []
for name, body in cases.items():
    document = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="'+ns+'" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><w:body>'+body+'<w:sectPr><w:headerReference r:id="header1"/><w:footerReference r:id="footer1"/></w:sectPr></w:body></w:document>'
    relations = [('hyperlink','link1','https://example.invalid/reference',True),('header','header1','header1.xml',False),('footer','footer1','footer1.xml',False),('footnotes','notes1','footnotes.xml',False),('endnotes','notes2','endnotes.xml',False)]
    relxml = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+''.join('<Relationship Id="'+identifier+'" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'+kind+'" Target="'+target+'"'+(' TargetMode="External"' if external else '')+'/>' for kind,identifier,target,external in relations)+'</Relationships>'
    path = root / (name+'.docx')
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('word/document.xml',document)
        z.writestr('word/_rels/document.xml.rels',relxml)
        z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr('word/header1.xml','<w:hdr xmlns:w="'+ns+'">'+paragraph('ヘッダー')+'</w:hdr>')
        z.writestr('word/footer1.xml','<w:ftr xmlns:w="'+ns+'">'+paragraph('フッター')+'</w:ftr>')
        z.writestr('word/footnotes.xml','<w:footnotes xmlns:w="'+ns+'"><w:footnote w:id="1">'+paragraph('脚注')+'</w:footnote></w:footnotes>')
        z.writestr('word/endnotes.xml','<w:endnotes xmlns:w="'+ns+'"><w:endnote w:id="1">'+paragraph('文末注')+'</w:endnote></w:endnotes>')
    files.append({'name':name,'path':str(path),'mime':'application/vnd.openxmlformats-officedocument.wordprocessingml.document'})
svg = root/'solid.svg'
svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><rect width="400" height="200" fill="#ff0000"/></svg>')
files.append({'name':'solid-svg','path':str(svg),'mime':'image/svg+xml'})
for name,xml in {
    'viewbox-svg':'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"><rect width="400" height="200" fill="#0000ff"/></svg>',
    'gradient-svg':'<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><defs><linearGradient id="g"><stop stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient></defs><rect width="400" height="200" fill="url(#g)"/></svg>',
    'japanese-svg':'<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><rect width="400" height="200" fill="white"/><text x="100" y="100" font-size="32">日本語😀</text></svg>',
    'huge-dimensions-svg':'<svg xmlns="http://www.w3.org/2000/svg" width="2000000" height="1000000" viewBox="0 0 400 200"><rect width="400" height="200" fill="#ff0000"/></svg>',
}.items():
    path=root/(name+'.svg');path.write_text(xml);files.append({'name':name,'path':str(path),'mime':'image/svg+xml'})

(root/'inputs.json').write_text(json.dumps(files,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'fixtures':len(files)}))
