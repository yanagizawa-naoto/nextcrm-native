'use strict';
// Executes locked original TS with explicit synthetic env and database boundaries.
// Does not inspect process.env, dotenv, a real database, Keychain, or the network.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),Module=require('node:module'),ts=require('typescript');
const root=path.resolve(__dirname,'../..'), hashes={};
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const serverKey=Buffer.from(Array.from({length:32},(_,i)=>i+1)),handoffKey=Buffer.from(Array.from({length:32},(_,i)=>255-i));
function environment({stored=null,key=serverKey.toString('hex')}={}) {
 let nonce=0;const updates=[],warnings=[];const cache=new Map();
 function load(relative) {
  const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file).exports;
  const module={exports:{}};cache.set(file,module);const source=fs.readFileSync(file,'utf8');hashes[relative]=hash(Buffer.from(source));
  const req=name=>{
   if(name==='crypto')return {...crypto,randomBytes:n=>crypto.createHash('sha256').update('synthetic-original-'+(++nonce)).digest().subarray(0,n)};
   if(name==='./prisma'||name==='@/lib/prisma')return {prismadb:{systemServices:{findFirst:async()=>stored===null?null:{id:'synthetic-row',serviceKey:stored},update:async args=>{updates.push(args);return args.data;}}}};
   if(name==='./env-secret')return {envSecret:()=>undefined};
   if(name==='resend')return {Resend:class {constructor(){throw Error('not-used');}}};
   if(name.startsWith('@/'))return load(name.slice(2)+'.ts');
   if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),name))+'.ts');
   return Module.createRequire(file)(name);
  };
  const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText;
  new Function('exports','require','module','__filename','__dirname','process','console',code)(module.exports,req,module,file,path.dirname(file),{env:{EMAIL_ENCRYPTION_KEY:key}},{log:()=>warnings.push('redacted'),error:()=>warnings.push('redacted')});return module.exports;
 }
 return {load,updates,warnings};
}
async function makeReference(output){
 fs.mkdirSync(output,{recursive:true,mode:0o700});const env=environment(),email=env.load('lib/email-crypto.ts'),plugins=env.load('lib/plugins/settings.ts');
 const cases=[];
 for(const plaintext of ['synthetic-key-123','日本語の合成パスワード😀','','control\nvalue','nul\u0000value','x'.repeat(65536)]){
  const ciphertext=email.encrypt(plaintext);cases.push({family:'email-crypto',plaintext,ciphertext,decoded:email.decrypt(ciphertext)});
 }
 for(const ciphertext of [cases[0].ciphertext.replace(/(.{9})/g,'$1\n'),cases[0].ciphertext.replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''),cases[0].ciphertext.replace(/=+$/,'')])cases.push({family:'email-crypto',ciphertext,decoded:email.decrypt(ciphertext)});
 for(const values of [{},{apiKey:'synthetic-plugin',unknownBusiness:{items:['日本語',1,true]}},{password:'synthetic-odoo',token:'synthetic-oxo'}]){
  const ciphertext=plugins.encryptSecrets(values);cases.push({family:'plugins',values,ciphertext,decoded:plugins.decryptSecrets(ciphertext)});
 }
 const broken=['garbage',Buffer.alloc(27).toString('base64'),cases[0].ciphertext.slice(0,-4)+'AAAA'];
 for(const ciphertext of broken){let rejected=false;try{email.decrypt(ciphertext)}catch{rejected=true;}let warning=0;cases.push({family:'invalid',ciphertext,rejected,pluginFallback:plugins.decryptSecrets(ciphertext,()=>warning++),warning});}
 for(const stored of [null,'legacy-synthetic-resend', 'enc:'+email.encrypt('encrypted-synthetic-resend')]){
  const e=environment({stored}),resend=e.load('lib/resend.ts'),decoded=await resend.getResendApiKey();cases.push({family:'resend',stored,decoded,updates:e.updates.length,upgraded:e.updates[0]?.data.serviceKey??null});
 }
 for(const key of ['', '0'.repeat(63), 'z'.repeat(64)]){const e=environment({stored:'legacy-survives-key-unavailable',key}),resend=e.load('lib/resend.ts');cases.push({family:'resend-invalid-key',decoded:await resend.getResendApiKey(),updates:e.updates.length,warnings:e.warnings.length});}
 const result={syntheticOnly:true,serverKeyHex:serverKey.toString('hex'),handoffKeyHex:handoffKey.toString('hex'),cases,sourceSHA256:hashes,limits:['Original source executes with injected synthetic process.env and in-memory Prisma boundary. No live environment, PostgreSQL, provider or real secret used.','Original plugin corrupt-cipher fallback is {}, migration intentionally keeps encrypted original as held instead of discarding it.']};
 fs.writeFileSync(path.join(output,'reference.json'),JSON.stringify(result,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify({sourceCases:cases.length,sourceFiles:Object.keys(hashes).length}));return result;
}
module.exports={environment,makeReference,serverKey,handoffKey};
if(require.main===module)makeReference(process.argv[2]).catch(()=>{console.error('Synthetic credential source oracle failed');process.exitCode=1});
