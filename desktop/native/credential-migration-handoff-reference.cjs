'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {createCredentialHandoff}=require('./credential-migration-handoff.cjs');
const {makeReference,serverKey,handoffKey,environment}=require('./credential-migration-reference.cjs');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');let checks=0;
const check=(v,message)=>{assert(v,message);checks++;};
const reject=async f=>{let failed=false;try{await f();}catch{failed=true;}check(failed,'must reject');};
function read(file,key){
 const b=fs.readFileSync(file);let at=0;function take(n){assert(n>=0&&n<=b.length-at);const r=b.subarray(at,at+n);at+=n;return r;}
 assert.equal(take(8).toString(),'NCRMSEC1');const raw=take(take(4).readUInt32BE()),h=JSON.parse(raw),headerHash=hash(raw);
 const derived=Buffer.from(crypto.hkdfSync('sha256',key,Buffer.from(h.salt,'base64'),Buffer.from('nextcrm-credential-handoff/v1'),32));
 const entries=[],stream=crypto.createHash('sha256');
 while(at<b.length){const start=at,type=take(1)[0],aSize=take(4).readUInt32BE(),n=Number(take(8).readBigUInt64BE());assert(n<=8*1024*1024&&aSize<=65536);const aad=take(aSize),a=JSON.parse(aad),nonce=take(12),cipher=take(n),tag=take(16);assert.equal(a.headerSHA256,headerHash);assert.equal(a.index,entries.length);const d=crypto.createDecipheriv('aes-256-gcm',derived,nonce);d.setAAD(aad);d.setAuthTag(tag);const plaintext=Buffer.concat([d.update(cipher),d.final()]);
  if(type===255){const seal=JSON.parse(plaintext);assert.equal(seal.entries,entries.length);assert.equal(seal.entryStreamSHA256,stream.digest('hex'));assert.equal(at,b.length);return{header:h,entries};}
  assert.equal(type,1);stream.update(b.subarray(start,at));assert.equal(a.valueSHA256,hash(plaintext));entries.push({aad:a,plaintext});
 }throw Error('seal missing');
}
async function main(output){
 output=path.resolve(output);
 fs.mkdirSync(output,{recursive:true,mode:0o700});fs.chmodSync(output,0o700);const reference=await makeReference(output);const crypt=environment().load('lib/email-crypto.ts');
 const id=n=>'e7000000-0000-4000-8000-'+String(n).padStart(12,'0');
 const specs=[
  ['ApiKeys',id(10),'encryptedKey',crypt.encrypt('synthetic-openai-key')],
  ['EmailAccount',id(11),'passwordEncrypted',crypt.encrypt('合成メールパスワード')],
  ['InstalledPlugin','odoo-connector','secrets',crypt.encrypt('{"password":"synthetic-odoo","unknownBusiness":{"note":"保持する"}}')],
  ['systemServices',id(12),'serviceKey','enc:'+crypt.encrypt('synthetic-resend-key')],
  ['systemServices',id(13),'serviceKey','legacy-synthetic-resend'],
  ['CalendarConnection',id(14),'refreshTokenEncrypted',crypt.encrypt('synthetic-refresh-token')],
  ['CalendarConnection',id(14),'accessTokenEncrypted',crypt.encrypt('synthetic-access-token')],
  ['crm_SystemSettings','calendly_api_token','value',crypt.encrypt('synthetic-calendly-token')],
  ['crm_SystemSettings','calendly_signing_key','value',crypt.encrypt('synthetic-calendly-signing')],
  ['PluginData',id(15),'value',' { "business" : [1, 2], "unknownToken" : "preserve-synthetic" }\n','opaque-json'],
  ['Session',id(16),'token','synthetic-session-never-activate'],
  ['Documents',id(17),'document_file_url','https://fixture.invalid/object?signature=synthetic','credential-url']
 ];
 const items=specs.map(([model,id,field,value,kind='credential'])=>({kind,owner:{model,key:{[model==='crm_SystemSettings'?'key':'id']:id},field},originalBytes:Buffer.from(value),valueSHA256:hash(Buffer.from(value)),classification:kind==='credential'?'known-secret':kind==='opaque-json'?'operator-hold':'url-credential'}));
 const root=path.join(output,'handoff');fs.mkdirSync(root,{mode:0o700});const writer=createCredentialHandoff({key:handoffKey});const schemaSHA256=reference.sourceSHA256['prisma/schema.prisma']??hash(fs.readFileSync(path.resolve(__dirname,'../../prisma/schema.prisma')));
 await writer.begin({output:root,schemaSHA256,snapshotID:'synthetic-snapshot-1'});const refs=[];
 for(const item of items)refs.push(await writer.capture(item));
 const descriptor=await writer.seal(),file=path.join(root,descriptor.path),decoded=read(file,handoffKey);
 check(decoded.entries.length===items.length,'all original held values preserved');check(descriptor.entries===items.length&&descriptor.bytes===fs.statSync(file).size&&descriptor.sha256===hash(fs.readFileSync(file)),'descriptor integrity');
 for(let i=0;i<items.length;i++){check(decoded.entries[i].plaintext.equals(items[i].originalBytes),'exact original bytes');check(decoded.entries[i].aad.entryID===refs[i].entryID,'entry reference');check(!fs.readFileSync(file).includes(items[i].originalBytes),'no original plaintext bytes');}
 await writer.abort();check(fs.existsSync(file),'sealed artifact owned by bundle, not writer abort');await reject(()=>writer.capture(items[0]));await reject(()=>writer.seal());
 await reject(()=>read(file,Buffer.alloc(32,8)));
 const changed=Buffer.from(fs.readFileSync(file));changed[changed.length-20]^=1;fs.writeFileSync(path.join(output,'tampered'),changed,{mode:0o600});await reject(()=>read(path.join(output,'tampered'),handoffKey));
 fs.writeFileSync(path.join(output,'truncated'),changed.subarray(0,changed.length-64),{mode:0o600});await reject(()=>read(path.join(output,'truncated'),handoffKey));
 const existing=createCredentialHandoff({key:handoffKey});await reject(()=>existing.begin({output:root,schemaSHA256,snapshotID:'synthetic-snapshot-1'}));await existing.abort();check(hash(fs.readFileSync(file))===descriptor.sha256,'preexisting result never overwritten/removed');
 const cancelled=path.join(output,'cancelled');fs.mkdirSync(cancelled,{mode:0o700});const cancel=createCredentialHandoff({key:handoffKey});await cancel.begin({output:cancelled,schemaSHA256,snapshotID:'synthetic'});await cancel.capture(items[0]);await cancel.abort();await cancel.abort();check(fs.readdirSync(cancelled).length===0,'abort removes only owned incomplete file');
 const replaced=path.join(output,'replaced');fs.mkdirSync(replaced,{mode:0o700});const replace=createCredentialHandoff({key:handoffKey});await replace.begin({output:replaced,schemaSHA256,snapshotID:'synthetic'});const target=path.join(replaced,'credentials.handoff');fs.renameSync(target,path.join(replaced,'owned-renamed'));fs.writeFileSync(target,'foreign sentinel',{mode:0o600});await replace.abort();check(fs.readFileSync(target,'utf8')==='foreign sentinel','abort preserves replacement inode');
 const linked=path.join(output,'linked');fs.symlinkSync(root,linked);const link=createCredentialHandoff({key:handoffKey});await reject(()=>link.begin({output:linked,schemaSHA256,snapshotID:'synthetic'}));await link.abort();
 const bad=path.join(output,'invalid');fs.mkdirSync(bad,{mode:0o700});const invalid=createCredentialHandoff({key:handoffKey});await invalid.begin({output:bad,schemaSHA256,snapshotID:'synthetic'});
 for(const item of [{...items[0],owner:{key:{id:'x'}}},{...items[0],valueSHA256:'0'.repeat(64)},{...items[0],originalBytes:Buffer.alloc(8*1024*1024+1)}])await reject(()=>invalid.capture(item));await invalid.abort();
 const stress=[];
 for(const [label,count] of [['large',1],['many',1000]]){
  const dir=path.join(output,label);fs.mkdirSync(dir,{mode:0o700});const w=createCredentialHandoff({key:handoffKey});await w.begin({output:dir,schemaSHA256,snapshotID:'synthetic-'+label});let lastHash;
  for(let i=0;i<count;i++){const bytes=label==='large'?Buffer.from('"'+'x'.repeat(8*1024*1024-2)+'"'):Buffer.from('{"business":"synthetic-'+i+'"}');lastHash=hash(bytes);await w.capture({kind:'opaque-json',owner:{model:'PluginData',key:{id:id(1000+i)},field:'value'},originalBytes:bytes,valueSHA256:lastHash,classification:'operator-hold'});bytes.fill(0);}
  const sealed=await w.seal();check(sealed.entries===count,'bounded archive count');stress.push({label,descriptor:sealed,lastHash,snapshotID:'synthetic-'+label});
 }
 fs.writeFileSync(path.join(output,'handoff-fixture.json'),JSON.stringify({descriptor,schemaSHA256,snapshotID:'synthetic-snapshot-1',refs,stress,items:items.map(i=>({...i,originalBytes:i.originalBytes.toString('base64')}))},null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify({handoffChecks:checks,entries:items.length,sourceCases:reference.cases.length}));
}
module.exports={read,main};if(require.main===module)main(process.argv[2]).catch(error=>{console.error(JSON.stringify({failure:'synthetic-handoff',checks,name:error.name,frames:String(error.stack).split('\n').filter(x=>x.trim().startsWith('at ')).slice(0,3)}));process.exitCode=1});
