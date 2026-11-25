const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),hashes={},cache={};let active;
function load(file){if(cache[file])return cache[file];const source=fs.readFileSync(path.join(root,file),'utf8');hashes[file]=crypto.createHash('sha256').update(source).digest('hex');const m={exports:{}};
 const require=n=>{
  if(n==='@/inngest/client')return{inngest:{createFunction:(_config,handler)=>handler}};
  if(n==='@/lib/prisma')return{prismadb:{crm_campaign_sends:{findUnique:async()=>active.record,updateMany:async({data})=>{if(!['queued','failed'].includes(active.record.status))return{count:0};Object.assign(active.record,data);return{count:1};},update:async({data})=>Object.assign(active.record,data)}}};
  if(n==='@/lib/resend')return async()=>({emails:{send:async(args,options)=>{active.mail=args;active.options=options;return{data:{id:'ed73d5b1-bf1f-4d6a-9b8f-1b2008bb12ed'},error:null};}}});
  if(n==='@/lib/campaigns/render-email')return{renderCampaignEmail:async(args)=>{active.render=args;return 'REFERENCE_RENDERED_HTML';}};
  if(n==='@/lib/campaigns/mark-campaign-sent')return{markCampaignSentIfStep0Done:async()=>{active.completed++;}};
  if(n.startsWith('@/'))return load(n.slice(2)+'.ts');throw Error(n);
 };
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,{module:m,exports:m.exports,require,process:{env:{RESEND_FROM_EMAIL:'sender@example.invalid',NEXT_PUBLIC_APP_URL:'https://crm.example.invalid/base/'}},Date});cache[file]=m.exports;return m.exports;
}
(async()=>{
 const handler=load('inngest/functions/campaigns/send-step.ts').campaignSendStep,cases=[];
 for(const [name,status,campaignStatus,unsubscribed,suppressed,deleted] of [
  ['queued','queued','sending',false,false,false],['failed','failed','sending',false,false,false],['sending','sending','sending',false,false,false],['sent','sent','sending',false,false,false],['delivered','delivered','sending',false,false,false],['bounced','bounced','sending',false,false,false],['unsubscribed','queued','sending',true,false,false],['suppressed','queued','sending',false,true,false],['paused','queued','paused',false,false,false],['deleted','queued','sending',false,false,true]
 ]){
  active={completed:0,record:{id:'48c35656-2fc6-4a67-b734-aa646e0f4005',status,email:'recipient@example.invalid',unsubscribe_token:'a9e5277a-1918-458a-bf47-32d219469448',unsubscribed_at:unsubscribed?new Date():null,campaign:{status:campaignStatus,deletedAt:deleted?new Date():null,from_name:'日本語営業',reply_to:'reply@example.invalid'},step:{subject:'{{last_name}} 様へのご案内',template:{content_html:'<p>{{first_name}} 様：日本語😀</p>'}},target:{last_name:'検証',first_name:'山田<&"',do_not_email:suppressed}}};
  const result=await handler({event:{data:{sendId:active.record.id,campaignId:'f064583e-2dab-4d14-a2be-c644c817d733'}},step:{run:async(_name,fn)=>fn()}});
  cases.push({name,status,campaignStatus,unsubscribed,suppressed,deleted,sent:!!active.mail,result,finalStatus:active.record.status,mail:active.mail,render:active.render,options:active.options,completed:active.completed});
 }
 fs.writeFileSync(path.join(__dirname,'build/campaign-mail-reference.json'),JSON.stringify({hashes,cases},null,2)+'\n');console.log(JSON.stringify({suite:'actual source campaign send-step handler',cases:cases.length}));
})().catch(e=>{console.error(e);process.exitCode=1;});
