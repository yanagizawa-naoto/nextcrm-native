// Execute the original action with captured Prisma queries and a fixed clock.
// No database, credentials, or external request is used.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),dayjs=require('dayjs');
const root=path.resolve(__dirname,'../..');
const filename=path.join(root,'actions/projects/get-tasks-past-due.ts');
const code=ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,esModuleInterop:true}}).outputText;
function matches(row,where){
  if(where.AND && !where.AND.every(w=>matches(row,w)))return false;
  for(const [key,value] of Object.entries(where)){
    if(key==='AND')continue;
    if(key==='user' && row.user!==value)return false;
    if(key==='taskStatus' && (row.taskStatus===null || row.taskStatus===value.not))return false;
    if(key==='dueDateAt'){
      if(row.dueDateAt===null)return false;
      const a=Date.parse(row.dueDateAt);
      for(const [op,b] of Object.entries(value))if(!({lte:a<=+b,gt:a>+b,lt:a<+b}[op]))return false;
    }
  }
  return true;
}
(async()=>{
 const contexts=[];
 for(const zone of ['Asia/Tokyo','UTC','America/Los_Angeles'])for(const stamp of ['2026-03-07T20:30:00.000Z','2026-11-01T10:30:00.000Z']){
  process.env.TZ=zone;const now=new Date(stamp);const captures=[];let currentRole='user';
  class FixedDate extends Date{constructor(...args){super(...(args.length?args:[now.getTime()]));}static now(){return now.getTime();}}
  const exports={};const ctx={exports,Date:FixedDate,require(id){
   if(id==='@/lib/prisma')return {prismadb:{tasks:{async findMany(query){captures.push(query.where);return [];}}}};
   if(id==='@/lib/authz')return {requireAuthenticated:async()=>({id:'actor',role:currentRole}),isUnhandledRole:u=>!['user','manager','admin'].includes(u.role),AuthenticationError:class extends Error{}};
   if(id==='dayjs')return (...args)=>dayjs(args.length?args[0]:now);
   throw new Error('Unexpected import '+id);
  }};
  vm.runInNewContext(code,ctx,{filename});await exports.getTasksPastDue();
  const start=+captures[1].AND.find(x=>x.dueDateAt).dueDateAt.gt,end=+captures[1].AND.find(x=>x.dueDateAt).dueDateAt.lt;
  const due=[start-1,start,start+1,+now-1,+now,+now+1,end-1,end,end+1,null];
  const rows=[];for(const d of due)for(const taskStatus of ['ACTIVE','PENDING','COMPLETE',null])for(const user of ['actor','other'])rows.push({name:'row-'+rows.length,user,taskStatus,dueDateAt:d===null?null:new Date(d).toISOString()});
  const expected={};for(const role of ['user','manager','admin','partner']){
   currentRole=role;captures.length=0;await exports.getTasksPastDue();
   expected[role]=captures.length?{overdue:rows.filter(r=>matches(r,captures[0])).map(r=>r.name),week:rows.filter(r=>matches(r,captures[1])).map(r=>r.name)}:null;
  }
  contexts.push({zone,now:stamp,start:new Date(start).toISOString(),end:new Date(end).toISOString(),rows,expected});
 }
 fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,'build/project-tasks-reference.json'),JSON.stringify(contexts));
 console.log(JSON.stringify({contexts:contexts.length,rows:contexts.reduce((a,c)=>a+c.rows.length,0),source:'actions/projects/get-tasks-past-due.ts',zones:['Asia/Tokyo','UTC','America/Los_Angeles']}));
})().catch(e=>{console.error(e);process.exit(1);});
