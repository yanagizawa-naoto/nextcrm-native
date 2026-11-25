// Execute the repository's real document authorization helpers. Hydrated
// relational fixtures are evaluated independently of the native SQL scopes.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'), ts = require('typescript');
const root = path.resolve(__dirname, '../..');
const records = {}, labels = {}, hashes = {};
let sequence = 0;
function add(model, label, values) {
  const row = {id:`10000000-0000-4000-8000-${String(++sequence).padStart(12,'0')}`, ...values};
  (records[model] ??= []).push(row); labels[label] = row.id; return row;
}
const users = ['admin','manager','alice','bob','partner','unknown'].map(name=>add('Users',name,{
  name,email:name+'@example.invalid',role:['alice','bob'].includes(name)?'user':name,userStatus:'ACTIVE',
}));
const [admin,manager,alice,bob,partner,unknown] = users;
function account(name, values={}) { return add('crm_Accounts',name,{v:0,name,createdBy:bob.id,assigned_to:bob.id,...values}); }
const ownA=account('alice-account',{assigned_to:alice.id});
const other=account('bob-account');
const watched=account('watched-account');
records.AccountWatchers=[{account_id:watched.id,user_id:alice.id}];
const client=account('partner-client',{partnerUserId:partner.id});
const company=account('partner-company',{partnerUserId:partner.id}); partner.partnerAccountId=company.id;
const contact=add('crm_Contacts','own-contact',{last_name:'Own contact',assigned_to:alice.id,createdBy:bob.id,accountsIDs:other.id});
const indirect=add('crm_Contacts','indirect-contact',{last_name:'Indirect only',assigned_to:bob.id,createdBy:bob.id,accountsIDs:ownA.id});
const partnerContact=add('crm_Contacts','partner-contact',{last_name:'Partner contact',assigned_to:bob.id,createdBy:bob.id,accountsIDs:client.id});
const lead=add('crm_Leads','own-lead',{lastName:'Own lead',assigned_to:alice.id,createdBy:bob.id});
const opportunity=add('crm_Opportunities','own-opportunity',{name:'Own opportunity',assigned_to:alice.id,createdBy:bob.id});
function doc(name, values={}) { return add('Documents',name,{document_name:name,document_file_mimeType:'text/plain',document_file_url:'unmigrated:test',size:10,createdBy:bob.id,assigned_user:bob.id,visibility:'private',...values}); }
function link(model, field, document, target) { (records[model]??=[]).push({document_id:document.id,[field]:target.id}); }
doc('created',{createdBy:alice.id}); doc('legacy-created',{created_by_user:alice.id}); doc('assigned',{assigned_user:alice.id});
doc('public',{visibility:'public'}); doc('private'); doc('deleted',{visibility:'public',deletedAt:'2026-01-01T00:00:00Z'});
link('DocumentsToAccounts','account_id',doc('account-owned'),ownA);
link('DocumentsToAccounts','account_id',doc('account-watched'),watched);
link('DocumentsToContacts','contact_id',doc('contact-owned'),contact);
link('DocumentsToContacts','contact_id',doc('contact-indirect-only'),indirect);
link('DocumentsToLeads','lead_id',doc('lead-owned'),lead);
link('DocumentsToOpportunities','opportunity_id',doc('opportunity-owned'),opportunity);
link('DocumentsToAccounts','account_id',doc('partner-linked'),client);
link('DocumentsToContacts','contact_id',doc('partner-contact-linked'),partnerContact);
link('DocumentsToAccounts','account_id',doc('partner-own-company'),company);
doc('partner-created-public',{createdBy:partner.id,assigned_user:partner.id,visibility:'public'});

function get(model,id) { return records[model]?.find(x=>x.id===id); }
function hydratedAccount(id) {
  const row=get('crm_Accounts',id); if(!row)return null;
  return {deletedAt:null,...row,watchers:records.AccountWatchers.filter(x=>x.account_id===id),partner_own_users:users.filter(u=>u.partnerAccountId===id)};
}
function hydratedEntity(model,id) {
  const row=get(model,id);if(!row)return null;
  return {deletedAt:null,...row,assigned_accounts:hydratedAccount(row.accountsIDs),assigned_account:hydratedAccount(row.account)};
}
const documents=records.Documents.map(d=>({
  deletedAt:null,parent_document_id:null,created_by_user:null,...d,
  accounts:(records.DocumentsToAccounts??[]).filter(x=>x.document_id===d.id).map(x=>({account:hydratedAccount(x.account_id)})),
  contacts:(records.DocumentsToContacts??[]).filter(x=>x.document_id===d.id).map(x=>({contact:hydratedEntity('crm_Contacts',x.contact_id)})),
  leads:(records.DocumentsToLeads??[]).filter(x=>x.document_id===d.id).map(x=>({lead:hydratedEntity('crm_Leads',x.lead_id)})),
  opportunities:(records.DocumentsToOpportunities??[]).filter(x=>x.document_id===d.id).map(x=>({opportunity:hydratedEntity('crm_Opportunities',x.opportunity_id)})),
}));
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
const prisma={documents:{findFirst:async({where})=>documents.find(d=>matches(d,where))??null}};
const cache=new Map();
function load(relative) {
  const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file);
  const source=fs.readFileSync(file,'utf8');hashes[path.relative(root,file)]=crypto.createHash('sha256').update(source).digest('hex');
  const module={exports:{}};cache.set(file,module.exports);
  const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const requireStub=name=>{
    if(name==='@/lib/prisma')return {prismadb:prisma};
    if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),name+'.ts')));
    throw new Error('Unexpected dependency '+name);
  };
  vm.runInNewContext(code,{module,exports:module.exports,require:requireStub,console},{filename:file,timeout:2000});return module.exports;
}
(async()=>{
  const original=load('lib/authz/scopes/crm.ts');const cases=[];
  for(const user of users) {
    const readable=documents.filter(d=>matches(d,original.documentReadScopeWhere(user))).map(d=>d.id).sort();
    const writable=[];
    for(const document of documents)try{await original.assertCanWriteDocument(user,document.id);writable.push(document.id);}catch{}
    cases.push({userId:user.id,role:user.role,partnerAccountId:user.partnerAccountId??null,readable,writable:writable.sort()});
  }
  const output={sourceSHA256:hashes,records,labels,cases,comparisons:cases.length*documents.length*2,
    intentionalCorrections:['Native versions inherit root permissions','Native linked-entity grants exclude deleted parents','Native version replacement preserves old bytes and updates MIME/hash; file deletion follows committed metadata and retains shared files']};
  fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,'build/documents-reference.json'),JSON.stringify(output,null,2)+'\n');
  console.log(JSON.stringify({suite:'document source scopes',users:users.length,documents:documents.length,comparisons:output.comparisons}));
})().catch(e=>{console.error(e);process.exit(1)});
