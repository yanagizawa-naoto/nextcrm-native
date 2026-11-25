const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ts = require('typescript');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const root = path.resolve(__dirname, '../..');
const textPath = path.join(root, 'inngest/lib/document-text.ts');
const enrichPath = path.join(root, 'inngest/functions/documents/enrich-document.ts');
function evaluate(source) {
  const module = {exports: {}};
  vm.runInNewContext(ts.transpileModule(source, {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,
    {module,exports:module.exports,require,Buffer,console});
  return module.exports;
}
async function main() {
  const source = ts.createSourceFile('enrich.ts',fs.readFileSync(enrichPath,'utf8'),ts.ScriptTarget.Latest,true);
  const node = source.statements.find(n => ts.isFunctionDeclaration(n) && n.name?.text === 'classifyByFilename');
  if (!node) throw new Error('Original classification function missing');
  const {classifyByFilename} = evaluate(node.getText(source)+'\nexport {classifyByFilename};');
  const {extractDocumentText} = evaluate(fs.readFileSync(textPath,'utf8'));
  const names = ['請求書.pdf','領収書.png','支払明細.docx','契約更新.txt','利用規約.pdf','見積書.docx','提案書.txt','議事録.txt','INVOICE-01.pdf','NDA Agreement','QUOTE 100','Offer','invoice contract quote','payment terms','estimate','receipt','bill','scandal','普通の写真.jpg',''];
  const classifications = names.map(name => ({name,expected:classifyByFilename(name)}));
  const inputs = [Buffer.from('日本語と😀、改行\n二行目'),Buffer.from('a'.repeat(32767)+'日本語😀末尾'),Buffer.from(''),Buffer.from([0xe3,0x81]),Buffer.from([0xf0,0x80,0x80,0x80]),Buffer.from([0xed,0xa0,0x80,0x61]),Buffer.from([0xc3,0x28,0xff]),Buffer.from([0x61,0,0x62]),Buffer.from([0xe0,0x80,0x61])];
  const decoding = [];
  for (const input of inputs) for (const size of [1,2,3,7,32768]) {
    const expected = await extractDocumentText('text/plain',async () => (async function*(){for(let i=0;i<input.length;i+=size)yield input.subarray(i,i+size);})());
    decoding.push({base64:input.toString('base64'),size,expected:expected??''});
  }
  const directory = path.join(__dirname,'build/document-processing-fixtures'); fs.mkdirSync(directory,{recursive:true});
  const word = path.join(directory,'日本語.docx');
  const xml = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>日本語の契約書😀</w:t><w:tab/><w:t>見出し</w:t></w:r></w:p><w:p><w:r><w:t>二つ目の段落 &amp; 条項</w:t></w:r></w:p></w:body></w:document>';
  execFileSync('python3',['-c','import zipfile,sys\nwith zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED) as z:\n z.writestr("word/document.xml",sys.argv[2])\n z.writestr("[Content_Types].xml",\'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>\')',word,xml]);
  const bytes = fs.readFileSync(word);
  const wordText = await extractDocumentText('application/vnd.openxmlformats-officedocument.wordprocessingml.document',async () => (async function*(){yield bytes;})());
  let loads = 0;
  const unsupported = await extractDocumentText('image/png',async () => {loads++;throw new Error('Unexpected read');});
  if (unsupported !== null || loads !== 0) throw new Error('Unsupported source behavior changed');
  const result = {classifications,decoding,word:{path:word,expected:wordText},sourceSHA256:Object.fromEntries([textPath,enrichPath].map(p=>[path.relative(root,p),crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')]))};
  fs.writeFileSync(path.join(__dirname,'build/document-processing-reference.json'),JSON.stringify(result,null,2)+'\n');
  console.log(JSON.stringify({classifications:classifications.length,decoding:decoding.length,word:true,source:'actual filename function, StringDecoder and mammoth extraction'}));
}
main().catch(error=>{console.error(error);process.exitCode=1;});
