'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {DatabaseSync}=require('node:sqlite');
const {CalendarRelayStore,createHTTPServer,verifyCalendly,MAX_BODY,MAX_PAGE}=require('../calendar-relay/relay.cjs');
const key=Buffer.alloc(32,31),authKey=key.toString('base64url'),signingKey='fixture-calendly-key-only',now=1800000000125;
function sign(body,time=String(Math.floor(now/1000)),secret=signingKey){return`t=${time},v1=${crypto.createHmac('sha256',secret).update(time+'.').update(body).digest('hex')}`;}
function body(index=1,extra=''){return Buffer.from(JSON.stringify({event:'invitee.created',payload:{uri:`https://api.calendly.com/scheduled_events/event/invitees/${index}`,email:'CLIENT@EXTERNAL.INVALID',name:'予約のお客様',scheduled_event:{name:'日本語の予約',start_time:'2027-01-15T10:00:00.000Z',event_memberships:[{user_email:'host@example.invalid'}]},extra}}));}
function fixture(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'NextCRM-CalendarRelay-')),filename=path.join(root,'relay.sqlite');let store=new CalendarRelayStore(filename,authKey);t.after(()=>{try{store.close();}catch{}fs.rmSync(root,{recursive:true,force:true});});return{root,filename,get store(){return store;},restart(){store.close();store=new CalendarRelayStore(filename,authKey);return store;}};}
function configure(store){const clientId=crypto.randomUUID();store.bind(clientId);store.configure(clientId,signingKey,null);return clientId;}
async function listen(store){const server=createHTTPServer({store,basePath:'/crm',clock:()=>now});await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});return{server,base:'http://127.0.0.1:'+server.address().port};}
async function close(server){await new Promise(resolve=>{server.close(resolve);server.closeAllConnections();});}
function headers(method,target,bytes,nonce=crypto.randomUUID(),timestamp=String(Math.floor(now/1000))){return{'Content-Type':'application/json','X-NextCRM-Nonce':nonce,'X-NextCRM-Timestamp':timestamp,'X-NextCRM-Signature':crypto.createHmac('sha256',key).update('nextcrm-calendar-v1-request\n'+method+'\n'+target+'\n'+timestamp+'\n'+nonce+'\n').update(bytes).digest('base64')};}
async function api(base,method,target,value,custom){const bytes=value===undefined?Buffer.alloc(0):Buffer.from(JSON.stringify(value)),h=custom??headers(method,target,bytes),response=await fetch(base+target,{method,headers:h,body:method==='GET'?undefined:bytes}),received=Buffer.from(await response.arrayBuffer());if(response.headers.has('x-nextcrm-signature'))assert.equal(response.headers.get('x-nextcrm-signature'),crypto.createHmac('sha256',key).update('nextcrm-calendar-v1-response\n'+h['X-NextCRM-Nonce']+'\n'+response.status+'\n').update(received).digest('base64'));return{status:response.status,data:JSON.parse(received),signed:response.headers.has('x-nextcrm-signature'),bytes:received};}
test('large original webhook bytes survive signed HTTP ingress, encrypted storage and first-event page budget',async t=>{
 const f=fixture(t),client=configure(f.store),{server,base}=await listen(f.store);t.after(async()=>{if(server.listening)await close(server)});
 let after=0;const results=[];
 for(const size of [1048575,1048576,1048577,2097153]){
  const i=after+1,raw=body(i,'x'.repeat(size-body(i).length));assert.equal(raw.length,size);
  const response=await fetch(base+'/crm/api/crm/calendar/webhooks/calendly',{method:'POST',headers:{'calendly-webhook-signature':sign(raw)},body:raw});assert.equal(response.status,200);
  const page=await api(base,'GET',`/crm/api/native-calendly/v1/events?clientId=${client}&after=${after}`);assert.equal(page.status,200);assert.equal(page.signed,true);assert.equal(page.data.events.length,1);assert.deepEqual(Buffer.from(page.data.events[0].body,'base64'),raw);assert.equal(page.data.cursor,i);assert.equal(page.data.hasMore,false);
  results.push({bytes:size,bodySHA256:crypto.createHash('sha256').update(raw).digest('hex'),responseBytes:page.bytes.length});after=i;
 }
 await close(server);f.restart();let page=f.store.events(client,3);assert.equal(page.events.length,1);assert.ok(Buffer.byteLength(JSON.stringify(page))>MAX_PAGE);assert.equal(page.cursor,4);
 const tiny=body(5);f.store.receive(tiny,sign(tiny),now);page=f.store.events(client,3);assert.equal(page.events.length,1);assert.equal(page.hasMore,true);assert.equal(page.cursor,4);assert.equal(f.store.events(client,4).events[0].seq,5);
 fs.writeFileSync(path.join(process.argv[2]||__dirname,'relay-large-result.json'),JSON.stringify({cases:results,afterRestartExact:true,singleOversizeEventAdvances:true,network:'loopback only'},null,2));
});
test('large invalid signature and oversized control body cannot publish receipt or management state',async t=>{
 const f=fixture(t),client=configure(f.store),{server,base}=await listen(f.store);t.after(async()=>{if(server.listening)await close(server)});
 const raw=body(1,'x'.repeat(1048577));let response=await fetch(base+'/crm/api/crm/calendar/webhooks/calendly',{method:'POST',headers:{'calendly-webhook-signature':sign(raw,undefined,'wrong')},body:raw});assert.equal(response.status,401);assert.equal(f.store.head(),0);
 response=await fetch(base+'/crm/api/native-calendly/v1/bind',{method:'POST',body:Buffer.alloc(MAX_BODY+1,32)});assert.equal(response.status,413);assert.equal(f.store.identity().clientId,client);assert.equal(f.store.head(),0);
});
