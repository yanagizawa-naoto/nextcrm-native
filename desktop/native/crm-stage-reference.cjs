const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
if(!process.argv[3])throw Error('Native production source directory required');
const native=path.resolve(process.argv[3]),root=path.resolve(native,'../..');
const {createSourceDatabase}=require(path.join(native,'plugins-source-database.cjs'));
const uid=n=>`a0000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const epoch='2026-03-06T07:00:00.123Z',RealDate=Date,models=['Users','crm_Accounts','crm_Opportunities_Sales_Stages','crm_FunnelSettings','crm_Opportunities','crm_Accounts_Tasks'];
const taskFields=['v','title','content','priority','taskStatus','account','opportunity_id','user','createdBy','updatedBy','dueDateAt','likes','tags'];
const titles=['営業フォロー 1/5：見積もり受領の確認電話','営業フォロー 2/5：確認メール','営業フォロー 3/5：メールまたは電話','営業フォロー 4/5：状況確認の電話','営業フォロー 5/5：最終確認と見積もり期限の延長提案'];
const bodies=['取引先に電話し、見積書・作業範囲の資料が届いているか確認して、不明点を聞いてください。','提出中の見積もりについて、短い確認メールを送ってください。','メールまたは電話で懸念点を聞き、説明の機会を提案してください。','見積もりを提出してから約5週間です。電話で予定時期や進行上の課題を確認してください。','最終確認のメールを送り、必要であれば見積もりの有効期限を15日延長できることを案内してください。'];
function translated(kind,index,settings,name){
 if(kind==='qualified')return {title:titles[index],content:bodies[index]+'\n商談：'+name};
 if(index===0)return {title:`導入後フォロー：${settings.careCheckinDays}日後の確認`,content:'導入後の満足度、困りごと、これまでに得られた効果を取引先に確認してください。\n取引先・案件：'+name};
 if(index===1)return {title:'導入後フォロー：紹介の依頼',content:'導入の成果を確認し、紹介を依頼してください。追加提案の機会も確認してください。\n取引先・案件：'+name};
 return {title:`導入後フォロー：定期確認（第${index-1}回）`,content:'定期的な関係確認として、満足度、契約更新、利用拡大の機会を話し合ってください。\n取引先・案件：'+name};
}
let hashes={},registrations={};
async function run(spec){
 let time=+new RealDate(spec.entry??epoch),notices=[],createdNames={};
 const d=createSourceDatabase({root,clock:()=>new RealDate(time),mocks:{
  '@/inngest/client':{inngest:{createFunction:(config,handler)=>{registrations[config.id]=config;return handler}}},
  resend:{Resend:class {constructor(){this.emails={send:async body=>{notices.push(body);return {id:'synthetic'}}}}}},
 }});
 d.seed('Users',{id:uid(1),email:'owner@example.invalid',name:'担当者',role:'admin',userStatus:'ACTIVE'});
 d.seed('Users',{id:uid(2),email:'second@example.invalid',name:'担当者2',role:'admin',userStatus:'ACTIVE'});
 d.seed('crm_Accounts',{id:uid(3),v:0,name:'取引先',assigned_to:uid(1)});
 for(const [id,kind]of [[10,'qualified'],[11,'care'],[12,'pre_sale'],[13,'qualified']])d.seed('crm_Opportunities_Sales_Stages',{id:uid(id),name:kind,stage_kind:kind,order:id});
 if(spec.settings)d.seed('crm_FunnelSettings',{id:uid(20),...spec.settings});
 const kind=spec.kind??'qualified',stage=kind==='qualified'?uid(10):uid(11);
 d.seed('crm_Opportunities',{id:uid(30),name:spec.name??'更新システム・商談',account:spec.noAccount?null:uid(3),assigned_to:spec.unassigned?null:uid(1),sales_stage:spec.currentStage??stage,status:spec.status??'ACTIVE',...(spec.deleted?{deletedAt:new RealDate(time)}:{})});
 // Exact select of the real source handler, extending only the missing shared
 // synthetic Prisma relation projection; no handler/service is replaced.
 const find=d.prisma.crm_Opportunities.findUnique;
 d.prisma.crm_Opportunities.findUnique=async args=>{
  const row=await find({...args,select:undefined});if(!row)return null;
  if(!args.select)return row;
  return Object.fromEntries(Object.keys(args.select).map(k=>k==='assigned_sales_stage'?[k,d.state.crm_Opportunities_Sales_Stages.find(s=>s.id===row.sales_stage)??null]:[k,row[k]]));
 };
 const create=d.prisma.crm_Accounts_Tasks.create;
 d.prisma.crm_Accounts_Tasks.create=async args=>{const row=await create(args);createdNames[row.id]=d.state.crm_Opportunities.find(o=>o.id===uid(30))?.name??uid(30);return row};
 const timers=d.load('lib/crm/funnel-timers.ts'),settings=await d.load('lib/crm/funnel-settings.ts').getFunnelSettings();
 const scheduled=(kind==='qualified'?timers.cadenceSchedule(new RealDate(time),settings):timers.careSchedule(new RealDate(time),settings));
 if(spec.existing)d.seed('crm_Accounts_Tasks',{id:uid(40),v:0,title:scheduled[0].title,content:'既存の本文',priority:'low',taskStatus:spec.existing,account:uid(3),opportunity_id:uid(30),user:uid(1)});
 const seeds=d.snapshot(models),handler=d.load(kind==='qualified'?'inngest/functions/crm/qualified-cadence.ts':'inngest/functions/crm/care-tasks.ts')[kind==='qualified'?'qualifiedCadence':'careTasks'];
 let index=-1,sleeps=[],result,cancelled=false;
 const actions=spec.actions??[];
 try{await d.run(async()=>{result=await handler({event:{data:{record_id:uid(30),to_stage:spec.toStage??stage},...(spec.missingTimestamp?{}:{ts:+new RealDate(spec.entry??epoch)})},step:{run:async(_,fn)=>fn(),sleepUntil:async(_,due)=>{
  index++;time=Math.max(time,+due);sleeps.push({index,due:due.toISOString(),executedAt:new RealDate(time).toISOString()});
  for(const action of actions.filter(x=>x.at===index)){
   if(action.cancel){cancelled=true;throw Error('synthetic Inngest cancelOn')}
   if(action.remove)d.state.crm_Opportunities=[];
   if(action.values)await d.prisma.crm_Opportunities.update({where:{id:uid(30)},data:action.values});
   if(action.settings){if(d.state.crm_FunnelSettings.length)await d.prisma.crm_FunnelSettings.update({where:{id:d.state.crm_FunnelSettings[0].id},data:action.settings});else d.seed('crm_FunnelSettings',{id:uid(20),...action.settings})}
  }
 }}})})}catch(e){if(!cancelled)throw e;result={cancelled:true}}
 Object.assign(hashes,d.sourceHashes);
 const rows=d.snapshot(['crm_Accounts_Tasks']).crm_Accounts_Tasks;
 const rawTasks=rows.map(x=>Object.fromEntries(taskFields.map(k=>[k,x[k]])));
 const tasks=rows.map((row,i)=>row.id===uid(40)?rawTasks[i]:{...rawTasks[i],...translated(kind,scheduled.findIndex(x=>x.title===row.title),settings,createdNames[row.id])});
 assert.equal(notices.length,rows.length-seeds.crm_Accounts_Tasks.length);
 return {label:spec.label,kind,entry:spec.entry??epoch,toStage:spec.toStage??stage,missingTimestamp:!!spec.missingTimestamp,settings,seeds,actions,sleeps,result,rawTasks,tasks,created:rows.length-seeds.crm_Accounts_Tasks.length,recipients:notices.map(x=>x.to).sort(),scheduled:scheduled.map((x,index)=>({index,title:x.title,content:x.content,due:x.date.toISOString()}))};
}
(async()=>{
 const specs=[];
 for(const kind of ['qualified','care']){
  for(const [label,more]of [['default',{}],['no-timestamp',{missingTimestamp:true,entry:'2026-03-06T07:00:00.000Z'}],['weekend',{entry:'2026-03-07T23:59:59.999Z'}],['unassigned',{unassigned:true}],['no-account',{noAccount:true}],['closed',{status:'CLOSED'}],['deleted-source-still-active',{deleted:true}],['empty-name',{name:''}],['unicode',{name:'𠮷田é/é\n案件'}],['wrong-stage',{toStage:uid(12)}],['missing-stage',{toStage:uid(999)}],['wrong-current-kind',{currentStage:uid(12)}],['assignee-change',{actions:[{at:0,values:{assigned_to:uid(2),name:'新しい案件名'}}]}],['later-close',{actions:[{at:1,values:{status:'CLOSED'}}]}],['later-stage-without-event',{actions:[{at:1,values:{sales_stage:uid(12)}}]}],['delete-record',{actions:[{at:0,remove:true}]}],['cancel-before-first',{actions:[{at:0,cancel:true}]}],['cancel-after-first',{actions:[{at:1,cancel:true}]}],['settings-frozen',{actions:[{at:0,settings:{care_quarter_count:0,cadence_touch2_offset_days:365}}]}]])specs.push({label:kind+'-'+label,kind,...more});
  for(const status of ['ACTIVE','PENDING','COMPLETE'])specs.push({label:kind+'-existing-'+status,kind,existing:status});
 }
 for(const n of [0,1,24])specs.push({label:'care-count-'+n,kind:'care',settings:{care_quarter_count:n}});
 specs.push({label:'care-out-of-order',kind:'care',settings:{care_checkin_days:100,care_referral_days:1,care_quarter_interval_days:1,care_quarter_count:2}});
 specs.push({label:'qualified-out-of-order-import',kind:'qualified',settings:{cadence_touch1_business_days:0,cadence_touch2_offset_days:-1,cadence_touch3_offset_days:0,cadence_touch4_offset_days:-1,cadence_touch5_offset_days:1}});
 const cases=[];for(const s of specs)cases.push(await run(s));
 const d=createSourceDatabase({root,epoch}),timers=d.load('lib/crm/funnel-timers.ts'),pure=[];
 for(let day=0;day<7;day++)for(const n of [-1,0,1,3,5,10,365]){
  const entry=new RealDate(+new RealDate(epoch)+day*86400000),settings={...timers.DEFAULT_FUNNEL_SETTINGS,cadenceTouch1BusinessDays:n};
  pure.push({entry:entry.toISOString(),settings,result:timers.cadenceSchedule(entry,settings).map(x=>({title:x.title,content:x.content,due:x.date.toISOString()}))});
 }
 Object.assign(hashes,d.sourceHashes);for(const name of ['prisma/schema.prisma','desktop/native/plugins-source-loader.cjs','desktop/native/plugins-source-database.cjs'])hashes[name]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,name))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,models,taskFields,registrations,cases,pure,sourceSHA256:hashes,limits:['Actual handlers/helpers with synthetic Prisma and step clock. cancelOn registration is asserted and simulated at delivery; no live Inngest engine.', 'Japanese templates are explicit declared mappings; rawTasks preserve source output for independent review. Native same-second producer generation/SQLite rollback are separately exercised.']},null,2)+'\n');
 console.log(`Stage handlers: ${cases.length} effects + ${pure.length} pure scenarios`);
})().catch(e=>{console.error(e);process.exit(1)});
