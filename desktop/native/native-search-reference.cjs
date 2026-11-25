// Execute the actual global-search action and authorization helpers with a
// relational Prisma fixture. No SDK, sockets, real credentials or downloads.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), crypto = require('node:crypto'), ts = require('typescript');
const root = path.resolve(__dirname, '../..'), records = {}, labels = {}, hashes = {}, vectors = [];
let sequence = 0, actor, semantic = false;
function add(model, name, values) {
  const row = {id:`20000000-0000-4000-8000-${String(++sequence).padStart(12,'0')}`, ...(['Boards','Sections','Tasks'].includes(model)?{v:0}:{}), ...values};
  (records[model] ??= []).push(row); labels[name] = row.id; return row;
}
const users = ['admin','manager','alice','bob','partner'].map(name => add('Users',name,{name:'検索 '+name,email:name+'@example.invalid',username:name,role:['alice','bob'].includes(name)?'user':name,userStatus:'ACTIVE'}));
const [admin,manager,alice,bob,partner] = users;
function account(name, values={}) { return add('crm_Accounts',name,{v:0,name:'検索 '+name,createdBy:bob.id,assigned_to:bob.id,...values}); }
const owned = account('owned',{assigned_to:alice.id}), watched=account('watched'), hidden=account('hidden'), client=account('client',{partnerUserId:partner.id}), company=account('company',{partnerUserId:partner.id});
partner.partnerAccountId=company.id;
records.AccountWatchers=[{account_id:watched.id,user_id:alice.id}];
account('deleted',{deletedAt:'2026-01-01T00:00:00Z'});
const onlySemantic=account('only-semantic',{name:'星空の会社',assigned_to:alice.id});
for (const [name, owner, account] of [['own-contact',alice,hidden],['indirect-contact',bob,owned],['client-contact',bob,client],['company-contact',bob,company]]) {
  add('crm_Contacts',name,{first_name:'検索',last_name:name,createdBy:bob.id,assigned_to:owner.id,accountsIDs:account.id});
}
for (const model of ['crm_Leads','crm_Opportunities']) for (const [name,owner,account] of [['own',alice,hidden],['private',bob,hidden],['client',bob,client],['company',bob,company]]) {
  add(model,model+name,{createdBy:bob.id,assigned_to:owner.id,...(model==='crm_Leads'?{lastName:'検索 '+name,company:'会社',accountsIDs:account.id}:{name:'検索 '+name,account:account.id,status:'ACTIVE'})});
}
function board(name, values={}) { return add('Boards',name,{title:'検索 '+name,description:'日本語の説明'.repeat(30),user:bob.id,visibility:'private',sharedWith:[],...values}); }
const ownBoard=board('own-board',{user:alice.id}), publicBoard=board('public-board',{visibility:'public'}), shared=board('shared-board',{sharedWith:[alice.id]}), watchedBoard=board('watched-board'), privateBoard=board('private-board');
records.BoardWatchers=[{board_id:watchedBoard.id,user_id:alice.id}];
for (const [name,parent,owner] of [['own-task',ownBoard,alice],['assigned-private-task',privateBoard,alice],['other-task',publicBoard,bob]]) {
  const section=add('Sections',name+'-section',{title:'一覧',board:parent.id,position:0});
  add('Tasks',name,{title:'検索 '+name,content:'タスクの本文',section:section.id,user:owner.id,position:0,taskStatus:'ACTIVE',priority:'LOW'});
}
function doc(name, values={}) { return add('Documents',name,{document_name:'検索 '+name,document_file_mimeType:'text/plain',document_file_url:'local:test',size:10,createdBy:bob.id,assigned_user:bob.id,visibility:'private',...values}); }
const ownDoc=doc('own-doc',{createdBy:alice.id,summary:'日本語の要約'}), publicDoc=doc('public-doc',{visibility:'public'}), privateDoc=doc('private-doc'), linkedDoc=doc('linked-doc'), semanticDoc=doc('semantic-doc',{document_name:'星空の資料',createdBy:alice.id});
records.DocumentsToAccounts=[{document_id:linkedDoc.id,account_id:client.id},{document_id:publicDoc.id,account_id:owned.id}];
doc('version-doc',{parent_document_id:ownDoc.id,visibility:'public'}); doc('deleted-doc',{deletedAt:'2026-01-01T00:00:00Z',visibility:'public'});
for(const [kind,model] of Object.entries({account:'crm_Accounts',contact:'crm_Contacts',lead:'crm_Leads',opportunity:'crm_Opportunities',document:'Documents'})) {
  for(const [index,row] of records[model].entries()) vectors.push({kind,parentID:row.id,values:index%3===0?[3,4]:index%3===1?[1,0]:[-1,0]});
}
vectors.push({kind:'documentChunk',parentID:semanticDoc.id,values:[1,0]},{kind:'documentChunk',parentID:semanticDoc.id,values:[0,1]},{kind:'documentChunk',parentID:ownDoc.id,values:[0,1]});
function get(model,id) { return (records[model]??[]).find(r=>r.id===id); }
function hydrate(model,row) {
  if(!row)return null;
  const result={deletedAt:null,...row};
  if(model==='crm_Accounts') Object.assign(result,{watchers:(records.AccountWatchers??[]).filter(r=>r.account_id===row.id),partner_own_users:users.filter(r=>r.partnerAccountId===row.id)});
  if(['crm_Contacts','crm_Leads'].includes(model))result.assigned_accounts=hydrate('crm_Accounts',get('crm_Accounts',row.accountsIDs));
  if(model==='crm_Opportunities')result.assigned_account=hydrate('crm_Accounts',get('crm_Accounts',row.account));
  if(model==='Boards')result.watchers=(records.BoardWatchers??[]).filter(r=>r.board_id===row.id);
  if(model==='Documents') {
    Object.assign(result,{parent_document_id:null,created_by_user:null,...row});
    result.accounts=(records.DocumentsToAccounts??[]).filter(r=>r.document_id===row.id).map(r=>({account:hydrate('crm_Accounts',get('crm_Accounts',r.account_id))}));
    result.contacts=[];result.leads=[];result.opportunities=[];
  }
  return result;
}
function matches(row,where) {
  if(!row)return false;
  return Object.entries(where??{}).every(([key,value])=>{
    if(key==='OR')return value.some(x=>matches(row,x));
    if(key==='AND')return (Array.isArray(value)?value:[value]).every(x=>matches(row,x));
    if(key==='NOT')return !(Array.isArray(value)?value:[value]).every(x=>matches(row,x));
    if(value && typeof value==='object') {
      if('some' in value)return (row[key]??[]).some(x=>matches(x,value.some));
      if('has' in value)return (row[key]??[]).includes(value.has);
      if('in' in value)return value.in.includes(row[key]);
      if('contains' in value)return row[key]!=null && String(row[key]).toLowerCase().includes(value.contains.toLowerCase());
      return matches(row[key],value);
    }
    return (row[key]??null)===value;
  });
}
const modelMap={users:'Users',boards:'Boards',tasks:'Tasks',documents:'Documents',crm_Accounts:'crm_Accounts',crm_Contacts:'crm_Contacts',crm_Leads:'crm_Leads',crm_Opportunities:'crm_Opportunities'};
const prisma={};
for(const [property,model] of Object.entries(modelMap))prisma[property]={
  findMany:async({where,take,skip=0,orderBy})=>{
    const rows=(records[model]??[]).map(r=>hydrate(model,r)).filter(r=>matches(r,where));
    rows.sort((a,b)=>{if(orderBy?.name){const x=(a.name??'').toLowerCase(),y=(b.name??'').toLowerCase();if(x!==y)return x<y?-1:1;}return a.id.localeCompare(b.id);});
    return rows.slice(skip,take==null?undefined:skip+take);
  },
  count:async({where})=>(records[model]??[]).map(r=>hydrate(model,r)).filter(r=>matches(r,where)).length,
};
prisma.$transaction=async operations=>Promise.all(operations);
prisma.$queryRaw=async(strings)=>{
  const sql=strings.join(''), kinds={account:'crm_Embeddings_Accounts',contact:'crm_Embeddings_Contacts',lead:'crm_Embeddings_Leads',opportunity:'crm_Embeddings_Opportunities',document:'crm_Embeddings_Documents',documentChunk:'crm_Document_Chunks'};
  const kind=Object.keys(kinds).find(k=>sql.includes('"'+kinds[k]+'"')); if(!kind)throw Error('Unknown SQL');
  const model={account:'crm_Accounts',contact:'crm_Contacts',lead:'crm_Leads',opportunity:'crm_Opportunities',document:'Documents',documentChunk:'Documents'}[kind], scores=new Map();
  for(const v of vectors.filter(v=>v.kind===kind)) {
    const row=get(model,v.parentID);if(row.deletedAt || model==='Documents' && row.parent_document_id)continue;
    const similarity=v.values[0]/Math.hypot(...v.values);scores.set(row.id,Math.max(scores.get(row.id)??-Infinity,similarity));
  }
  const minimum=sql.includes('> 0.7')?0.7:-Infinity,limit=Number(sql.match(/LIMIT\s+(\d+)/i)?.[1]??10);
  return [...scores].map(([id,similarity])=>({id,similarity})).filter(r=>r.similarity>minimum).sort((a,b)=>b.similarity-a.similarity || a.id.localeCompare(b.id)).slice(0,limit);
};
const cache=new Map();
function load(relative) {
  const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file);
  const source=fs.readFileSync(file,'utf8');hashes[path.relative(root,file)]=crypto.createHash('sha256').update(source).digest('hex');
  const module={exports:{}};cache.set(file,module.exports);
  const requireStub=name=>{
    if(name==='@/lib/prisma')return {prismadb:prisma};
    if(name==='@/inngest/lib/embedding-utils')return {generateEmbedding:async()=>{if(!semantic)throw Error('synthetic unavailable');return [1,0];},toVectorLiteral:()=> '[1,0]'};
    if(name==='@/lib/authz')return {...load('lib/authz/scopes/crm.ts'),requireAuthenticated:async()=>actor,AuthenticationError:class extends Error{}};
    if(name.startsWith('@/'))return load(name.slice(2)+'.ts');
    if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),name+'.ts')));
    throw Error('Unexpected import '+name);
  };
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module,exports:module.exports,require:requireStub,console:{warn(){},error:console.error}},{filename:file,timeout:2000});return module.exports;
}
module.exports={records,labels,hashes,vectors,users,prisma,load,hydrate,matches,add,account,doc,setActor:user=>{actor=user;},setSemantic:value=>{semantic=value;}};
if(require.main===module)(async()=>{
  const original=load('actions/fulltext/unified-search.ts'), cases=[];
  for(const user of users)for(const enabled of [false,true]) {
    actor=user;semantic=enabled;const result=await original.unifiedSearch('検索','ja');if(result.error)throw Error(result.error);
    // The native UI exposes linked account names only when the account itself
    // is readable. Do not reproduce the original unscoped subtitle disclosure.
    for(const hit of result.documents)if(hit.id===publicDoc.id && !matches(hydrate('crm_Accounts',owned),load('lib/authz/scopes/crm.ts').accountReadScopeWhere(user)))hit.subtitle='';
    cases.push({userId:user.id,role:user.role,partnerAccountId:user.partnerAccountId??null,semantic:enabled,result});
  }
  fs.writeFileSync(process.argv[2],JSON.stringify({sourceSHA256:hashes,records,labels,vectors,cases,intentionalCorrections:['Scope semantic candidates before top-k so private rows cannot crowd out authorized results','Never disclose inaccessible linked account names in public-document subtitles','Exclude tasks whose parent board is deleted','Unicode case-folded literal matching; wildcard characters are literal','Bound displayed snippets; full records remain available through navigation']},null,2)+'\n');
  console.log(JSON.stringify({sourceCases:cases.length,facetsPerCase:8,records:Object.values(records).reduce((n,v)=>n+v.length,0)}));
})().catch(e=>{console.error(e);process.exitCode=1;});
