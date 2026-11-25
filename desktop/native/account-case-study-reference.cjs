// Actual original action + auth-server/session/role/scope/audit implementations.
// Only session transport, in-memory Prisma boundary and Next cache are injected.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto'),ts=require('typescript');
const root=path.resolve(__dirname,'../..'),source='actions/crm/accounts/case-study.ts';
const watched=new Map(),hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
function load(relative,replace,cache=new Map()) {
 const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file).exports;
 const m=new Module(file,module);m.filename=file;m.paths=Module._nodeModulePaths(path.dirname(file));cache.set(file,m);watched.set(path.relative(root,file),hash(file));const old=m.require.bind(m);
 m.require=name=>{if(Object.hasOwn(replace,name))return replace[name];if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),name))+'.ts',replace,cache);if(name.startsWith('@/'))return load(name.slice(2)+'.ts',replace,cache);return old(name)};
 m._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,file);return m.exports;
}
const uid=n=>'10000000-0000-4000-8000-'+String(n).padStart(12,'0'),actor=uid(1),other=uid(2),account=uid(3),stamp='2026-11-20T00:00:00.000Z';
const scenarios=[];
function add(label,operation,value,extra={}) {scenarios.push({label,operation,value,role:'user',status:'ACTIVE',banned:false,scope:'assigned',candidate:false,approved:false,deleted:false,...extra})}
for(const operation of ['candidate','approved'])for(const candidate of [false,true])for(const approved of [false,true])for(const value of [false,true])add(`${operation}-${candidate}-${approved}-${value}`,operation,value,{role:operation==='approved'?'manager':'user',candidate,approved});
for(const scope of ['created','watcher','none'])add('candidate-scope-'+scope,'candidate',true,{scope});
for(const role of ['user','partner','manager','admin'])for(const operation of ['candidate','approved'])add(operation+'-role-'+role,operation,true,{role,scope:'none',candidate:true});
for(const operation of ['candidate','approved']) {
 add(operation+'-missing',''+operation,true,{role:'admin',missing:true});add(operation+'-deleted',operation,true,{role:'admin',deleted:true});
 add(operation+'-no-session',operation,true,{role:'admin',noSession:true});add(operation+'-deleted-user',operation,true,{role:'admin',missingUser:true});
 add(operation+'-inactive',operation,true,{role:'admin',status:'INACTIVE'});add(operation+'-pending',operation,true,{role:'admin',status:'PENDING'});
 add(operation+'-banned',operation,true,{role:'admin',banned:true});add(operation+'-audit-failure',operation,true,{role:'admin',candidate:true,auditFailure:true});
}
(async()=>{
 const cases=[];
 for(const s of scenarios) {
  let row=s.missing?null:{id:account,name:'導入事例の確認',case_study_candidate:s.candidate,case_study_approved:s.approved,deletedAt:s.deleted?stamp:null,assigned_to:s.scope==='assigned'?actor:other,createdBy:s.scope==='created'?actor:other,updatedBy:null};
  const audits=[],queries=[],updates=[],revalidations=[];
  function match(where) {if(!row)return false;return Object.entries(where).every(([k,v])=>{if(k==='OR')return v.some(match);if(k==='watchers')return s.scope==='watcher'&&v.some.user_id===actor;return row[k]===v})}
  const prisma={users:{findUnique:async()=>s.missingUser?null:{id:actor,role:s.role}},crm_Accounts:{findFirst:async q=>{queries.push(q);return match(q.where)?structuredClone(row):null},update:async q=>{updates.push(q);row={...row,...q.data};return structuredClone(row)}},crm_AuditLog:{create:async q=>{if(s.auditFailure)throw Error('synthetic audit failure');audits.push(q.data);return q.data}}};
  const replace={'@/lib/prisma':{prismadb:prisma},'@/lib/auth':{auth:{api:{getSession:async()=>s.noSession||s.banned?null:{user:{id:actor,role:s.role,userStatus:s.status}}}}},'next/headers':{headers:async()=>({})},'next/cache':{revalidatePath:(...args)=>revalidations.push(args)}};
  const cache=new Map();const session=load('lib/authz/session.ts',replace,cache),scope=load('lib/authz/scopes/crm.ts',replace,cache),errors=load('lib/authz/errors.ts',replace,cache);
  replace['@/lib/authz']={...session,...scope,...errors};const action=load(source,replace,cache);const saved=console.error;console.error=()=>{};let result;
  try {result=await (s.operation==='candidate'?action.setCaseStudyCandidate:action.setCaseStudyApproved)(account,s.value)} finally {console.error=saved}
  cases.push({input:s,result,account:row,audits,updates,revalidations,queries});
 }
 watched.set('app/[locale]/(routes)/crm/accounts/[accountId]/components/CaseStudyCard.tsx',hash(path.join(root,'app/[locale]/(routes)/crm/accounts/[accountId]/components/CaseStudyCard.tsx')));
 watched.set('prisma/schema.prisma',hash(path.join(root,'prisma/schema.prisma')));
 const output={cases,sourceHashes:Object.fromEntries(watched),limits:['Synthetic auth transport supplies session-or-null; actual original auth-server/session/scopes/roles execute. Banned session-null is transport fixture, not a live BetterAuth endpoint test.','Prisma adapter preserves predicates and actions but is not live PostgreSQL. Native transaction/CAS/mandatory audit behavior is tested separately.']};
 fs.writeFileSync(process.argv[2],JSON.stringify(output,null,2)+'\n');console.log(JSON.stringify({cases:cases.length,sourceFiles:watched.size}));
})().catch(e=>{console.error(e);process.exit(1)});
