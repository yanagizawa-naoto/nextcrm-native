// Executes installed, locked original parsers/actions. No HTTP or dependency installs.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const { createSourceLoader } = require('./plugins-source-loader.cjs');
const { createSourceDatabase } = require('./plugins-source-database.cjs');
const ExcelJS = require(path.join(root, 'node_modules/exceljs'));
const work = process.argv[2] || path.join(__dirname,'build/target-spreadsheet-test');
const output = path.join(work, 'source-fixtures'); fs.mkdirSync(output, { recursive: true });
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const fakeFile = (name, bytes) => ({ name, text: async () => new TextDecoder('utf-8').decode(bytes), arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) });
const warnings = [], oldWarn = console.warn; console.warn = (...args) => warnings.push(args.map(String).join(' '));
const loader = createSourceLoader({}, { root });
const parse = loader.load('lib/spreadsheet/parse.ts').parseSpreadsheetFile;
const fields = loader.load('lib/spreadsheet/target-fields.ts').TARGET_FIELDS;
const csvCases = [
 ['basic', 'last_name,first_name,email\n山田,花子,hana@example.invalid\n'],
 ['bom', '\ufefflast_name,company\n山田,株式会社サンプル\n'],
 ['tab', 'last_name\tcompany\r\n山田\t\"会社\t東京\"\r\n'],
 ['semi', 'last_name;company;description\n山田;会社;\"複数\n行\"\n'],
 ['pipe', 'last_name|company|email\n山田|会社|x@example.invalid\n'],
 ['unit_separator', 'last_name\x1fcompany\n山田\x1f会社\n'],
 ['record_separator', 'last_name\x1ecompany\n山田\x1e会社\n'],
 ['quotes', 'last_name,company,description\r\n\"姓\"\"名\",\"会社,東京\",\"改行\r\n本文\"\r\n'],
 ['cr', 'last_name,company\r山田,会社\r佐藤,別会社\r'],
 ['greedy_empty', '\n  \nlast_name,company\n,\n  , \n山田,\n\"\",\" \"\n'],
 ['spaces', ' last_name ,company\n 山田 , 会社 \n'],
 ['empty_header', 'last_name,,company\n山田,skip,会社\n'],
 ['duplicate_header', 'last_name,last_name,email,last_name_1\n一,二,x@example.invalid,三\n'],
 ['unicode_headers', 'é,e\u0301,会社名\n一,二,会社\n'],
 ['fewer_fields', 'last_name,company,email\n山田\n,会社\n'],
 ['extra_fields', 'last_name,company\n山田,会社,余分,末尾\n'],
 ['open_quote', 'last_name,company\n\"山田,会社\n'],
 ['quote_suffix', 'last_name,company\n\"山田\"x,会社\n'],
 ['quote_spaces', 'last_name,company\n\"山田\"   ,会社\n'],
 ['inner_quote', 'last_name,company\n山\"田,会社\n'],
 ['header_only', 'last_name,company'], ['empty', ''], ['only_newlines', '\n\r\n'],
 ['embedded_nul', 'last_name,company\n山\0田,会社\n'],
 ['newlines_in_quotes', 'last_name,description\n\"山\n田\",\"\n\n本文\n\"\n'],
 ['duplicate_rename', 'a,a,a_1,a_1,a\nx,y,z,w,v\n'],
 ['multi_delimiter', 'last_name,company;email\n山田,会社;x@example.invalid\n'],
 ['double_bom', '\ufeff\ufefflast_name,company\n山田,会社\n'],
 ['quote_nbsp', 'last_name,company\n\"山田\"\u00a0,会社\n'],
 ['quote_ideographic', 'last_name,company\n\"山田\"\u3000,会社\n'],
 ['proto_headers', '__proto__,constructor,last_name,company\na,b,山田,会社\n'],
 ['extra_collision', 'last_name,__parsed_extra\n山田,文字,extra\n'],
];
const parser = [], mapping = [], imports = [];
async function parsed(id, name, bytes) {
 fs.writeFileSync(path.join(output, name), bytes);
 try { parser.push({ id, file: name, bytes: bytes.length, sha256: hash(bytes), rows: await parse(fakeFile(name, bytes)) }); }
 catch (error) { parser.push({ id, file: name, bytes: bytes.length, sha256: hash(bytes), error: String(error.message ?? error) }); }
}
async function xlsx(id, build) {
 const workbook = new ExcelJS.Workbook(); const sheet = workbook.addWorksheet('営業対象'); build(sheet, workbook);
 await parsed(id, id + '.xlsx', Buffer.from(await workbook.xlsx.writeBuffer()));
}
async function main() {
 for (const [id, text] of csvCases) await parsed('csv_' + id, id + '.csv', Buffer.from(text));
 await parsed('csv_invalid_utf8', 'invalid_utf8.csv', Buffer.concat([Buffer.from('last_name,company\n'), Buffer.from([0xff, 0x80]), Buffer.from(',会社\n')]));
 await xlsx('xlsx_strings', s => { s.addRow(fields.map(x => x.key)); s.addRow(fields.map((x,i) => i === 0 ? '山田' : `${i}: ${x.label}`)); s.addRow(['', '花子', '', '', '', '会社']); });
 await xlsx('xlsx_mixed', s => { s.addRow(['last_name','company','email','description','employees','position','city']); s.addRow(['山田',123,true,{formula:'1+2',result:3},{formula:'0',result:0},{formula:'FALSE()',result:false},{error:'#N/A'}]); s.addRow(['佐藤',{richText:[{text:'株式会社',font:{bold:true}},{text:' 東京'}]},{text:'label',hyperlink:'https://example.invalid'},{formula:'"本文"',result:'本文'},1.2345678901234568e20,false,null]); });
 await xlsx('xlsx_dates', s => { s.addRow(['last_name','company','description','city']); s.addRow(['山田',new Date('2026-11-20T12:34:56.789Z'),new Date('1900-02-28T00:00:00Z'),new Date('1904-01-01T00:00:00Z')]); s.getCell('B2').numFmt='yyyy-mm-dd hh:mm:ss'; });
 await xlsx('xlsx_date1904', (s,w) => { w.properties.date1904=true; s.addRow(['last_name','company']); s.addRow(['山田',new Date('2026-11-20T12:00:00Z')]); });
 await xlsx('xlsx_headers', s => { s.addRow(['last_name',' company ','company','',123,{richText:[{text:'職業'}]},true]); s.addRow(['山田','旧','新','skip','数字','object','boolean']); });
 await xlsx('xlsx_sparse', s => { s.getCell('A1').value='last_name';s.getCell('D1').value='company';s.getCell('A3').value='山田';s.getCell('D3').value='会社';s.getCell('F4').value='headerなし';s.getCell('D6').value=' 別会社 '; });
 await xlsx('xlsx_multisheet', (s,w) => {s.addRow(['last_name']);s.addRow(['先頭']);let other=w.addWorksheet('2');other.addRow(['last_name']);other.addRow(['後続']);});
 await xlsx('xlsx_empty_first', (s,w) => {let other=w.addWorksheet('2');other.addRow(['last_name']);other.addRow(['後続']);});
 await xlsx('xlsx_merge', s => {s.addRow(['last_name','company','description']);s.addRow(['山田','会社','本文']);s.mergeCells('B2:C2');});
 await xlsx('xlsx_unicode', s => {s.addRow(['last_name','é','e\u0301','company']);s.addRow(['山田','一','二','\u00a0会社\ufeff']);});
 await xlsx('xlsx_shared_formula', s => {s.addRow(['last_name','company']);s.addRow(['山田',{formula:'1+2',result:3}]);s.addRow(['佐藤',{sharedFormula:'B2',result:4}]);});
 await xlsx('xlsx_object_headers', s => {s.addRow([{text:'last_name',hyperlink:'https://example.invalid'},{formula:'1+1',result:2},{error:'#N/A'},'company']);s.addRow(['A','B','C','会社']);});
 await xlsx('xlsx_formula_errors', s => {s.addRow(['last_name','company','description','city','country']);s.addRow(['山田',{formula:'1/0',result:{error:'#DIV/0!'}},{formula:'TRUE()',result:true},{formula:'FALSE()',result:false},{formula:'DATE(2020,1,1)',result:new Date('2020-01-01T00:00:00Z')}]);s.getCell('E2').numFmt='yyyy-mm-dd';});
 await xlsx('xlsx_formula_empty', s => {s.addRow(['last_name','company','description','city']);s.addRow(['山田',{formula:'A1'},{formula:'""',result:''},{formula:'-1',result:-1}]);});
 await xlsx('xlsx_merge_rows', s => {s.addRow(['last_name','company','description']);s.addRow(['山田','会社','本文']);s.mergeCells('A2:A4');s.getCell('C4').value='後続';});
 await xlsx('xlsx_numfmt', s => {s.addRow(['last_name','company','description','city','country']);s.addRow(['山田',0,60,123,123]);s.getCell('B2').numFmt='yyyy';s.getCell('C2').numFmt='mm/dd/yyyy';s.getCell('D2').numFmt='[Red]0.00';s.getCell('E2').numFmt='0 "months"';});
 await xlsx('xlsx_controls', s => {s.addRow(['last_name','company','description']);s.addRow(['山田','a\u0001b\r終','_x0001_ _x005F_ 😀']);});
 await xlsx('xlsx_calendar_edges', s=>{s.addRow(['last_name','company','description','city','country']);s.addRow(['山田',...['0000-01-01T00:00:00Z','1500-03-01T00:00:00Z','-000001-01-01T00:00:00Z','+010000-01-01T00:00:00Z'].map(x=>new Date(x))]);});
 const JSZip=require(require.resolve('jszip',{paths:[path.dirname(require.resolve(path.join(root,'node_modules/exceljs')))]}));
 for(const [id,xml] of [
  ['xlsx_inline','<c r="B2" t="inlineStr"><is><t>_x0041_ &amp; 😀</t></is></c>'],
  ['xlsx_inline_rich','<c r="B2" t="inlineStr"><is><r><t>会社</t></r><r><t> 東京</t></r></is></c>'],
  ['xlsx_inline_phonetic','<c r="B2" t="inlineStr"><is><t>会社</t><rPh sb="0" eb="2"><t>かいしゃ</t></rPh></is></c>'],
  ['xlsx_inline_phonetic_nested','<c r="B2" t="inlineStr"><is><r><t>会社</t></r><rPh sb="0" eb="2"><t>除外</t><rPh sb="0" eb="1"><t>内部</t></rPh><t>除外</t></rPh><r><t> 東京</t></r></is></c>'],
  ['xlsx_inline_phonetic_multiple','<c r="B2" t="inlineStr"><is><r><t>会社</t></r><rPh sb="0" eb="2"><t>かいしゃ</t></rPh><rPh sb="0" eb="2"><t>別の読み</t></rPh><r><t> 東京</t></r></is></c>'],
  ['xlsx_unknown_style','<c r="B2" s="999" t="n"><v>12</v></c>'],
 ]) {
  const zip=await JSZip.loadAsync(fs.readFileSync(path.join(output,'xlsx_controls.xlsx')));
  let data=await zip.file('xl/worksheets/sheet1.xml').async('string');data=data.replace(/<c r="B2"[^>]*>[\s\S]*?<\/c>/,xml);zip.file('xl/worksheets/sheet1.xml',data);
  await parsed(id,id+'.xlsx',await zip.generateAsync({type:'nodebuffer'}));
 }
 for(const item of parser.filter(x=>x.id.startsWith('xlsx_inline_phonetic'))) {
  item.intentionalCorrection={reason:'Valid inline rPh/phonetic runs make installed ExcelJS lose the cell and subsequent cells. Native excludes only phonetic text and preserves ordinary content and later cells.',rows:[{...parser.find(x=>x.id==='xlsx_controls').rows[0],company:item.id==='xlsx_inline_phonetic'?'会社':'会社 東京'}]};
 }
 for(const zone of ['Asia/Tokyo','America/New_York']) {
  const previous=process.env.TZ;process.env.TZ=zone;
  for(const id of ['xlsx_dates','xlsx_date1904','xlsx_calendar_edges']) {
   const name=id+'.xlsx',bytes=fs.readFileSync(path.join(output,name));
   parser.push({id:id+'@'+zone,file:name,timeZone:zone,bytes:bytes.length,sha256:hash(bytes),rows:await parse(fakeFile(name,bytes))});
  }
  process.env.TZ=previous;
 }
 const heads = ['Last Name','First Name','E-mail','mail','phone','Company Name','メールアドレス','会社名','unknown','company_website','HQ Country',' job-title ','employees','姓','名'];
 for (const scenario of ['none','success','invalidField','invalidJSON','empty','throw','loggedOut','invalidHeaders']) {
  const calls=[]; const mocks={'@/lib/auth-server':{getSession:async()=>scenario==='loggedOut'?null:{user:{id:'actor'}}},'@/lib/openai':{openAiHelper:async()=>scenario==='none'?null:{chat:{completions:{create:async input=>{calls.push(input);if(scenario==='throw')throw Error('synthetic');return {choices:[{message:{content:scenario==='empty'?'':scenario==='invalidJSON'?'not-json':JSON.stringify(Object.fromEntries(heads.map(k=>[k,scenario==='invalidField'?'not_field':'company'])))}}]};}}}}}};
  const l=createSourceLoader(mocks,{root}); let result;try{result=await l.load('actions/crm/targets/suggest-mapping.ts').suggestMapping(scenario==='invalidHeaders'?null:heads);}catch(e){result={thrown:String(e.message)}}
  mapping.push({id:scenario,headers:heads,result,calls});Object.assign(loader.hashes,l.hashes);
 }
 const actor={id:'10000000-0000-4000-8000-000000000001',role:'user',name:'営業担当'};
 const sourceRows = [
  ['plain',[{last_name:'山田',company:'会社',email:'dup@example.invalid'},{last_name:'佐藤',email:'dup@example.invalid'}],{}],
  ['invalid',[{first_name:'名だけ'},{last_name:' '},{company:'会社だけ'},{last_name:'山田',employees:'0'}],{}],
  ['mapping',[{姓:'山田',会社:'会社',連絡先:'stop@example.invalid'}],{姓:'last_name',会社:'company',連絡先:'email'}],
  ['unicode_stop', ['ÉX@例え.invalid','i\u0307@example.invalid','ΟΣ@example.invalid','foo@xn--r8jz45g.invalid','foo@例え.invalid'].map(email=>({last_name:'山田',email})),{}],
  ['all_fields',[Object.fromEntries(fields.map(f=>[f.key, f.key === 'last_name'?'山田':f.key]))],{}],
 ];
 for (const [id, rows, map] of sourceRows) {
  const d=createSourceDatabase({root,epoch:'2026-11-20T12:00:00.000Z',mocks:{'@/lib/authz':{requireAuthenticated:async()=>actor},'@/lib/spreadsheet/parse':{parseSpreadsheetFile:async()=>rows}}});
  d.seed('Users',{id:actor.id,name:actor.name,email:'actor@example.invalid'});
  d.seed('crm_Targets',{id:'20000000-0000-4000-8000-000000000001',last_name:'既存',email:'STOP@EXAMPLE.INVALID',do_not_email:true});
  const other='10000000-0000-4000-8000-000000000002';d.seed('Users',{id:other,name:'別担当者',email:'other@example.invalid'});
  for(const [i,email] of ['éx@例え.invalid','İ@example.invalid','ος@example.invalid','foo@例え.invalid'].entries())d.seed('crm_Targets',{id:'20000000-0000-4000-8000-'+String(i+2).padStart(12,'0'),last_name:'停止済み',email,do_not_email:true,created_by:other,deletedAt:new Date('2025-01-01T00:00:00Z')});
  const seeds=d.state.crm_Targets.map(x=>({...x}));
  const args={get:key=>key==='file'?{name:'synthetic.csv'}:key==='mapping'?JSON.stringify(map):null};
  const result=await d.run(()=>d.load('actions/crm/targets/import-targets.ts').importTargets(args));
  imports.push({id,rows,mapping:map,actor,seeds,result,created:d.state.crm_Targets.filter(x=>!seeds.some(s=>s.id===x.id)),events:d.events,logs:d.logs,observed:d.observed});
  Object.assign(loader.hashes,d.sourceHashes);
 }
 const core=require(require.resolve('@tanstack/table-core',{paths:[path.dirname(require.resolve(path.join(root,'node_modules/@tanstack/react-table')))]}));
 const targetData=Array.from({length:250},(_,i)=>({id:'target-'+i,last_name:i%2?'odd':'even'}));
 let tableState={rowSelection:{},columnFilters:[],sorting:[],pagination:{pageIndex:0,pageSize:100}};
 let table;const update=(key,value)=>{tableState={...tableState,[key]:typeof value==='function'?value(tableState[key]):value};table.setOptions(old=>({...old,state:tableState}));};
 table=core.createTable({data:targetData,columns:[{accessorKey:'id'},{accessorKey:'last_name'}],state:tableState,enableRowSelection:true,onRowSelectionChange:v=>update('rowSelection',v),onPaginationChange:v=>update('pagination',v),onColumnFiltersChange:v=>update('columnFilters',v),getCoreRowModel:core.getCoreRowModel(),getFilteredRowModel:core.getFilteredRowModel(),getPaginationRowModel:core.getPaginationRowModel(),getSortedRowModel:core.getSortedRowModel()});
 const selection=[];const capture=name=>{const page=table.getRowModel().rows;selection.push({name,visible:page.map(x=>x.original.id),indexes:page.flatMap((x,i)=>x.getIsSelected()?[i]:[]),selected:table.getSelectedRowModel().rows.map(x=>x.original.id),filtered:table.getFilteredRowModel().rows.map(x=>x.original.id)});};
 table.getRow('0').toggleSelected(true);capture('first-page');await Promise.resolve();await Promise.resolve();
 table.setPageIndex(1);table.toggleAllPageRowsSelected(true);capture('page-checkbox');
 table.setPageIndex(2);table.getRow('222').toggleSelected(true);capture('third-page');
 table.setColumnFilters([{id:'last_name',value:'odd'}]);table.setPageIndex(0);capture('filter-keeps-hidden-selected');
 table.toggleAllPageRowsSelected(false);capture('clear-current-filtered-page');
 const dates=['1970-01-01T00:00:00Z','1969-12-31T23:59:59.999Z','0000-01-01T00:00:00Z','1582-10-10T01:23:45.123Z','+010000-01-01T00:00:00Z','2026-01-01T09:30:12.345+09:00'].map(input=>({input,milliseconds:new Date(input).getTime()}));
 const exportCalls=[];const orderLoader=createSourceLoader({'@/lib/authz':{requireAuthenticated:async()=>actor,targetReadScopeWhere:()=>({created_by:actor.id}),AuthenticationError:class extends Error{}},'@/lib/prisma':{prismadb:{crm_Targets:{findMany:async args=>{exportCalls.push(args);return []}}}}},{root});
 await orderLoader.load('actions/crm/get-targets.ts').getTargets();Object.assign(loader.hashes,orderLoader.hashes);
 for(const p of ['app/[locale]/(routes)/campaigns/targets/table-components/data-table.tsx','app/[locale]/(routes)/campaigns/targets/table-components/columns.tsx'])loader.hashes[p]=hash(fs.readFileSync(path.join(root,p)));
 const dependencyHashes=Object.fromEntries(['exceljs','papaparse','typescript','openai','@tanstack/react-table'].map(name=>{const file=require.resolve(path.join(root,'node_modules',name,'package.json'));return [name,{version:JSON.parse(fs.readFileSync(file)).version,packageSHA256:hash(fs.readFileSync(file))}]}));
 const result={dates,exportCalls,selection,dependencyHashes,timeZone:process.env.TZ,fields,parser,mapping,imports,sourceHashes:loader.hashes,warnings,limits:['Prisma adapter is isolated, not PostgreSQL; actual middleware import hooks/audit are inspected separately.','No live AI call or real user file was used.']};
 fs.writeFileSync(path.join(work,'reference.json'),JSON.stringify(result,null,2)+'\n');
 console.warn=oldWarn;console.log(JSON.stringify({parser:parser.length,mapping:mapping.length,imports:imports.length,filesBytes:fs.readdirSync(output).reduce((n,x)=>n+fs.statSync(path.join(output,x)).size,0)}));
}
main().catch(error=>{console.warn=oldWarn;console.error(error);process.exitCode=1;});
