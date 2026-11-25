// Execute original order handlers, services, pricing, workflow, audit and mail
// selection against isolated Prisma/Resend adapters. No network or real database.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const ts=require('typescript'),{Prisma}=require('@prisma/client');
const root=path.resolve(__dirname,'../..'),schema=fs.readFileSync(path.join(root,'prisma/schema.prisma'),'utf8');
const shared=JSON.parse(fs.readFileSync(path.join(__dirname,'build/mcp-accounts-reference.json'),'utf8'));
const catalog=JSON.parse(fs.readFileSync(path.join(__dirname,'build/mcp-catalog-reference.json'),'utf8'));
const epoch=shared.epoch,RealDate=Date;
global.Date=class extends RealDate{constructor(...args){super(...(args.length?args:[epoch]));}static now(){return new RealDate(epoch).getTime();}};
process.env.NEXT_PUBLIC_APP_URL='https://fixture.invalid';process.env.NEXT_PUBLIC_APP_NAME='Fixture';process.env.EMAIL_FROM='fixture@example.invalid';
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`,definitions=new Map(),cache=new Map(),hashes={};
function fields(model){
 if(definitions.has(model))return definitions.get(model);
 const body=schema.match(new RegExp(`model ${model}\\s*\\{([\\s\\S]*?)^\\}`,'m'))[1],names=new Set(Prisma.dmmf.datamodel.models.find(x=>x.name===model).fields.filter(x=>x.kind!=='object').map(x=>x.name));
 const rows=body.split('\n').map(line=>{const m=line.match(/^\s*(\w+)\s+(\w+)(\[\]|\?)?(.*)$/);return m&&names.has(m[1])?{name:m[1],type:m[2],array:m[3]==='[]',optional:m[3]==='?',rest:m[4]}:null;}).filter(Boolean);definitions.set(model,rows);return rows;
}
let serial=9000;
function full(model,values){
 const row={};for(const f of fields(model)){const exp=f.rest.match(/@default\(([^)]*)\)/)?.[1];let v=f.array?[]:null;if(f.rest.includes('@updatedAt')||exp?.startsWith('now('))v=epoch;else if(exp?.startsWith('uuid('))v=values.id??uid(++serial);else if(exp!==undefined){try{v=JSON.parse(exp);}catch{v=exp;}}row[f.name]=v;}
 Object.assign(row,Object.fromEntries(Object.entries(values).filter(([,v])=>v!==undefined)));
 for(const f of fields(model)){
  let v=row[f.name];if(v==null){if(!f.optional&&!f.array)throw Error('Missing scalar '+model+'.'+f.name);continue;}
  if(f.type==='Decimal'){const [,p,s]=f.rest.match(/@db.Decimal\((\d+),\s*(\d+)\)/);v=new Prisma.Decimal(v).toDecimalPlaces(Number(s),Prisma.Decimal.ROUND_HALF_UP);if(v.abs().gte(new Prisma.Decimal(10).pow(Number(p)-Number(s))))throw Error('numeric overflow');if(v.isZero())v=new Prisma.Decimal(0);}
  if(f.type==='DateTime'){v=new Date(v);if(!Number.isFinite(v.getTime()))throw Error('invalid date');if(f.rest.includes('@db.Date'))v=new Date(v.toISOString().slice(0,10)+'T00:00:00Z');}
  if(f.type==='Int'&&(!Number.isInteger(v)||v< -2147483648||v>2147483647))throw Error('integer overflow');
  if(f.rest.includes('@db.Uuid')){if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v))throw Error('invalid UUID');v=v.toLowerCase();}
  if(f.type==='String'&&typeof v==='string'&&v.includes('\0'))throw Error('NUL text');
  if(f.type==='Json')v=JSON.parse(JSON.stringify(v));row[f.name]=v;
 }
 return row;
}
const modelNames=['Users',...Object.keys(catalog.seeds),'crm_Contacts','NumberSeries','crm_Orders','crm_OrderLines'];
const seeds=Object.fromEntries(modelNames.map(m=>[m,[]]));
for(const [m,rows]of Object.entries(catalog.seeds))seeds[m]=rows.map(x=>full(m,x));
seeds.Users=shared.users.map(x=>full('Users',x));
function seed(m,v){const row=full(m,v);seeds[m].push(row);return row;}
seed('crm_SystemSettings',{key:'default_currency',value:'JPY'});seed('crm_SystemSettings',{key:'orders_approval_emails',value:'true'});
seed('crm_Contacts',{id:uid(1401),last_name:'同じ取引先',accountsIDs:uid(101)});seed('crm_Contacts',{id:uid(1402),last_name:'別取引先',accountsIDs:uid(102)});seed('crm_Contacts',{id:uid(1403),last_name:'削除済み連絡先',accountsIDs:uid(101),deletedAt:epoch});
seed('NumberSeries',{id:uid(1500),scope:'order',name:'受注',template:'ORD-{YYYY}-{####}',counter:7,currentYear:2026,isDefault:true});
seed('crm_Products',{id:uid(650),name:'端数',type:'PRODUCT',unit_price:'0.01',currency:'USD',status:'ACTIVE',tax_rate:'10',sku:'TINY'});
seed('crm_Products',{id:uid(651),name:'負税率',type:'PRODUCT',unit_price:'100',currency:'JPY',status:'ACTIVE',tax_rate:'-10'});
seed('crm_PriceLists',{id:uid(850),name:'換算前の微小額',currency:'USD'});seed('crm_PriceListRules',{id:uid(950),priceListId:uid(850),fixedPrice:'0.0049'});
const statuses=['DRAFT','PENDING_APPROVAL','READY','SENT','CONFIRMED','DELIVERED','INVOICED','PAID','CANCELLED','SYNC_FAILED'];
for(let i=0;i<statuses.length;i++)seed('crm_Orders',{id:uid(1600+i),number:'SEED-'+i,seriesId:uid(1500),accountId:uid(101),ownerId:uid(1),createdBy:uid(1),updatedBy:uid(1),currency:'JPY',priceListId:uid(800),status:statuses[i],approvalRequestedAt:i===1?epoch:null});
for(const [id,v]of [[1620,{accountId:uid(102),ownerId:uid(2),createdBy:uid(2)}],[1621,{accountId:uid(102),ownerId:uid(1),createdBy:uid(2)}],[1622,{accountId:uid(102),ownerId:uid(2),createdBy:uid(1)}],[1623,{accountId:uid(101),ownerId:uid(2),createdBy:uid(2)}],[1624,{source:'EXTERNAL'}],[1625,{status:'READY',externalRef:'remote'}],[1626,{priceListId:uid(850),currency:'JPY'}],[1627,{accountId:uid(104),ownerId:uid(2),createdBy:uid(2)}]])seed('crm_Orders',{id:uid(id),number:'SEED-'+id,seriesId:uid(1500),accountId:uid(101),ownerId:uid(1),createdBy:uid(1),updatedBy:uid(1),currency:'JPY',priceListId:uid(800),...v});
function line(id,order,overridden=false,unit='702'){seed('crm_OrderLines',{id:uid(id),orderId:uid(order),position:0,productId:uid(600),productName:'保存時の商品名',sku:'OLD-SKU',unit:'個',quantity:'2',listPrice:'702',unitPrice:unit,unitPriceOverridden:overridden,vatRate:'10',lineSubtotal:String(Number(unit)*2),lineVat:String(Number(unit)*.2),lineTotal:String(Number(unit)*2.2)});}
line(1700,1600,true,'600');line(1701,1601,true,'600');line(1702,1620);line(1703,1621);line(1704,1622);line(1705,1623);line(1706,1624);line(1707,1626);
let state,mails,actors,currentActorFrame;
function observed(){actors.push(currentActorFrame()?.actor);}
function eq(a,b){if(a instanceof RealDate||b instanceof RealDate)return new Date(a).getTime()===new Date(b).getTime();if(a instanceof Prisma.Decimal||b instanceof Prisma.Decimal)return String(a)===String(b);return a===b;}
function related(model,row,key){if(model==='crm_Orders'){const target={account:['crm_Accounts','accountId'],owner:['Users','ownerId'],priceList:['crm_PriceLists','priceListId']}[key];if(target)return[state[target[0]].find(x=>x.id===row[target[1]])??null,target[0]];}return null;}
function matches(model,row,where={}){return Object.entries(where).every(([k,v])=>{
 if(k==='OR')return v.some(x=>matches(model,row,x));if(k==='AND')return v.every(x=>matches(model,row,x));if(k==='NOT')return !matches(model,row,v);
 if(k==='watchers')return shared.watchers.some(x=>x.account_id===row.id&&matches('watcher',x,v.some));
 const relation=related(model,row,k);if(relation)return relation[0]!=null&&matches(relation[1],relation[0],v);
 assert.ok(Object.hasOwn(row,k),'Unhandled predicate '+model+'.'+k);
 if(v&&typeof v==='object'&&!(v instanceof RealDate)&&!(v instanceof Prisma.Decimal)){if(Object.hasOwn(v,'in'))return v.in.some(x=>eq(row[k],x));if(Object.hasOwn(v,'not'))return !eq(row[k],v.not);throw Error('Unhandled operator '+k);}
 return eq(row[k],v);
});}
function validateWhere(model,where={}){for(const[k,v]of Object.entries(where)){if(k==='OR'||k==='AND'){for(const x of v)validateWhere(model,x);continue;}const f=fields(model).find(x=>x.name===k);if(f?.rest.includes('@db.Uuid')){for(const value of v&&typeof v==='object'?v.in??[v.not]:[v])if(value!=null&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))throw Error('invalid UUID query');}}}
function sorted(rows,orderBy){if(!orderBy)return [...rows];return [...rows].sort((a,b)=>{for(const term of Array.isArray(orderBy)?orderBy:[orderBy]){const[k,d]=Object.entries(term)[0],x=a[k],y=b[k];let c=eq(x,y)?0:x==null?1:y==null?-1:x<y?-1:1;if(c)return d==='desc'?-c:c;}return 0;});}
function project(model,row,args={}){if(!row)return null;let out={...row};if(args.include)for(const[k,v]of Object.entries(args.include)){if(k==='lines')out[k]=sorted(state.crm_OrderLines.filter(x=>x.orderId===row.id),v.orderBy).map(x=>({...x}));else if(k==='rules')out[k]=state.crm_PriceListRules.filter(x=>x.priceListId===row.id).map(x=>({...x}));else{const r=related(model,row,k);assert.ok(r,'Unknown include '+k);out[k]=project(r[1],r[0],v);}}if(args.select)out=Object.fromEntries(Object.keys(args.select).map(k=>[k,out[k]]));return out;}
function fk(model,row){const refs={crm_Orders:{seriesId:'NumberSeries',accountId:'crm_Accounts',contactId:'crm_Contacts',ownerId:'Users',priceListId:'crm_PriceLists'},crm_OrderLines:{orderId:'crm_Orders',productId:'crm_Products'}}[model]??{};for(const[k,m]of Object.entries(refs))if(row[k]!=null&&!state[m].some(x=>x.id===row[k]))throw Error('foreign key');if(model==='crm_Orders'&&!state.Currency.some(x=>x.code===row.currency))throw Error('currency foreign key');}
function unique(model,row){if(model==='crm_Orders'&&state[model].some(x=>x.id!==row.id&&(x.number===row.number||row.externalRef!=null&&x.source===row.source&&x.externalRef===row.externalRef))){const e=Error('unique order');e.code='P2002';throw e;}}
const db={};for(const model of modelNames){const delegate={
 async findMany(args={}){observed();validateWhere(model,args.where);for(const k of ['take','skip'])if(args[k]!=null&&(!Number.isInteger(args[k])||args[k]<0||args[k]>2147483647))throw Error('bad pagination');return sorted(state[model].filter(x=>matches(model,x,args.where)),args.orderBy).slice(args.skip??0,args.take==null?undefined:(args.skip??0)+args.take).map(x=>project(model,x,args));},
 async findFirst(args={}){return(await this.findMany({...args,take:1}))[0]??null;},async findUnique(args){return this.findFirst(args);},async count(args={}){return(await this.findMany(args)).length;},
 async create({data,select,include}){observed();const raw={...data};delete raw.lines;const row=full(model,raw);fk(model,row);unique(model,row);state[model].push(row);if(data.lines?.create)for(const child of data.lines.create)await db.crm_OrderLines.create({data:{...child,orderId:row.id}});return project(model,row,{select,include});},
 async createMany({data}){for(const row of data)await this.create({data:row});return{count:data.length};},
 async updateMany({where,data}){observed();validateWhere(model,where);let count=0;for(let i=0;i<state[model].length;i++)if(matches(model,state[model][i],where)){const row=full(model,{...state[model][i],...data,...(fields(model).some(f=>f.rest.includes('@updatedAt'))?{updatedAt:epoch}:{})});fk(model,row);unique(model,row);state[model][i]=row;count++;}return{count};},
 async deleteMany({where}){observed();validateWhere(model,where);const ids=state[model].filter(x=>matches(model,x,where)).map(x=>x.id);state[model]=state[model].filter(x=>!ids.includes(x.id));if(model==='crm_Orders')state.crm_OrderLines=state.crm_OrderLines.filter(x=>!ids.includes(x.orderId));return{count:ids.length};}
 };db[model]=delegate;}
db.users=db.Users;db.exchangeRate=db.ExchangeRate;db.currency=db.Currency;
db.$transaction=async fn=>{observed();const backup=Object.fromEntries(Object.entries(state).map(([m,rows])=>[m,rows.map(x=>full(m,x))]));try{return await fn(db);}catch(e){state=backup;throw e;}};
db.$queryRaw=async query=>{observed();const year=query.values[0],scope=query.values.at(-1),row=sorted(state.NumberSeries.filter(x=>x.scope===scope&&x.isDefault&&x.active),{createdAt:'asc'})[0];if(!row)return[];const value=full('NumberSeries',{...row,counter:row.resetPolicy==='YEARLY'&&row.currentYear!==year?1:row.counter+1,currentYear:year,updatedAt:epoch});Object.assign(row,value);return[{id:row.id,template:row.template,counter:row.counter,currentYear:row.currentYear}];};
function load(relative){const filename=path.resolve(root,relative);assert.ok(filename.startsWith(root+'/lib/')&&filename.endsWith('.ts'));if(cache.has(filename))return cache.get(filename).exports;const source=fs.readFileSync(filename,'utf8'),mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;hashes[path.relative(root,filename)]=crypto.createHash('sha256').update(source).digest('hex');mod.require=name=>{
 if(name==='@/lib/prisma')return{prismadb:db};if(name==='@/lib/resend')return{default:async()=>({emails:{send:async value=>{observed();mails.push(value);return{id:uid(9999)};}}})};
 if(name==='@/lib/plugins/i18n')return{translatePluginMessage:()=> 'Synthetic rule rejection'};
 if(['zod','decimal.js','node:async_hooks','@prisma/client','@prisma/client/runtime/client'].includes(name))return require(name);
 if(name.startsWith('@/lib/'))return load(name.slice(2)+'.ts');if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(filename),name+'.ts')));throw Error('Blocked runtime import '+name);
 };mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,filename);return mod.exports;}
const json=v=>JSON.parse(JSON.stringify(v)),tracked=['crm_Orders','crm_OrderLines','NumberSeries'];
function diff(before){const result={};for(const m of tracked){const prior=new Map(before[m].map(x=>[x.id,JSON.stringify(x)]));result[m]={upsert:state[m].filter(x=>prior.get(x.id)!==JSON.stringify(x)),deleted:before[m].filter(x=>!state[m].some(y=>y.id===x.id)).map(x=>x.id)};}return result;}
(async()=>{
 const tools=load('lib/mcp/tools/crm-orders.ts').crmOrderTools,{runMcpToolCall}=load('lib/mcp/run-tool.ts');({currentActorFrame}=load('lib/plugins/actor.ts'));
 const requests=[],cases=[],add=(u,t,input,label=t,setup=[])=>requests.push({user:uid(u),tool:t,input,label,setup});
 for(const u of [1,2,3,4]){for(const input of [{},{limit:2,offset:1},{status:'READY'},{accountId:uid(102)},{ownerId:uid(2)}])add(u,'crm_list_orders',input);for(const id of [1600,1601,1602,1620,1621,1622,1623,1624,1625,1626,1627,9998])add(u,'crm_get_order',{id:uid(id)});}
 for(const u of [1,3])for(let i=0;i<statuses.length;i++)for(const action of ['withdraw','reopen','retry','advance','cancel'])add(u,action==='cancel'?'crm_cancel_order':'crm_set_order_status',{id:uid(1600+i),...(action==='cancel'?{}:{action,...(action==='advance'?{to:'PAID'}:{})})},statuses[i]+'-'+action);
 const lineInput={productId:uid(600),quantity:2};
 for(const u of [1,2,3])for(const account of [101,102,104,9998])add(u,'crm_create_order',{accountId:uid(account),lines:[lineInput]});
 for(const extra of [{},{contactId:uid(1401)},{contactId:uid(1402)},{contactId:uid(1403)},{contactId:''},{contactId:' '},{shipping_city:'  東京  ',shipping_street:null,note:'\uFEFF 記録 \uFEFF'},{requestedDeliveryDate:'2026-02-31'},{requestedDeliveryDate:'bad'},{requestedDeliveryDate:''}])add(1,'crm_create_order',{accountId:uid(101),lines:[],...extra},'headers-and-empty-lines');
 for(const extra of [{unitPrice:600},{unitPrice:0},{unitPrice:null},{quantity:0.00001},{quantity:9999999999.99995},{quantity:1e-200},{quantity:1e200},{productId:uid(601)},{productId:uid(603)},{productId:uid(9998)},{productId:'bad'},{productId:uid(651)}])add(1,'crm_create_order',{accountId:uid(101),lines:[{...lineInput,...extra}]},'line-boundaries');
 for(const id of [1600,1601,1620,1621,1622,1623,1624])add(1,'crm_update_order',{id:uid(id),lines:[{...lineInput,quantity:1.23456}],shipping_city:'  更新  ',note:'\u0085 preserved \u0085'});
 for(const u of [1,3])for(const id of [1600,1602,1621,1623,1624,1626])add(u,'crm_submit_order',{id:uid(id)});
 for(const decision of ['APPROVED','REJECTED'])for(const u of [1,2,3,4])for(const note of [undefined,'  確認しました  '])add(u,'crm_decide_order_approval',{id:uid(1601),decision,...(note===undefined?{}:{note})});
 for(const updatedAt of [epoch,'2026-01-02T12:04:05.678+09:00','2025-01-01','invalid',''])add(3,'crm_decide_order_approval',{id:uid(1601),decision:'APPROVED',updatedAt});
 const setup=(model,key,values)=>({model,key,values});
 add(1,'crm_create_order',{accountId:uid(101),lines:[]},'no-series',[setup('NumberSeries',uid(1500),{active:false})]);
 add(1,'crm_create_order',{accountId:uid(101),lines:[]},'number-collision',[setup('NumberSeries',uid(1500),{template:'SEED-0'})]);
 add(1,'crm_create_order',{accountId:uid(101),lines:[]},'yearly-reset',[setup('NumberSeries',uid(1500),{currentYear:2025,counter:2147483647})]);
 add(1,'crm_create_order',{accountId:uid(101),lines:[]},'counter-overflow',[setup('NumberSeries',uid(1500),{resetPolicy:'NEVER',counter:2147483647})]);
 add(1,'crm_submit_order',{id:uid(1600)},'emails-disabled',[setup('crm_SystemSettings','orders_approval_emails',{value:'false'})]);
 add(1,'crm_submit_order',{id:uid(1600)},'repricing-inactive',[setup('crm_Products',uid(600),{status:'ARCHIVED'})]);
 add(1,'crm_submit_order',{id:uid(1626)},'raw-before-exchange-rounding');
 add(1,'crm_update_order',{id:uid(1626),lines:[lineInput]},'raw-before-exchange-rounding-update');
 for(const input of [{limit:1.5},{offset:.5},{offset:2147483648},{accountId:'bad'},{ownerId:''}])add(1,'crm_list_orders',input);
 add(1,'crm_get_order',{id:uid(1600)},'negative-zero-discount',[setup('crm_OrderLines',uid(1700),{listPrice:'1000000000000',unitPrice:'1000000000000.01'})]);
 add(1,'crm_create_order',{accountId:uid(101),lines:Array.from({length:207},(_,i)=>({...lineInput,quantity:i+1,unitPrice:1}))},'bulk-lines');
 for(const request of requests){
  serial=9000;state=Object.fromEntries(Object.entries(seeds).map(([m,rows])=>[m,rows.map(x=>full(m,x))]));mails=[];actors=[];
  for(const x of request.setup){const key=x.model==='crm_SystemSettings'?'key':'id',i=state[x.model].findIndex(r=>r[key]===x.key);assert.ok(i>=0);state[x.model][i]=full(x.model,{...state[x.model][i],...x.values});}
  const before=json(state),user=shared.users.find(x=>x.id===request.user),tool=tools.find(x=>x.name===request.tool),args=tool.schema.parse(request.input);
  const result=await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>tool.handler(args,u.id,u));
  assert.ok(actors.length&&actors.every(a=>a?.type==='token'&&a.userId===user.id&&a.role===user.role));
  let followup; if(request.label==='bulk-lines'&&!result.isError){const data=JSON.parse(result.content[0].text).data;const get=tools.find(x=>x.name==='crm_get_order');followup=await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>get.handler({id:data.id},u.id,u));}
  cases.push({...request,result,followup,effects:diff(before),audit:state.crm_AuditLog,mails});
 }
 for(const f of ['prisma/schema.prisma','node_modules/@prisma/client/package.json','node_modules/decimal.js/package.json','node_modules/zod/package.json','desktop/native/build/mcp-catalog-reference.json','desktop/native/build/mcp-accounts-reference.json'])hashes[f]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,seeds,cases,tools:tools.map(x=>x.name),sourceSHA256:hashes},null,2)+'\n');
 console.log(JSON.stringify({sourceOrderCases:cases.length,tools:tools.length,scope:'Actual original order handlers/service/workflow/pricing/notifications with synthetic Prisma/Resend; no external activity.'}));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
