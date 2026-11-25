// Execute the actual report actions, scopes and currency code. No server/network.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require('typescript'), crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..'), hashes = {}, cache = new Map(), data = {};
const schema = JSON.parse(fs.readFileSync(path.join(__dirname, 'schema.json')));
const now = '2026-11-19T12:00:00.000Z', from = '2026-09-01T00:00:00.125Z', to = '2026-11-01T00:00:00.125Z';
const id = n => `71000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
let seq = 1000, active;
const users = ['admin', 'manager', 'alice', 'bob', 'partner'].map((name, i) => ({id:id(i+1), name, role:i===2||i===3?'user':name, email:`${name}@example.invalid`, userStatus:'ACTIVE', created_on:i<2?'2024-01-01T00:00:00.000Z':from}));
function add(model, row) { const result = {id:id(seq++), ...row}; (data[model]??=[]).push(result); return result; }
users.forEach(u => add('Users', u));
add('Users', {name:'停止中',email:'inactive@example.invalid',role:'user',userStatus:'INACTIVE',created_on:to});
add('Users', {name:'禁止中',email:'banned@example.invalid',role:'user',userStatus:'ACTIVE',banned:true,created_on:'2026-08-31T23:59:59.999Z'});
const a = users[2].id, b = users[3].id, partner = users[4].id;
const stage = add('crm_Opportunities_Sales_Stages',{name:'提案済み'}), industry = add('crm_Industry_Type',{name:'情報通信'}), source = add('crm_Lead_Sources',{name:'紹介'});
const dates = [from,'2026-09-30T15:00:00.000Z',to,'2026-08-31T23:59:59.999Z','2026-07-05T12:00:00.000Z',null,'2026-11-01T00:00:00.126Z'];
const accounts = [];
for(let i=0;i<16;i++) accounts.push(add('crm_Accounts',{name:`取引先${i}`,createdAt:dates[i%dates.length]??from,createdBy:i%2?a:b,assigned_to:i%3?null:a,industry:i%3?industry.id:null,annual_revenue:['9','100','20','1000','  +301円','invalid',null,'999999','12.8','0','-1',' 42','700','600','800','10'][i],employees:['10','11','50','51','200','201','500','501','不明',null,'0','-5','　+20人','1e2','+','-1'][i],deletedAt:i===14?to:null,partnerUserId:i===2||i===3||i===14?partner:null}));
users[4].partnerAccountId=accounts[3].id; data.Users.find(x=>x.id===partner).partnerAccountId=accounts[3].id;
add('AccountWatchers',{account_id:accounts[0].id,user_id:a});
for(let i=0;i<24;i++) {
 const owner=i%2?a:b, date=dates[i%dates.length], account=accounts[i%accounts.length].id;
 add('crm_Opportunities',{name:`商談${i}`,created_on:date,createdBy:owner,assigned_to:i%4?null:a,account,budget:['1.01','100.11','1200','-2.55','999999.99','0'][i%6],currency:['USD','JPY','EUR','GBP',null,null][i%6],status:['CLOSED','ACTIVE','INACTIVE',null][i%4],sales_stage:i%3?stage.id:null,close_date:i%3?to:null,deletedAt:i===8?to:null});
 add('crm_Leads',{lastName:`リード${i}`,createdAt:date,createdBy:owner,assigned_to:i%4?null:a,accountsIDs:account,lead_source_id:i%3?source.id:null,deletedAt:i===8?to:null});
 add('crm_Contacts',{last_name:`連絡先${i}`,created_on:date,createdBy:owner,assigned_to:i%4?null:a,accountsIDs:i%5?account:null,deletedAt:i===8?to:null});
 add('crm_Contracts',{title:`契約${i}`,endDate:date,createdBy:owner,assigned_to:i%4?null:a,account,deletedAt:i===8?to:null});
}
for(const [f,t,r] of [['USD','JPY','150.125'],['EUR','JPY','160.5'],['JPY','USD','0.00666']]) add('ExchangeRate',{fromCurrency:f,toCurrency:t,rate:r,source:'MANUAL',effectiveDate:from});
const boards = [false,true].map(deleted=>add('Boards',{title:'プロジェクト',description:'',user:a,deletedAt:deleted?to:null}));
const sections = boards.map(board=>add('Sections',{board:board.id,title:'作業中'}));
for(let i=0;i<18;i++) {
 add('Tasks',{title:`タスク${i}`,createdAt:dates[i%dates.length],dueDateAt:i%4===0?'2026-11-10T00:00:00.000Z':dates[i%dates.length],taskStatus:i%3?'ACTIVE':'COMPLETE',user:i%5===0?null:i%2?a:b,section:i%3===0?null:sections[i%2].id,position:i});
 add('crm_Activities',{title:`活動${i}`,type:['call','meeting','note','email','visit'][i%5],date:from,createdAt:dates[i%dates.length]??from,createdBy:i%2?a:b,deletedAt:i===8?to:null});
}
const templates = [0,1].map(i=>add('crm_campaign_templates',{name:`テンプレート${i}`,subject_default:'件名',content_html:'<p>本文</p>',created_by:a}));
const targets = [false,true].map(deleted=>add('crm_Targets',{last_name:'営業対象',email:'target@example.invalid',deletedAt:deleted?to:null,created_by:a}));
for(let i=0;i<14;i++) {
 const c=add('crm_campaigns',{name:`配信${i}`,created_on:dates[i%dates.length],created_by:i%2?a:b,status:[null,'sent','sending','draft','deleted','paused','sent'][i%7],deletedAt:i===8?to:null,template_id:i%4?templates[i%2].id:null});
 const step=add('crm_campaign_steps',{campaign_id:c.id,order:0,template_id:templates[0].id,subject:'件名'});
 for(let j=0;j<(i%5)+1;j++) {
  const target=add('crm_Targets',{last_name:`宛先${i}-${j}`,email:`target-${i}-${j}@example.invalid`,created_by:a});
  add('crm_campaign_sends',{campaign_id:c.id,step_id:step.id,target_id:target.id,email:target.email,unsubscribe_token:`token-${i}-${j}`,status:['sent','delivered','failed','queued'][j%4],sent_at:dates[(i+j)%dates.length],opened_at:j%2?from:null,clicked_at:j%3?to:null});
 }
 const list=add('crm_TargetLists',{name:`対象リスト${i}`,created_on:dates[i%dates.length],created_by:i%2?a:b,deletedAt:i===8?to:null});
 for(const target of targets) add('TargetsToTargetLists',{target_list_id:list.id,target_id:target.id});
}
// Only actual model fields are persisted; relation-only synthetic IDs are removed.
for(const [model,rows] of Object.entries(data)) {
 const m=schema.models.find(m=>m.name===model);
 for(const row of rows) {
  if(m.fields.some(f=>f.name==='v'))row.v??=0;
  if(model==='crm_Contracts')row.value='0';
  if(model==='Tasks')row.priority='normal';
  if(model==='crm_campaign_templates')row.content_json='{"type":"doc"}';
  for(const key of Object.keys(row)) if(!m.fields.some(f=>f.name===key)) delete row[key];
 }
}
const dateFields = Object.fromEntries(schema.models.map(m=>[m.name,new Set(m.fields.filter(f=>f.type==='DateTime').map(f=>f.name))]));
const records = Object.fromEntries(Object.entries(data).map(([m,rows])=>[m,rows.map(r=>Object.fromEntries(Object.entries(r).map(([k,v])=>[k,v!==null&&dateFields[m].has(k)?new Date(v):v])))]));
const lookup=(model,key)=>records[model]?.find(r=>r.id===key)??null;
function related(model,row,key) {
 const spec={crm_Opportunities:{assigned_sales_stage:['crm_Opportunities_Sales_Stages','sales_stage'],assigned_account:['crm_Accounts','account']},crm_Leads:{lead_source:['crm_Lead_Sources','lead_source_id'],assigned_accounts:['crm_Accounts','accountsIDs']},crm_Contacts:{assigned_accounts:['crm_Accounts','accountsIDs']},crm_Contracts:{assigned_account:['crm_Accounts','account']},crm_Accounts:{industry_type:['crm_Industry_Type','industry']},Tasks:{assigned_user:['Users','user'],assigned_section:['Sections','section']},Sections:{board_relation:['Boards','board']},crm_campaigns:{template:['crm_campaign_templates','template_id']},crm_campaign_sends:{campaign:['crm_campaigns','campaign_id']},TargetsToTargetLists:{target:['crm_Targets','target_id']}}[model]?.[key];
 if(spec) return [spec[0],lookup(spec[0],row[spec[1]])];
 const many={crm_Accounts:{watchers:['AccountWatchers','account_id'],partner_own_users:['Users','partnerAccountId']},crm_campaigns:{sends:['crm_campaign_sends','campaign_id']},crm_TargetLists:{targets:['TargetsToTargetLists','target_list_id']}}[model]?.[key];
 if(many) return [many[0],(records[many[0]]??[]).filter(r=>r[many[1]]===row.id)];
 return null;
}
function matches(model,row,where={}) {
 if(!row) return false;
 return Object.entries(where).every(([key,want])=>{
  if(key==='AND') return (Array.isArray(want)?want:[want]).every(w=>matches(model,row,w));
  if(key==='OR') return want.some(w=>matches(model,row,w));
  if(key==='NOT') return (Array.isArray(want)?want:[want]).every(w=>!matches(model,row,w));
  const rel=related(model,row,key);
  if(rel) return Array.isArray(rel[1]) ? ('some' in want?rel[1].some(r=>matches(rel[0],r,want.some)):(()=>{throw Error('unsupported relation '+key)})()) : matches(rel[0],rel[1],want);
  const value=row[key]??null;
  if(want===null||typeof want!=='object'||want instanceof Date) return value===want;
  return Object.entries(want).every(([op,v])=>{
   if(op==='in') return v.includes(value); if(op==='equals') return value===v;
   if(op==='not') return v===null?value!==null:value!==null&&value!==v;
   if(value===null) return false;
   if(op==='gte') return value>=v;if(op==='lte')return value<=v;if(op==='lt')return value<v;if(op==='gt')return value>v;
   throw Error('unsupported predicate '+op);
  });
 });
}
function select(model,row,fields) {
 if(!fields)return row;const out={};
 for(const [key,spec] of Object.entries(fields)) {
  if(key==='_count') {out[key]={};for(const [relation,condition] of Object.entries(spec.select)){const [m,rows]=related(model,row,relation);out[key][relation]=rows.filter(r=>matches(m,r,condition===true?{}:condition.where)).length;}continue;}
  const rel=related(model,row,key);out[key]=rel?(rel[1]?select(rel[0],rel[1],spec.select):null):(row[key]??null);
 }
 return out;
}
const aliases={users:'Users',tasks:'Tasks',exchangeRate:'ExchangeRate'};
const prisma=new Proxy({}, {get:(_,name)=>{
 const model=aliases[name]??name;
 return {findMany:async(options={})=>{
  let rows=(records[model]??[]).filter(r=>matches(model,r,options.where));
  if(options.orderBy) {const [key,order]=Object.entries(options.orderBy)[0], desc=order==='desc'||order?._count==='desc';const value=r=>typeof order==='object'?related(model,r,key)[1].length:r[key];rows.sort((a,b)=>(value(a)<value(b)?-1:value(a)>value(b)?1:0)*(desc?-1:1));}
  if(options.take!==undefined)rows=rows.slice(0,options.take);return rows.map(r=>select(model,r,options.select));
 },count:async({where}={})=>(records[model]??[]).filter(r=>matches(model,r,where)).length};
}});
class FixedDate extends Date { constructor(...args){super(...(args.length?args:[now]));} static now(){return new Date(now).getTime();} }
function load(relative) {
 const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file);
 const source=fs.readFileSync(file,'utf8');hashes[relative]=crypto.createHash('sha256').update(source).digest('hex');const module={exports:{}};cache.set(file,module.exports);
 const requireStub=name=>{
  if(name==='@/lib/prisma')return{prismadb:prisma};
  if(name==='@prisma/client/runtime/client')return require(name);
  if(name==='@/lib/authz')return{...load('lib/authz/errors.ts'),requireRole:async roles=>{if(!active||!roles.includes(active.role))throw new (load('lib/authz/errors.ts').AuthorizationError)();return active;}};
  if(name.startsWith('@/'))return load(name.slice(2)+'.ts');
  if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),name+'.ts')));
  throw Error('unexpected import '+name);
 };
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module,exports:module.exports,require:requireStub,Date:FixedDate,URLSearchParams,console},{filename:file,timeout:2000});return module.exports;
}
async function main() {
 const scope=load('lib/authz/scopes/report-scope.ts'), modules=Object.fromEntries(['sales','leads','accounts','activity','campaigns','users','dashboard'].map(n=>[n,load(`actions/reports/${n}.ts`)])), cases=[];
 const groups={sales:{oppsByStage:'getOppsByStage',oppsByMonth:'getOppsByMonth'},leads:{newLeads:'getNewLeads',leadSources:'getLeadSources',newContacts:'getNewContacts',contactsByAccount:'getContactsByAccount'},accounts:{newAccounts:'getNewAccounts',byIndustry:'getAccountsByIndustry',topByRevenue:'getTopAccountsByRevenue',bySize:'getAccountsBySize'},activity:{tasksCreatedCompleted:'getTasksCreatedCompleted',tasksByAssignee:'getTasksByAssignee',activitiesByType:'getActivitiesByType'},campaigns:{campaignROI:'getCampaignROI',topTemplates:'getTopTemplates',targetGrowth:'getTargetListGrowth'},users:{activeByYear:'getActiveUsersByYear',userGrowth:'getUserGrowth',usersByRole:'getUsersByRole'}};
 for(const user of users) for(const range of [[from,to],['2020-01-01T00:00:00.000Z','2020-02-01T00:00:00.000Z']]) for(const currency of ['JPY','USD']) {
  active=user;const filters={dateFrom:new Date(range[0]),dateTo:new Date(range[1])},s=scope.getReportScope(user);
  for(const category of [...Object.keys(groups),'overview']) {
   if(category==='users'&&!s.allowUserDirectory){let denied=false;try{await modules.users.getUserGrowth(filters);}catch{denied=true;}if(!denied)throw Error('users scope');continue;}
   const m=modules[category==='overview'?'dashboard':category],metrics={},series={},corrections={};let comparisons=[];
   for(const [key,fn] of Object.entries(groups[category]??{})) series[key]=await m[fn](filters,s);
   if(category==='sales') Object.assign(metrics,{revenue:await m.getRevenue(filters,currency,s),pipeline:await m.getPipelineValue(filters,currency,s),avgDeal:await m.getAvgDealSize(filters,currency,s),winRate:(await m.getWinLossRate(filters,s)).rate,cycleLength:await m.getSalesCycleLength(filters,s)});
   if(category==='leads'){const v=await m.getConversionRate(filters,s);Object.assign(metrics,{conversionRate:v.rate,converted:v.converted,leadCount:v.leads});}
   if(category==='activity')metrics.overdueTasks=await m.getOverdueTasks(filters,s);
   if(category==='campaigns'){Object.assign(metrics,await m.getCampaignPerformance(filters,s));series.performance=['sent','opened','clicked'].map(k=>({name:k[0].toUpperCase()+k.slice(1),Number:metrics[k]}));}
   if(category==='users')metrics.totalActive=await m.getActiveUsersLifetime();
   if(category==='overview')comparisons=await m.getDashboardKPIs(filters,currency,s);
   if(category==='accounts') {
    const rows=records.crm_Accounts.filter(r=>matches('crm_Accounts',r,{createdAt:{gte:filters.dateFrom,lte:filters.dateTo},deletedAt:null,...s.account}));
    corrections.topByRevenue=rows.filter(r=>r.annual_revenue!=null&&Number.isFinite(parseInt(r.annual_revenue,10))).sort((a,b)=>parseInt(b.annual_revenue,10)-parseInt(a.annual_revenue,10)||a.id.localeCompare(b.id)).slice(0,10).map(r=>({name:r.name,Number:parseInt(r.annual_revenue,10)}));
    const sizes={};for(const r of rows){const n=parseInt(r.employees??'',10),key=n>=1&&n<=10?'1-10':n<=50&&n>=11?'11-50':n<=200&&n>=51?'51-200':n<=500&&n>=201?'201-500':n>=501?'500+':'Unknown';sizes[key]=(sizes[key]??0)+1;}corrections.bySize=Object.entries(sizes).map(([name,Number])=>({name,Number}));
   }
   cases.push({user:user.id,category,from:range[0],to:range[1],currency,metrics,series,comparisons,corrections});
  }
 }
 // Hand-derived fixture anchors also check that the in-memory Prisma adapter is
 // exercising null handling, foreign scopes and local month boundaries.
 const adminCase=cases.find(c=>c.user===users[0].id&&c.category==='campaigns'&&c.from===from&&c.currency==='JPY');
 if(!adminCase.series.campaignROI.length||!adminCase.metrics.sent)throw Error('campaign fixtures ineffective');
 const numericCases=['9','100',' +301円','invalid','　-12.8','1e2','0x10','+','--1','\uFEFF42','\u008512','999999999999999999999999999999999999999'];
 const output={now,timeZone:process.env.TZ,users,data,cases,numericCases:numericCases.map(value=>({value,expected:Number.isFinite(parseInt(value,10))?parseInt(value,10):null})),hashes,corrections:['Numeric annual revenue ranking; omit nonnumeric values','Unknown employee bucket includes absent/invalid/nonpositive values','Overview user-directory metric hidden from ordinary users and partners']};
 fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,`build/reports-reference-${process.env.TZ==='UTC'?'UTC':'Tokyo'}.json`),JSON.stringify(output));
 console.log(JSON.stringify({suite:'actual TypeScript report metrics/scopes/currency',timeZone:process.env.TZ,cases:cases.length,sourceFiles:Object.keys(hashes).length,rows:Object.values(data).reduce((n,r)=>n+r.length,0)}));
}
main().catch(e=>{console.error(e);process.exit(1)});
