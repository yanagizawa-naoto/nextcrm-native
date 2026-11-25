// Original five contract handlers, auth scopes and run-tool, with an isolated
// synthetic Prisma adapter. No live PostgreSQL or plugin code is invoked.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const { Prisma } = require('@prisma/client');
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
const shared = JSON.parse(fs.readFileSync(path.join(__dirname, 'build/mcp-accounts-reference.json'), 'utf8'));
const schema = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8'), epoch = shared.epoch;
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const definitions = new Map();
function fields(model) {
  if (definitions.has(model)) return definitions.get(model);
  const body = schema.match(new RegExp(`model ${model}\\s*\\{([\\s\\S]*?)^\\}`, 'm'))[1];
  const scalarNames = new Set(Prisma.dmmf.datamodel.models.find(x => x.name === model).fields.filter(x => x.kind !== 'object').map(x => x.name));
  const values = body.split('\n').map(line => {
    const match = line.match(/^\s*(\w+)\s+(\w+)(\[\]|\?)?(.*)$/); if (!match || !scalarNames.has(match[1])) return null;
    return { name: match[1], type: match[2], array: match[3] === '[]', optional: match[3] === '?', rest: match[4] };
  }).filter(Boolean);
  definitions.set(model, values); return values;
}
function full(model, values, generated = uid(9000)) {
  const row = {};
  for (const field of fields(model)) {
    const expression = field.rest.match(/@default\(([^)]*)\)/)?.[1];
    let value = field.array ? [] : null;
    if (field.rest.includes('@updatedAt') || expression?.startsWith('now(')) value = epoch;
    else if (expression?.startsWith('uuid(')) value = generated;
    else if (expression !== undefined) { try { value = JSON.parse(expression); } catch { value = expression; } }
    row[field.name] = value;
  }
  Object.assign(row, Object.fromEntries(Object.entries(values).filter(([,value])=>value!==undefined)));
  for (const field of fields(model)) {
    const value = row[field.name];
    if (value == null) { if (!field.optional && !field.array) throw Error('Missing required scalar ' + field.name); continue; }
    if (field.type === 'Decimal') {
      const [, precision, scale] = field.rest.match(/@db.Decimal\((\d+),\s*(\d+)\)/);
      const decimal = new Prisma.Decimal(value).toDecimalPlaces(Number(scale), Prisma.Decimal.ROUND_HALF_UP);
      if (decimal.abs().gte(new Prisma.Decimal(10).pow(Number(precision) - Number(scale)))) throw Error('numeric overflow');
      row[field.name] = decimal;
    }
    const enumBody = schema.match(new RegExp(`enum ${field.type}\\s*\\{([\\s\\S]*?)^\\}`, 'm'))?.[1];
    if (enumBody && !enumBody.split('\n').map(x=>x.trim().split(/\s+/)[0]).includes(value)) throw Error('invalid Prisma enum');
    if (field.type === 'Int' && (!Number.isInteger(value) || value < -2147483648 || value > 2147483647)) throw Error('integer overflow');
    if (field.type === 'DateTime') { const date = new Date(value); if (!Number.isFinite(date.getTime())) throw Error('invalid date'); row[field.name] = date; }
    if (field.rest.includes('@db.Uuid') && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw Error('invalid UUID');
    if (field.type === 'String' && typeof value === 'string' && value.includes('\0')) throw Error('PostgreSQL text cannot contain NUL');
  }
  return row;
}
const users=shared.users, models=['crm_Products','crm_ProductCategories','crm_PriceLists','crm_PriceListRules','crm_AuditLog','Currency','ExchangeRate','crm_SystemSettings','crm_Accounts'];
const seeds=Object.fromEntries(models.map(m=>[m,[]]));
function seed(model,values){ const row=full(model,values);seeds[model].push(row); return row; }
for(const code of ['JPY','USD','EUR','CZK'])seed('Currency',{code,name:code,symbol:code,isEnabled:code!=='CZK',isDefault:code==='JPY'});
seed('ExchangeRate',{id:uid(1100),fromCurrency:'JPY',toCurrency:'USD',rate:'0.00666667'});
seed('ExchangeRate',{id:uid(1101),fromCurrency:'USD',toCurrency:'EUR',rate:'0.87654321'});
for(const [id,parentId]of [[700,null],[701,700],[702,701],[703,null]])seed('crm_ProductCategories',{id:uid(id),name:'Category'+id,parentId:parentId?uid(parentId):null,source:id===703?'EXTERNAL':'CRM',isActive:id!==701});
for(const [id,values]of [[600,{name:'日本語商品',unit_price:'1234.56',unit_cost:'345.67',categoryId:uid(702),status:'ACTIVE',sku:'SKU600'}],[601,{name:'Service',unit_price:'0.01',type:'SERVICE',currency:'USD',status:'ARCHIVED',unit_cost:null}],[602,{name:'External',source:'EXTERNAL'}],[603,{name:'Deleted',deletedAt:epoch}],[604,{name:'NegativeTiny',unit_price:'1'}]])seed('crm_Products',{id:uid(id),name:'Product'+id,type:'PRODUCT',unit_price:'100',currency:'JPY',...values});
for(let i=800;i<=825;i++)seed('crm_PriceLists',{id:uid(i),name:i===801||i===802?'Same':'List'+i,currency:({803:'USD',804:'EUR',805:'CZK'})[i]??'JPY',source:i===806?'EXTERNAL':'CRM',isActive:i!==807});
function r(id,list,values){return seed('crm_PriceListRules',{id:uid(id),priceListId:uid(list),fixedPrice:'100',...values});}
r(900,800,{appliesTo:'ALL',fixedPrice:'999'});r(901,800,{appliesTo:'CATEGORY',categoryId:uid(700),fixedPrice:'700'});r(902,800,{appliesTo:'CATEGORY',categoryId:uid(701),fixedPrice:'701'});r(903,800,{appliesTo:'CATEGORY',categoryId:uid(702),fixedPrice:'702'});r(904,800,{appliesTo:'CATEGORY',categoryId:uid(700),minQuantity:'10',fixedPrice:'710'});r(905,800,{appliesTo:'PRODUCT',productId:uid(600),minQuantity:'5',fixedPrice:'605'});r(906,800,{appliesTo:'PRODUCT',productId:uid(600),minQuantity:'5',fixedPrice:'606'});r(907,800,{appliesTo:'PRODUCT',productId:uid(600),minQuantity:'20',fixedPrice:'620',dateStart:'2026-02-01',dateEnd:'2026-02-28'});
r(908,801,{computePrice:'PERCENTAGE',percentPrice:'12.3456',base:'COST'});r(909,802,{computePrice:'FORMULA',priceDiscount:'10',priceRound:'0.05',priceSurcharge:'0.01',priceMinMargin:'-100',priceMaxMargin:'100'});r(910,803,{computePrice:'PERCENTAGE',percentPrice:'5',base:'PRICE_LIST',basePriceListId:uid(800)});r(911,804,{computePrice:'FORMULA',base:'PRICE_LIST',basePriceListId:uid(803),priceDiscount:'12.3456',priceRound:'0.025',priceSurcharge:'0.125'});r(912,806,{fixedPrice:'88'});r(913,807,{fixedPrice:'77'});
for(let i=810;i<821;i++)r(930+i-810,i,{computePrice:'PERCENTAGE',percentPrice:'1',base:'PRICE_LIST',basePriceListId:uid(i+1)});
r(941,821,{computePrice:'PERCENTAGE',percentPrice:'1',base:'PRICE_LIST',basePriceListId:uid(810)});
r(942,822,{computePrice:'FORMULA',priceDiscount:'101',priceRound:'0.05'});r(943,823,{computePrice:'FIXED',fixedPrice:'-0.0049'});r(944,824,{computePrice:'PERCENTAGE',percentPrice:'33.3333'});
for(const x of shared.seeds)seed('crm_Accounts',{...x,pricelist_id:x.id===uid(101)?uid(800):null});
seed('crm_SystemSettings',{key:'default_pricelist_id',value:uid(801)});
let state,actors=[],currentActorFrame,serial=9000,auditFailure=false;
const observed=()=>actors.push(currentActorFrame()?.actor);
function matches(row,where={}){return Object.entries(where).every(([key,value])=>{
 if(key==='OR')return value.some(x=>matches(row,x));if(key==='AND')return value.every(x=>matches(row,x));
 if(key==='watchers')return shared.watchers.some(x=>x.account_id===row.id&&matches(x,value.some));
 assert.ok(Object.hasOwn(row,key),'Unknown predicate '+key);
 if(value&&typeof value==='object'&&!(value instanceof Date)){if(Object.hasOwn(value,'not'))return row[key]!==value.not;throw Error('Unhandled predicate '+key);}
 return row[key]===value;
});}
function validateWhere(model,where={}){ for(const[k,v]of Object.entries(where)){if(k==='OR'||k==='AND'){for(const x of v)validateWhere(model,x);continue;}const f=fields(model).find(x=>x.name===k);if(f?.rest.includes('@db.Uuid')){const value=v&&typeof v==='object'?v.not:v;if(value!=null&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))throw Error('Invalid UUID query');}}}
function order(rows,orderBy){if(!orderBy)return[...rows];return[...rows].sort((a,b)=>{for(const term of Array.isArray(orderBy)?orderBy:[orderBy]){const[[key,direction]]=Object.entries(term),av=a[key] instanceof Date?a[key].getTime():a[key],bv=b[key] instanceof Date?b[key].getTime():b[key];const cmp=av==bv?0:av==null?1:bv==null?-1:av<bv?-1:1;if(cmp)return direction==='desc'?-cmp:cmp;}return 0;});}
function projection(model,row,select,include){if(!row)return null;if(select)return Object.fromEntries(Object.keys(select).map(k=>[k,row[k]]));const result={...row};if(include?.category)result.category=state.crm_ProductCategories.find(x=>x.id===row.categoryId)??null;if(include?.rules)result.rules=state.crm_PriceListRules.filter(x=>x.priceListId===row.id);return result;}
function constraints(model,row,old){const relations={crm_Products:{currency:'Currency.code',categoryId:'crm_ProductCategories.id'},crm_PriceLists:{currency:'Currency.code'},crm_PriceListRules:{priceListId:'crm_PriceLists.id',basePriceListId:'crm_PriceLists.id',categoryId:'crm_ProductCategories.id',productId:'crm_Products.id'}};for(const[field,target]of Object.entries(relations[model]??{})){if(row[field]==null)continue;const[m,k]=target.split('.');if(!state[m].some(x=>x[k]===row[field]))throw Error('FK '+field);}if(model==='crm_Products'&&row.sku!=null&&state[model].some(x=>x.id!==old?.id&&x.sku===row.sku))throw Error('unique sku');}
const db={};for(const model of models){const client=model==='Currency'?'currency':model==='ExchangeRate'?'exchangeRate':model;db[client]={
 findFirst:async({where,select,include}={})=>{observed();validateWhere(model,where);return projection(model,state[model].find(x=>matches(x,where)),select,include);},
 findUnique:async(args)=>db[client].findFirst(args),
 findMany:async({where,select,include,orderBy,take,skip}={})=>{observed();validateWhere(model,where);if(take!==undefined&&(!Number.isInteger(take)||!Number.isInteger(skip??0)||(skip??0)>2147483647))throw Error('Prisma pagination');return order(state[model].filter(x=>matches(x,where)),orderBy).slice(skip??0,take===undefined?undefined:(skip??0)+take).map(x=>projection(model,x,select,include));},
 count:async({where})=>{observed();validateWhere(model,where);return state[model].filter(x=>matches(x,where)).length;},
 create:async({data})=>{observed();if(model==='crm_AuditLog'&&auditFailure)throw Error('synthetic audit failure');const row=full(model,data,uid(serial++));constraints(model,row);state[model].push(row);return{...row};},
 update:async({where,data})=>{observed();validateWhere(model,where);const index=state[model].findIndex(x=>matches(x,where));assert.ok(index>=0);const old=state[model][index],row=full(model,{...old,...data,updatedAt:epoch});constraints(model,row,old);state[model][index]=row;return{...row};},
 delete:async({where})=>{observed();validateWhere(model,where);const index=state[model].findIndex(x=>matches(x,where));assert.ok(index>=0);return state[model].splice(index,1)[0];}
};}
function load(relative){const filename=path.resolve(root,relative);assert.ok(filename.startsWith(root+'/lib/')&&filename.endsWith('.ts'));if(cache.has(filename))return cache.get(filename).exports;const source=fs.readFileSync(filename,'utf8'),mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;hashes[path.relative(root,filename)]=crypto.createHash('sha256').update(source).digest('hex');mod.require=name=>{
 if(name==='@/lib/prisma')return{prismadb:db};if(name==='@/lib/authz')return{...load('lib/authz/errors.ts'),...load('lib/authz/scopes/pricing.ts')};
 if(name==='@/lib/plugins/i18n')return{translatePluginMessage:()=> 'Synthetic rule rejection'};
 if(['zod','node:async_hooks','decimal.js'].includes(name))return require(name);if(name.startsWith('@/lib/'))return load(name.slice(2)+'.ts');if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(filename),name+'.ts')));throw Error('Blocked runtime import '+name);
};mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,filename);return mod.exports;}
(async()=>{
 const tools=[...load('lib/mcp/tools/crm-products.ts').crmProductTools,...load('lib/mcp/tools/crm-price-lists.ts').crmPriceListTools],{runMcpToolCall}=load('lib/mcp/run-tool.ts');({currentActorFrame}=load('lib/plugins/actor.ts'));
 const requests=[],cases=[],add=(user,tool,input,label=tool,extra={})=>requests.push({user:uid(user),tool,input,label,...extra});
 for(const user of[1,2,3,4]){
  for(const input of[{}, {limit:2,offset:1},{status:'ACTIVE'},{status:'ARCHIVED'}])add(user,'crm_list_products',input);
  for(const id of[600,601,602,603,9998])add(user,'crm_get_product',{id:uid(id)});
  for(const input of[{}, {includeArchived:true},{source:'EXTERNAL'},{limit:2,offset:1}])add(user,'crm_list_price_lists',input);
  for(const id of[800,806,807,9998])add(user,'crm_get_price_list',{id:uid(id)});
  for(const id of[600,602,603,9998]){add(user,'crm_update_product',{id:uid(id),name:'  Changed  ',unit_price:1.005});add(user,'crm_delete_product',{id:uid(id)});}
  add(user,'crm_create_product',{name:'  新規  ',type:'PRODUCT',unit_price:1.005,currency:'JPY'});
  add(user,'crm_create_price_list',{name:'  新規  ',currency:'JPY'});
  for(const id of[800,806,807,9998]){add(user,'crm_update_price_list',{id:uid(id),name:'  更新  ',isActive:false});add(user,'crm_archive_price_list',{id:uid(id)});}
  for(const id of[900,912,9998])add(user,'crm_delete_price_list_rule',{id:uid(id)});
 }
 const product={name:'Product',type:'PRODUCT',unit_price:0,currency:'JPY'};
 for(const changes of[{currency:'CZK'},{currency:'ZZZ'},{categoryId:uid(703)},{categoryId:uid(9998)},{sku:''},{sku:'SKU600'},{description:'NUL\0bad'},{name:'長'.repeat(600),sku:'  '},{is_recurring:false,billing_period:'MONTHLY'},{type:'SERVICE',is_recurring:true,billing_period:'ANNUALLY'},{unit_price:0.015,unit_cost:2.675,tax_rate:1.005},{unit_price:1e16},{unit_price:5e-324}])add(3,'crm_create_product',{...product,...changes});
 for(const changes of[{},{sku:''},{sku:'SKU600'},{currency:'CZK'},{categoryId:uid(703)},{billing_period:'MONTHLY',is_recurring:false},{type:'SERVICE',status:'ARCHIVED',tax_rate:100}])add(3,'crm_update_product',{id:uid(600),...changes});
 for(const rawInputJSON of['{"name":"raw","type":"PRODUCT","currency":"JPY","unit_price":0.00499999999999999999999}'])add(3,'crm_create_product',JSON.parse(rawInputJSON),'raw JSON precision',{rawInputJSON});
 for(const tool of['crm_list_products','crm_list_price_lists'])for(const input of[{limit:1.5},{offset:0.5},{offset:2147483648}])add(1,tool,input);
 for(const currency of['CZK','ZZZ','USD']){add(3,'crm_create_price_list',{name:'Currency',currency});add(3,'crm_update_price_list',{id:uid(800),currency});}
 for(const id of['','bad',uid(9998)])for(const tool of['crm_get_price_list','crm_archive_price_list'])add(3,tool,{id});
 const fixed={priceListId:uid(808),appliesTo:'ALL',computePrice:'FIXED',fixedPrice:1.23456};
 for(const user of[1,2,3,4])add(user,'crm_upsert_price_list_rule',fixed);
 for(const changes of[{priceListId:uid(806)},{priceListId:uid(9998)},{priceListId:''},{ruleId:uid(900)},{ruleId:'bad'},{ruleId:''},{fixedPrice:null},{appliesTo:'CATEGORY'},{appliesTo:'PRODUCT',minQuantity:-1},{appliesTo:'CATEGORY',categoryId:uid(703)},{appliesTo:'PRODUCT',productId:uid(603)},{appliesTo:'PRODUCT',productId:uid(9998)},{appliesTo:'PRODUCT',productId:'bad'},{fixedPrice:-1.23455},{fixedPrice:0.00005},{fixedPrice:1e14},{minQuantity:1e10},{minQuantity:0.00005},{categoryId:uid(9998),productId:'bad',base:'PRICE_LIST',basePriceListId:'bad',percentPrice:1000,priceDiscount:2000,priceRound:-10}])add(3,'crm_upsert_price_list_rule',{...fixed,...changes});
 const formula={...fixed,computePrice:'FORMULA'};
 for(const changes of[{computePrice:'PERCENTAGE'},{computePrice:'PERCENTAGE',percentPrice:-1},{computePrice:'PERCENTAGE',percentPrice:101},{computePrice:'PERCENTAGE',percentPrice:100},{computePrice:'PERCENTAGE',percentPrice:0},{base:'PRICE_LIST'},{base:'PRICE_LIST',basePriceListId:uid(808)},{base:'PRICE_LIST',basePriceListId:uid(9998)},{base:'PRICE_LIST',basePriceListId:uid(806)},{priceRound:0},{priceRound:-1},{priceMinMargin:10,priceMaxMargin:1},{priceMinMargin:-10,priceMaxMargin:-1,priceDiscount:125,priceSurcharge:-1},{priceDiscount:1000},{priceDiscount:999.99995},{priceRound:0.00001},{appliesTo:'CATEGORY',minQuantity:-1,base:'PRICE_LIST',priceRound:0,priceMinMargin:2,priceMaxMargin:1}])add(3,'crm_upsert_price_list_rule',{...formula,...changes});
 add(3,'crm_upsert_price_list_rule',{...formula,priceListId:uid(800),base:'PRICE_LIST',basePriceListId:uid(804)},'cycle rejection');
 add(3,'crm_upsert_price_list_rule',{...fixed,priceListId:uid(802),ruleId:uid(909)},'update resets irrelevant fields');
 add(3,'crm_upsert_price_list_rule',{...formula,priceListId:uid(803),ruleId:uid(910),base:'PRICE_LIST',basePriceListId:uid(804)},'update cycle');
 const dates=['2026-01-01','2026-01','2026','2026-02-30','2026-01-01T24:00:00Z','2026-01-01T12:34:56.123456+09:00','2026-01-01T12:34','2026-01-01T00:00:00-05:30','Thu, 19 Nov 2026 12:00:00 GMT','11/19/2026','Nov 19, 2026',' 2026-01-01 ','0','1','12','13','49','50','99','100','0000-01-01','0001-01-01','1582-10-10','9999-12-31','bad','2026-13-01','2026-01-32','2026-01-01T25:00:00Z','2026-01-01T12:00:00+24:00','2026-01-01\0','2026-1-1','2026-01-01 12:34:56','2026-01-01t12:34:56z','2026-1-01','2026-01-1','2026/1/1','11-19-2026','2026-01-01 GMT','2026-01-01Z','Nov 19 2026',''];
 for(const dateStart of dates)add(3,'crm_upsert_price_list_rule',{...fixed,dateStart},'date compatibility');
 for(const changes of[{dateStart:'2026-02-01',dateEnd:'2026-01-01'},{dateStart:'bad',dateEnd:'2026-01-01'},{dateStart:'',dateEnd:null},{dateStart:'bad',base:'PRICE_LIST',basePriceListId:uid(9998)}])add(3,'crm_upsert_price_list_rule',{...formula,...changes});
 const price={productId:uid(600),quantity:1,date:'2026-02-15'};
 for(const priceListId of[undefined,'',uid(800),uid(801),uid(802),uid(803),uid(804),uid(805),uid(806),uid(807),uid(808),uid(810),uid(822),uid(823),uid(824),uid(9998),'bad'])for(const quantity of[1,5,20])add(1,'crm_get_price',{...price,priceListId,quantity});
 for(const accountId of[uid(101),uid(102),uid(103),uid(105),uid(9998),'bad','']){add(1,'crm_get_price',{...price,accountId});add(1,'crm_get_price',{...price,accountId,priceListId:uid(800)});}
 for(const productId of[uid(601),uid(602),uid(603),uid(604),uid(9998),'bad'])for(const priceListId of[undefined,uid(800),uid(803)])add(1,'crm_get_price',{...price,productId,priceListId});
 for(const date of['2026-01-31T23:59:59Z','2026-02-01T23:59:59Z','2026-02-28T23:59:59Z','2026-03-01','bad','0000-01-01','1582-10-10'])add(1,'crm_get_price',{...price,priceListId:uid(800),quantity:20,date});
 add(1,'crm_get_price',{...price,date:'bad'},'invalid date ignored without list');add(1,'crm_get_price',{...price,date:'bad',priceListId:uid(805)},'rate error precedes invalid date');
 for(const quantity of[5e-324,0.00001,4.999999999999999,5,1e100,1.7976931348623157e308])add(1,'crm_get_price',{...price,quantity,priceListId:uid(800)});
 add(3,'crm_create_price_list',{name:'Audit failure is best effort',currency:'JPY'},'business audit failure',{auditFailure:true});
 add(3,'crm_get_price_list',{id:uid(808)},'all105rules',{extraRules:Array.from({length:105},(_,i)=>full('crm_PriceListRules',{id:uid(2000+i),priceListId:uid(808),fixedPrice:i}))});
 const scenario=(label,changes,extraRules=[],input={})=>add(1,'crm_get_price',{...price,priceListId:uid(800),...input},label,{seedChanges:changes,extraRules});
 scenario('newest before id',{crm_PriceListRules:[{id:uid(905),createdAt:'2027-01-01'}]},[],{quantity:5});
 scenario('fractional threshold',{crm_PriceListRules:[{id:uid(905),minQuantity:'4.9999'}]},[],{quantity:4.9999});
 scenario('UTC inclusive rule dates',{crm_PriceListRules:[{id:uid(907),dateStart:'2026-02-02T00:30:00+09:00',dateEnd:'2026-02-02T00:30:00+09:00'}]},[],{quantity:20,date:'2026-02-01T01:00:00Z'});
 scenario('ten levels succeed',{crm_PriceListRules:[{id:uid(941),computePrice:'FIXED',fixedPrice:'100'}]},[],{priceListId:uid(811)});
 scenario('BFS eleven list fanout',{},[...Array.from({length:12},(_,i)=>full('crm_PriceListRules',{id:uid(3000+i),priceListId:uid(808),computePrice:'PERCENTAGE',base:'PRICE_LIST',basePriceListId:uid(800+i),percentPrice:0})),full('crm_PriceListRules',{id:uid(3020),priceListId:uid(808),appliesTo:'PRODUCT',productId:uid(600),computePrice:'PERCENTAGE',base:'PRICE_LIST',basePriceListId:uid(821),percentPrice:0})],{priceListId:uid(808)});
 scenario('inverse rate exact',{},[],{productId:uid(601),priceListId:uid(808)});
 scenario('small inverse rate precision',{ExchangeRate:[{id:uid(1100),rate:'0.00000001'}]},[],{productId:uid(601),priceListId:uid(808)});
 scenario('zero margin skipped',{crm_PriceListRules:[{id:uid(909),priceMinMargin:0,priceMaxMargin:0}]},[],{priceListId:uid(802)});
 scenario('negative rounding half away',{crm_Products:[{id:uid(604),unit_price:'2.5'}],crm_PriceListRules:[{id:uid(942),priceDiscount:110,priceRound:'0.1'}]},[],{productId:uid(604),priceListId:uid(822)});
 for(const date of['+010000-01-01','-000001-01-01'])add(1,'crm_get_price',{...price,date,priceListId:uid(800)},'extended pricing date');
 for(const billing_period of ['QUARTERLY','SEMIANNUALLY','ANNUALLY'])add(3,'crm_create_product',{...product,billing_period},'schema enum versus input enum');
 for(const request of requests){state=Object.fromEntries(Object.entries(seeds).map(([m,rows])=>[m,rows.map(x=>({...x}))]));state.crm_PriceListRules.push(...(request.extraRules??[]));for(const[m,changes]of Object.entries(request.seedChanges??{}))for(const change of changes){const i=state[m].findIndex(x=>x.id===change.id);state[m][i]=full(m,{...state[m][i],...change});}actors=[];serial=9000;auditFailure=!!request.auditFailure;
 const user=users.find(x=>x.id===request.user),tool=tools.find(x=>x.name===request.tool);assert.ok(tool,'tool '+request.tool);const args=tool.schema.parse(request.input);
 const oldError=console.error;if(auditFailure)console.error=()=>{};let result;try{result=await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>tool.handler(args,u.id,u));}finally{console.error=oldError;}
 if(actors.length)assert.ok(actors.every(x=>x?.type==='token'&&x.userId===user.id&&x.role===user.role));
 cases.push({...request,result,state:Object.fromEntries(['crm_Products','crm_PriceLists','crm_PriceListRules','crm_AuditLog'].map(m=>[m,state[m]]))});}
 for(const file of['prisma/schema.prisma','node_modules/@prisma/client/package.json','node_modules/@prisma/client/runtime/client.js','node_modules/zod/package.json','node_modules/decimal.js/decimal.js'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,seeds,cases,tools:tools.map(x=>x.name),sourceSHA256:hashes,timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,dateCases:dates.map(text=>({text,iso:Number.isFinite(new Date(text).getTime())?new Date(text).toISOString():null}))})+'\n');console.log(JSON.stringify({sourceCatalogCases:cases.length,tools:tools.length,dates:dates.length,sourceFiles:Object.keys(hashes).length}));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
