// Execute original Inngest handlers against an in-memory Prisma adapter. No
// provider, network, database or Inngest server is used.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),cache=new Map(),hashes={};let campaign,steps,sends,targets,events;
const base='2026-11-14T10:00:00.125Z'; let currentTime=base;
class FixedDate extends Date { constructor(...args){super(...(args.length?args:[currentTime]));} static now(){return new Date(currentTime).getTime();} }
function nested(s){return {...s,step:steps.find(p=>p.id===s.step_id),target:targets.find(t=>t.id===s.target_id)};}
function match(r,w){return r!=null&&Object.entries(w||{}).every(([k,v])=>{if(k==='OR')return v.some(x=>match(r,x));if(v&&typeof v==='object'){if('in'in v)return v.in.includes(r[k]);if('gt'in v)return r[k]>v.gt;if('not'in v)return r[k]!=null&&r[k]!==v.not;return match(r[k],v);}return (r[k]??null)===v;});}
const prisma={
 crm_campaigns:{findUnique:async()=>campaign,updateMany:async({where,data})=>{if(!match(campaign,where))return{count:0};Object.assign(campaign,data);return{count:1};}},
 crm_campaign_steps:{findFirst:async({where})=>steps.find(s=>match(s,where))??null,findUnique:async({where})=>steps.find(s=>match(s,where))??null,findMany:async({where})=>steps.filter(s=>match(s,where))},
 crm_TargetLists:{findMany:async({include})=>[{targets:targets.filter(t=>match({target:t},include.targets.where)).map(target=>({target}))},{targets:targets.filter(t=>match({target:t},include.targets.where)).slice(0,1).map(target=>({target}))}]},
 crm_campaign_sends:{createMany:async({data})=>{for(const d of data)if(!sends.some(s=>s.step_id===d.step_id&&s.target_id===d.target_id))sends.push({id:crypto.randomUUID(),status:'queued',opened_at:null,unsubscribed_at:null,...d});},findMany:async({where})=>sends.filter(s=>match(nested(s),where)),count:async({where})=>sends.filter(s=>match(nested(s),where)).length}
};
function load(relative){const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file);const source=fs.readFileSync(file,'utf8');hashes[relative]=crypto.createHash('sha256').update(source).digest('hex');const module={exports:{}};cache.set(file,module.exports);
 const req=name=>{if(name==='@/lib/prisma')return{prismadb:prisma};if(name==='@/inngest/client')return{inngest:{createFunction:(config,fn)=>fn}};if(name==='crypto')return crypto;if(name.startsWith('@/'))return load(name.slice(2)+'.ts');throw Error(name);};
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module,exports:module.exports,require:req,Date:FixedDate},{filename:file,timeout:2000});return module.exports;
}
function seed(status='sending'){
 currentTime=base;
 campaign={id:'campaign',status,deletedAt:null};steps=[{id:'first',campaign_id:'campaign',order:0,delay_days:0},{id:'followup',campaign_id:'campaign',order:1,delay_days:7,send_to:'all'}];
 targets=[{id:'a',email:'one@example.invalid',do_not_email:false},{id:'b',email:'one@example.invalid',do_not_email:false},{id:'c',email:'two@example.invalid',do_not_email:false},{id:'d',email:'stop@example.invalid',do_not_email:true},{id:'e',email:'',do_not_email:false}];sends=[];events=[];
}
const step={run:async(_,fn)=>fn(),sleepUntil:async()=>{},sendEvent:async(_,es)=>{events.push(...es);}};
(async()=>{
 const send=load('inngest/functions/campaigns/send-now.ts').campaignSendNow,schedule=load('inngest/functions/campaigns/schedule-send.ts').campaignScheduleSend,followup=load('inngest/functions/campaigns/process-follow-up.ts').campaignProcessFollowUp,mark=load('lib/campaigns/mark-campaign-sent.ts').markCampaignSentIfStep0Done;
 const dispatch=[];
 for(const mode of ['now','schedule'])for(const status of [mode==='now'?'sending':'scheduled','paused','deleted']){
  seed(status);const result=await(mode==='now'?send:schedule)({event:{data:{campaignId:'campaign',scheduledAt:base}},step});dispatch.push({mode,status,resultStatus:campaign.status,skipped:!!result.skipped,emails:sends.map(s=>s.email).sort(),followups:events.filter(e=>e.name==='campaigns/follow-up').map(e=>e.data.scheduledAt)});
 }
 seed();currentTime=new Date(new Date(base).getTime()+301000).toISOString();const late=await send({event:{data:{campaignId:'campaign'}},step});dispatch.push({mode:'now',status:'sending',delaySeconds:301,resultStatus:campaign.status,skipped:!!late.skipped,emails:sends.map(s=>s.email).sort(),followups:events.filter(e=>e.name==='campaigns/follow-up').map(e=>e.data.scheduledAt)});
 seed();targets=[];await send({event:{data:{campaignId:'campaign'}},step});const emptyStatus=campaign.status;
 const followups=[];for(const mode of ['all','non_openers'])for(const status of ['sent','delivered','failed','queued'])for(const suppressed of [false,true])for(const unsubscribed of [false,true]){
  seed('sent');steps[1].send_to=mode;targets[0].do_not_email=suppressed;sends=[{id:'initial-a',campaign_id:'campaign',step_id:'first',target_id:'a',email:targets[0].email,status,opened_at:null,unsubscribed_at:unsubscribed?base:null},{id:'initial-c',campaign_id:'campaign',step_id:'first',target_id:'c',email:targets[2].email,status,opened_at:base,unsubscribed_at:null}];
  await followup({event:{data:{campaignId:'campaign',stepId:'followup',scheduledAt:base}},step});followups.push({mode,status,suppressed,unsubscribed,emails:sends.filter(s=>s.step_id==='followup').map(s=>s.email).sort()});
 }
 const completion=[];for(const status of ['queued','sending','sent','delivered','failed','bounced'])for(const suppressed of [false,true])for(const unsubscribed of [false,true]){
  seed();targets[0].do_not_email=suppressed;sends=[{id:'one',campaign_id:'campaign',step_id:'first',target_id:'a',email:targets[0].email,status,unsubscribed_at:unsubscribed?base:null}];await mark('campaign');completion.push({status,suppressed,unsubscribed,resultStatus:campaign.status});
 }
 const out={base,dispatch,emptyStatus,followups,completion,sourceSHA256:hashes};fs.writeFileSync(path.join(__dirname,'build/campaign-dispatch-reference.json'),JSON.stringify(out,null,2)+'\n');console.log(JSON.stringify({suite:'actual original campaign dispatch/followup/completion handlers',dispatch:dispatch.length,empty:1,followups:followups.length,completion:completion.length}));
})().catch(e=>{console.error(e);process.exitCode=1;});
