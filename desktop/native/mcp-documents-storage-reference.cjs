// Isolated original binary-provider execution. No network or normal app data.
const fs=require('node:fs'),fsp=require('node:fs/promises'),path=require('node:path'),os=require('node:os'),Module=require('node:module'),crypto=require('node:crypto'),assert=require('node:assert/strict'),ts=require('typescript');
const root=path.resolve(__dirname,'../..'),sourceFile=path.join(root,'lib/local-storage.ts'),source=fs.readFileSync(sourceFile,'utf8');
function load(){const m=new Module(sourceFile,module);m.filename=sourceFile;m.require=n=>{assert.ok(n.startsWith('node:'));return require(n);};m._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,sourceFile);return m.exports;}
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');
(async()=>{
 const directory=await fsp.mkdtemp(path.join(os.tmpdir(),'nextcrm-mcp-document-provider-'));
 Object.assign(process.env,{MINIO_BUCKET:'fixture-bucket',NEXTCRM_STORAGE_DIR:directory,NEXTCRM_DESKTOP:'1',NEXTCRM_STORAGE_MODE:'local'});
 try{
  const storage=load(),cases=[],block=Buffer.from(Array.from({length:65537},(_,i)=>i%251));
  for(const[label,contentType,repeat]of[['empty','text/plain',0],['binary','application/pdf',20],['opaque-key','application/custom',1]]){
   const key=label==='opaque-key'?'../日本語/space%+?#/key.dat':'documents/'+label+'.dat';
   const expected=crypto.createHash('sha256');for(let i=0;i<repeat;i++)expected.update(block);
   const put=await storage.putLocalObject(key,(async function*(){for(let i=0;i<repeat;i++)yield block;})(),contentType),read=await storage.getLocalObject(key),received=crypto.createHash('sha256');let bytes=0;
   for await(const chunk of read.Body){received.update(chunk);bytes+=chunk.length;}
   const digest=expected.digest('hex');assert.equal(put.ETag,'"'+digest+'"');assert.equal(read.ContentType,contentType);assert.equal(read.ContentLength,block.length*repeat);assert.equal(received.digest('hex'),digest);
   cases.push({label,key,contentType,bytes,sha256:digest,ETag:put.ETag});
  }
  const key='documents/replaced.txt';await storage.putLocalObject(key,'old','text/plain');const old=await storage.getLocalObject(key);await storage.putLocalObject(key,'new\0bytes','application/custom');const current=await storage.getLocalObject(key);
  assert.equal(Buffer.from(await old.Body.transformToByteArray()).toString(),'old');assert.equal(Buffer.from(await current.Body.transformToByteArray()).toString(),'new\0bytes');
  cases.push({label:'replace-keeps-open-inode',oldSHA256:hash(Buffer.from('old')),newSHA256:hash(Buffer.from('new\0bytes')),newType:current.ContentType,newBytes:current.ContentLength});
  const interrupted='documents/interrupted.txt';let rejected=false;
  try{await storage.putLocalObject(interrupted,(async function*(){yield block;throw Error('synthetic interruption');})(),'text/plain');}catch{rejected=true;}assert.ok(rejected);
  let missing=false;try{await storage.getLocalObject(interrupted);}catch(e){missing=e.code==='ENOENT';}assert.ok(missing);
  async function files(dir){const out=[];for(const entry of await fsp.readdir(dir,{withFileTypes:true})){const p=path.join(dir,entry.name);if(entry.isDirectory())out.push(...await files(p));else out.push(p);}return out;}
  assert.ok((await files(directory)).every(p=>!p.endsWith('.tmp')));cases.push({label:'interrupted-no-object-or-temp',missing:true});
  await storage.deleteLocalObject('documents/empty.dat');await storage.deleteLocalObject('documents/empty.dat');cases.push({label:'idempotent-object-delete',deleted:true});
  for(const type of['text/plain\r\ninjected','a'.repeat(257)]){let invalid=false;try{await storage.putLocalObject('documents/invalid.dat','',type);}catch{invalid=true;}assert.ok(invalid);}cases.push({label:'invalid-type-before-publication',rejected:true});
  const result={cases,sourceSHA256:{'lib/local-storage.ts':hash(Buffer.from(source))},scope:'Actual original binary object put/get/delete; isolated temporary files, no network or normal app data.'};
  fs.writeFileSync(process.argv[2],JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({sourceBinaryProviderCases:cases.length,temporaryFilesRemoved:true}));
 }finally{await fsp.rm(directory,{recursive:true,force:true});}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
