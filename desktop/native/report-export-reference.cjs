const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),file='actions/reports/export-csv.ts',source=fs.readFileSync(path.join(root,file),'utf8'),moduleValue={exports:{}};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module:moduleValue,exports:moduleValue.exports,require:name=>{throw Error(name)}},{filename:file});
const rows=Array.from({length:129},(_,i)=>({name:String(i).padStart(3,'0')+' '+(['営業,第一部','"特別"な部署','複数\n行','CR\r単独'][i]??(i===4?'長い日本語😀'.repeat(2000):'日本語の担当チーム'+i)),Number:i%4+1}));
const output={rows,headers:['項目','件数'],sourceCSV:moduleValue.exports.generateCSV(rows,['項目','件数']),hashes:{[file]:crypto.createHash('sha256').update(source).digest('hex')}};
fs.writeFileSync(path.join(__dirname,'build/report-export-reference.json'),JSON.stringify(output));console.log(JSON.stringify({suite:'original CSV export',rows:rows.length,longLabelBytes:Buffer.byteLength(rows[4].name)}));
