// Original app auth configuration + installed BetterAuth signed-cookie/session
// implementation. Prisma and unrelated external email boundaries are isolated.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto'),assert=require('node:assert/strict'),ts=require('typescript');
const root=path.resolve(__dirname,'../..'),RealDate=Date,epoch='2026-11-19T12:00:00.000Z';
global.Date=class extends RealDate{constructor(...args){super(...(args.length?args:[epoch]));}static now(){return new RealDate(epoch).getTime();}};
const secret='isolated-session-fixture-secret-with-64-characters-only-for-tests-001';
const secure=process.argv.includes('--secure'),cookieName=(secure?'__Secure-':'')+'better-auth.session_token';
Object.assign(process.env,{NODE_ENV:'test',BETTER_AUTH_SECRET:secret,BETTER_AUTH_URL:(secure?'https':'http')+'://fixture.invalid',NEXTCRM_DESKTOP:'0',GOOGLE_ID:'synthetic-client',GOOGLE_SECRET:'synthetic-google-secret'});
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`,reference=JSON.parse(fs.readFileSync(path.join(__dirname,'build/mcp-reports-reference.json'),'utf8'));
const userSeeds=reference.seeds.Users.filter(u=>Number(u.id.slice(-12))<=6).map(u=>({...u,created_on:new Date(u.created_on),updated_at:new Date(u.updated_at)}));
const sessionSeeds=[{id:uid(900),token:'isolated-session-token-001',userId:uid(3),createdAt:new Date(epoch),updatedAt:new Date(epoch),expiresAt:new Date(Date.now()+7*86400000),ipAddress:null,userAgent:null,impersonatedBy:null}];
let users,sessions,cookie,reads=[],writes=[],hashes={},cache=new Map();
function eq(a,b){return a instanceof RealDate||b instanceof RealDate?+new Date(a)===+new Date(b):a===b;}
function match(r,w={}){return Object.entries(w).every(([k,v])=>{if(k==='AND')return (Array.isArray(v)?v:[v]).every(x=>match(r,x));if(k==='OR')return v.some(x=>match(r,x));if(v&&typeof v==='object'&&!(v instanceof RealDate)){return Object.entries(v).every(([op,b])=>{if(op==='equals')return eq(r[k],b);if(op==='in')return b.some(x=>eq(r[k],x));if(op==='lt')return r[k]<b;if(op==='gte')return r[k]>=b;if(op==='lte')return r[k]<=b;throw Error('Unsupported '+op);});}return eq(r[k],v);});}
function project(model,row,args){if(!row)return null;const result={...row};if(args.include)for(const[k,v]of Object.entries(args.include)){if(model==='Session'&&k==='user')result[k]=users.find(u=>u.id===row.userId)??null;else throw Error('Unhandled relation '+model+'.'+k);}
if(args.select)return Object.fromEntries(Object.entries(args.select).map(([k,v])=>[k,result[k]]));return result;}
function delegate(model,rows){return {findFirst:async(a={})=>{reads.push({model,op:'findFirst',args:a});return project(model,rows().find(r=>match(r,a.where)),a);},findUnique:async(a={})=>{reads.push({model,op:'findUnique',args:a});return project(model,rows().find(r=>match(r,a.where)),a);},findMany:async(a={})=>{reads.push({model,op:'findMany',args:a});return rows().filter(r=>match(r,a.where)).map(r=>project(model,r,a));},update:async a=>{writes.push({model,op:'update',args:a});const row=rows().find(r=>match(r,a.where));assert.ok(row);Object.assign(row,a.data);return {...row};},updateMany:async a=>{writes.push({model,op:'updateMany',args:a});let count=0;for(const row of rows())if(match(row,a.where)){Object.assign(row,a.data);count++;}return{count};},delete:async a=>{writes.push({model,op:'delete',args:a});const i=rows().findIndex(r=>match(r,a.where));if(i<0)throw Error('missing delete');return rows().splice(i,1)[0];},deleteMany:async a=>{writes.push({model,op:'deleteMany',args:a});const old=rows().length;for(let i=rows().length-1;i>=0;i--)if(match(rows()[i],a.where))rows().splice(i,1);return {count:old-rows().length};},count:async(a={})=>rows().filter(r=>match(r,a.where)).length};}
const db={users:delegate('Users',()=>users),session:delegate('Session',()=>sessions)};db.Users=db.users;db.Session=db.session;db.$transaction=async f=>f(db);
function load(relative){let f=path.resolve(root,relative);if(!fs.existsSync(f))f=f.replace(/\.ts$/,'/index.ts');assert.ok(f.startsWith(root+'/')&&f.endsWith('.ts'));if(cache.has(f))return cache.get(f).exports;const source=fs.readFileSync(f,'utf8'),mod=new Module(f,module);cache.set(f,mod);mod.filename=f;hashes[path.relative(root,f)]=crypto.createHash('sha256').update(source).digest('hex');mod.require=name=>{
 if(name==='@/lib/prisma'||name==='./prisma-base')return{prismadb:db,prismaBase:db};
 if(name==='@/lib/new-user-notify')return{newUserNotify:async()=>{throw Error('unused notify');}};
 if(name==='@/lib/resend')return{default:async()=>{throw Error('external mail forbidden');}};
 if(name==='@/lib/plugins/i18n')return{translatePluginMessage:()=>{throw Error('unused plugin translation');}};
 if(name==='next/headers')return{headers:async()=>new Headers(cookie?{cookie}: {})};
 if(name==='next/server')return{NextResponse:{json:()=>{throw Error('unused response');}}};
 if(name==='server-only')return{};
 if(name.startsWith('@/'))return load(name.slice(2)+'.ts');if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(f),name+'.ts')));
 return Module.createRequire(path.join(root,'package.json'))(name);
 };mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,f);return mod.exports;}
function sign(token,key=secret){return encodeURIComponent(token+'.'+crypto.createHmac('sha256',key).update(token).digest('base64'));}
(async()=>{
 const cases=[],requests=[],add=(label,options={})=>requests.push({label,...options});
 const token=sessionSeeds[0].token;
 for(const user of [1,2,3,4,5,6])add('cookie role/status '+user,{owner:uid(user)});
 for(const change of [{role:'admin',banned:true},{role:'manager',banned:true,banExpires:new Date(Date.now()-1)},{role:'manager',userStatus:'PENDING'}])add('current user properties',{userChange:change});
 for(const ms of [-1,0,1,86400000,6*86400000,6*86400000+1,7*86400000])add('expiry/refresh boundary '+ms,{expiry:ms});
 add('banned session refresh due',{expiry:86400000,userChange:{banned:true}});add('inactive session refresh due',{expiry:86400000,userChange:{userStatus:'INACTIVE'}});add('partner session refresh due',{expiry:86400000,userChange:{role:'partner'}});
 add('invalid signature cannot clean up expired session',{expiry:-1,raw:sign(token,'wrong secret')});
 add('session revoked',{removeSession:true});add('owner deleted',{removeOwner:true});
 for(const value of [null,'',sign(token,'wrong secret'),'plain-token',sign('unknown-token'),sign(token).replace(/.$/,'x')])add('cookie absent/invalid',{raw:value});
 for(const [label,header]of [
 ['duplicate valid then bad',cookieName+'='+sign(token)+'; '+cookieName+'=bad'],
 ['duplicate bad then valid',cookieName+'=bad; '+cookieName+'='+sign(token)],
 ['quoted',cookieName+'="'+sign(token)+'"'],
 ['whitespace',' x=y; '+cookieName+' = '+sign(token)+' ; z=w'],
 ['unescaped base64',cookieName+'='+decodeURIComponent(sign(token))],
 ['case sensitive key','Better-Auth.session_token='+sign(token)],
 ['broken percent',cookieName+'=%XX'+sign(token)],
 ['encoded key','better-auth%2Esession_token='+sign(token)],
 ['extra semicolons',';;; ignored ; '+cookieName+'='+sign(token)],
 ['wrong cookie prefix',(secure?'better-auth.session_token':'__Secure-better-auth.session_token')+'='+sign(token)]])add(label,{header});
 const rawSigned=decodeURIComponent(sign(token)), alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', at=rawSigned.length-2;
 for(let delta=1;delta<=3;delta++)add('noncanonical base64 padding bits '+delta,{raw:encodeURIComponent(rawSigned.slice(0,at)+alphabet[alphabet.indexOf(rawSigned[at])+delta]+rawSigned.slice(at+1))});
 add('permissive unmatched quote',{header:cookieName+'="'+sign(token)+'x'});
 add('dont remember invalid signature',{expiry:86400000,header:cookieName+'='+sign(token)+'; '+(secure?'__Secure-':'')+'better-auth.dont_remember=invalid'});
 for(const value of ['true','false','0',''])add('dont remember '+value,{expiry:86400000,dontRemember:value});
 for(const suffix of ['.dot','日本語',';=value','%encoded',' spaces '])add('signed token content',{token:token+suffix});
 for(const bearer of [1,3,4])for(const owner of [1,3,4,5,6])add('independent bearer/cookie',{bearer:uid(bearer),owner:uid(owner)});
 const auth=load('lib/auth.ts').auth,tools=load('lib/mcp/tools/reports.ts').reportTools,{runMcpToolCall}=load('lib/mcp/run-tool.ts');
 for(const q of requests){users=userSeeds.map(x=>({...x}));sessions=sessionSeeds.map(x=>({...x}));const session=sessions[0];session.userId=q.owner??uid(3);if(q.token)session.token=q.token;if(q.expiry!==undefined)session.expiresAt=new Date(Date.now()+q.expiry);if(q.userChange)Object.assign(users.find(u=>u.id===session.userId),q.userChange);if(q.removeOwner){users=users.filter(u=>u.id!==session.userId);sessions=[];}if(q.removeSession)sessions=[];
 cookie=q.header??(q.raw===null?null:cookieName+'='+(q.raw??sign(session.token)));if(q.dontRemember!==undefined)cookie+='; '+(secure?'__Secure-':'')+'better-auth.dont_remember='+sign(q.dontRemember);
 reads=[];writes=[];const bearer=users.find(u=>u.id===(q.bearer??uid(4)))??{id:uid(4),role:'admin'},tool=tools.find(t=>t.name==='reports_run'),input=tool.schema.parse({category:'users',dateFrom:'2026-01-01T00:00:00Z',dateTo:'2026-12-31T23:59:59Z'});
 const before={users:structuredClone(users),sessions:structuredClone(sessions)};
 const result=await runMcpToolCall(async()=>({id:bearer.id,role:bearer.role}),u=>tool.handler(input,u.id,u));
 cases.push({request:q,cookie,bearer:{id:bearer.id,role:bearer.role},before,result,after:{users,sessions},reads,writes});
 }
 for(const name of ['prisma/schema.prisma','node_modules/better-auth/package.json','node_modules/better-auth/dist/api/routes/session.mjs','node_modules/better-auth/dist/cookies/index.mjs','node_modules/better-auth/dist/db/internal-adapter.mjs','node_modules/.pnpm/better-call@1.4.4_zod@4.6.7/node_modules/better-call/dist/context.cjs','node_modules/.pnpm/better-call@1.4.4_zod@4.6.7/node_modules/better-call/dist/cookies.cjs','node_modules/.pnpm/better-call@1.4.4_zod@4.6.7/node_modules/better-call/dist/crypto.cjs','node_modules/.pnpm/better-call@1.4.4_zod@4.6.7/node_modules/better-call/dist/context.mjs','node_modules/.pnpm/better-call@1.4.4_zod@4.6.7/node_modules/better-call/dist/cookies.mjs','node_modules/.pnpm/better-call@1.4.4_zod@4.6.7/node_modules/better-call/dist/crypto.mjs','node_modules/.pnpm/better-call@1.4.4_zod@4.6.7/node_modules/better-call/dist/utils.mjs'])hashes[name]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,name))).digest('hex');
 fs.writeFileSync(process.argv[2]??path.join(__dirname,'build/mcp-session-auth-reference.json'),JSON.stringify({epoch,secret,baseURL:process.env.BETTER_AUTH_URL,secure,cases,sourceSHA256:hashes},null,2)+'\n');
 console.log(JSON.stringify({cases:cases.length,secure,provider:'BetterAuth1.7.14/better-call1.4.4 actual app configuration'}));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
