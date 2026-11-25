const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
if(!process.argv[3])throw Error('native source directory is required');
const n=path.resolve(process.argv[3]),root=path.resolve(n,'../..');
const {createSourceDatabase}=require(path.join(n,'plugins-source-database.cjs'));
const uid=n=>`e1000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const epoch='2026-03-02T06:30:00.123Z',dt=(days,ms=0)=>new Date(+new Date(epoch)+days*86400000+ms).toISOString();
const models=['Users','crm_Accounts','crm_Contacts','crm_Opportunities_Sales_Stages','crm_Opportunities','EmailAccount','Email','EmailsToContacts','EmailsToAccounts','crm_Activities','crm_ActivityLinks','crm_campaign_templates','crm_campaigns','crm_campaign_steps','crm_Targets','crm_TargetLists','TargetsToTargetLists','crm_campaign_sends','crm_FunnelSettings','crm_AuditLog'];
let sourceSHA256={},registrations={};
function extensions(d){
 const p=d.prisma;
 const opp=p.crm_Opportunities.findMany;
 p.crm_Opportunities.findMany=async a=>{const {assigned_sales_stage,...where}=a.where??{};if(assigned_sales_stage)where.sales_stage={in:d.state.crm_Opportunities_Sales_Stages.filter(x=>x.stage_kind===assigned_sales_stage.stage_kind).map(x=>x.id)};return opp({...a,where})};
 const email=p.email.findFirst;
 p.email.findFirst=async a=>{const {OR,...where}=a.where??{};if(OR){const ids=new Set();for(const v of OR){const name=v.contacts?'EmailsToContacts':'EmailsToAccounts',field=v.contacts?'contactId':'accountId',scope=(v.contacts??v.accounts).some[field];for(const r of d.state[name])if(r[field]===scope)ids.add(r.emailId)}where.id={in:[...ids]}}return email({...a,where})};
 p.crm_campaign_steps.groupBy=async a=>{if(JSON.stringify(a.by)!=='["campaign_id"]'||a._max?.order!==true)throw Error('unexpected groupBy');const groups=new Map();for(const r of d.state.crm_campaign_steps)groups.set(r.campaign_id,Math.max(groups.get(r.campaign_id)??-Infinity,r.order));return [...groups].map(([campaign_id,order])=>({campaign_id,_max:{order}}))};
 const sends=p.crm_campaign_sends.findMany;
 p.crm_campaign_sends.findMany=async a=>{if(!a.select?.step)return sends(a);const rows=await sends({...a,select:undefined});return rows.map(row=>Object.fromEntries(Object.entries(a.select).map(([k,v])=>[k,k==='step'?{order:d.state.crm_campaign_steps.find(x=>x.id===row.step_id).order}:row[k]])))};
 const targets=p.crm_Targets.findMany;
 p.crm_Targets.findMany=async a=>{const {target_lists,...where}=a.where??{};if(target_lists){const name=target_lists.none.target_list.name,listIDs=new Set(d.state.crm_TargetLists.filter(x=>x.name===name).map(x=>x.id)),members=d.state.TargetsToTargetLists.filter(x=>listIDs.has(x.target_list_id)).map(x=>x.target_id);where.AND=[{id:{notIn:members}}]}return targets({...a,where})};
}
async function one(spec){
 let sent=[],logged=[],steps=[],selected=[];
 class FakeResend { constructor() { this.emails={send:async payload=>{sent.push(payload);if(spec.mailFailure)throw Error('fake unavailable');return{id:uid(999999)}}}; } }
 const d=createSourceDatabase({root,epoch,mocks:{
  '@/inngest/client':{inngest:{createFunction:(config,handler)=>{registrations[spec.kind]=config;return handler}}},
  resend:{Resend:FakeResend}
 }});extensions(d);
 d.seed('Users',{id:uid(1),name:'管理者',email:spec.adminEmail??'admin@example.invalid',role:spec.noAdmins?'user':'admin',userStatus:'ACTIVE',banned:!!spec.bannedAdmin});
 d.seed('Users',{id:uid(2),name:'担当者',email:spec.repNoEmail?'':'rep@example.invalid',role:'user',userStatus:spec.inactiveRep?'INACTIVE':'ACTIVE'});
 for(let i=0;i<(spec.admins??0);i++)d.seed('Users',{id:uid(5000+i),name:'管理者'+i,email:`admin${i}@example.invalid`,role:'admin',userStatus:'ACTIVE'});
 if(spec.days!==undefined)d.seed('crm_FunnelSettings',{id:uid(4),kill_after_days:spec.days,recycle_after_days:spec.days});
 if(spec.secondSettings)d.seed('crm_FunnelSettings',{id:uid(5),kill_after_days:365,recycle_after_days:365});
 d.seed('crm_Accounts',{id:uid(10),v:0,name:'会社'});d.seed('crm_Contacts',{id:uid(11),v:0,last_name:'顧客'});
 if(spec.kind==='kill'){
  d.seed('crm_Opportunities_Sales_Stages',{id:uid(20),name:'見積もり',stage_kind:spec.stage??'qualified'});
  for(let i=0;i<(spec.count??1);i++)d.seed('crm_Opportunities',{id:uid(100+i),name:spec.name===null?null:spec.name??'商談'+i,sales_stage:uid(20),account:spec.noScopes?null:uid(10),contact:spec.noScopes?null:uid(11),assigned_to:spec.unassigned?null:uid(2),updatedBy:uid(1),stage_entered_at:spec.nilStage?null:new Date(dt(spec.entered??-45,spec.stageMS??0)),status:spec.status??'ACTIVE',...(spec.deleted?{deletedAt:new Date(epoch)}:{})});
  if(spec.email!==undefined){d.seed('EmailAccount',{id:uid(30),userId:uid(2),label:'Mail',username:'rep@example.invalid',imapHost:'imap.example.invalid',imapPort:993,imapSsl:true,smtpHost:'smtp.example.invalid',smtpPort:587,smtpSsl:false,passwordEncrypted:'synthetic-unused'});d.seed('Email',{id:uid(31),emailAccountId:uid(30),userId:uid(2),rfcMessageId:'synthetic',folder:spec.folder??'INBOX',sentAt:spec.email===null?null:new Date(dt(spec.email)),isDeleted:!!spec.deletedEmail});d.seed(spec.accountEmail?'EmailsToAccounts':'EmailsToContacts',{emailId:uid(31),[spec.accountEmail?'accountId':'contactId']:spec.unlinkedEmail?uid(999):uid(spec.accountEmail?10:11)});}
  if(spec.activity!==undefined){d.seed('crm_Activities',{id:uid(40),type:'call',title:'記録',date:new Date(dt(spec.activity)),status:spec.activityStatus??'completed',...(spec.deletedActivity?{deletedAt:new Date(epoch)}:{})});d.seed('crm_ActivityLinks',{id:uid(41),activityId:uid(40),entityType:spec.otherEntity?'account':'opportunity',entityId:uid(100)});}
  if(spec.auditFailure)d.faults['crm_AuditLog.create']='synthetic audit failure';
 } else {
  d.seed('crm_campaign_templates',{id:uid(50),name:'Template',content_html:'<p>Template</p>',content_json:{}});
  for(let c=0;c<2;c++){
   d.seed('crm_campaigns',{id:uid(60+c),v:0,name:'Campaign'+c,...(spec.deletedCampaign?{deletedAt:new Date(epoch)}:{})});
   if(!spec.noSteps)for(let i=1;i<=2;i++)d.seed('crm_campaign_steps',{id:uid(70+c*2+i),campaign_id:uid(60+c),order:i,template_id:uid(50),subject:'Step'});
  }
  if(spec.existingList||spec.existingMember)d.seed('crm_TargetLists',{id:uid(80),name:spec.listName??'Recycled',status:spec.listInactive?false:true,...(spec.listDeleted?{deletedAt:new Date(epoch)}:{})});
  for(let i=0;i<(spec.count??1);i++){
   const id=uid(1000+i);d.seed('crm_Targets',{id,last_name:'対象'+i,do_not_email:!!spec.blocked,converted_at:spec.converted?new Date(epoch):null,...(spec.deleted?{deletedAt:new Date(epoch)}:{})});
   if(!spec.noSteps){d.seed('crm_campaign_sends',{id:uid(10000+i),campaign_id:uid(60),step_id:uid(spec.nonfinal?71:72),target_id:id,email:'target@example.invalid',status:spec.sendStatus??'sent',sent_at:spec.nilSent?null:new Date(dt(spec.sent??-90,spec.sentMS??0))});if(spec.extra)d.seed('crm_campaign_sends',{id:uid(20000+i),campaign_id:uid(61),step_id:uid(74),target_id:id,email:'target@example.invalid',status:spec.extra.status,sent_at:spec.extra.days===null?null:new Date(dt(spec.extra.days))});}
   if(spec.existingMember)d.seed('TargetsToTargetLists',{target_id:id,target_list_id:uid(80)});
  }
 }
 const initial=d.snapshot(models),module=d.load('inngest/functions/crm/'+(spec.kind==='kill'?'kill-rule':'recycle-targets')+'.ts');
 const oldURL=process.env.NEXT_PUBLIC_APP_URL,oldError=console.error;process.env.NEXT_PUBLIC_APP_URL='https://crm.example.invalid';console.error=(...v)=>logged.push(String(v[0]));let result,second;
 try{await d.run(async()=>{const step={run:async(name,body)=>{steps.push(name);const value=await body();if(name==='find-qualified-deals')selected=value.map(x=>x.id);return JSON.parse(JSON.stringify(value??null))}};const handler=spec.kind==='kill'?module.killRule:module.recycleTargets;result=await handler({step});if(spec.rerun)second=await handler({step})})}finally{console.error=oldError;if(oldURL===undefined)delete process.env.NEXT_PUBLIC_APP_URL;else process.env.NEXT_PUBLIC_APP_URL=oldURL}
 Object.assign(sourceSHA256,d.sourceHashes);
 return{...spec,initial,result,second,selected,steps,after:d.snapshot(models),sent,logged};
}
(async()=>{
 const kill=[{}, {entered:-44},{stageMS:1},{stageMS:-1},{nilStage:true},{nilStage:true,email:-45},{noScopes:true,email:-1},{email:-1},{accountEmail:true,email:-1},{email:-50},{email:null},{email:-1,deletedEmail:true},{email:-1,folder:'SENT'},{activity:-1},{activity:-1,activityStatus:'cancelled'},{activity:-1,deletedActivity:true},{activity:-1,otherEntity:true},{stage:'care'},{status:'CLOSED'},{deleted:true},{unassigned:true},{repNoEmail:true},{inactiveRep:true},{name:null},{name:''},{name:'日本語「éとé」'}, {days:1,entered:-1},{days:0,entered:0},{days:-1,entered:0},{days:1,secondSettings:true,entered:-2},{count:501},{rerun:true},{auditFailure:true},{mailFailure:true}].map((x,i)=>({kind:'kill',label:'kill-'+i,...x}));
 const recycle=[{}, {sent:-89},{sentMS:1},{sentMS:-1},{nonfinal:true},{sendStatus:'delivered'},{sendStatus:'failed'},{nilSent:true},{blocked:true},{converted:true},{deleted:true},{noSteps:true},{existingList:true},{existingList:true,listInactive:true},{existingList:true,listDeleted:true},{existingMember:true},{existingMember:true,listDeleted:true},{existingMember:true,listName:'recycled'},{extra:{status:'queued',days:null}},{extra:{status:'sending',days:-100}},{extra:{status:'failed',days:-1}},{extra:{status:'sent',days:-1}},{extra:{status:'sent',days:-100}},{noAdmins:true},{adminEmail:''},{bannedAdmin:true},{days:1,sent:-1},{days:0,sent:0},{days:-1,sent:0},{days:1,secondSettings:true,sent:-2},{count:205},{admins:205},{rerun:true},{mailFailure:true},{deletedCampaign:true}].map((x,i)=>({kind:'recycle',label:'recycle-'+i,...x}));
 const cases=[];for(const spec of [...kill,...recycle])cases.push(await one(spec));
 for(const f of ['prisma/schema.prisma','desktop/native/plugins-source-database.cjs','desktop/native/plugins-source-loader.cjs'])sourceSHA256[f]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,models,registrations,cases,sourceSHA256,limits:['Real handlers and helper modules; synthetic Prisma adapter/Resend only. No PostgreSQL, Inngest deployment or external send.','No-ORDER-BY source rows use fixture insertion order; native comparisons use the same selected ID set, not a guarantee of PostgreSQL planner order.']},null,2)+'\n');console.log(JSON.stringify({sourceCases:cases.length}));
})().catch(e=>{console.error(e.stack);process.exit(1)});
