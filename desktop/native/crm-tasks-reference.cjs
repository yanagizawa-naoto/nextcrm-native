// Runs the original CRM-task authorization and create/comment/delete actions.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto'),ts=require('typescript');
const root=path.resolve(__dirname,'../..'), records={},labels={},hashes={};let seq=0;
function add(model,label,values){const row={id:`20000000-0000-4000-8000-${String(++seq).padStart(12,'0')}`,...values};(records[model]??=[]).push(row);labels[label]=row.id;return row;}
const users=['admin','manager','alice','bob','partner','unknown'].map(name=>add('Users',name,{name,email:name+'@example.invalid',role:['alice','bob'].includes(name)?'user':name,userStatus:'ACTIVE'}));
const [admin,manager,alice,bob,partner,unknown]=users;
function account(name,values={}){return add('crm_Accounts',name,{v:0,name,createdBy:bob.id,assigned_to:bob.id,...values});}
const owned=account('owned',{assigned_to:alice.id}),created=account('created',{createdBy:alice.id}),other=account('other'),watched=account('watched'),client=account('client',{partnerUserId:partner.id}),company=account('company',{partnerUserId:partner.id}),deleted=account('deleted',{assigned_to:alice.id,partnerUserId:partner.id,deletedAt:'2026-01-01T00:00:00Z'});partner.partnerAccountId=company.id;
records.AccountWatchers=[{account_id:watched.id,user_id:alice.id},{account_id:owned.id,user_id:alice.id},{account_id:owned.id,user_id:bob.id}];
const opportunity=add('crm_Opportunities','client-opportunity',{name:'Partner opportunity',account:client.id,createdBy:bob.id,assigned_to:bob.id});
const ownOpportunity=add('crm_Opportunities','company-opportunity',{name:'Company opportunity',account:company.id,createdBy:bob.id,assigned_to:bob.id});
const deletedOpportunity=add('crm_Opportunities','deleted-opportunity',{name:'Deleted opportunity',account:client.id,createdBy:bob.id,assigned_to:bob.id,deletedAt:'2026-01-01T00:00:00Z'});
function task(name,values={}){return add('crm_Accounts_Tasks',name,{v:0,title:name,content:'日本語の内容',priority:'medium',taskStatus:'ACTIVE',createdBy:bob.id,updatedBy:bob.id,user:bob.id,account:other.id,...values});}
task('creator',{createdBy:alice.id});task('assignee',{user:alice.id});task('owned-account',{account:owned.id});task('created-account',{account:created.id});task('watched-account',{account:watched.id});task('unrelated');task('partner-client',{account:client.id});task('partner-opportunity',{account:null,opportunity_id:opportunity.id});task('own-company',{account:company.id});task('own-company-opportunity',{account:null,opportunity_id:ownOpportunity.id});task('deleted-parent-reader',{account:deleted.id});task('deleted-parent-creator',{account:deleted.id,createdBy:alice.id});task('no-parent',{account:null});task('deleted-opportunity',{account:null,opportunity_id:deletedOpportunity.id});
function get(model,id){return records[model]?.find(x=>x.id===id);}
function hydratedAccount(id){const row=get('crm_Accounts',id);return row?{deletedAt:null,...row,watchers:records.AccountWatchers.filter(x=>x.account_id===id),partner_own_users:users.filter(x=>x.partnerAccountId===id)}:null;}
function hydrate(row){return {...row,crm_accounts:hydratedAccount(row.account),opportunity:row.opportunity_id?{...get('crm_Opportunities',row.opportunity_id),assigned_account:hydratedAccount(get('crm_Opportunities',row.opportunity_id)?.account)}:null};}
const tasks=records.crm_Accounts_Tasks.map(hydrate);
function matches(row,where) {
  if(row==null)return false;
  return Object.entries(where).every(([key,value])=>{
    if(key==='OR')return value.some(v=>matches(row,v));
    if(key==='AND')return (Array.isArray(value)?value:[value]).every(v=>matches(row,v));
    if(key==='NOT')return !(Array.isArray(value)?value:[value]).every(v=>matches(row,v));
    if(value && typeof value==='object') {
      if('some' in value)return (row[key]??[]).some(v=>matches(v,value.some));
      if('in' in value)return value.in.includes(row[key]);
      return matches(row[key],value);
    }
    return (row[key]??null)===value;
  });
}

let active, inserted=[],sent=[],comments=[],deletedCalls=[];
const prisma={
 crm_Accounts_Tasks:{findFirst:async({where})=>tasks.find(x=>matches(x,where))??null,findUnique:async({where})=>tasks.find(x=>matches(x,where))??null,create:async({data})=>{inserted.push(data);return{id:'created-task',...data};},delete:async({where})=>{deletedCalls.push(['task',where]);return where;}},
 crm_Accounts:{findFirst:async({where})=>records.crm_Accounts.map(x=>hydratedAccount(x.id)).find(x=>matches(x,where))??null},
 users:{findUnique:async({where})=>users.find(x=>matches(x,where))??null},
 accountWatchers:{findMany:async({where})=>records.AccountWatchers.filter(x=>x.account_id===where.account_id&&x.user_id!==where.user_id?.not).map(x=>({...x,user:get('Users',x.user_id)}))},
 tasksComments:{create:async({data})=>{comments.push(data);return{id:'comment',...data};},deleteMany:async({where})=>{deletedCalls.push(['comment',where]);return{count:0};}},
 documentsToCrmAccountsTasks:{deleteMany:async({where})=>{deletedCalls.push(['links',where]);return{count:0};}}
};
const cache=new Map();
function load(relative) {
  const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file);
  const source=fs.readFileSync(file,'utf8');hashes[path.relative(root,file)]=crypto.createHash('sha256').update(source).digest('hex');
  const module={exports:{}};cache.set(file,module.exports);
  const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const requireStub=name=>{
    if(name==='@/lib/prisma')return {prismadb:prisma};
    if(name==='@/lib/auth-server')return {getSession:async()=>({user:active})};
    if(name==='@/lib/authz')return {...load('lib/authz/scopes/crm.ts'),...load('lib/authz/errors.ts'),requireAuthenticated:async()=>active};
    if(name==='next/cache')return {revalidatePath:()=>{}};
    if(name==='@/lib/resend')return {__esModule:true,default:async()=>({emails:{send:async request=>{sent.push(request.to);return{id:'fake'};}}})};
    if(name.startsWith('@/emails/'))return {__esModule:true,default:props=>props};
    if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),name+'.ts')));
    throw new Error('Unexpected dependency '+name);
  };
  vm.runInNewContext(code,{module,exports:module.exports,require:requireStub,console,process:{env:{NEXT_PUBLIC_APP_NAME:"Test",EMAIL_FROM:"test@example.invalid"}}},{filename:file,timeout:2000});return module.exports;
}

(async()=>{
 const original=load('lib/authz/scopes/crm.ts'),cases=[];
 for(const user of users){const readable=tasks.filter(t=>matches(t,original.crmTaskReadScopeWhere(user))).map(t=>t.id).sort();const writable=[],deletable=[];for(const t of tasks){try{await original.assertCanWriteCrmTask(user,t.id,original.PARTNER_EDIT);writable.push(t.id);}catch{}try{await original.assertCanWriteCrmTask(user,t.id);deletable.push(t.id);}catch{}}cases.push({userId:user.id,role:user.role,partnerAccountId:user.partnerAccountId??null,readable,writable:writable.sort(),deletable:deletable.sort()});}
 const create=load('actions/crm/accounts/create-task.ts').createTask,actionCases=[];
 for(const [actor,parent,assigned] of [[alice,owned,bob],[partner,client,bob],[alice,other,bob],[partner,company,partner]]){active=actor;inserted=[];sent=[];const input={title:'日本語タスク',content:'確認と連絡をお願いします。',priority:'high',account:parent.id,user:assigned.id};const result=await create(input);actionCases.push({actorId:actor.id,parentID:parent.id,assignedID:assigned.id,ok:!!result.data,data:inserted[0]??null,recipients:[...new Set(sent)].sort()});}
 active=alice;await load('actions/crm/tasks/add-comment.ts').addComment({taskId:labels.assignee,comment:'日本語コメント'});await load('actions/crm/tasks/delete-task.ts').deleteTask(labels.assignee);
 if(comments[0].assigned_crm_account_task!==labels.assignee||comments[0].task!==undefined)throw Error('Wrong source comment FK');
 const output={records,labels,cases,actionCases,comment:comments[0],deleteCalls:deletedCalls,sourceSHA256:hashes,comparisons:users.length*tasks.length*3,intentionalCorrections:['Deduplicate assignee+watcher notices','Omitted due date remains null','Creation and notices/deletion and dependants are atomic','Do not block local task creation on mail configuration']};
 fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,'build/crm-tasks-reference.json'),JSON.stringify(output,null,2)+'\n');console.log(JSON.stringify({suite:'CRM task source reference',comparisons:output.comparisons,createCases:actionCases.length}));
})().catch(error=>{console.error(error);process.exit(1)});
