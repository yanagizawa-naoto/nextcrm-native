// Runs the actual installed TypeScript actions. Isolated lazy Prisma promises
// model transactions, nullable FKs and unique constraints; no real DB or network.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),crypto=require('node:crypto'),assert=require('node:assert/strict'),ts=require('typescript');
const root=path.resolve(__dirname,'../..');
const source='app/[locale]/(routes)/admin/crm-settings/_actions/crm-settings.ts';
const watched=[source,'lib/crm/stage-kinds.ts','prisma/schema.prisma','prisma/migrations/0_init/migration.sql','prisma/migrations/20260327000001_crm_settings_db_backed/migration.sql'];
const hashes=Object.fromEntries(watched.map(p=>[p,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,p))).digest('hex')]));
function load(relative,replacements){const filename=path.join(root,relative),m=new Module(filename,module);m.filename=filename;m.paths=Module._nodeModulePaths(path.dirname(filename));const inherited=m.require.bind(m);m.require=n=>Object.hasOwn(replacements,n)?replacements[n]:inherited(n);m._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,filename);return m.exports;}
const specs={industry:['crm_Industry_Type','crm_Accounts','industry','accounts'],contactType:['crm_Contact_Types','crm_Contacts','contact_type_id','contacts'],leadSource:['crm_Lead_Sources','crm_Leads','lead_source_id','leads'],leadStatus:['crm_Lead_Statuses','crm_Leads','lead_status_id','leads'],leadType:['crm_Lead_Types','crm_Leads','lead_type_id','leads'],opportunityType:['crm_Opportunities_Type','crm_Opportunities','type','assigned_opportunities'],salesStage:['crm_Opportunities_Sales_Stages','crm_Opportunities','sales_stage','assigned_opportunities_sales_stage']};
const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0'), old='2025-01-02T03:04:05.000Z', now='2026-11-20T00:00:00.000Z';
const schema=fs.readFileSync(path.join(root,'prisma/schema.prisma'),'utf8');
const kindModule=load('lib/crm/stage-kinds.ts',{});
const scenarios=[];
function scenario(label,kind,op,extra={}){scenarios.push({label,kind,op,role:'admin',status:'ACTIVE',banned:false,name:'  新しい名称  ',id:uid(1),seed:[{id:uid(1),name:'Alpha',v:7,stage_kind:'care',order:3,probability:65},{id:uid(2),name:'Zulu',v:0,stage_kind:null}],references:2,...extra});}
for(const kind of Object.keys(specs)){
 scenario(kind+'-list',kind,'list',{seed:[{id:uid(1),name:'Zulu',v:7,stage_kind:'care',order:3,probability:65},{id:uid(2),name:'Alpha',v:0,stage_kind:null}],references:3});
 scenario(kind+'-create',kind,'create');
 scenario(kind+'-rename',kind,'update');
 scenario(kind+'-delete-used-including-trash',kind,'delete');
 scenario(kind+'-missing-record',kind,'update',{id:uid(777)});
 scenario(kind+'-same-replacement',kind,'delete',{replacementID:uid(1)});
 if(['contactType','leadSource','leadStatus','leadType'].includes(kind)){
  scenario(kind+'-reassign-over-page',kind,'delete',{replacementID:uid(2),references:121});
  scenario(kind+'-reassign-missing',kind,'delete',{replacementID:uid(777)});
  scenario(kind+'-reassign-unused-missing',kind,'delete',{replacementID:uid(777),references:0});
  scenario(kind+'-reassign-rollback',kind,'delete',{replacementID:uid(2),failure:'delete'});
  scenario(kind+'-duplicate',kind,'create',{name:'Alpha'});
 }else scenario(kind+'-unsupported-reassignment',kind,'delete',{replacementID:uid(2)});
}
for(const stageKind of [...kindModule.STAGE_KINDS,null,'wrong'])scenario('stage-'+String(stageKind),'salesStage','update',{stageKind});
scenario('stage-omitted-preserves','salesStage','update');
scenario('stage-create-null','salesStage','create',{stageKind:null});
scenario('nonstage-ignores-invalid-stage','industry','create',{stageKind:'wrong'});
for(const [label,name] of [['empty','  \n\t'],['too-long','x'.repeat(101)],['emoji100','😀'.repeat(100)],['emoji101','😀'.repeat(101)],['decomposed','e\u0301'.repeat(51)],['bom-trim','\ufeff日本語\u3000'],['nel-preserved','\u0085文字\u0085']])scenario('name-'+label,'industry','create',{name});
for(const role of ['manager','user','partner'])for(const op of ['list','create','update','delete'])scenario('denied-'+role+'-'+op,'industry',op,{role,name:''});
scenario('inactive-admin','industry','create',{status:'INACTIVE'});scenario('banned-admin','industry','delete',{banned:true});
scenario('delete-empty-replacement','contactType','delete',{replacementID:''});
scenario('delete-cascade-rollback','salesStage','delete',{failure:'delete'});
scenario('dictionary-pagination','industry','list',{seed:Array.from({length:107},(_,i)=>({id:uid(i+1),name:'Name '+String(i).padStart(3,'0'),v:0})),references:0});
class AuthenticationError extends Error{};class AuthorizationError extends Error{};
let checks=0;
function category(e){if(e instanceof AuthenticationError||e instanceof AuthorizationError||/ログイン|権限/.test(e.message))return'denied';if(e.name==='ZodError'){return e.issues.some(x=>x.message.includes('名称')||x.message.includes('100文字'))?'name':'stage';}if(e.message.includes('differ'))return'same';if(e.message.includes('support'))return'unsupported';return e.message;}
async function run(c){
 const [model,related,fk,countRelation]=specs[c.kind];const block=schema.match(new RegExp('^model '+model+' \\{([\\s\\S]*?)^}','m'))[1];const unique=/name\s+String\s+@unique/.test(block);let rows=c.seed.map(r=>{const value={id:r.id,name:r.name,v:r.v};if(c.kind==='salesStage')Object.assign(value,{stage_kind:r.stage_kind??null,probability:r.probability??null,order:r.order??null});if(c.kind==='opportunityType')value.order=r.order??null;return value;}),refs=Array.from({length:c.references},(_,i)=>({id:uid(1000+i),value:uid(1),updatedAt:old,deletedAt:i%2?old:null})),revalidated=[];
 class Lazy{constructor(f){this.f=f;}then(resolve,reject){return Promise.resolve().then(this.f).then(resolve,reject);}}
 const lazy=f=>new Lazy(f);let serial=9000;
 function checkUnique(name,except){if(unique&&rows.some(r=>r.name===name&&r.id!==except))throw Error('unique');}
 const dict={findMany:async()=>[...rows].sort((a,b)=>Buffer.compare(Buffer.from(a.name),Buffer.from(b.name))).map(r=>({...r,_count:{[countRelation]:refs.filter(x=>x.value===r.id).length}})),create:({data})=>lazy(()=>{checkUnique(data.name);const row={id:uid(++serial),name:data.name,v:data.v};if(c.kind==='salesStage')Object.assign(row,{stage_kind:data.stage_kind??null,probability:null,order:null});if(c.kind==='opportunityType')row.order=null;rows.push(row);return row;}),update:({where,data})=>lazy(()=>{const row=rows.find(r=>r.id===where.id);if(!row)throw Error('missing');checkUnique(data.name,row.id);Object.assign(row,data);return row;}),delete:({where})=>lazy(()=>{if(c.failure==='delete')throw Error('injected');const row=rows.find(r=>r.id===where.id);if(!row)throw Error('missing');rows=rows.filter(r=>r.id!==where.id);refs.forEach(r=>{if(r.value===where.id)r.value=null;});return row;})};
 const relatedModel={updateMany:({where,data})=>lazy(()=>{const targets=refs.filter(r=>r.value===where[fk]);if(targets.length&&!rows.some(r=>r.id===data[fk]))throw Error('fk');targets.forEach(r=>Object.assign(r,{value:data[fk],updatedAt:now}));return{count:targets.length};})};
 const prisma={[model]:dict,[related]:relatedModel,$transaction:async operations=>{const before=structuredClone({rows,refs});try{const values=[];for(const operation of operations)values.push(await operation);return values;}catch(e){rows=before.rows;refs=before.refs;throw e;}}};
 const actions=load(source,{'@/lib/prisma':{prismadb:prisma},'next/cache':{revalidatePath:(...args)=>revalidated.push(args)},'@/lib/authz':{AuthenticationError,AuthorizationError,requireRole:async()=>{if(c.status!=='ACTIVE'||c.banned)throw new AuthenticationError();if(c.role!=='admin')throw new AuthorizationError();return{id:uid(5000),role:c.role};}},'@/lib/crm/stage-kinds':kindModule});
 let result, error=null;
 try{if(c.op==='list')result=await actions.getConfigValues(c.kind);if(c.op==='create')await actions.createConfigValue(c.kind,c.name,...(Object.hasOwn(c,'stageKind')?[c.stageKind]:[]));if(c.op==='update')await actions.updateConfigValue(c.kind,c.id,c.name,...(Object.hasOwn(c,'stageKind')?[c.stageKind]:[]));if(c.op==='delete')await actions.deleteConfigValue(c.kind,c.id,c.replacementID);}catch(e){error=category(e);}
 if(error)assert.equal(revalidated.length,0);else if(c.op!=='list')assert.deepEqual(revalidated,[['/','layout']]);checks++;
 const normalizeID=id=>id===uid(9001)?'created':id;
 rows=rows.map(r=>({...r,id:normalizeID(r.id)})).sort((a,b)=>a.id.localeCompare(b.id));
 refs=refs.map(r=>({...r,updatedAt:r.updatedAt===old?'original':'changed'}));
 return {...c,stageProvided:Object.hasOwn(c,'stageKind'),expected:{error,rows,refs,list:result??null,revalidationCount:revalidated.length}};
}
(async()=>{const cases=[];for(const c of scenarios)cases.push(await run(c));const output={sourceHashes:hashes,stageKinds:kindModule.STAGE_KINDS,old,checks,cases,limitations:['Prisma is an isolated relational adapter, not live PostgreSQL. Nullable SET NULL is grounded in checked-in SQL migrations; collation fixture uses binary names and is not a claim of all PostgreSQL locale equivalence.','Source actions emit no domain events or audit call; native CRUD audit/hooks are separately checked as host integration.']};fs.writeFileSync(process.argv[2],JSON.stringify(output));console.log(JSON.stringify({sourceCases:cases.length,sourceChecks:checks}));})().catch(e=>{console.error(e.stack);process.exit(1);});
