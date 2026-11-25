// Execute original actions/scopes/recipient rules. Prisma and events stay in memory.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),hashes={},cache=new Map();let active,seq=0;const records={},events=[];
const uuid=n=>`30000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function matches(row,where){return row!=null&&Object.entries(where).every(([k,v])=>{
 if(k==='AND')return(Array.isArray(v)?v:[v]).every(x=>matches(row,x));if(k==='OR')return v.some(x=>matches(row,x));if(k==='NOT')return !matches(row,v);
 if(v&&typeof v==='object'&&!(v instanceof Date)){if('in'in v)return v.in.includes(row[k]);if('not'in v)return row[k]!=null&&row[k]!==v.not;return matches(row[k],v);}
 return(row[k]??null)===v;
});}
function model(name){return {
 findFirst:async({where})=>(records[name]??[]).find(r=>matches(r,where))??null,
 findUnique:async({where})=>(records[name]??[]).find(r=>matches(r,where))??null,
 findMany:async({where})=>(records[name]??[]).filter(r=>matches(r,where)),
 create:async({data})=>{const row={id:uuid(1000+(++seq)),deletedAt:null,...data};(records[name]??=[]).push(row);return row;},
 update:async({where,data})=>{const row=(records[name]??[]).find(r=>matches(r,where));if(!row)throw Error('missing '+name);if(data.steps?.updateMany){const u=data.steps.updateMany;for(const s of records.crm_campaign_steps??[])if(s.campaign_id===row.id&&matches(s,u.where))Object.assign(s,u.data);}const {steps,...rest}=data;Object.assign(row,rest);return row;},
 updateMany:async({where,data})=>{const found=(records[name]??[]).filter(r=>matches(r,where));found.forEach(r=>Object.assign(r,data));return{count:found.length};}
};}
const prisma=new Proxy({}, {get:(_,name)=>model(name)});
function load(relative){const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file);const source=fs.readFileSync(file,'utf8');hashes[relative]=crypto.createHash('sha256').update(source).digest('hex');const module={exports:{}};cache.set(file,module.exports);
const requireStub=name=>{
 if(name==='@/lib/prisma')return{prismadb:prisma};if(name==='zod')return require('zod');
 if(name==='@/inngest/client')return{inngest:{send:async e=>{events.push(e);return{id:'fake'};}}};
 if(name==='@/lib/authz')return{...load('lib/authz/scopes/crm.ts'),...load('lib/authz/errors.ts'),requireAuthenticated:async()=>{if(!active)throw new(load('lib/authz/errors.ts').AuthenticationError)();return active;},requireRole:async roles=>{if(!active)throw new(load('lib/authz/errors.ts').AuthenticationError)();if(!roles.includes(active.role))throw new(load('lib/authz/errors.ts').AuthorizationError)();return active;}};
 if(name.startsWith('@/'))return load(name.slice(2)+'.ts');
 if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),name+'.ts')));
 throw Error(name);
};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module,exports:module.exports,require:requireStub,console,Date,process:{env:{}}},{filename:file,timeout:2000});return module.exports;}
(async()=>{
 const users=['admin','manager','alice','bob','partner','unknown'].map((name,i)=>({name,id:uuid(i+1),role:['alice','bob'].includes(name)?'user':name}));const [admin,manager,alice,bob]=users;
 const templates=[{id:uuid(101),created_by:alice.id,deletedAt:null},{id:uuid(102),created_by:bob.id,deletedAt:null},{id:uuid(103),created_by:alice.id,deletedAt:'2026-01-01'}];records.crm_campaign_templates=templates;
 const lists=[{id:uuid(201),created_by:alice.id,deletedAt:null},{id:uuid(202),created_by:bob.id,deletedAt:null},{id:uuid(203),created_by:alice.id,deletedAt:'2026-01-01'}];records.crm_TargetLists=lists;
 const campaigns=[];for(const owner of [alice,bob])for(const status of [null,'draft','scheduled','sending','sent','paused','deleted'])for(const deleted of [false,true])campaigns.push({id:uuid(300+campaigns.length),created_by:owner.id,status,deletedAt:deleted?'2026-01-01':null});records.crm_campaigns=campaigns;
 const scopes=[],scope=load('lib/authz/scopes/crm.ts');for(const user of users)for(const row of campaigns){let read=true,write=true;try{await scope.assertCanReadCampaign(user,row.id)}catch{read=false}try{await scope.assertCanWriteCampaign(user,row.id)}catch{write=false}scopes.push({user:user.id,campaign:row.id,read,write});}
 const create=load('actions/campaigns/create-campaign.ts').createCampaign,created=[];active=admin;
 for(const stamp of [null,'2026-11-20T03:15:30.125Z','2026-03-07T21:00:00.000Z']){
  const input={name:'日本語キャンペーン😀',description:'説明\n二行',from_name:'営業部',reply_to:'sales@example.invalid',template_id:templates[0].id,target_list_ids:lists.slice(0,2).map(x=>x.id),steps:[0,1,3].map((order,i)=>({order,template_id:templates[i%2].id,subject:'件名'+order,delay_days:[0,3,7][i],send_to:i===2?'non_openers':'all'})),...(stamp?{scheduled_at:new Date(stamp)}:{})};
  const result=await create(input);if(result.error)throw Error(result.error);created.push({input,result});
 }
 const deniedCreates=[];active=alice;for(const patch of [{template_id:templates[1].id},{target_list_ids:[lists[1].id]},{target_list_ids:[lists[0].id,lists[0].id]},{steps:[{order:0,template_id:templates[1].id,subject:'不可',delay_days:0,send_to:'all'}]},{scheduled_at:new Date('2026-11-20T00:00:00Z'),steps:[]}]){const input={name:'拒否',target_list_ids:[],steps:[],...patch};const result=await create(input);if(!result.error)throw Error('denial');deniedCreates.push(input);}
 const schedule=load('actions/campaigns/schedule-campaign.ts').scheduleCampaign,pause=load('actions/campaigns/pause-campaign.ts').pauseCampaign,remove=load('actions/campaigns/delete-campaign.ts').deleteCampaign,send=load('actions/campaigns/send-campaign-now.ts').sendCampaignNow,update=load('actions/campaigns/update-campaign.ts').updateCampaign;
 const states=[];for(const user of [admin,alice])for(const status of ['draft','scheduled','sending','sent','paused'])for(const action of ['pause','delete','send']){const row={id:uuid(2000+(++seq)),status,deletedAt:null,created_by:alice.id};records.crm_campaigns.push(row);records.crm_campaign_steps=[{id:uuid(999),campaign_id:row.id,order:0}];active=user;const result=await({pause,delete:remove,send}[action])(row.id);states.push({role:user.role,status,action,allowed:!result?.error,resultStatus:row.status,scheduledAtSet:row.scheduled_at instanceof Date});}
 let actionChecks=0;active=admin;const row={id:uuid(4000),status:'draft',deletedAt:null,created_by:alice.id};records.crm_campaigns.push(row);records.crm_campaign_steps=[];if(!(await schedule(row.id,new Date())).error)throw Error('step0');actionChecks++;
 records.crm_campaign_steps=[{id:uuid(4001),campaign_id:row.id,order:0}];const when=new Date('2026-11-30T01:00:00Z');await schedule(row.id,when);if(row.status!=='scheduled'||records.crm_campaign_steps[0].scheduled_at!==when)throw Error('schedule');actionChecks++;
 for(const data of [{status:'sent'},{created_by:bob.id},{reply_to:'bad'},{name:''}]){if(!(await update(row.id,data)).error)throw Error('strict update');actionChecks++;}
 const filter=load('lib/campaigns/recipient-filters.ts'),recipientCases=[];for(const status of ['queued','sending','sent','delivered','bounced','failed'])for(const suppressed of [false,true])for(const opened of [false,true])for(const unsubscribed of [false,true])for(const sendTo of ['all','non_openers']){const send={step_id:'step0',status,opened_at:opened?'date':null,unsubscribed_at:unsubscribed?'date':null,target:{do_not_email:suppressed}};recipientCases.push({status,suppressed,opened,unsubscribed,sendTo,eligible:matches(send,filter.eligibleFollowUpSendsWhere('step0',sendTo)),skip:filter.sendStepSkipReason(send)});}
 const out={hashes,users,templates,lists,campaigns:campaigns.slice(0,28),scopes,created,deniedCreates,states,actionChecks,recipientCases};fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,'build/campaigns-reference.json'),JSON.stringify(out));console.log(JSON.stringify({suite:'original campaign actions/scopes/recipient rules',scopes:scopes.length,created:created.length,deniedCreates:deniedCreates.length,states:states.length,actionChecks,recipientCases:recipientCases.length}));
})().catch(e=>{console.error(e);process.exit(1)});
