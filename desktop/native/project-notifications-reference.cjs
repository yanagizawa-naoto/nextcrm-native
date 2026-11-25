// Execute the original project actions with isolated Prisma/mail adapters.
// Captures delivery intent only; no network, real mail, or database is used.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require('typescript');
const root = path.resolve(__dirname, '../..');
const sourcePaths = {
  create: 'actions/projects/create-task.ts',
  update: 'actions/projects/update-task.ts',
  comment: 'actions/projects/add-comment-to-task.ts',
};
const definitions = [
  {name:'create-other', action:'create'},
  {name:'create-self', action:'create', assigned:'actor'},
  {name:'create-no-address', action:'create', noAddress:true},
  {name:'create-no-provider', action:'create', noProvider:true},
  {name:'create-forbidden', action:'create', forbidden:true},
  {name:'update-other', action:'update'},
  {name:'update-board-alias', action:'update', boardAlias:true},
  {name:'update-no-board-argument', action:'update', noBoardArgument:true},
  {name:'update-self', action:'update', assigned:'actor'},
  {name:'update-forbidden', action:'update', forbidden:true},
  {name:'comment-watchers-and-creator', action:'comment'},
  {name:'comment-creator-also-watcher', action:'comment', creator:'recipient'},
  {name:'comment-self-only', action:'comment', creator:'actor', watchers:['actor']},
  {name:'comment-no-provider', action:'comment', noProvider:true},
  {name:'comment-forbidden', action:'comment', forbidden:true},
];
async function execute(definition) {
  const actor = {id:'actor',name:'作成者',email:'actor@example.invalid',role:'admin',userLanguage:'ja'};
  const users = {actor,
    recipient:{id:'recipient',name:'担当者',email:definition.noAddress ? null : 'recipient@example.invalid',userLanguage:'ja'},
    creator:{id:'creator',name:'タスク作成者',email:'creator@example.invalid',userLanguage:'ja'}};
  const task = {id:'task',title:'日本語の通知対象',content:'本文です。',user:definition.assigned ?? 'recipient',
    section:'section',createdBy:definition.creator ?? 'creator',priority:'normal',dueDateAt:null};
  const board = {id:'board',title:'日本語プロジェクト'};
  const sends = [], writes = [], authorization = [];
  const prisma = {
    sections:{findFirst:async()=>({id:'section'}),findUnique:async()=>({id:'section',board:'board'})},
    tasks:{count:async()=>1,
      create:async({data})=>{writes.push({model:'Tasks',operation:'create',data});return {...task,...data};},
      update:async({data})=>{writes.push({model:'Tasks',operation:'update',data});return {...task,...data};},
      findUnique:async(args)=>args.select ? {assigned_section:{board_relation:{id:'board'}}} : task},
    boards:{findUnique:async()=>board,update:async(args)=>{writes.push({model:'Boards',operation:'update',...args});return board;}},
    users:{findUnique:async({where})=>users[where.id] ?? null},
    boardWatchers:{findMany:async({where})=>(definition.watchers ?? ['actor','recipient'])
      .filter(id=>id!==where.user_id.not).map(id=>({user:users[id]}))},
    tasksComments:{create:async({data})=>{writes.push({model:'tasksComments',operation:'create',data});return {id:'comment',...data};}},
  };
  class AuthenticationError extends Error {}
  class AuthorizationError extends Error {}
  const modules = {
    '@/lib/auth-server':{getSession:async()=>({user:actor})},
    '@/lib/prisma':{prismadb:prisma},
    'next/cache':{revalidatePath:()=>{}},
    '@/lib/junction-helpers':{junctionTableHelpers:{addWatcher:id=>({create:{user_id:id}})}},
    '@/lib/resend':{__esModule:true,default:async()=>definition.noProvider ? null : {emails:{send:async(message)=>{sends.push(message);return {data:{id:'fake'}};}}}},
    '@/lib/authz':{AuthenticationError,AuthorizationError,requireAuthenticated:async()=>actor,
      assertCanWriteBoard:async(user,id)=>{authorization.push({user:user.id,board:id});if(definition.forbidden)throw new AuthorizationError();}},
  };
  const filename = path.join(root,sourcePaths[definition.action]);
  const source = fs.readFileSync(filename,'utf8');
  const code = ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText;
  const module = {exports:{}};
  const requireStub = name => {
    if(name.startsWith('@/emails/'))return {__esModule:true,default:props=>({template:name,props})};
    if(Object.hasOwn(modules,name))return modules[name];
    throw new Error('Unmocked import: '+name);
  };
  vm.runInNewContext(code,{module,exports:module.exports,require:requireStub,
    process:{env:{NEXT_PUBLIC_APP_NAME:'NextCRM',EMAIL_FROM:'sender@example.invalid'}},
    console:{log:()=>{}},Date}, {filename});
  const input = {title:task.title,user:task.user,priority:task.priority,content:task.content,taskId:'task',comment:'日本語のコメント'};
  if(!definition.noBoardArgument) input[definition.boardAlias ? 'board' : definition.action==='update' ? 'boardId' : 'board']='board';
  const action = module.exports[{create:'createTask',update:'updateTask',comment:'addCommentToTask'}[definition.action]];
  const result = await action(input);
  return {case:definition.name,action:definition.action,result,authorization,writes,sends};
}
(async()=>{
  const cases=[];
  for(const definition of definitions)cases.push(await execute(definition));
  const sourceHashes=Object.fromEntries(Object.values(sourcePaths).map(name=>[name,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,name))).digest('hex')]));
  const output=path.join(__dirname,'build/project-notifications-reference.json');
  fs.writeFileSync(output,JSON.stringify({sourceHashes,cases,
    intentionalNativeCorrections:['Japanese subjects/templates instead of original Czech fallback for ja.','Deduplicate watcher/creator delivery to the same user.','Revalidate current recipient activity and task/board access before delivery.','Resolve the authoritative parent board instead of trusting a supplied unrelated board.']},null,2)+'\n');
  console.log(JSON.stringify({cases:cases.length,sends:cases.reduce((n,c)=>n+c.sends.length,0),source:Object.values(sourcePaths),output}));
})().catch(error=>{console.error(error);process.exit(1);});
