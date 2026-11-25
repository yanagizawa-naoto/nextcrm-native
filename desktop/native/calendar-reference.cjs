// Execute the original TypeScript calendar rules with an in-memory Prisma adapter.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),hashes={},cache=new Map();let records={},sequence=1000;
const uuid=n=>`71000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function match(row,where={}){return Object.entries(where).every(([k,v])=>{
 if(k==='OR')return v.some(q=>match(row,q));
 if(k==='source_externalId')return match(row,v);
 if(v instanceof Date)return row[k] instanceof Date&&row[k].getTime()===v.getTime();
 if(v&&typeof v==='object'&&!Array.isArray(v)&&'in'in v)return v.in.some(x=>v.mode==='insensitive'?String(row[k]??'').toLowerCase()===x.toLowerCase():row[k]===x);
 return(row[k]??null)===(v??null);
});}
function model(name){name=name==='users'?'Users':name;return{
 findFirst:async({where})=>(records[name]??[]).find(r=>match(r,where))??null,
 findUnique:async({where})=>(records[name]??[]).find(r=>match(r,where))??null,
 findMany:async({where,take})=>(records[name]??[]).filter(r=>match(r,where)).slice(0,take??Infinity),
 create:async({data})=>{const {links,...values}=data,row={id:uuid(sequence++),...values};(records[name]??=[]).push(row);if(links)for(const link of links.create)(records.crm_ActivityLinks??=[]).push({...link,activityId:row.id});return row;},
 update:async({where,data})=>{const row=(records[name]??[]).find(r=>match(r,where));if(!row)throw Error('missing '+name);Object.assign(row,data);return row;}
};}
const prisma=new Proxy({}, {get:(_,name)=>name==='$transaction'?async f=>f(prisma):model(name)});
function load(name){const file=path.resolve(root,name);if(cache.has(file))return cache.get(file);const source=fs.readFileSync(file,'utf8');hashes[name]=crypto.createHash('sha256').update(source).digest('hex');const module={exports:{}};
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module,exports:module.exports,Date,require:n=>{if(n==='@/lib/prisma')return{prismadb:prisma};if(n.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(file),n+'.ts')));throw Error(n);}},{filename:file,timeout:2000});cache.set(file,module.exports);return module.exports;}
(async()=>{
 const normalize=load('lib/crm/calendar/google-normalize.ts').normalizeGoogleEvent,opts={connectionId:uuid(1),accountEmail:'rep@example.invalid'};
 const base={id:'event1',iCalUID:'event1@google.invalid',summary:'日本語の商談😀',status:'confirmed',start:{dateTime:'2026-07-21T10:00:00.125+02:00'},end:{dateTime:'2026-07-21T10:30:00.125+02:00'},attendees:[{email:opts.accountEmail,self:true,responseStatus:'accepted'},{email:'CLIENT@EXTERNAL.INVALID'}]};
 const patches=[{}, {id:null},{start:{date:'2026-07-21'}},{attendees:[{self:true,responseStatus:'declined'},{email:'client@external.invalid'}]},{attendees:[{email:'colleague@example.invalid'}]},{attendees:[]},{attendees:null},{status:'cancelled',start:null,summary:null},{status:'cancelled',start:null},{summary:null},{summary:''},{end:null},{attendees:[{email:'REP@EXAMPLE.INVALID'},{email:'colleague@example.invalid'},{email:'Jane@client.invalid'},{email:'jane@client.invalid'}]}];
 const normalization=patches.map(p=>{const input={...base,...p};return{input,options:opts,expected:normalize(input,opts)};});
 const account={id:uuid(10),v:0,name:'取引先'},contact={id:uuid(11),last_name:'山田',email:'CLIENT@EXTERNAL.INVALID',accountsIDs:account.id},target={id:uuid(12),last_name:'営業対象',email:'client@external.invalid'},lead={id:uuid(13),lastName:'リード',email:'client@external.invalid'},opp={id:uuid(14),account:account.id,status:'ACTIVE'};
 const layouts=[{crm_Contacts:[contact],crm_Opportunities:[opp]},{crm_Contacts:[contact],crm_Opportunities:[opp,{...opp,id:uuid(15)}]},{crm_Contacts:[{...contact,accountsIDs:null}]},{crm_Targets:[target]},{crm_Leads:[lead]},{crm_Contacts:[contact],crm_Targets:[target],crm_Leads:[lead]},{crm_Contacts:[{...contact,deletedAt:'2026-01-01T00:00:00Z'}],crm_Targets:[target]},{crm_Targets:[{...target,email:null,personal_email:target.email}]},{crm_Targets:[{...target,email:null,company_email:target.email}]},{crm_Contacts:[{...contact,email:null,personal_email:contact.email}]},{crm_Leads:[{...lead,deletedAt:'2026-01-01T00:00:00Z'}]},{}];
 const matcher=load('lib/crm/calendar/match.ts').matchCounterparty,matching=[];
 for(const layout of layouts){records={crm_Accounts:[account],...layout};const emails=['  Client@External.Invalid  ',''];matching.push({records,emails,expected:await matcher(emails)});}
 records={crm_Contacts:[contact]};matching.push({records:{crm_Accounts:[account],...records},emails:[],expected:await matcher([])});
 records={crm_Accounts:[account],crm_Contacts:[contact],crm_Opportunities:[opp],Users:[{id:uuid(2),email:opts.accountEmail}]};
 const syncRecords=JSON.parse(JSON.stringify(records)),upsert=load('lib/crm/calendar/sync.ts').upsertCalendarEvent;
 const first={source:'calendly',externalId:'booking1',title:'日本語の面談',startAt:new Date('2026-07-21T10:00:00.125Z'),endAt:new Date('2026-07-21T10:30:30.125Z'),counterpartyEmails:['client@external.invalid'],hostEmail:opts.accountEmail,status:'scheduled'};
 const moved={...first,startAt:new Date('2026-07-22T10:00:00.125Z')},again={...first,startAt:new Date('2026-07-23T10:00:00.125Z')};
 const inputs=[first,first,{...first,title:'日時が同じ'},moved,{...moved,status:'cancelled'},{...moved,status:'cancelled'},moved,again,{...again,source:'google',externalId:'google-duplicate',connectionId:opts.connectionId},{...again,source:'google',externalId:'google-new',connectionId:opts.connectionId,startAt:new Date('2026-07-24T10:00:00Z')},{...first,source:'google',externalId:'google-no-match',connectionId:opts.connectionId,counterpartyEmails:['unknown@external.invalid']},{...first,externalId:'new-booking',counterpartyEmails:['unknown@external.invalid'],rawPayload:{payload:{name:'山田 太郎'}}},{...first,externalId:'unknown-cancel',status:'cancelled'}],transitions=[];
 for(const input of inputs){const result=await upsert(input),activity=result.activityId?(records.crm_Activities??[]).find(x=>x.id===result.activityId):null;transitions.push({input,expected:{action:result.action,reason:result.reason??null},activity:activity?{title:activity.title,date:activity.date,status:activity.status,duration:activity.duration}:null});}
 const result={sourceHashes:hashes,normalization,matching,syncRecords,transitions};fs.mkdirSync(path.join(__dirname,'build'),{recursive:true});fs.writeFileSync(path.join(__dirname,'build/calendar-reference.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify({suite:'actual original Google normalization, CRM counterparty matching and calendar upsert',normalization:normalization.length,matching:matching.length,transitions:transitions.length}));
})().catch(e=>{console.error(e);process.exitCode=1;});
