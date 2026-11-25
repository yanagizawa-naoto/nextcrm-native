const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),hashes={},cache={};let active;
const NativeDate=Date,now='2026-11-14T10:00:00.125Z',instant=NativeDate.parse(now);
global.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[instant]));}static now(){return instant;}};
const {Webhook}=require('svix'),secret='whsec_'+Buffer.from('nextcrm-fixture-secret-not-a-real-key').toString('base64'),signer=new Webhook(secret);
class NextResponse{constructor(body='',options={}){this.body=body;this.status=options.status??200;this.headers=options.headers??{};}static json(body,options={}){return new NextResponse(JSON.stringify(body),options);}}
function load(file){if(cache[file])return cache[file];const source=fs.readFileSync(path.join(root,file),'utf8');hashes[file]=crypto.createHash('sha256').update(source).digest('hex');const m={exports:{}};
 const required=n=>{
  if(n==='next/server')return{NextResponse};
  if(n==='svix')return require(n);
  if(n==='@/lib/prisma')return{prismadb:{crm_campaign_sends:{findUnique:async({where})=>active.send?.unsubscribe_token===where.unsubscribe_token?active.send:null,findFirst:async({where})=>active.send?.resend_message_id===where.resend_message_id?active.send:null,update:async({data})=>Object.assign(active.send,data)},crm_Targets:{updateMany:async({where,data})=>{let count=0;for(const t of active.targets){if(!t.do_not_email&&(t.id===where.OR[0].id||t.email?.toLowerCase()===where.OR[1].email.equals.toLowerCase())){Object.assign(t,data);count++;}}return{count};}}}};
  if(n.startsWith('@/'))return load(n.slice(2)+'.ts');throw Error(n);
 };
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,{module:m,exports:m.exports,require:required,process:{env:{RESEND_WEBHOOK_SECRET:secret}},Date,console});cache[file]=m.exports;return m.exports;
}
function headers(body,{delta=0,id='msg_fixture',...overrides}={}){const date=new Date(instant+delta*1000);return{'svix-id':id,'svix-timestamp':String(Math.floor(date.getTime()/1000)),'svix-signature':signer.sign(id,date,body),...overrides};}
(async()=>{
 const signature=load('lib/campaigns/resend-signature.ts').verifyResendSignature,signatures=[],body='{"type":"email.opened","data":{"email_id":"e07c9c68-d381-4395-b73d-7851d24df3b4"}}';
 function vector(name,b,h){signatures.push({name,body:b,headers:h,expected:signature(b,new Headers(h))});}
 vector('valid',body,headers(body));
 for(const delta of [-301,-300,-1,0,1,300,301])vector('timestamp'+delta,body,headers(body,{delta}));
 vector('tampered-body',body+' ',headers(body));vector('tampered-id',body,{...headers(body),'svix-id':'msg_changed'});
 vector('wrong-version',body,{...headers(body),'svix-signature':headers(body)['svix-signature'].replace('v1,','v2,')});
 vector('rotation-list',body,{...headers(body),'svix-signature':'v1,'+Buffer.alloc(32).toString('base64')+' '+headers(body)['svix-signature']});
 vector('bad-base64',body,{...headers(body),'svix-signature':'v1,invalid'});
 for(const field of ['svix-id','svix-timestamp','svix-signature']){const h=headers(body);delete h[field];vector('missing-'+field,body,h);}
 vector('uppercase-headers',body,Object.fromEntries(Object.entries(headers(body)).map(([k,v])=>[k.toUpperCase(),v])));
 const unsubscribe=load('app/api/campaigns/unsubscribe/route.ts').GET,unsubscribes=[];
 for(const email of ['customer@example.invalid','Älice@example.invalid'])for(const already of [false,true]){
  active={send:{id:'send',target_id:'original',email,unsubscribe_token:'b3ee4e3c-d747-4ca3-a149-2d39597f7f99',unsubscribed_at:already?new Date('2025-01-01T00:00:00Z'):null},targets:[{id:'original',email:'changed@example.invalid',do_not_email:false},{id:'same',email,do_not_email:false},{id:'case',email:email.toUpperCase(),do_not_email:false},{id:'other',email:'unrelated@example.invalid',do_not_email:false},{id:'existing',email,do_not_email:true,do_not_email_at:new Date('2025-01-01T00:00:00Z')}]};
  const before=JSON.parse(JSON.stringify(active)),response=await unsubscribe({nextUrl:new URL('https://example.invalid/api/campaigns/unsubscribe?token='+active.send.unsubscribe_token)});
  unsubscribes.push({email,already,before,after:JSON.parse(JSON.stringify(active)),status:response.status});
 }
 const post=load('app/api/campaigns/webhooks/resend/route.ts').POST,events=[];
 for(const status of ['queued','sending','sent','delivered','bounced','failed'])for(const kind of ['email.delivered','email.bounced','email.opened','email.clicked','email.unknown'])for(const seen of [false,true]){
  const providerID='e07c9c68-d381-4395-b73d-7851d24df3b4';active={send:{id:'send',resend_message_id:providerID,status,error_message:'previous error',opened_at:seen?new Date('2025-01-01T00:00:00Z'):null,clicked_at:seen?new Date('2025-01-02T00:00:00Z'):null}};
  const before=JSON.parse(JSON.stringify(active.send)),payload=JSON.stringify({type:kind,data:{email_id:providerID,message_id:'<not-the-provider-id@example.invalid>'}}),response=await post({text:async()=>payload,headers:new Headers(headers(payload))});
  events.push({status,kind,seen,before,after:JSON.parse(JSON.stringify(active.send)),responseStatus:response.status});
 }
 fs.writeFileSync(path.join(__dirname,'build/campaign-events-reference.json'),JSON.stringify({now,secret,hashes,signatures,unsubscribes,events},null,2)+'\n');console.log(JSON.stringify({suite:'actual source unsubscribe/webhook/signature',signatures:signatures.length,unsubscribes:unsubscribes.length,events:events.length}));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{global.Date=NativeDate;});
