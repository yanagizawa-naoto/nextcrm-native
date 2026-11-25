const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),ts=require('typescript'),{Decimal}=require('decimal.js');
const root=path.resolve(__dirname,'../..'),cache=new Map();
function source(file){
  const filename=path.join(root,file); if(cache.has(filename))return cache.get(filename).exports;
  const mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;mod.paths=Module._nodeModulePaths(path.dirname(filename));
  const standard=mod.require.bind(mod);mod.require=id=>id.startsWith('@/')?source(id.slice(2)+'.ts'):id.startsWith('.')?source(path.relative(root,path.resolve(path.dirname(filename),id))+'.ts'):standard(id);
  mod._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,filename);return mod.exports;
}
const p=source('lib/invoices/permissions.ts');
const statuses=['DRAFT','ISSUED','SENT','PARTIALLY_PAID','PAID','OVERDUE','CANCELLED','DISPUTED','REFUNDED','WRITTEN_OFF'];
const cases=[];
for(const status of statuses)for(const role of ['user','manager','admin','partner','unknown'])for(const creator of ['actor','other']){
 const invoice={status,createdBy:creator},user={id:'actor',role};
 for(const [action,fn] of Object.entries({read:p.canReadInvoice,edit:p.canEditInvoice,issue:p.canIssueInvoice,cancel:p.canCancelInvoice,payment:p.canAddPayment}))cases.push({status,role,creator,action,allowed:fn(invoice,user)});
}
fs.writeFileSync(path.join(__dirname,'build/invoice-workflow-reference.json'),JSON.stringify(cases));
console.log(JSON.stringify({invoicePolicyCases:cases.length,source:'lib/invoices/permissions.ts'}));
