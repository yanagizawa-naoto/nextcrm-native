const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),ts=require('typescript'),{Decimal}=require('decimal.js');
const root=path.resolve(__dirname,'../..'),cache=new Map();
function source(file){
  const filename=path.join(root,file); if(cache.has(filename))return cache.get(filename).exports;
  const mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;mod.paths=Module._nodeModulePaths(path.dirname(filename));
  const standard=mod.require.bind(mod);mod.require=id=>id.startsWith('@/')?source(id.slice(2)+'.ts'):id.startsWith('.')?source(path.relative(root,path.resolve(path.dirname(filename),id))+'.ts'):standard(id);
  mod._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,filename);return mod.exports;
}
const wf=source('lib/orders/transitions.ts'),pricing=source('lib/orders/pricing.ts'),numbering=source('lib/invoices/numbering.ts');
const statuses=['DRAFT','PENDING_APPROVAL','READY','SENT','CONFIRMED','DELIVERED','INVOICED','PAID','CANCELLED','SYNC_FAILED'];
const actions=['edit','delete','submit','approve','reject','withdraw','reopen','cancel','retry','advance'];
const transitions=[];
for(const status of statuses)for(const src of ['CRM','EXTERNAL'])for(const role of ['user','manager','admin'])for(const creator of ['actor','other',null])for(const externalRef of [null,'ERP-1']){
 const order={status,source:src,createdBy:creator,externalRef};const actor={kind:'user',id:'actor',role};
 for(const action of actions)transitions.push({...order,role,action,allowed:wf.can(order,action,actor)});
}
const plugins=[];for(const status of statuses)for(const to of statuses)plugins.push({status,to,allowed:wf.canPluginSet({status},to)});
let seed=62821;const rand=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
const lines=[];for(let i=0;i<400;i++){
 const quantity=new Decimal(1+rand()%10000000).div(10000),unitPrice=new Decimal(rand()%10000000).div(100),vatRate=new Decimal(rand()%10001).div(100);
 const r=pricing.lineAmounts({quantity,unitPrice,vatRate});lines.push({quantity:quantity.toFixed(),unitPrice:unitPrice.toFixed(),vatRate:vatRate.toFixed(),...Object.fromEntries(Object.entries(r).map(([k,v])=>[k,v.toFixed()]))});
}
const numbers=[];for(const template of ['ORD-{YYYY}-{####}','A-{##}-{YYYY}-{##}','{#}','{######}-固定','{YYYY}/{YYYY}/{###}'])for(const counter of [1,9,999,10000,2147483647]) numbers.push({template,counter,year:2027,number:numbering.formatNumber(template,2027,counter)});
fs.writeFileSync(path.join(__dirname,'build/orders-reference.json'),JSON.stringify({transitions,plugins,lines,numbers}));
console.log(JSON.stringify({transitions:transitions.length,plugins:plugins.length,lines:lines.length,numbers:numbers.length,source:'lib/orders/transitions.ts, lib/orders/pricing.ts, lib/invoices/numbering.ts'}));
