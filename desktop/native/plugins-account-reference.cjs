const fs=require('node:fs'),path=require('node:path'),{load,hashes}=require('./plugins-core-reference.cjs');
const hooks=load('plugins/account-protection/hooks.ts'),jobs=load('plugins/account-protection/jobs.ts'),rules=load('plugins/account-protection/rules.ts'),orders=load('plugins/account-protection/orders.ts'),settings=load('plugins/account-protection/settings.ts');
const RealDate=Date,epoch='2026-01-01T12:34:56.789Z',uid=n=>`a0000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
let now=epoch;global.Date=class extends RealDate {constructor(...args){super(...(args.length?args:[now]))}static now(){return new RealDate(now).getTime()}};
const clone=x=>JSON.parse(JSON.stringify(x)),base=[
 {id:uid(1),name:'First',company_id:'123',billing_country:'CZ',assigned_to:uid(100),createdAt:'2025-01-01T00:00:00.000Z',deletedAt:null},
 {id:uid(2),name:'Duplicate',company_id:'00000123',billing_country:'Czech Republic',assigned_to:uid(101),createdAt:'2025-02-01T00:00:00.000Z',deletedAt:null},
 {id:uid(3),name:'Free',company_id:'456',billing_country:'US',assigned_to:null,createdAt:'2025-03-01T00:00:00.000Z',deletedAt:null},
 {id:uid(4),name:'No number',company_id:null,billing_country:null,assigned_to:uid(100),createdAt:'2025-04-01T00:00:00.000Z',deletedAt:null},
 {id:uid(5),name:'Deleted',company_id:'999',billing_country:'CZ',assigned_to:uid(100),createdAt:'2025-05-01T00:00:00.000Z',deletedAt:'2025-12-01T00:00:00.000Z'}];
function matches(row,where={}){return Object.entries(where).every(([k,v])=>v&&typeof v==='object'&&Array.isArray(v.in)?v.in.includes(row[k]):row[k]===v)}
function make(config){
 const accounts=clone(base),orderRows=clone(config.orders??[]),activityRows=clone(config.activities??[]),values=new Map(),notifications=[],logs=[];
 const store={async get(k){return clone(values.get(k)??null)},async set(k,v){values.set(k,clone(v))},async delete(k){values.delete(k)},async list(prefix=''){return [...values].filter(([k])=>k.startsWith(prefix)).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([key,value])=>({key,value:clone(value)}))}};
 const actor=config.actor??{type:'user',userId:uid(102),role:'user'};
 const ctx={plugin:{id:'account-protection',version:'0.2.0'},actor,locale:config.locale??'en',settings:settings.settingsSchema.parse(config.settings??{}),secrets:{},store,data:{accounts:{async get(id){return clone(accounts.find(a=>a.id===id)??null)},async find({where={},skip=0,take=100,orderBy}={}){let rows=accounts.filter(a=>matches(a,where));if(orderBy)rows.sort((a,b)=>String(a.createdAt).localeCompare(String(b.createdAt)));return clone(rows.slice(skip,skip+take))},async update(id,patch){const a=accounts.find(a=>a.id===id);if(!a)throw Error('missing account');Object.assign(a,patch);return clone(a)}},orders:{async find(args){if(config.orderError)throw Error('orders unavailable');return clone(orderRows.filter(r=>matches(r,args.where)).sort((a,b)=>b.orderDate.localeCompare(a.orderDate)).slice(0,args.take))},async get(id){return clone(orderRows.find(r=>r.id===id)??null)}},activities:{async findForRecord(type,id,q){return clone(activityRows.filter(r=>r.accountId===id&&r.deletedAt==null&&q.types.includes(r.type)&&r.status===q.status&&new Date(r.date)>=q.since).sort((a,b)=>b.date.localeCompare(a.date)).slice(0,q.take))}},users:{async get(id){return {id,name:'User '+id,email:'qa@example.invalid'}}}},log:Object.fromEntries(['debug','info','warn','error'].map(level=>[level,(message,context)=>logs.push({level,message,...(context?{context}: {})})])),t:(key,params)=>key+(params?':'+JSON.stringify(params):''),notify:async input=>{if(config.notifyError)throw Error('notification unavailable');notifications.push(clone(input))}};
 return {accounts,orderRows,activityRows,values,notifications,logs,ctx};
}
const scenarios=[];
async function scenario(name,config,actions){now=epoch;const f=make(config),results=[];for(const action of actions){if(action.now)now=action.now;try{
 let result=null;
 if(action.kind==='install')await jobs.install(f.ctx,new Date());
 else if(action.kind==='createRule'||action.kind==='updateRule'){const input={entity:'account',operation:action.kind==='createRule'?'beforeCreate':'beforeUpdate',data:action.data,...(action.id?{recordId:action.id,existing:clone(f.accounts.find(a=>a.id===action.id))}:{})};result=await rules[action.kind==='createRule'?'beforeCreate':'beforeUpdate'](input,f.ctx)}
 else if(action.kind==='after'){const a=f.accounts.find(a=>a.id===action.id);if(a&&action.patch)Object.assign(a,action.patch);await hooks[{created:'onCreated',updated:'onUpdated',deleted:'onDeleted'}[action.operation]]({entity:'account',operation:action.operation,recordId:action.id,changed:action.changed??[],actor:action.actor},f.ctx,new Date())}
 else if(action.kind==='order'){const row=f.orderRows.find(r=>r.id===action.id);if(row)Object.assign(row,action.patch);await orders.onOrderChanged({entity:'order',operation:action.operation,recordId:action.id,changed:action.changed??[]},f.ctx)}
 else if(action.kind==='set'){await f.ctx.store.set(action.key,action.value)}
 else if(action.kind==='expire')await jobs.expire(f.ctx,new Date());
 else if(action.kind==='notices')await jobs.sendNotices(f.ctx,new Date());
 else if(action.kind==='resume')await jobs.resume(f.ctx,new Date());
 else if(action.kind==='upgrade')await jobs.upgrade(f.ctx,new Date());
 results.push({ok:true,value:result});
 }catch(e){results.push({ok:false,error:e.message})}}
 const stored=await f.ctx.store.list();const notices=stored.filter(x=>x.key.startsWith('notice:')).map(x=>x.value);const store=stored.filter(x=>!x.key.startsWith('notice:'));
 scenarios.push({name,config,actions,results,store,notices,accounts:f.accounts,notifications:f.notifications,logs:f.logs});}
(async()=>{
 const install={kind:'install'};
 await scenario('install duplicates and retry',{},[install,install]);
 for(const actor of [{type:'user',role:'user',userId:uid(102)},{type:'token',role:'user',userId:uid(100)},{type:'user',role:'manager',userId:uid(102)},{type:'plugin',pluginId:'another'},{type:'system'}])await scenario('rules '+actor.type+' '+(actor.role??''),{actor,settings:{requireNumber:true}},[install,{kind:'createRule',data:{}},{kind:'createRule',data:{company_id:'123'}},{kind:'createRule',data:{company_id:'456',billing_country:'US'}},{kind:'updateRule',id:uid(1),data:{assigned_to:uid(101)}},{kind:'updateRule',id:uid(1),data:{assigned_to:uid(100),company_id:'00000123'}},{kind:'updateRule',id:uid(4),data:{company_id:'123'}},{kind:'updateRule',id:uid(1),data:{company_id:null}}]);
 await scenario('owner edit retry restore',{},[install,{kind:'after',id:uid(1),operation:'updated',patch:{assigned_to:uid(101)},changed:['assigned_to'],actor:{type:'token',role:'manager',userId:uid(102)},now:'2026-01-03T00:00:00.000Z'},{kind:'after',id:uid(1),operation:'updated',changed:['assigned_to']},{kind:'after',id:uid(1),operation:'updated',patch:{company_id:'789'},changed:['company_id'],now:'2026-01-04T00:00:00.000Z'},{kind:'after',id:uid(1),operation:'deleted',patch:{deletedAt:now}},{kind:'after',id:uid(1),operation:'updated',patch:{deletedAt:null},changed:['deletedAt'],now:'2026-01-05T00:00:00.000Z'}]);
 await scenario('delete holder handover',{},[install,{kind:'after',id:uid(1),operation:'deleted',patch:{deletedAt:'2026-01-05T00:00:00.000Z'},now:'2026-01-05T00:00:00.000Z'},{kind:'after',id:uid(1),operation:'deleted'}]);
 const expired='2026-02-02T12:34:56.789Z';
 for(const activity of [null,{id:uid(300),accountId:uid(1),date:'2026-01-01T01:00:00.000Z',type:'visit',status:'completed',deletedAt:null},{id:uid(300),accountId:uid(1),date:'2026-01-01T01:00:00.000Z',type:'call',status:'completed',deletedAt:null}])await scenario('expire contact '+(activity?.type??'none'),{activities:activity?[activity]:[]},[install,{kind:'set',key:'meta:lastRun',value:{at:expired}},{kind:'expire',now:expired}]);
 for(const months of [0,1,12]){const order={id:uid(200),accountId:uid(1),status:'CONFIRMED',orderDate:'2025-12-31T00:00:00.000Z'};await scenario('orders '+months,{orders:[order],settings:{orderMonths:months}},[install,{kind:'order',id:order.id,operation:'updated',patch:{status:'CANCELLED'},changed:['status']},{kind:'order',id:order.id,operation:'updated',patch:{status:'PAID',orderDate:'2026-05-31T00:00:00.000Z'},changed:['status','orderDate']},{kind:'upgrade'}]);}
 await scenario('order unavailable conservative',{orderError:true},[install,{kind:'upgrade'},{kind:'set',key:'meta:lastRun',value:{at:expired}},{kind:'expire',now:expired}]);
 await scenario('disabled pause renew',{},[install,{kind:'after',id:uid(3),operation:'updated',patch:{assigned_to:uid(101)},changed:[]},{kind:'resume',now:'2026-03-01T00:00:00.000Z'},{kind:'resume',now:'2026-03-01T00:30:00.000Z'}]);
 for(const notifyError of [false,true])await scenario('notice retry '+notifyError,{notifyError},[install,{kind:'createRule',data:{company_id:'123'}},{kind:'notices'},{kind:'notices',now:'2026-01-02T12:34:56.789Z'},{kind:'notices',now:'2026-01-02T12:34:56.790Z'}]);
 await scenario('upgrade missing metadata and stale conflict',{},[install,{kind:'set',key:'meta:lastRun',value:null},{kind:'after',id:uid(2),operation:'updated',patch:{company_id:'555'},changed:[]},{kind:'upgrade'}]);
 const out={epoch,base,scenarios,sourceHashes:hashes};fs.writeFileSync(path.join(__dirname,'build/plugins-account-reference.json'),JSON.stringify(out));console.log(JSON.stringify({scenarios:scenarios.length,actions:scenarios.reduce((n,s)=>n+s.actions.length,0),sourceFiles:Object.keys(hashes).length}));
})().catch(e=>{console.error(e);process.exit(1)}).finally(()=>global.Date=RealDate);
