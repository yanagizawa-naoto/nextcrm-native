// Run the original schedule actions, including their owner/manager/shared rules.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),cache=new Map(),hashes={};let active,rows=[],sequence=0;
const base=JSON.parse(fs.readFileSync(path.join(__dirname,'build/report-configs-reference.json'),'utf8')),users=base.users;
const configs=base.configs.filter(c=>c.category==='sales').map(c=>({...c,id:'schedule-'+c.id}));
const schedules=users.map((u,i)=>({id:'schedule-fixture-'+i,reportConfigId:configs.find(c=>c.isShared).id,cronExpression:'0 9 * * 1',recipients:['recipient@example.invalid'],format:'pdf',createdBy:u.id,isActive:true}));
const matches=(row,where={})=>Object.entries(where).every(([k,v])=>row[k]===v);
const prisma={crm_Report_Config:{findUnique:async({where})=>configs.find(c=>c.id===where.id)??null},crm_Report_Schedule:{
 findUnique:async({where})=>rows.find(r=>r.id===where.id)??null,findMany:async({where})=>rows.filter(r=>matches(r,where)),
 create:async({data})=>{const row={id:'created-'+(++sequence),...data};rows.push(row);return row},
 update:async({where,data})=>Object.assign(rows.find(r=>r.id===where.id),data),delete:async({where})=>rows.splice(rows.findIndex(r=>r.id===where.id),1)[0]
}};
function load(relative){const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file);const source=fs.readFileSync(file,'utf8');hashes[relative]=crypto.createHash('sha256').update(source).digest('hex');const module={exports:{}};cache.set(file,module.exports);
 const requireStub=name=>{if(name==='@/lib/prisma')return{prismadb:prisma};if(name==='@/lib/authz')return{...load('lib/authz/roles.ts'),...load('lib/authz/errors.ts'),requireAuthenticated:async()=>{if(!active)throw Error('authentication');return active}};throw Error(name)};
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module,exports:module.exports,require:requireStub},{filename:file,timeout:2000});return module.exports;}
(async()=>{const api=load('actions/reports/schedule.ts'),scopes=[],creates=[],lists=[];
 for(const user of users){active=user;rows=structuredClone(schedules);lists.push({user:user.id,ids:(await api.listSchedules()).map(x=>x.id)});
  for(const cfg of configs){rows=[];let allowed;try{const r=await api.createSchedule({reportConfigId:cfg.id,cronExpression:'0 9 * * 1',recipients:['recipient@example.invalid'],format:'pdf'});if(r.createdBy!==user.id)throw Error('owner mismatch');allowed=true}catch(error){if(error.message==='owner mismatch')throw error;allowed=false}creates.push({user:user.id,config:cfg.id,allowed})}
  for(const schedule of schedules){const result={user:user.id,schedule:schedule.id};for(const [name,run] of Object.entries({update:()=>api.updateSchedule(schedule.id,{isActive:false}),delete:()=>api.deleteSchedule(schedule.id)})){rows=structuredClone(schedules);try{await run();result[name]=true}catch{result[name]=false}}scopes.push(result)}
 }
 const output={users,configs,schedules,lists,creates,scopes,hashes};fs.writeFileSync(path.join(__dirname,'build/report-schedules-reference.json'),JSON.stringify(output));console.log(JSON.stringify({suite:'actual TypeScript report schedules',creates:creates.length,scopes:scopes.length,lists:lists.length}));
})().catch(error=>{console.error(error);process.exit(1)});
