'use strict';
// External Calendly receiver; never started by the Mac application.
const {DatabaseSync}=require('node:sqlite');
const crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const MAX_BODY=1024*1024,MAX_PAGE=2*1024*1024,UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
class Problem extends Error{constructor(status,message){super(message);this.status=status;}}
function requireValue(value,status=400,message='受信内容が不正です。'){if(!value)throw new Problem(status,message);}
function authBytes(value){requireValue(typeof value==='string'&&value.length===43&&/^[A-Za-z0-9_-]{43}$/.test(value),500,'受信窓口の認証キーを確認してください。');const bytes=Buffer.from(value,'base64url');requireValue(bytes.length===32,500);return bytes;}
function digest(bytes){return crypto.createHash('sha256').update(bytes).digest('hex');}
function mac(key,prefix,body){return crypto.createHmac('sha256',key).update(prefix).update(body).digest();}
function matches(actual,encoded){if(typeof encoded!=='string'||encoded.length>128||!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))return false;const value=Buffer.from(encoded,'base64');return value.length===actual.length&&crypto.timingSafeEqual(value,actual);}
function json(body){try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(body));}catch{throw new Problem(400,'受信したJSONが不正です。');}}
function verifyCalendly(body,header,key,now){
 if(!Buffer.isBuffer(body)||typeof header!=='string'||header.length>8192||typeof key!=='string'||!key||Buffer.byteLength(key)>16384||!Number.isFinite(now))return false;
 const parts=Object.fromEntries(header.split(',').map(p=>p.trim().split('=',2))),t=parts.t,v1=parts.v1;
 if(!t||typeof v1!=='string'||v1.length!==64||!/^[a-f0-9]{64}$/.test(v1)||!(Math.abs(now/1000-Number(t))<=180))return false;
 return crypto.timingSafeEqual(Buffer.from(v1,'hex'),mac(Buffer.from(key),t+'.',body));
}
class CalendarRelayStore{
 constructor(filename,authKey){
  this.authKey=authBytes(authKey);this.storageKey=Buffer.from(crypto.hkdfSync('sha256',this.authKey,Buffer.from('nextcrm-calendar-relay-v1'),Buffer.from('stored-records'),32));
  const parent=path.dirname(filename);fs.mkdirSync(parent,{recursive:true,mode:0o700});requireValue((fs.statSync(parent).mode&0o022)===0,500,'専用の保存フォルダを指定してください。');
  let prior;try{prior=fs.lstatSync(filename);}catch(e){if(e.code!=='ENOENT')throw e;}if(prior)requireValue(prior.isFile()&&!prior.isSymbolicLink(),500,'保存先が不正です。');
  this.db=new DatabaseSync(filename,{timeout:5000});try{
   const tables=this.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all();requireValue(!tables.length||tables.some(x=>x.name==='calendar_relay_meta'),500,'別の用途のデータベースは使用できません。');
   if(tables.length)requireValue(this.meta('version')==='1',500,'受信窓口の形式を確認してください。');
   fs.chmodSync(filename,0o600);this.db.exec('PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-1024; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;');
   this.db.exec(`CREATE TABLE IF NOT EXISTS calendar_relay_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS calendar_receipts(seq INTEGER PRIMARY KEY AUTOINCREMENT,body_sha256 TEXT NOT NULL UNIQUE,body_bytes INTEGER NOT NULL,encrypted_body TEXT NOT NULL,signature TEXT NOT NULL,received_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS calendar_nonces(nonce TEXT PRIMARY KEY,expires INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS calendar_nonces_expiry ON calendar_nonces(expires);`);
   this.transaction(()=>{this.db.prepare('INSERT OR IGNORE INTO calendar_relay_meta VALUES(?,?)').run('version','1');this.db.prepare('INSERT OR IGNORE INTO calendar_relay_meta VALUES(?,?)').run('instance_id',crypto.randomUUID());
    if(this.meta('key_check')===null)this.setMeta('key_check',this.seal(Buffer.from('nextcrm-calendar-relay-v1'),'key-check'));
    requireValue(this.open(this.meta('key_check'),'key-check').toString()==='nextcrm-calendar-relay-v1',500,'受信窓口の認証キーが保存済みのデータと一致しません。');});
  }catch(error){this.db.close();throw error;}
 }
 seal(data,context){const iv=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',this.storageKey,iv);cipher.setAAD(Buffer.from(context));const encrypted=Buffer.concat([cipher.update(data),cipher.final()]);return Buffer.concat([iv,cipher.getAuthTag(),encrypted]).toString('base64');}
 open(encoded,context){try{const data=Buffer.from(encoded,'base64'),decipher=crypto.createDecipheriv('aes-256-gcm',this.storageKey,data.subarray(0,12));decipher.setAAD(Buffer.from(context));decipher.setAuthTag(data.subarray(12,28));return Buffer.concat([decipher.update(data.subarray(28)),decipher.final()]);}catch{throw new Problem(503,'保存済みの通知を復号できません。認証キーと保存データを確認してください。');}}
 meta(key){return this.db.prepare('SELECT value FROM calendar_relay_meta WHERE key=?').get(key)?.value??null;}
 setMeta(key,value){this.db.prepare('INSERT INTO calendar_relay_meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key,value);}
 transaction(fn){this.db.exec('BEGIN IMMEDIATE');try{const value=fn();this.db.exec('COMMIT');return value;}catch(error){this.db.exec('ROLLBACK');throw error;}}
 close(){this.db.close();}
 head(){return this.db.prepare('SELECT COALESCE(MAX(seq),0) n FROM calendar_receipts').get().n;}
 identity(){return{version:1,...this.db.prepare("SELECT (SELECT value FROM calendar_relay_meta WHERE key='instance_id') instanceId,(SELECT value FROM calendar_relay_meta WHERE key='client_id') clientId,(SELECT COALESCE(MAX(seq),0) FROM calendar_receipts) head,(SELECT value FROM calendar_relay_meta WHERE key='key_generation') keyGeneration,(SELECT value FROM calendar_relay_meta WHERE key='signing_key_fingerprint') signingKeyFingerprint").get()};}
 requireClient(clientId){requireValue(UUID.test(clientId??'')&&this.meta('client_id')===clientId,409,'接続先のCRMが一致しません。');}
 bind(clientId){requireValue(UUID.test(clientId??''));return this.transaction(()=>{const prior=this.meta('client_id');requireValue(prior===null||prior===clientId,409,'この窓口は別のCRMに接続されています。');this.setMeta('client_id',clientId);return this.identity();});}
 configure(clientId,signingKey,expectedGeneration){
  this.requireClient(clientId);requireValue(typeof signingKey==='string'&&Buffer.byteLength(signingKey)>0&&Buffer.byteLength(signingKey)<=16384&&!/[\u0000-\u001f\u007f]/.test(signingKey));
  requireValue(expectedGeneration===null||UUID.test(expectedGeneration??''));
  return this.transaction(()=>{const fingerprint=digest(Buffer.from(signingKey));if(this.meta('signing_key_fingerprint')===fingerprint)return this.identity();requireValue(this.meta('key_generation')===expectedGeneration,409,'署名の設定が変更されています。再読み込みしてください。');
   const generation=crypto.randomUUID();this.setMeta('signing_key',this.seal(Buffer.from(signingKey),'signing-key'));this.setMeta('key_generation',generation);this.setMeta('signing_key_fingerprint',fingerprint);return this.identity();});
 }
 nonce(value,now){return this.transaction(()=>{this.db.prepare('DELETE FROM calendar_nonces WHERE expires<?').run(Math.floor(now/1000));requireValue(!this.db.prepare('SELECT 1 FROM calendar_nonces WHERE nonce=?').get(value),409,'認証リクエストが再利用されています。');this.db.prepare('INSERT INTO calendar_nonces VALUES(?,?)').run(value,Math.floor(now/1000)+600);});}
 receive(body,signature,now){
  const encrypted=this.meta('signing_key');requireValue(encrypted!==null&&this.meta('client_id')!==null,503,'予約連携が設定されていません。');
  requireValue(verifyCalendly(body,signature,this.open(encrypted,'signing-key').toString(),now),401,'通知の署名を確認できません。');
  let value;try{value=json(body);}catch{return{ok:true,ignored:true};}
  if(!value||!['invitee.created','invitee.canceled'].includes(value.event)||typeof value.payload?.uri!=='string'||!value.payload.uri||typeof value.payload?.scheduled_event?.start_time!=='string'||!value.payload.scheduled_event.start_time)return{ok:true,ignored:true};
  const hash=digest(body);return this.transaction(()=>{const prior=this.db.prepare('SELECT seq FROM calendar_receipts WHERE body_sha256=?').get(hash);if(prior)return{ok:true,duplicate:true};
   this.db.prepare('INSERT INTO calendar_receipts(body_sha256,body_bytes,encrypted_body,signature,received_at) VALUES(?,?,?,?,?)').run(hash,body.length,this.seal(body,'event:'+hash),signature,new Date(now).toISOString());return{ok:true};});
 }
 events(clientId,after){
  return this.transaction(()=>{
  this.requireClient(clientId);requireValue(Number.isSafeInteger(after)&&after>=0);const head=this.head();requireValue(after<=head,409,'受信履歴が巻き戻っています。保存データを確認してください。');
  const candidates=this.db.prepare('SELECT seq FROM calendar_receipts WHERE seq>? ORDER BY seq LIMIT 100').all(after);let bytes=2048,cursor=after;const events=[];
  for(const candidate of candidates){if(events.length>0&&bytes>=MAX_PAGE)break;const row=this.db.prepare('SELECT * FROM calendar_receipts WHERE seq=?').get(candidate.seq),body=this.open(row.encrypted_body,'event:'+row.body_sha256);requireValue(body.length===row.body_bytes&&digest(body)===row.body_sha256,503,'保存した通知が破損しています。');
   const event={seq:row.seq,body:body.toString('base64'),bodySHA256:row.body_sha256,signature:row.signature,receivedAt:row.received_at},size=Buffer.byteLength(JSON.stringify(event))+1;
   if(events.length>0 && bytes+size>MAX_PAGE)break;events.push(event);bytes+=size;cursor=row.seq;
  }
  return{...this.identity(),head,events,cursor,hasMore:cursor<head};});
 }
}
function oneHeader(req,name){const values=[];for(let i=0;i<req.rawHeaders.length;i+=2)if(req.rawHeaders[i].toLowerCase()===name)values.push(req.rawHeaders[i+1]);return values.length===1?values[0]:undefined;}
function readBody(req,maximum=MAX_BODY){return new Promise((resolve,reject)=>{let count=0,finished=false;const chunks=[];req.on('data',chunk=>{if(finished)return;count+=chunk.length;if(count>maximum){finished=true;req.pause();reject(new Problem(413,'受信内容が大きすぎます。'));}else chunks.push(chunk);});req.on('end',()=>{if(!finished){finished=true;try{resolve(Buffer.concat(chunks,count));}catch{reject(new Problem(503,'受信内容を処理できません。空き容量を確認してください。'));}}});for(const event of ['error','aborted'])req.on(event,()=>{if(!finished){finished=true;reject(new Problem(400,'通信が中断されました。'));}});});}
function createHTTPServer({store,basePath='',clock=Date.now}){
 requireValue(typeof basePath==='string'&&(basePath===''||basePath.startsWith('/'))&&!/[?#\u0000-\u0020]/.test(basePath),500);basePath=basePath.replace(/\/+$/,'');requireValue(!basePath.split('/').includes('..'),500);
 const api=basePath+'/api/native-calendly/v1/',callback=basePath+'/api/crm/calendar/webhooks/calendly';
 const server=http.createServer({requestTimeout:15000,headersTimeout:5000,keepAliveTimeout:1000,maxHeaderSize:12288},async(req,res)=>{
  let nonce,authenticated=false;
  function reply(status,value){if(res.destroyed)return;const data=Buffer.from(JSON.stringify(value));const headers={'Content-Type':'application/json; charset=utf-8','Content-Length':data.length,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};if(status>=400)headers.Connection='close';if(authenticated)headers['X-NextCRM-Signature']=mac(store.authKey,'nextcrm-calendar-v1-response\n'+nonce+'\n'+status+'\n',data).toString('base64');res.writeHead(status,headers);res.end(data);}
  try{
   requireValue(req.url?.startsWith('/')&&!req.url.startsWith('//')&&req.url.length<=4096);const url=new URL(req.url,'http://relay.invalid'),pathname=decodeURIComponent(url.pathname);requireValue(!url.hash);const body=await readBody(req,pathname===callback&&req.method==='POST' ? Number.MAX_SAFE_INTEGER:MAX_BODY),now=clock();
   function authenticate(){const timestamp=oneHeader(req,'x-nextcrm-timestamp');nonce=oneHeader(req,'x-nextcrm-nonce');requireValue(/^\d{1,12}$/.test(timestamp??'')&&UUID.test(nonce??'')&&Number.isFinite(now)&&Math.abs(Math.floor(now/1000)-Number(timestamp))<=300,401,'認証を確認できません。');requireValue(matches(mac(store.authKey,'nextcrm-calendar-v1-request\n'+req.method+'\n'+req.url+'\n'+timestamp+'\n'+nonce+'\n',body),oneHeader(req,'x-nextcrm-signature')),401,'認証を確認できません。');authenticated=true;store.nonce(nonce,now);}
   if(pathname.startsWith(api)){
    authenticate();
    if(pathname===api+'health'&&req.method==='GET'){requireValue(!body.length&&!url.search);return reply(200,store.identity());}
    if(pathname===api+'bind'&&req.method==='POST'){requireValue(!url.search);return reply(200,store.bind(json(body)?.clientId));}
    if(pathname===api+'signing-key'&&req.method==='POST'){requireValue(!url.search);const value=json(body);return reply(200,store.configure(value?.clientId,value?.signingKey,value?.expectedGeneration));}
    if(pathname===api+'events'&&req.method==='GET'){requireValue(!body.length&&url.searchParams.size===2&&url.searchParams.getAll('after').length===1&&url.searchParams.getAll('clientId').length===1&&/^(0|[1-9]\d*)$/.test(url.searchParams.get('after')??''));return reply(200,store.events(url.searchParams.get('clientId'),Number(url.searchParams.get('after'))));}
    throw new Problem(404,'ページが見つかりません。');
   }
   if(pathname===callback){
    if(req.method==='GET'&&url.searchParams.has('check')){authenticate();requireValue(!body.length&&url.searchParams.size===2&&url.searchParams.get('check')==='ready');store.requireClient(url.searchParams.get('clientId'));return reply(200,{...store.identity(),callbackReady:store.meta('key_generation')!==null});}
    requireValue(req.method==='POST',405,'この操作は利用できません。');requireValue(!url.search||(url.searchParams.size===1&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(url.searchParams.get('subscription')??'')));return reply(200,store.receive(body,oneHeader(req,'calendly-webhook-signature'),now));
   }
   throw new Problem(404,'ページが見つかりません。');
  }catch(error){reply(error instanceof Problem?error.status:503,{error:error instanceof Problem?error.message:'予約通知を保存できませんでした。時間をおいて再試行してください。'});}
 });server.maxConnections=32;return server;
}
module.exports={CalendarRelayStore,createHTTPServer,verifyCalendly,MAX_BODY,MAX_PAGE};
if(require.main===module){let store,server;try{requireValue(!!process.env.NEXTCRM_CALENDAR_RELAY_DATABASE,500,'専用データベースの保存先を設定してください。');store=new CalendarRelayStore(path.resolve(process.env.NEXTCRM_CALENDAR_RELAY_DATABASE),process.env.NEXTCRM_CALENDAR_RELAY_AUTH_KEY);server=createHTTPServer({store,basePath:process.env.NEXTCRM_CALENDAR_RELAY_BASE_PATH??''});const port=Number(process.env.PORT??8788);requireValue(Number.isInteger(port)&&port>=1&&port<=65535,500);server.listen(port,'127.0.0.1',()=>console.log(JSON.stringify({ready:true,host:'127.0.0.1',port,instanceId:store.meta('instance_id')})));const close=()=>{server.close(()=>{store.close();process.exit(0);});server.closeAllConnections();};process.on('SIGTERM',close);process.on('SIGINT',close);}catch(error){try{store?.close();}catch{}console.error(error.message);process.exitCode=1;}}
