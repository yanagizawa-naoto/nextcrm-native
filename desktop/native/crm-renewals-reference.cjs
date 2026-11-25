// Execute the checked-in handler/helpers unchanged. Synthetic Prisma and Resend
// boundaries only; installed/locked TypeScript and Prisma are reused.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
if(!process.argv[3])throw Error('Native production source directory required');
const native=path.resolve(process.argv[3]),root=path.resolve(native,'../..');
const {createSourceDatabase}=require(path.join(native,'plugins-source-database.cjs'));
const uid=n=>`c0000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const epoch='2026-03-02T07:00:00.123Z',dt=days=>new Date(+new Date(epoch)+days*86400000).toISOString();
const taskFields=['v','title','content','priority','taskStatus','account','opportunity_id','user','createdBy','updatedBy','dueDateAt','likes','tags'];
const models=['Users','Currency','crm_Accounts','crm_Products','crm_FunnelSettings','crm_Contracts','crm_AccountProducts','crm_Accounts_Tasks'];
let registrations,hashes={};
async function one(spec){
 let sent=[],logged=[];
 const d=createSourceDatabase({root,epoch,mocks:{
  '@/inngest/client':{inngest:{createFunction:(config,handler)=>{registrations=config;return handler}}},
  resend:{Resend:class {constructor(){this.emails={send:async payload=>{sent.push(payload);if(spec.mailFailure)throw Error('synthetic mail failure');return {id:'fake'}}}}}},
 }});
 // The shared plugin adapter does not project these two relations. This narrow
 // Prisma projection extension preserves the handler's real select/where code.
 const original=d.prisma.crm_AccountProducts.findMany;
 d.prisma.crm_AccountProducts.findMany=async args=>{
  const rows=await original({...args,select:undefined});
  return rows.map(row=>Object.fromEntries(Object.entries(args.select).map(([key,selection])=>{
   if(key==='account'||key==='product'){
    const linked=d.state[key==='account'?'crm_Accounts':'crm_Products'].find(x=>x.id===row[key==='account'?'accountId':'productId']);
    return [key,linked?Object.fromEntries(Object.keys(selection.select).map(k=>[k,linked[k]])):null];
   }
   return [key,row[key]];
  })));
 };
 d.seed('Users',{id:uid(1),email:spec.noEmail?'':'owner@example.invalid',name:'担当者',role:'admin',userStatus:'ACTIVE'});
 d.seed('Currency',{code:'JPY',name:'Japanese Yen',symbol:'¥'});
 d.seed('crm_Accounts',{id:uid(2),v:0,name:spec.accountName??'日本の取引先',assigned_to:spec.noProductAssignee?null:uid(1),...(spec.deletedAccount?{deletedAt:new Date(epoch)}:{})});
 d.seed('crm_Products',{id:uid(3),name:spec.productName??'保守契約',type:'SERVICE',unit_price:'123.45',currency:'JPY',...(spec.deletedProduct?{deletedAt:new Date(epoch)}:{})});
 if(spec.days!==undefined)d.seed('crm_FunnelSettings',{id:uid(4),renewal_window_days:spec.days});
 if(spec.secondSettings)d.seed('crm_FunnelSettings',{id:uid(5),renewal_window_days:365});
 const contracts=spec.contracts??[{days:10}],products=spec.products??[{days:20}];
 contracts.forEach((item,i)=>d.seed('crm_Contracts',{id:uid(100+i),v:0,title:item.title??spec.title??'年間契約',value:'123.45',account:item.noAccount?null:uid(2),assigned_to:item.unassigned?null:uid(1),status:item.status??'NOTSTARTED',renewalReminderDate:item.nil?null:new Date(item.timestamp??dt(item.days)),...(item.deleted?{deletedAt:new Date(epoch)}:{})}));
 products.forEach((item,i)=>d.seed('crm_AccountProducts',{id:uid(1000+i),accountId:uid(2),productId:uid(3),currency:'JPY',start_date:new Date(epoch),createdBy:uid(1),status:item.status??'ACTIVE',renewal_date:item.nil?null:new Date(item.timestamp??dt(item.days))}));
 if(spec.existing){const c=d.state.crm_Contracts[0],cycle=c.renewalReminderDate.toISOString().slice(0,10);d.seed('crm_Accounts_Tasks',{id:uid(8000),v:0,title:`Renewal ${cycle}: contract "${c.title}"`,priority:'low',taskStatus:spec.existing,account:c.account,user:uid(1)})}
 const seeds=d.snapshot(models),handler=d.load('inngest/functions/crm/renewal-reminders.ts'),steps=[];
 const oldURL=process.env.NEXT_PUBLIC_APP_URL,oldTZ=process.env.TZ,oldLog=console.error;
 if(spec.noURL)delete process.env.NEXT_PUBLIC_APP_URL;else process.env.NEXT_PUBLIC_APP_URL='https://crm.example.invalid';
 process.env.TZ=spec.zone??'UTC';console.error=(...x)=>logged.push(String(x[0]));
 let result,rerun;
 try{await d.run(async()=>{const step={run:async(id,body)=>{steps.push(id);return body()}};result=await handler.renewalReminders({step});if(spec.rerun)rerun=await handler.renewalReminders({step})})}
 finally{console.error=oldLog;if(oldURL===undefined)delete process.env.NEXT_PUBLIC_APP_URL;else process.env.NEXT_PUBLIC_APP_URL=oldURL;if(oldTZ===undefined)delete process.env.TZ;else process.env.TZ=oldTZ}
 Object.assign(hashes,d.sourceHashes);
 const snapshot=d.snapshot(['crm_Accounts_Tasks']).crm_Accounts_Tasks;
 const tasks=snapshot.map(x=>Object.fromEntries(taskFields.map(k=>[k,x[k]])));
 const notices=sent.map(x=>({to:x.to,subject:x.subject,text:x.text.replace(/\/viewtask\/[^\s]+$/,'/viewtask/<task>')}));
 assert.equal(snapshot.length-seeds.crm_Accounts_Tasks.length,result.created);
 return {label:spec.label,zone:spec.zone??'UTC',appURL:spec.noURL?null:'https://crm.example.invalid',seeds,result,rerun:rerun??null,tasks,notices,notificationFailures:logged.length,steps};
}
(async()=>{
 const specs=[{label:'defaults'},{label:'custom-one-day',days:1},{label:'custom-full-year',days:365},{label:'zero-imported',days:0},{label:'negative-imported',days:-1},{label:'first-setting-row',days:1,secondSettings:true},{label:'missing-app-url',noURL:true},{label:'task-dedup-rerun',rerun:true},{label:'notification-fails-best-effort',mailFailure:true},{label:'no-email',noEmail:true},{label:'unassigned-contract',contracts:[{days:10,unassigned:true}],products:[]},{label:'unassigned-account',noProductAssignee:true,contracts:[]},{label:'null-account',contracts:[{days:1,noAccount:true}],products:[]},{label:'deleted-parent-account',deletedAccount:true},{label:'deleted-product',deletedProduct:true},{label:'empty-related-names',accountName:'',productName:'',title:''},{label:'unicode-and-quotes',title:'更新「éとé」\n"多行"',accountName:'𠮷田',productName:'P\t2'},{label:'Tokyo',zone:'Asia/Tokyo'},{label:'LosAngeles-DST',zone:'America/Los_Angeles'},{label:'empty',contracts:[],products:[]},{label:'page-205',contracts:Array.from({length:205},(_,i)=>({days:1,title:'契約'+i})),products:[]},{label:'dedup-duplicate-contracts',contracts:[{days:1},{days:1}],products:[]},{label:'dedup-duplicate-products',contracts:[],products:[{days:1},{days:1}]},{label:'null-account-dedup',contracts:[{days:1,noAccount:true},{days:1,noAccount:true}],products:[]}];
 for(const status of ['ACTIVE','PENDING','COMPLETE'])specs.push({label:'existing-'+status,existing:status,products:[]});
 for(const status of ['ACTIVE','EXPIRED','CANCELLED','PENDING'])specs.push({label:'product-'+status,contracts:[],products:[{days:1,status}]});
 for(const value of [{days:-1},{days:0},{days:30},{days:31},{nil:true},{days:1,deleted:true},{timestamp:'2026-03-02T07:00:00.122Z'},{timestamp:'2026-03-02T07:00:00.124Z'},{timestamp:'2026-04-01T07:00:00.122Z'},{timestamp:'2026-04-01T07:00:00.124Z'}]){
  specs.push({label:'contract-boundary-'+JSON.stringify(value),contracts:[value],products:[]});
  specs.push({label:'product-boundary-'+JSON.stringify(value),contracts:[],products:[value]});
 }
 const cases=[];for(const spec of specs)cases.push(await one(spec));
 for(const file of ['prisma/schema.prisma','desktop/native/plugins-source-database.cjs','desktop/native/plugins-source-loader.cjs'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,registrations,models,taskFields,cases,sourceSHA256:hashes,limits:['Synthetic Prisma projection/filter/default adapter; not a live PostgreSQL or Inngest service proof.','Original handler/helpers run unchanged. Resend records payloads only; no network.','Timezone explicitly selected per fixture; source collection order has no ORDER BY guarantee.']},null,2)+'\n');
 console.log(`Renewal original handler: ${cases.length} scenarios`);
})().catch(e=>{console.error(e);process.exit(1)});
