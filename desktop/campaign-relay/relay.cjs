'use strict';
// Optional external receiver. The Mac application never starts this service.
// Uses only Node built-ins; deployed behind an HTTPS reverse proxy.
const {DatabaseSync}=require('node:sqlite');
const crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const MAX_BODY=1024*1024,UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const kinds=new Set(['email.delivered','email.bounced','email.opened','email.clicked']);
class Problem extends Error{constructor(status,message){super(message);this.status=status;}}
function requireValue(ok,status=400,message='受信内容が不正です。'){if(!ok)throw new Problem(status,message);}
function opaque(v,max){return typeof v==='string'&&v.length>0&&Buffer.byteLength(v)<=max&&!/[\u0000-\u001f\u007f]/.test(v);}
function hash(bytes){return crypto.createHash('sha256').update(bytes).digest('hex');}
function mac(key,prefix,body){return crypto.createHmac('sha256',key).update(prefix).update(body).digest();}
function matches(expected,encoded){if(typeof encoded!=='string'||!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))return false;const actual=Buffer.from(encoded,'base64');return actual.length===expected.length&&crypto.timingSafeEqual(actual,expected);}
function json(bytes){try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw new Problem(400,'受信内容が不正です。');}}
function signingKey(value){requireValue(typeof value==='string'&&/^[A-Za-z0-9_-]{43}$/.test(value),500,'受信窓口の認証キーを設定してください。');const key=Buffer.from(value,'base64url');requireValue(key.length===32,500);return key;}
function verifyWebhook(body,headers,secret,now){
 const id=headers['svix-id'],timestamp=headers['svix-timestamp'],signature=headers['svix-signature'];
 if(body.length>MAX_BODY||!Number.isFinite(now)||!opaque(id,255)||!/^\d{1,12}$/.test(timestamp??'')||Math.abs(Math.floor(now/1000)-Number(timestamp))>300||typeof signature!=='string'||signature.length>4096||typeof secret!=='string'||secret.length>2048)return false;
 const encoded=secret.replace(/^whsec_/,'');if(!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))return false;
 const key=Buffer.from(encoded,'base64');if(!key.length)return false;
 const expected=mac(key,id+'.'+timestamp+'.',body);
 return signature.split(' ').some(item=>item.startsWith('v1,')&&matches(expected,item.slice(3)));
}
class RelayStore{
 constructor(filename){
  const parent=path.dirname(filename);fs.mkdirSync(parent,{recursive:true,mode:0o700});
  requireValue((fs.statSync(parent).mode&0o022)===0,500,'保存先には他の利用者が変更できない専用フォルダを指定してください。');
  let prior;try{prior=fs.lstatSync(filename);}catch(e){if(e.code!=='ENOENT')throw e;}
  if(prior)requireValue(prior.isFile()&&!prior.isSymbolicLink(),500,'保存先が不正です。');
  this.db=new DatabaseSync(filename,{timeout:5000});try{
  const tables=this.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all();
  requireValue(!tables.length||tables.some(t=>t.name==='relay_meta'),500,'別の用途のデータベースは使用できません。');
  if(tables.length)requireValue(this.meta('version')==='1',500,'受信窓口のデータ形式を確認してください。');
  fs.chmodSync(filename,0o600);
  this.db.exec('PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-1024; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;');
  this.db.exec(`CREATE TABLE IF NOT EXISTS relay_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
   CREATE TABLE IF NOT EXISTS registrations(send_id TEXT PRIMARY KEY,token TEXT UNIQUE NOT NULL,provider_id TEXT UNIQUE,created_at TEXT NOT NULL,unsubscribed_at TEXT);
   CREATE TABLE IF NOT EXISTS observations(provider_id TEXT NOT NULL,kind TEXT NOT NULL,event_id TEXT NOT NULL,body_sha256 TEXT NOT NULL,received_at TEXT NOT NULL,PRIMARY KEY(provider_id,kind));
   CREATE TABLE IF NOT EXISTS webhook_seen(event_id TEXT PRIMARY KEY,body_sha256 TEXT NOT NULL,received_at TEXT NOT NULL);
   CREATE INDEX IF NOT EXISTS webhook_seen_time ON webhook_seen(received_at);
   CREATE TABLE IF NOT EXISTS event_log(seq INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,send_id TEXT NOT NULL REFERENCES registrations(send_id),token TEXT,provider_id TEXT,source_event_id TEXT NOT NULL,body_sha256 TEXT,received_at TEXT NOT NULL,UNIQUE(kind,send_id));
   CREATE TABLE IF NOT EXISTS auth_nonces(nonce TEXT PRIMARY KEY,expires INTEGER NOT NULL);
   CREATE INDEX IF NOT EXISTS auth_nonces_expiry ON auth_nonces(expires);`);
  this.transaction(()=>{const version=this.meta('version');requireValue(version===null||version==='1',500,'受信窓口のデータ形式を確認してください。');this.db.prepare('INSERT OR IGNORE INTO relay_meta VALUES(?,?)').run('version','1');this.db.prepare('INSERT OR IGNORE INTO relay_meta VALUES(?,?)').run('instance_id',crypto.randomUUID());});
  }catch(e){this.db.close();throw e;}
 }
 meta(key){return this.db.prepare('SELECT value FROM relay_meta WHERE key=?').get(key)?.value??null;}
 transaction(fn){this.db.exec('BEGIN IMMEDIATE');try{const result=fn();this.db.exec('COMMIT');return result;}catch(e){this.db.exec('ROLLBACK');throw e;}}
 close(){this.db.close();}
 head(){return this.db.prepare('SELECT COALESCE(MAX(seq),0) n FROM event_log').get().n;}
 identity(){return{version:1,instanceId:this.meta('instance_id'),clientId:this.meta('client_id'),head:this.head()};}
 bind(clientId){requireValue(UUID.test(clientId??''));return this.transaction(()=>{const current=this.meta('client_id');requireValue(current===null||current===clientId,409,'この窓口は別のCRMに接続されています。');this.db.prepare('INSERT OR IGNORE INTO relay_meta VALUES(?,?)').run('client_id',clientId);return this.identity();});}
 requireClient(clientId){requireValue(UUID.test(clientId??'')&&this.meta('client_id')===clientId,409,'CRMの接続先が一致しません。');}
 nonce(value,now){this.transaction(()=>{this.db.prepare('DELETE FROM auth_nonces WHERE expires<?').run(Math.floor(now/1000));requireValue(!this.db.prepare('SELECT 1 FROM auth_nonces WHERE nonce=?').get(value),409,'認証リクエストが再利用されています。');this.db.prepare('INSERT INTO auth_nonces VALUES(?,?)').run(value,Math.floor(now/1000)+600);});}
 appendObservations(registration){
  for(const row of this.db.prepare('SELECT * FROM observations WHERE provider_id=? ORDER BY rowid').all(registration.provider_id)){
   this.db.prepare('INSERT OR IGNORE INTO event_log(kind,send_id,provider_id,source_event_id,body_sha256,received_at) VALUES(?,?,?,?,?,?)').run(row.kind,registration.send_id,row.provider_id,row.event_id,row.body_sha256,row.received_at);
  }
 }
 register(clientId,items,now){
  this.requireClient(clientId);requireValue(Array.isArray(items)&&items.length>0&&items.length<=100);
  return this.transaction(()=>{const rows=[];for(const item of items){
   requireValue(item&&UUID.test(item.sendId??'')&&UUID.test(item.token??'')&&(item.providerId===undefined||item.providerId===null||opaque(item.providerId,512)));
   const old=this.db.prepare('SELECT * FROM registrations WHERE send_id=?').get(item.sendId),other=this.db.prepare('SELECT send_id FROM registrations WHERE token=?').get(item.token);
   requireValue(!other||other.send_id===item.sendId,409,'配信停止の識別子が競合しています。');
   if(old){requireValue(old.token===item.token&&(!old.provider_id||!item.providerId||old.provider_id===item.providerId),409,'保存した送信情報と一致しません。');}
   if(item.providerId){const owner=this.db.prepare('SELECT send_id FROM registrations WHERE provider_id=?').get(item.providerId);requireValue(!owner||owner.send_id===item.sendId,409,'配信結果の識別子が競合しています。');}
   this.db.prepare('INSERT INTO registrations(send_id,token,provider_id,created_at) VALUES(?,?,?,?) ON CONFLICT(send_id) DO UPDATE SET provider_id=COALESCE(registrations.provider_id,excluded.provider_id)').run(item.sendId,item.token,item.providerId??null,new Date(now).toISOString());
   const record=this.db.prepare('SELECT * FROM registrations WHERE send_id=?').get(item.sendId);if(record.provider_id)this.appendObservations(record);
   rows.push({sendId:record.send_id,token:record.token,providerId:record.provider_id,unsubscribedAt:record.unsubscribed_at});
  }return{...this.identity(),registrations:rows};});
 }
 unsubscribe(token,now){requireValue(UUID.test(token??''));return this.transaction(()=>{
  const record=this.db.prepare('SELECT * FROM registrations WHERE token=?').get(token);requireValue(!!record,404,'配信停止リンクが見つかりません。');
  if(!record.unsubscribed_at){const stamp=new Date(now).toISOString();this.db.prepare('UPDATE registrations SET unsubscribed_at=? WHERE send_id=?').run(stamp,record.send_id);this.db.prepare('INSERT INTO event_log(kind,send_id,token,source_event_id,received_at) VALUES(?,?,?,?,?)').run('unsubscribe',record.send_id,token,'unsubscribe/'+token,stamp);}
  return true;
 });}
 webhook(body,headers,secret,now){
  requireValue(verifyWebhook(body,headers,secret,now),401,'署名を確認できません。');const event=json(body);requireValue(event&&typeof event==='object'&&!Array.isArray(event)&&typeof event.type==='string');
  if(event.data!==null&&event.data!==undefined)requireValue(typeof event.data==='object'&&!Array.isArray(event.data));
  const providerId=event?.data?.email_id??event?.data?.message_id;
  if(!kinds.has(event?.type)||!providerId)return'ignored';requireValue(opaque(providerId,512));
  const id=headers['svix-id'],digest=hash(body),stamp=new Date(now).toISOString();
  return this.transaction(()=>{
   const old=this.db.prepare('SELECT body_sha256 FROM webhook_seen WHERE event_id=?').get(id);if(old){requireValue(old.body_sha256===digest,409,'同じ配信結果IDの内容が異なります。');return'duplicate';}
   this.db.prepare('DELETE FROM webhook_seen WHERE event_id IN (SELECT event_id FROM webhook_seen WHERE received_at<? ORDER BY received_at LIMIT 100)').run(new Date(now-30*86400000).toISOString());
   const registration=this.db.prepare('SELECT * FROM registrations WHERE provider_id=?').get(providerId);
   if(!registration&&!this.db.prepare('SELECT 1 FROM observations WHERE provider_id=?').get(providerId)){
    const count=this.db.prepare('SELECT COUNT(DISTINCT o.provider_id) n FROM observations o WHERE NOT EXISTS(SELECT 1 FROM registrations r WHERE r.provider_id=o.provider_id)').get().n;requireValue(count<10000,503,'未照合の配信結果が上限に達しています。');
   }
   this.db.prepare('INSERT INTO webhook_seen VALUES(?,?,?)').run(id,digest,stamp);
   this.db.prepare('INSERT OR IGNORE INTO observations VALUES(?,?,?,?,?)').run(providerId,event.type,id,digest,stamp);
   if(registration)this.appendObservations(registration);
   return registration?'applied':'pending';
  });
 }
 events(clientId,after){this.requireClient(clientId);requireValue(Number.isSafeInteger(after)&&after>=0);return this.transaction(()=>{
  const head=this.head();requireValue(after<=head,409,'受信窓口の履歴がCRMの同期位置より古くなっています。');
  const rows=this.db.prepare('SELECT seq,kind,send_id AS sendId,token,provider_id AS providerId,source_event_id AS sourceEventId,body_sha256 AS bodySHA256,received_at AS receivedAt FROM event_log WHERE seq>? ORDER BY seq LIMIT 100').all(after),cursor=rows.at(-1)?.seq??after;
  return{...this.identity(),events:rows,cursor,hasMore:cursor<head};
 });}
}
function oneHeader(req,name){const values=[];for(let i=0;i<req.rawHeaders.length;i+=2)if(req.rawHeaders[i].toLowerCase()===name)values.push(req.rawHeaders[i+1]);return values.length===1?values[0]:undefined;}
function readBody(req){return new Promise((resolve,reject)=>{let size=0,finished=false;const chunks=[];
 req.on('data',chunk=>{if(finished)return;size+=chunk.length;if(size>MAX_BODY){finished=true;req.pause();reject(new Problem(413,'受信内容が大きすぎます。'));}else chunks.push(chunk);});
 req.on('end',()=>{if(!finished){finished=true;resolve(Buffer.concat(chunks,size));}});req.on('error',e=>{if(!finished){finished=true;reject(e);}});req.on('aborted',()=>{if(!finished){finished=true;reject(new Problem(400,'通信が中断されました。'));}});
 });}
function createHTTPServer({store,authKey,webhookSecret,basePath='',clock=Date.now}){
 const key=signingKey(authKey);requireValue(typeof basePath==='string'&&(basePath===''||basePath.startsWith('/'))&&!/[?#\u0000-\u0020]/.test(basePath),500);
 requireValue(typeof webhookSecret==='string'&&webhookSecret.length<=2048&&/^[A-Za-z0-9+/]+={0,2}$/.test(webhookSecret.replace(/^whsec_/,'')),500,'配信結果の署名キーを設定してください。');
 basePath=basePath.replace(/\/+$/,'');requireValue(!basePath.split('/').includes('..'),500);
 const api=basePath+'/api/native-campaigns/v1/';
 const server=http.createServer({requestTimeout:15000,headersTimeout:5000,keepAliveTimeout:1000,maxHeaderSize:8192},async(req,res)=>{
  let nonce,authenticated=false;
  function reply(status,data,html=false){if(res.destroyed)return;const body=Buffer.from(typeof data==='string'?data:JSON.stringify(data));const h={'Content-Type':html?'text/html; charset=utf-8':typeof data==='string'?'text/plain; charset=utf-8':'application/json; charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",'Content-Length':body.length};if(status>=400)h.Connection='close';if(authenticated)h['X-NextCRM-Signature']=mac(key,'nextcrm-relay-v1-response\n'+nonce+'\n'+status+'\n',body).toString('base64');res.writeHead(status,h);res.end(body);}
  try{
   requireValue(req.url?.startsWith('/')&&!req.url.startsWith('//')&&req.url.length<=4096);const url=new URL(req.url,'http://relay.invalid'),pathname=decodeURIComponent(url.pathname);requireValue(!url.hash);
   const body=await readBody(req),now=clock();
   function authenticate(){
    const timestamp=oneHeader(req,'x-nextcrm-timestamp'),signature=oneHeader(req,'x-nextcrm-signature');nonce=oneHeader(req,'x-nextcrm-nonce');
    requireValue(/^\d{1,12}$/.test(timestamp??'')&&UUID.test(nonce??'')&&Math.abs(Math.floor(now/1000)-Number(timestamp))<=300,401,'認証を確認できません。');
    requireValue(matches(mac(key,'nextcrm-relay-v1-request\n'+req.method+'\n'+req.url+'\n'+timestamp+'\n'+nonce+'\n',body),signature),401,'認証を確認できません。');authenticated=true;store.nonce(nonce,now);
   }
   if(pathname.startsWith(api)){
    authenticate();
    if(pathname===api+'health'&&req.method==='GET'){requireValue(body.length===0);return reply(200,store.identity());}
    if(pathname===api+'bind'&&req.method==='POST'){return reply(200,store.bind(json(body)?.clientId));}
    if(pathname===api+'registrations'&&req.method==='POST'){const data=json(body);return reply(200,store.register(data?.clientId,data?.registrations,now));}
    if(pathname===api+'events'&&req.method==='GET'){
     requireValue(body.length===0&&url.searchParams.getAll('after').length===1&&url.searchParams.getAll('clientId').length===1&&/^(0|[1-9]\d*)$/.test(url.searchParams.get('after')??''));
     return reply(200,store.events(url.searchParams.get('clientId'),Number(url.searchParams.get('after'))));
    }
    throw new Problem(404,'ページが見つかりません。');
   }
   if(pathname===basePath+'/api/campaigns/unsubscribe'){
    requireValue(req.method==='GET',405,'この操作は利用できません。');
    if(url.searchParams.has('check')){
     authenticate();
     requireValue(body.length===0&&url.searchParams.size===2&&url.searchParams.getAll('check').length===1&&url.searchParams.get('check')==='ready'&&url.searchParams.getAll('clientId').length===1);
     const identity=store.identity();requireValue(UUID.test(url.searchParams.get('clientId')??'')&&identity.clientId===url.searchParams.get('clientId'),409,'接続済みのCRMと一致しません。');
     return reply(200,{...identity,unsubscribeReady:true});
    }
    requireValue(url.searchParams.getAll('token').length===1);store.unsubscribe(url.searchParams.get('token'),now);
    return reply(200,'<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>配信停止</title></head><body style="font-family:sans-serif;text-align:center;padding:40px"><h1>配信停止を受け付けました</h1><p>この送信元からの案内メールの配信を停止しました。</p></body></html>',true);
   }
   if(pathname===basePath+'/api/campaigns/webhooks/resend'){
    requireValue(req.method==='POST',405,'この操作は利用できません。');const headers=Object.fromEntries(['svix-id','svix-timestamp','svix-signature'].map(k=>[k,oneHeader(req,k)]));store.webhook(body,headers,webhookSecret,now);return reply(200,{ok:true});
   }
   throw new Problem(404,'ページが見つかりません。');
  }catch(error){reply(error instanceof Problem?error.status:503,{error:error instanceof Problem?error.message:'受信内容を保存できませんでした。時間をおいて再試行してください。'});}
 });server.maxConnections=64;return server;
}
module.exports={RelayStore,createHTTPServer,verifyWebhook,MAX_BODY};
if(require.main===module){
 let store,server;try{
  requireValue(!!process.env.NEXTCRM_RELAY_DATABASE,500,'専用データベースの保存先を設定してください。');
  store=new RelayStore(path.resolve(process.env.NEXTCRM_RELAY_DATABASE));server=createHTTPServer({store,authKey:process.env.NEXTCRM_RELAY_AUTH_KEY,webhookSecret:process.env.RESEND_WEBHOOK_SECRET,basePath:process.env.NEXTCRM_RELAY_BASE_PATH??''});
  const port=Number(process.env.PORT??8787);requireValue(Number.isInteger(port)&&port>=1&&port<=65535,500);
  server.listen(port,'127.0.0.1',()=>console.log(JSON.stringify({ready:true,host:'127.0.0.1',port,instanceId:store.meta('instance_id')})));
  const close=()=>{server.close(()=>{store.close();process.exit(0);});server.closeAllConnections();};process.on('SIGTERM',close);process.on('SIGINT',close);
 }catch(error){try{store?.close();}catch{}console.error(error.message);process.exitCode=1;}
}
