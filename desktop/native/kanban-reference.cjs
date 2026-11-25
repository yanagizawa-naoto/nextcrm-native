// Exercise the original action using in-memory Prisma, never a network call.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const file=path.resolve(__dirname,'../../actions/projects/update-kanban-position.ts');
const source=fs.readFileSync(file,'utf8');
const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
(async()=>{
 const cases=[];
 for(const same of [true,false])for(const sourceCount of [1,3])for(const destinationCount of (same?[0]:[0,2]))for(let from=0;from<sourceCount;from++)for(let to=0;to<=(same?sourceCount-1:destinationCount);to++){
  const src=Array.from({length:sourceCount},(_,i)=>'s'+i),dst=Array.from({length:destinationCount},(_,i)=>'d'+i);
  const moved=src[from],remaining=src.filter(x=>x!==moved),target=same?remaining:dst.slice(),before=target[to]??null;
  target.splice(to,0,moved);const resource=same?target:remaining;
  const rows=new Map([...src.map((id,i)=>[id,{id,section:'src',position:sourceCount-1-i}]),...dst.map((id,i)=>[id,{id,section:'dst',position:destinationCount-1-i}])]);
  const exports={};let authorized=true;const checked=[];
  class AuthorizationError extends Error{};class AuthenticationError extends Error{};
  vm.runInNewContext(code,{exports,console,require(id){
   if(id==='@/lib/auth-server')return {getSession:async()=>({user:{id:'actor'}})};
   if(id==='@/lib/authz')return {requireAuthenticated:async()=>({id:'actor'}),assertCanWriteTask:async(_,task)=>{checked.push(task);if(!authorized)throw new AuthorizationError()},AuthorizationError,AuthenticationError};
   if(id==='@/lib/prisma')return {prismadb:{tasks:{update:async({where,data})=>{Object.assign(rows.get(where.id),data);return rows.get(where.id)}}}};
   if(id==='next/cache')return {revalidatePath(){}};
   throw new Error(id);
  }},{filename:file});
  const input={resourceList:resource.map(id=>({id})),destinationList:target.map(id=>({id})),resourceSectionId:'src',destinationSectionId:same?'src':'dst'};
  const result=await exports.updateKanbanPosition(input);if(!result.success)throw Error('reference failed');
  const expected=[...rows.values()].sort((a,b)=>a.section.localeCompare(b.section)||b.position-a.position||a.id.localeCompare(b.id));
  authorized=false;const rejected=await exports.updateKanbanPosition(input);if(!rejected.error)throw Error('denial failed');
  cases.push({same,src,dst,moved,before,expected,denied:true});
 }
 fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,'build/kanban-reference.json'),JSON.stringify({source:file,sha256:crypto.createHash('sha256').update(source).digest('hex'),cases}));
 console.log(JSON.stringify({suite:'original kanban action',cases:cases.length}));
})().catch(e=>{console.error(e);process.exit(1)});
