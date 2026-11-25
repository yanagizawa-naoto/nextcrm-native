'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {DatabaseSync}=require('node:sqlite');
const {RelayStore,createHTTPServer,verifyWebhook,MAX_BODY}=require('./relay.cjs');
const key=Buffer.alloc(32,7),authKey=key.toString('base64url'),webhookKey=Buffer.from('relay-fixture-signing-key-not-real'),secret='whsec_'+webhookKey.toString('base64'),now=Date.parse('2026-11-14T10:00:00.125Z');
function signature(body,id='msg_test',timestamp=String(Math.floor(now/1000))){return{'svix-id':id,'svix-timestamp':timestamp,'svix-signature':'v1,'+crypto.createHmac('sha256',webhookKey).update(id+'.'+timestamp+'.').update(body).digest('base64')};}
function event(kind,providerId){return Buffer.from(JSON.stringify({type:kind,data:{email_id:providerId,message_id:'<rfc5322@example.invalid>'}}));}
function registration(){return{sendId:crypto.randomUUID(),token:crypto.randomUUID()};}
function fixture(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'NextCRM-CampaignRelay-')),filename=path.join(root,'relay.sqlite');let store=new RelayStore(filename);t.after(()=>{try{store.close();}catch{}fs.rmSync(root,{recursive:true,force:true});});return{root,filename,get store(){return store;},restart(){store.close();store=new RelayStore(filename);return store;}};}
async function listen(store){const server=createHTTPServer({store,authKey,webhookSecret:secret,basePath:'/crm',clock:()=>now});await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});return{server,base:'http://127.0.0.1:'+server.address().port};}
async function close(server){await new Promise(resolve=>{server.close(resolve);server.closeAllConnections();});}
function authenticated(method,target,body=Buffer.alloc(0),nonce=crypto.randomUUID(),timestamp=String(Math.floor(now/1000))){const signature=crypto.createHmac('sha256',key).update('nextcrm-relay-v1-request\n'+method+'\n'+target+'\n'+timestamp+'\n'+nonce+'\n').update(body).digest('base64');return{'X-NextCRM-Timestamp':timestamp,'X-NextCRM-Nonce':nonce,'X-NextCRM-Signature':signature,'Content-Type':'application/json'};}
async function api(base,method,target,value,options={}){const body=value===undefined?Buffer.alloc(0):Buffer.from(JSON.stringify(value)),headers=options.headers??authenticated(method,target,body);const response=await fetch(base+target,{method,headers,body:method==='GET'?undefined:body}),bytes=Buffer.from(await response.arrayBuffer());
 if(options.verify!==false){const expected=crypto.createHmac('sha256',key).update('nextcrm-relay-v1-response\n'+headers['X-NextCRM-Nonce']+'\n'+response.status+'\n').update(bytes).digest('base64');assert.equal(response.headers.get('x-nextcrm-signature'),expected,'response authenticated against fresh request nonce and raw bytes');}
 return{status:response.status,data:JSON.parse(bytes),headers:response.headers};}

test('actual source and official Svix signature vectors',()=>{
 const reference=JSON.parse(fs.readFileSync(path.join(__dirname,'../native/build/campaign-events-reference.json')));
 for(const row of reference.signatures){const headers=Object.fromEntries(Object.entries(row.headers).map(([k,v])=>[k.toLowerCase(),v]));assert.equal(verifyWebhook(Buffer.from(row.body),headers,reference.secret,Date.parse(reference.now)),row.expected,row.name);}
 assert.equal(verifyWebhook(Buffer.from('{"event_type":"ping","data":{"success":true}}'),{'svix-id':'msg_loFOjxBNrRLzqYUf','svix-timestamp':'1731705121','svix-signature':'v1,rAvfW3dJ/X/qxhsaXPOyyCGmRKsaKWcsNccKXlIktD0='},'whsec_plJ3nmyCDGBKInavdOK15jsl',1731705121000),true);
});
test('registration immutable, tenant binding, and whole-batch rollback',t=>{
 const f=fixture(t),id=crypto.randomUUID(),r=registration();f.store.bind(id);assert.throws(()=>f.store.bind(crypto.randomUUID()),/別のCRM/);
 f.store.register(id,[r],now);assert.equal(f.store.register(id,[r],now).registrations[0].token,r.token);
 assert.throws(()=>f.store.register(id,[{...r,token:crypto.randomUUID()}],now),/一致/);
 assert.throws(()=>f.store.register(id,[{...registration(),token:r.token}],now),/競合/);
 const valid=registration();assert.throws(()=>f.store.register(id,[valid,{sendId:'bad',token:'bad'}],now));assert.equal(f.store.db.prepare('SELECT COUNT(*) n FROM registrations WHERE send_id=?').get(valid.sendId).n,0);
 assert.throws(()=>f.store.register(crypto.randomUUID(),[valid],now),/一致/);
 assert.throws(()=>f.store.register(id,Array.from({length:101},registration),now));
 const instance=f.store.meta('instance_id');f.restart();assert.equal(f.store.meta('instance_id'),instance);assert.equal(f.store.meta('client_id'),id);assert.equal(fs.statSync(f.filename).mode&0o777,0o600);
});
test('unsubscribe while native app absent survives receiver restart and bounded replay',async t=>{
 const f=fixture(t),clientId=crypto.randomUUID(),r=registration();f.store.bind(clientId);f.store.register(clientId,[r],now);
 let {server,base}=await listen(f.store);t.after(async()=>{if(server.listening)await close(server);});
 const link=base+'/crm/api/campaigns/unsubscribe?token='+r.token;
 const result=await fetch(link),html=await result.text();assert.equal(result.status,200);assert.match(html,/配信停止を受け付けました/);assert.match(html,/lang="ja"/);assert.equal(html.includes(r.token),false);assert.equal(result.headers.get('cache-control'),'no-store');
 assert.equal((await fetch(link)).status,200);assert.equal(f.store.head(),1);
 await close(server);f.restart();({server,base}=await listen(f.store));
 const page=await api(base,'GET','/crm/api/native-campaigns/v1/events?clientId='+clientId+'&after=0');assert.equal(page.status,200);assert.equal(page.data.events.length,1);assert.equal(page.data.events[0].kind,'unsubscribe');assert.equal(page.data.events[0].token,r.token);assert.equal(page.data.events[0].receivedAt,new Date(now).toISOString());
 const more=Array.from({length:205},registration);for(let n=0;n<more.length;n+=100)f.store.register(clientId,more.slice(n,n+100),now);for(const item of more)f.store.unsubscribe(item.token,now);
 let cursor=0,count=0;do{const page=f.store.events(clientId,cursor);assert.ok(page.events.length<=100);assert.ok(page.events.every(e=>e.seq>cursor));count+=page.events.length;cursor=page.cursor;if(!page.hasMore)break;}while(true);
 assert.equal(count,206);assert.equal(cursor,f.store.head());assert.throws(()=>f.store.events(clientId,cursor+1),/履歴/);
 await close(server);
});
test('early webhooks journal after receipt registration and duplicate opens stay bounded',t=>{
 const f=fixture(t),clientId=crypto.randomUUID(),r=registration(),providerId=crypto.randomUUID();f.store.bind(clientId);f.store.register(clientId,[r],now);
 const opened=event('email.opened',providerId),bounced=event('email.bounced',providerId);assert.equal(f.store.webhook(opened,signature(opened,'msg_early'),secret,now),'pending');
 assert.equal(f.store.webhook(bounced,signature(bounced,'msg_bounced'),secret,now),'pending');assert.equal(f.store.head(),0);f.restart();
 f.store.register(clientId,[{...r,providerId}],now+1000);let page=f.store.events(clientId,0);assert.deepEqual(page.events.map(e=>e.kind),['email.opened','email.bounced']);assert.ok(page.events.every(e=>e.sendId===r.sendId&&e.providerId===providerId));
 assert.equal(f.store.webhook(opened,signature(opened,'msg_early'),secret,now),'duplicate');
 for(let n=0;n<150;n++)f.store.webhook(opened,signature(opened,'msg_repeat_'+n),secret,now);
 assert.equal(f.store.head(),2);assert.equal(f.store.db.prepare('SELECT COUNT(*) n FROM observations').get().n,2);
 assert.throws(()=>f.store.webhook(bounced,signature(bounced,'msg_early'),secret,now),/異なり/);
 const second=registration();assert.throws(()=>f.store.register(clientId,[{...second,providerId}],now),/競合/);assert.equal(f.store.db.prepare('SELECT COUNT(*) n FROM registrations').get().n,1);
});
test('persist failures never acknowledge or partially publish',t=>{
 const f=fixture(t),id=crypto.randomUUID(),r=registration();f.store.bind(id);f.store.register(id,[r],now);
 f.store.db.exec("CREATE TRIGGER refuse_log BEFORE INSERT ON event_log BEGIN SELECT RAISE(ABORT,'injected'); END");
 assert.throws(()=>f.store.unsubscribe(r.token,now),/injected/);assert.equal(f.store.db.prepare('SELECT unsubscribed_at FROM registrations').get().unsubscribed_at,null);assert.equal(f.store.head(),0);
 const providerId=crypto.randomUUID(),payload=event('email.clicked',providerId);f.store.webhook(payload,signature(payload),secret,now);
 assert.throws(()=>f.store.register(id,[{...r,providerId}],now),/injected/);assert.equal(f.store.db.prepare('SELECT provider_id FROM registrations').get().provider_id,null);
 f.store.db.exec('DROP TRIGGER refuse_log');f.store.register(id,[{...r,providerId}],now);assert.equal(f.store.head(),1);f.store.unsubscribe(r.token,now);assert.equal(f.store.head(),2);
});
test('real HTTP authentication, replay fencing, malformed and unsigned public requests',async t=>{
 const f=fixture(t),{server,base}=await listen(f.store);t.after(()=>close(server));
 const root='/crm/api/native-campaigns/v1/',clientId=crypto.randomUUID();
 assert.equal((await api(base,'GET',root+'health')).status,200);
 assert.equal((await api(base,'POST',root+'bind',{clientId})).data.clientId,clientId);
 const r=registration();assert.equal((await api(base,'POST',root+'registrations',{clientId,registrations:[r]})).status,200);
 const h=authenticated('GET',root+'health');assert.equal((await api(base,'GET',root+'health',undefined,{headers:h})).status,200);assert.equal((await api(base,'GET',root+'health',undefined,{headers:h})).status,409);
 const changed={...authenticated('GET',root+'health'),'X-NextCRM-Signature':Buffer.alloc(32).toString('base64')};assert.equal((await api(base,'GET',root+'health',undefined,{headers:changed,verify:false})).status,401);
 const expired=authenticated('GET',root+'health',Buffer.alloc(0),crypto.randomUUID(),String(Math.floor(now/1000)-301));assert.equal((await api(base,'GET',root+'health',undefined,{headers:expired,verify:false})).status,401);
 const differentPath=authenticated('GET',root+'health');assert.equal((await api(base,'GET',root+'events?clientId='+clientId+'&after=0',undefined,{headers:differentPath,verify:false})).status,401);
 assert.equal((await fetch(base+'/crm/api/campaigns/unsubscribe')).status,400);assert.equal((await fetch(base+'/crm/api/campaigns/unsubscribe?token='+r.token+'&token='+r.token)).status,400);assert.equal((await fetch(base+'/crm/api/campaigns/unsubscribe?token='+crypto.randomUUID())).status,404);
 const payload=event('email.delivered',crypto.randomUUID()),endpoint=base+'/crm/api/campaigns/webhooks/resend';assert.equal((await fetch(endpoint,{method:'POST',body:payload})).status,401);assert.equal((await fetch(endpoint,{method:'POST',headers:signature(payload),body:payload})).status,200);
 const bad=Buffer.from('not JSON');assert.equal((await fetch(endpoint,{method:'POST',headers:signature(bad,'msg_bad'),body:bad})).status,400);
 assert.equal((await fetch(endpoint,{method:'POST',body:Buffer.alloc(MAX_BODY+1)})).status,413);
 assert.equal(f.store.db.prepare('SELECT COUNT(*) n FROM registrations').get().n,1);
});
test('wrong database and symlink paths rejected without modifying foreign schema',t=>{
 const f=fixture(t),foreign=path.join(f.root,'foreign.sqlite');const db=new DatabaseSync(foreign);db.exec('CREATE TABLE unrelated(value TEXT)');db.close();
 assert.throws(()=>new RelayStore(foreign),/別の用途/);const check=new DatabaseSync(foreign);assert.deepEqual(check.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(x=>x.name),['unrelated']);check.close();
 const link=path.join(f.root,'link.sqlite');fs.symlinkSync(path.join(f.root,'missing.sqlite'),link);assert.throws(()=>new RelayStore(link),/保存先/);
});
test('unknown provider inbox capacity does not block known deliveries or discard old pending data',t=>{
 const f=fixture(t),id=crypto.randomUUID(),r=registration(),providerId=crypto.randomUUID();f.store.bind(id);f.store.register(id,[{...r,providerId}],now);
 f.store.db.exec("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO observations SELECT 'unknown-'||x,'email.opened','msg_capacity_'||x,printf('%064d',0),'2020-01-01T00:00:00.000Z' FROM n");
 const unrelated=event('email.opened','another-unknown');assert.throws(()=>f.store.webhook(unrelated,signature(unrelated,'msg_overflow'),secret,now),/上限/);
 assert.equal(f.store.db.prepare('SELECT COUNT(*) n FROM observations').get().n,10000);assert.equal(f.store.db.prepare('SELECT COUNT(*) n FROM webhook_seen').get().n,0);
 const known=event('email.delivered',providerId);assert.equal(f.store.webhook(known,signature(known,'msg_known'),secret,now),'applied');assert.equal(f.store.head(),1);
});

test('signed read-only readiness probe uses the real public unsubscribe path',async t=>{
 const f=fixture(t),clientId=crypto.randomUUID(),r=registration();f.store.bind(clientId);f.store.register(clientId,[r],now);
 const {server,base}=await listen(f.store);t.after(()=>close(server));
 const target='/crm/api/campaigns/unsubscribe?check=ready&clientId='+clientId;
 const anonymous=await fetch(base+target);assert.equal(anonymous.status,401);assert.equal(anonymous.headers.get('x-nextcrm-signature'),null);
 const ready=await api(base,'GET',target);assert.equal(ready.status,200);assert.equal(ready.data.unsubscribeReady,true);assert.equal(ready.data.instanceId,f.store.meta('instance_id'));assert.equal(ready.data.clientId,clientId);
 assert.equal(f.store.head(),0);assert.equal(f.store.db.prepare('SELECT unsubscribed_at FROM registrations WHERE send_id=?').get(r.sendId).unsubscribed_at,null);
 assert.equal((await api(base,'GET',target+'&token='+r.token)).status,400);
 assert.equal((await api(base,'GET',target+'&check=ready')).status,400);
 assert.equal((await api(base,'GET',target.replace(clientId,crypto.randomUUID()))).status,409);
 const elsewhere=authenticated('GET','/crm/api/native-campaigns/v1/health');assert.equal((await api(base,'GET',target,undefined,{headers:elsewhere,verify:false})).status,401);
 assert.equal(f.store.head(),0,'every probe remains read-only');
 assert.equal((await fetch(base+'/crm/api/campaigns/unsubscribe?token='+r.token)).status,200);assert.equal(f.store.head(),1,'ordinary recipient link still unsubscribes');
});
