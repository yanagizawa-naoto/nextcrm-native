'use strict';
// Explicit-key, one-shot encrypted snapshot handoff. No environment reads.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const MAGIC=Buffer.from('NCRMSEC1'), MAX_VALUE=8*1024*1024, MAX_AAD=65536;
const INFO=Buffer.from('nextcrm-credential-handoff/v1');
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
const fail=code=>{throw new Error('credential.handoff.'+code)};
function all(fd,b){let at=0;while(at<b.length){const n=fs.writeSync(fd,b,at,b.length-at);if(n<=0)fail('write');at+=n;}}
function u32(n){const b=Buffer.alloc(4);b.writeUInt32BE(n);return b;}
function u64(n){const b=Buffer.alloc(8);b.writeBigUInt64BE(BigInt(n));return b;}
function ownerValid(o){return o&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).sort().join(',')==='field,key,model'&&typeof o.model==='string'&&typeof o.field==='string'&&/^[A-Za-z_][A-Za-z0-9_]*$/.test(o.model)&&/^[A-Za-z_][A-Za-z0-9_]*$/.test(o.field)&&o.key&&typeof o.key==='object'&&!Array.isArray(o.key)&&Object.keys(o.key).length>0&&Object.keys(o.key).length<=16&&Object.entries(o.key).every(([k,v])=>/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)&&(typeof v==='string'||typeof v==='boolean')&&(typeof v!=='string'||Buffer.byteLength(v)<=4096));}
function createCredentialHandoff({key}) {
 if(!Buffer.isBuffer(key)||key.length!==32)fail('key');
 const inputKey=Buffer.from(key);let derived,fd=-1,rootfd=-1,rootPath,identity,header,headerHash,stream,fileDigest,bytes=0,count=0,state='new';const ancestors=[];
 const write=b=>{if(!Number.isSafeInteger(bytes+b.length))fail('size');all(fd,b);fileDigest.update(b);bytes+=b.length;};
 function close(){if(fd>=0){fs.closeSync(fd);fd=-1;}for(const pin of ancestors.splice(0).reverse())fs.closeSync(pin.fd);rootfd=-1;}
 function current(){for(const pin of ancestors){const held=fs.fstatSync(pin.fd),named=fs.lstatSync(pin.path);if(!named.isDirectory()||named.dev!==held.dev||named.ino!==held.ino||held.dev!==pin.dev||held.ino!==pin.ino)fail('ancestor_changed');}}
 function pin(output){
  if(!path.isAbsolute(output)||output.split('/').some(x=>x==='.'||x==='..'))fail('directory');
  // Only the fixed, root-owned macOS aliases are normalized. Arbitrary user
  // symlinks remain forbidden. Node has no openat: retain/check all ancestors.
  for(const [alias,target] of [['/var','/private/var'],['/tmp','/private/tmp']])if(output===alias||output.startsWith(alias+'/')){const s=fs.lstatSync(alias);if(s.isSymbolicLink()&&s.uid===0&&path.resolve('/',fs.readlinkSync(alias))===target)output=target+output.slice(alias.length);}
  const parts=output.split('/').filter(Boolean);let named='/';
  for(const component of [null,...parts]){if(component)named=path.join(named,component);const f=fs.openSync(named,fs.constants.O_RDONLY|fs.constants.O_DIRECTORY|fs.constants.O_NOFOLLOW),s=fs.fstatSync(f);ancestors.push({fd:f,path:named,dev:s.dev,ino:s.ino});}
  rootPath=named;rootfd=ancestors.at(-1).fd;current();
 }
 function frame(type,aad,plain){
  const encoded=Buffer.from(JSON.stringify(aad));if(encoded.length>MAX_AAD||plain.length>MAX_VALUE)fail('limit');
  const nonce=Buffer.alloc(12);nonce.writeBigUInt64BE(BigInt(count),4);
  const cipher=crypto.createCipheriv('aes-256-gcm',derived,nonce);cipher.setAAD(encoded,{plaintextLength:plain.length});
  const recordHash=type===1?stream:null;
  const put=b=>{write(b);recordHash?.update(b);};
  put(Buffer.from([type]));put(u32(encoded.length));put(u64(plain.length));put(encoded);put(nonce);
  for(let at=0;at<plain.length;at+=65536)put(cipher.update(plain.subarray(at,at+65536)));
  put(cipher.final());put(cipher.getAuthTag());
 }
 return {
  async begin({output,schemaSHA256,snapshotID}) {
   if(state!=='new'||typeof output!=='string'||!/^[a-f0-9]{64}$/.test(schemaSHA256)||typeof snapshotID!=='string'||!snapshotID||Buffer.byteLength(snapshotID)>4096)fail('begin');
   state='starting';
   try {
    pin(output);
    const root=fs.fstatSync(rootfd);if(root.uid!==process.getuid()||(root.mode&0o077)!==0)fail('directory');
    fd=fs.openSync(path.join(rootPath,'credentials.handoff'),fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_NOFOLLOW,0o600);
    const st=fs.fstatSync(fd);identity={dev:st.dev,ino:st.ino};
    current();fileDigest=crypto.createHash('sha256');
    const salt=crypto.randomBytes(16);header={version:1,handoffID:crypto.randomUUID(),schemaSHA256,snapshotID,salt:salt.toString('base64')};
    derived=Buffer.from(crypto.hkdfSync('sha256',inputKey,salt,INFO,32));inputKey.fill(0);
    const encoded=Buffer.from(JSON.stringify(header));headerHash=digest(encoded);stream=crypto.createHash('sha256');
    write(MAGIC);write(u32(encoded.length));write(encoded);state='open';
   } catch {state='failed';throw new Error('credential.handoff.begin');}
  },
  async capture({kind,owner,originalBytes,valueSHA256,classification}) {
   if(state!=='open')fail('state');
   if(!['credential','opaque-json','credential-url'].includes(kind)||!ownerValid(owner)||!['known-secret','operator-hold','url-credential'].includes(classification)||!Buffer.isBuffer(originalBytes)||originalBytes.length>MAX_VALUE||digest(originalBytes)!==valueSHA256)fail('entry');
   if(!Number.isSafeInteger(count+1))fail('count');
   const entryID=crypto.randomUUID();
   try {current();frame(1,{version:1,headerSHA256:headerHash,index:count,entryID,kind,owner,valueSHA256,classification},originalBytes);current();count++;}
   catch {state='failed';throw new Error('credential.handoff.write');}
   return {version:1,handoffID:header.handoffID,entryID,valueSHA256};
  },
  async seal(){
   if(state!=='open')fail('state');
   try {
    const seal=Buffer.from(JSON.stringify({entries:count,entryStreamSHA256:stream.digest('hex')}));
    frame(255,{version:1,headerSHA256:headerHash,index:count,type:'seal'},seal);seal.fill(0);fs.fsyncSync(fd);
    fs.closeSync(fd);fd=-1;
    current();const expected=fileDigest.digest('hex');const read=fs.openSync(path.join(rootPath,'credentials.handoff'),fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
    let hash;try {const st=fs.fstatSync(read);if(st.dev!==identity.dev||st.ino!==identity.ino||st.size!==bytes)fail('changed');const h=crypto.createHash('sha256'),buffer=Buffer.alloc(65536);let n;while((n=fs.readSync(read,buffer))>0)h.update(buffer.subarray(0,n));hash=h.digest('hex');}finally{fs.closeSync(read);}
    if(hash!==expected)fail('changed');current();fs.fsyncSync(rootfd);close();derived.fill(0);state='sealed';
    return {version:1,handoffID:header.handoffID,path:'credentials.handoff',entries:count,bytes,sha256:hash};
   }catch {state='failed';throw new Error('credential.handoff.seal');}
  },
  async abort(){
   // Never remove another attempt's replacement file; after seal M06 owns it.
   if(state==='sealed'||state==='aborted')return;
   if(fd>=0){try{fs.closeSync(fd)}finally{fd=-1;}}
   if(rootfd>=0&&identity){try{current();const p=path.join(rootPath,'credentials.handoff'),st=fs.lstatSync(p);if(st.isFile()&&st.dev===identity.dev&&st.ino===identity.ino)fs.unlinkSync(p);}catch(error){if(error.code!=='ENOENT'){close();derived?.fill(0);inputKey.fill(0);state='aborted';throw new Error('credential.handoff.abort');}}}
   close();derived?.fill(0);inputKey.fill(0);state='aborted';
  }
 };
}
module.exports={createCredentialHandoff,MAGIC,MAX_VALUE,INFO};
