// Synthetic Prisma boundary for actual plugin DataApi/catalog/order services.
// Models, defaults, enum and numeric precision come from checked-in schema;
// no live PostgreSQL, app bootstrapping, environment, mail or HTTP is invoked.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{Prisma}=require('@prisma/client');
const {createSourceLoader}=require('./plugins-source-loader.cjs');
function createSourceDatabase(options={}){
 const root=options.root??path.resolve(__dirname,'../..'),schema=fs.readFileSync(path.join(root,'prisma/schema.prisma'),'utf8');
 const OriginalDate=Date,clock=options.clock??(()=>new OriginalDate(options.epoch??'2026-01-01T12:34:56.789Z')),state={},definitions={},events=[],logs=[],observed=[],faults={};let serial=options.serial??900000;
 const clone=x=>x instanceof Date?new Date(x):Prisma.Decimal.isDecimal(x)?new Prisma.Decimal(x):Array.isArray(x)?x.map(clone):x&&typeof x==='object'?Object.fromEntries(Object.entries(x).map(([k,v])=>[k,clone(v)])):x;
 for(const model of Prisma.dmmf.datamodel.models){
  const block=schema.match(new RegExp(`^model ${model.name}\\s*\\{([\\s\\S]*?)^\\}`,'m'))?.[1];if(!block)continue;
  const scalarNames=new Set(model.fields.filter(f=>f.kind!=='object').map(f=>f.name));
  const fields=block.split('\n').map(line=>{const m=line.match(/^\s*(\w+)\s+(\w+)(\[\]|\?)?(.*)$/);return m&&scalarNames.has(m[1])?{name:m[1],type:m[2],array:m[3]==='[]',optional:m[3]==='?',attributes:m[4]}:null}).filter(Boolean);
  const unique=fields.filter(f=>f.attributes.includes('@id')||f.attributes.includes('@unique')).map(f=>[f.name]);
  for(const m of block.matchAll(/@@(?:unique|id)\(\[([^\]]+)\]/g))unique.push(m[1].split(',').map(x=>x.trim()));
  definitions[model.name]={fields,unique,relations:model.fields.filter(f=>f.kind==='object')};state[model.name]=[];
 }
 const id=()=>`d0000000-0000-4000-8000-${String(serial++).padStart(12,'0')}`;
 function normalized(model,values,base){
  const row=base?clone(base):{};
  for(const field of definitions[model].fields){
   if(base)continue;let value=field.array?[]:null,expression=field.attributes.match(/@default\(([^)]*)\)/)?.[1];
   if(expression?.startsWith('uuid(')||expression?.startsWith('cuid('))value=id();
   else if(expression?.startsWith('now(')||field.attributes.includes('@updatedAt'))value=clock();
   else if(expression!==undefined){try{value=JSON.parse(expression)}catch{value=expression}}
   row[field.name]=value;
  }
  for(const [key,input]of Object.entries(values??{})){
   if(input===undefined)continue;const field=definitions[model].fields.find(f=>f.name===key);if(!field){if(['lines','rules'].includes(key))continue;throw Error('Unknown field '+model+'.'+key)}
   let value=input;
   if(base&&value&&typeof value==='object'&&!Array.isArray(value)&&!(value instanceof Date)&&!Prisma.Decimal.isDecimal(value)&&field.type!=='Json'){
    if(Object.hasOwn(value,'set'))value=value.set;
    else for(const [op,operand]of Object.entries(value)){
     if(!['increment','decrement','multiply','divide','push'].includes(op))throw Error('Invalid field operation '+op);
     if(op==='push'){value=[...(row[key]??[]),...(Array.isArray(operand)?operand:[operand])];break}
     const x=new Prisma.Decimal(row[key]??0),y=new Prisma.Decimal(operand);value=({increment:()=>x.add(y),decrement:()=>x.sub(y),multiply:()=>x.mul(y),divide:()=>x.div(y)})[op]();if(field.type!=='Decimal')value=value.toNumber();
    }
   }
   row[key]=clone(value);
  }
  for(const field of definitions[model].fields){
   let value=row[field.name];if(base&&field.attributes.includes('@updatedAt'))value=clock();
   if(value===null||value===undefined){if(!field.optional&&!field.array)throw Error('Missing required scalar '+field.name);row[field.name]=null;continue}
   if(field.type==='Decimal'){
    const [,precision,scale]=field.attributes.match(/@db.Decimal\((\d+),\s*(\d+)\)/)??[];
    value=new Prisma.Decimal(value);if(scale!==undefined)value=value.toDecimalPlaces(Number(scale),Prisma.Decimal.ROUND_HALF_UP);
    if(precision!==undefined&&value.abs().gte(new Prisma.Decimal(10).pow(Number(precision)-Number(scale))))throw Error('numeric overflow');
   }
   if(field.type==='DateTime'){value=new Date(value);if(!Number.isFinite(+value))throw Error('Invalid time value');if(field.attributes.includes('@db.Date'))value=new Date(value.toISOString().slice(0,10)+'T00:00:00.000Z')}
   if(field.type==='Int'&&(!Number.isInteger(value)||value < -2147483648||value>2147483647))throw Error('integer overflow');
   if(field.type==='String'&&!field.array&&(typeof value!=='string'||value.includes('\0')))throw Error('Invalid text');
   if(field.type==='Boolean'&&typeof value!=='boolean')throw Error('Invalid boolean');
   if(field.array&&!Array.isArray(value))throw Error('Invalid array');
   const body=schema.match(new RegExp(`^enum ${field.type}\\s*\\{([\\s\\S]*?)^\\}`,'m'))?.[1];if(body&&!body.split('\n').map(x=>x.trim().split(/\s+/)[0]).includes(value))throw Error('Invalid enum');
   row[field.name]=value;
  }
  return row;
 }
 const same=(a,b)=>a==null||b==null?a==null&&b==null:Prisma.Decimal.isDecimal(a)||Prisma.Decimal.isDecimal(b)?new Prisma.Decimal(a).eq(b):a instanceof Date||b instanceof Date?+new Date(a)===+new Date(b):JSON.stringify(a)===JSON.stringify(b);
 function scalar(a,op){
  if(op==null||typeof op!=='object'||op instanceof Date||Prisma.Decimal.isDecimal(op)||Array.isArray(op))return same(a,op);
  const folded=x=>op.mode==='insensitive'&&typeof x==='string'?x.toLowerCase():x,left=folded(a);
  return Object.entries(op).every(([key,value])=>{
   if(key==='mode')return true;if(key==='equals')return same(left,folded(value));if(key==='not')return a!=null&&!scalar(a,value);
   if(key==='in')return a!=null&&value.some(v=>same(left,folded(v)));if(key==='notIn')return a!=null&&!value.some(v=>same(left,folded(v)));
   if(['lt','lte','gt','gte'].includes(key)){if(a==null)return false;const right=folded(value),cmp=Prisma.Decimal.isDecimal(a)?a.comparedTo(value):a instanceof Date?Math.sign(+a-+new Date(value)):left<right?-1:left>right?1:0;return {lt:cmp<0,lte:cmp<=0,gt:cmp>0,gte:cmp>=0}[key]}
   if(['contains','startsWith','endsWith'].includes(key)){if(typeof left!=='string')return false;let text=String(folded(value)),pattern='',escaped=false;for(const char of text){if(!escaped&&char==='\\'){escaped=true;continue}pattern+=!escaped&&char==='%'?'.*':!escaped&&char==='_'?'.':char.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');escaped=false}return new RegExp((key==='contains'||key==='endsWith'?'':'^')+pattern+(key==='contains'||key==='startsWith'?'':'$'),'su').test(left)}
   if(key==='has')return Array.isArray(a)&&a.some(x=>same(x,value));if(key==='hasSome')return Array.isArray(a)&&value.some(x=>a.some(y=>same(x,y)));if(key==='hasEvery')return Array.isArray(a)&&value.every(x=>a.some(y=>same(x,y)));if(key==='isEmpty')return Array.isArray(a)&&(a.length===0)===value;
   throw Error('Unimplemented scalar operator '+key);
  });
 }
 function relation(model,row,name){
  if(model==='crm_Orders'&&name==='lines')return {model:'crm_OrderLines',rows:state.crm_OrderLines.filter(x=>x.orderId===row.id),many:true};
  if(model==='crm_PriceLists'&&name==='rules')return {model:'crm_PriceListRules',rows:state.crm_PriceListRules.filter(x=>x.priceListId===row.id),many:true};
  if(model==='crm_ProductCategories'&&name==='parent')return {model,rows:state[model].filter(x=>x.id===row.parentId),many:false};
  if(model==='crm_Activities'&&name==='links')return {model:'crm_ActivityLinks',rows:state.crm_ActivityLinks.filter(x=>x.activityId===row.id),many:true};
  throw Error('Unimplemented relation '+model+'.'+name);
 }
 function matches(model,row,where={}){
  return Object.entries(where??{}).every(([key,value])=>{
   if(value===undefined)return true;const many=Array.isArray(value)?value:[value];
   if(key==='AND')return many.every(x=>matches(model,row,x));if(key==='OR')return many.some(x=>matches(model,row,x));if(key==='NOT')return many.every(x=>!matches(model,row,x));
   if(Object.hasOwn(row,key))return scalar(row[key],value);
   if(definitions[model].unique.some(keys=>keys.join('_')===key))return matches(model,row,value);
   const linked=relation(model,row,key);if(value.some)return linked.rows.some(x=>matches(linked.model,x,value.some));if(value.none)return !linked.rows.some(x=>matches(linked.model,x,value.none));if(value.every)return linked.rows.every(x=>matches(linked.model,x,value.every));
   return linked.rows.length>0&&matches(linked.model,linked.rows[0],value.is??value);
  });
 }
 function projected(model,row,args={}){
  if(!row)return null;const result=args.select?{}:clone(row);
  for(const [key,selection]of Object.entries({...args.include,...args.select}))if(selection){
   if(Object.hasOwn(row,key))result[key]=clone(row[key]);else{const linked=relation(model,row,key),spec=selection===true?{}:selection,rows=linked.rows.filter(x=>matches(linked.model,x,spec.where));result[key]=linked.many?rows.map(x=>projected(linked.model,x,spec)):projected(linked.model,rows[0],spec)}
  }
  for(const [key,omit]of Object.entries(args.omit??{}))if(omit)delete result[key];return result;
 }
 function unique(model,row,ignore){for(const fields of definitions[model].unique){if(fields.some(k=>row[k]==null))continue;if(state[model].some(old=>old!==ignore&&fields.every(k=>same(old[k],row[k]))))throw Error('Unique constraint failed: '+model+'.'+fields.join(','))}}
 function checkFault(model,op,args){observed.push({model,operation:op,args:clone(args),actor:loader?.load('lib/plugins/actor.ts').currentActorFrame()?.actor});const fault=faults[model+'.'+op]??faults[model]??faults['*'];if(fault){if(typeof fault==='function')fault(args);else throw Error(String(fault))}}
 function rows(model,args={}){
  let found=state[model].filter(x=>matches(model,x,args.where));const order=Array.isArray(args.orderBy)?args.orderBy:args.orderBy?[args.orderBy]:[];
  if(order.length)found.sort((a,b)=>{for(const terms of order)for(const [key,dir]of Object.entries(terms)){const x=a[key],y=b[key];let c;if(x==null||y==null)c=x==null&&y==null?0:x==null?1:-1;else c=Prisma.Decimal.isDecimal(x)?x.comparedTo(y):x<y?-1:x>y?1:0;if(c)return dir==='desc'?-c:c}return 0});
  const take=args.take??found.length,skip=args.skip??0;if(take<0)return found.slice(0,Math.max(0,found.length-skip)).slice(take);return found.slice(skip,skip+take);
 }
 const prisma={};let loader;
 for(const model of Object.keys(definitions)){
  const delegate={
   async findUnique(args){checkFault(model,'findUnique',args);return projected(model,state[model].find(x=>matches(model,x,args.where)),args)},
   async findFirst(args={}){checkFault(model,'findFirst',args);return projected(model,rows(model,{...args,take:1})[0],args)},
   async findMany(args={}){checkFault(model,'findMany',args);return rows(model,args).map(x=>projected(model,x,args))},
   async count(args={}){checkFault(model,'count',args);return state[model].filter(x=>matches(model,x,args.where)).length},
   async groupBy(args){const result=new Map();for(const row of state[model].filter(x=>matches(model,x,args.where))){const item=Object.fromEntries(args.by.map(k=>[k,row[k]]));result.set(JSON.stringify(item),item)}return [...result.values()]},
   async create(args){checkFault(model,'create',args);const row=normalized(model,args.data);unique(model,row);state[model].push(row);
    for(const field of ['lines','rules'])if(args.data[field]?.create){const linked=field==='lines'?['crm_OrderLines','orderId']:['crm_PriceListRules','priceListId'];for(const child of [args.data[field].create].flat())await prisma[linked[0]].create({data:{...child,[linked[1]]:row.id}})}
    return projected(model,row,args)},
   async createMany(args){checkFault(model,'createMany',args);let count=0;for(const data of [args.data].flat()){try{await delegate.create({data});count++}catch(e){if(!args.skipDuplicates)throw e}}return {count}},
   async update(args){checkFault(model,'update',args);const old=state[model].find(x=>matches(model,x,args.where));if(!old)throw Error('Record to update not found');const row=normalized(model,args.data,old);unique(model,row,old);Object.assign(old,row);return projected(model,old,args)},
   async updateMany(args){checkFault(model,'updateMany',args);const found=state[model].filter(x=>matches(model,x,args.where));for(const row of found){const next=normalized(model,args.data,row);unique(model,next,row);Object.assign(row,next)}return {count:found.length}},
   async upsert(args){const old=state[model].find(x=>matches(model,x,args.where));return old?delegate.update({...args,data:args.update}):delegate.create({...args,data:args.create})},
   async delete(args){checkFault(model,'delete',args);const index=state[model].findIndex(x=>matches(model,x,args.where));if(index<0)throw Error('Record to delete not found');return projected(model,state[model].splice(index,1)[0],args)},
   async deleteMany(args={}){checkFault(model,'deleteMany',args);let count=0;for(let i=state[model].length-1;i>=0;i--)if(matches(model,state[model][i],args.where)){state[model].splice(i,1);count++}return {count}},
  };
  prisma[model]=delegate;prisma[model[0].toLowerCase()+model.slice(1)]=delegate;
 }
 prisma.$transaction=async fn=>{const before=clone(state);try{return typeof fn==='function'?await fn(prisma):await Promise.all(fn)}catch(e){for(const key of Object.keys(state))state[key]=before[key];throw e}};
 prisma.$queryRaw=async(query,...values)=>{
  const text=Array.isArray(query)?query.join('?'):query.sql??query.text??String(query);if(!Array.isArray(query))values=query.values??values;
  if(text.includes('UPDATE "NumberSeries"')){const year=values[0],scope=values[values.length-1],row=rows('NumberSeries',{where:{scope,isDefault:true,active:true},orderBy:{createdAt:'asc'},take:1})[0];if(!row)return [];row.counter=row.resetPolicy==='YEARLY'&&row.currentYear!==year?1:row.counter+1;if(row.counter>2147483647)throw Error('integer overflow');row.currentYear=year;row.updatedAt=clock();return [clone(row)]}
  if(text.includes('INSERT INTO "PluginData"')){const [pluginId,entityType,entityId,key,ms]=values;const existing=state.PluginData.find(x=>x.pluginId===pluginId&&x.entityType===entityType&&x.entityId===entityId&&x.key===key);if(existing?.value?.until!=null){const date=new Date(existing.value.until);if(!Number.isFinite(+date))throw Error('invalid input syntax for type timestamp');if(date>clock())return []}const value={until:new Date(+clock()+Math.round(ms)).toISOString()};await prisma.PluginData.upsert({where:{pluginId_entityType_entityId_key:{pluginId,entityType,entityId,key}},create:{pluginId,entityType,entityId,key,value},update:{value}});return [{key}]}
  if(text.includes('pg_try_advisory_xact_lock'))return [{locked:true}];throw Error('Unsupported raw SQL in source adapter: '+text.slice(0,100));
 };
 const forbidden=()=>{throw Error('Unexpected external boundary in source oracle')};
 const mocks={
  '@/lib/prisma':{prismadb:prisma},'@/lib/prisma-base':{prismaBase:prisma},
  '@/inngest/client':{inngest:{send:async message=>{if(faults.events)throw Error(String(faults.events));events.push(clone(message));return {ids:['synthetic-event']}}}},
  '@/lib/authz/session':{requireAuthenticated:forbidden},'@/lib/plugins/log':{writePluginLog:(pluginId,level,message,context)=>logs.push({pluginId,level,message,context})},
  'lib/orders/service.ts':{loadOrder:forbidden,priceLine:forbidden,saveDraft:forbidden},'lib/orders/notify.ts':{notifyApprovers:forbidden,notifyCreator:forbidden},
  ...options.mocks,
 };
 loader=createSourceLoader(mocks,{root});
 function seed(model,values){const row=normalized(model,values);unique(model,row);state[model].push(row);return clone(row)}
 function snapshot(models=Object.keys(state)){return JSON.parse(JSON.stringify(Object.fromEntries(models.map(model=>[model,clone(state[model])]))))}
 async function run(body){const previous=global.Date;global.Date=class extends OriginalDate {constructor(...args){super(...(args.length?args:[+clock()]))}static now(){return +clock()}static [Symbol.hasInstance](value){return value instanceof OriginalDate}};try{return await body()}finally{global.Date=previous}}
 return {prisma,base:prisma,state,definitions,events,logs,observed,faults,seed,snapshot,clone,matches,clock,run,load:loader.load,sourceHashes:loader.hashes,data:(pluginId,permissions)=>loader.load('lib/plugins/data-api.ts').createDataApi(pluginId,permissions),store:pluginId=>loader.load('lib/plugins/store.ts').createStore(pluginId)};
}
module.exports={createSourceDatabase};
