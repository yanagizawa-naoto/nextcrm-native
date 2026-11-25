const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..'),now=1800000000000,hashes={};
class FixedDate extends Date{constructor(...args){if(args.length)super(...args);else super(now);}static now(){return now;}}
function load(name,require){const file=path.join(root,name),source=fs.readFileSync(file,'utf8'),m={exports:{}};hashes[name]=crypto.createHash('sha256').update(source).digest('hex');vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module:m,exports:m.exports,Date:FixedDate,require},{filename:file,timeout:2000});return m.exports;}
const normalize=load('lib/crm/calendar/google-normalize.ts',n=>{throw Error(n)}).normalizeGoogleEvent;
const event=id=>({id,summary:'日本語の予定',start:{dateTime:'2027-01-15T10:00:00.000Z'},attendees:[{email:'client@external.invalid'}]});
const cases=[
 {name:'initial pages including empty page',cursor:null,responses:[{items:[event('initial-a')],nextPageToken:'page+one/='},{items:[],nextPageToken:'page-two'},{items:[event('initial-b'),{id:'all-day',start:{date:'2027-01-15'}}],nextSyncToken:'cursor-new'}]},
 {name:'incremental pages',cursor:'cursor-before',responses:[{items:[event('incremental-a')],nextPageToken:'next-incremental'},{items:[event('incremental-b')],nextSyncToken:'cursor-after'}]},
 {name:'expired cursor after page discards previous items',cursor:'cursor-expired',responses:[{items:[event('abandoned')],nextPageToken:'expired-page'},{status:410},{items:[event('fresh-window')],nextSyncToken:'cursor-reset'}]},
 {name:'mid-download failure retains cursor and imports nothing',cursor:'cursor-stable',responses:[{items:[event('not-yet-imported')],nextPageToken:'error-page'},{status:503}]},
 {name:'revoked refresh grant',cursor:'cursor-revoked',responses:[{status:400,error:'invalid_grant'}]},
 {name:'quota preserves connection',cursor:'cursor-quota',responses:[{status:403,error:{errors:[{reason:'quotaExceeded'}]}}]}
];
(async()=>{for(const entry of cases){let connection={id:'test-connection',accountEmail:'rep@example.invalid',isActive:true,syncToken:entry.cursor},index=0,queries=[],imported=[];
 const prisma={calendarConnection:{findUnique:async()=>connection,update:async({data})=>Object.assign(connection,data)}};
 const calendar={events:{list:async query=>{queries.push(query);const r=entry.responses[index++];if(!r)throw Error('unexpected request');if(r.status){const error=Error('synthetic Google failure');error.code=r.status;error.response={data:{error:r.error??{}}};throw error;}return{data:r};}}};
 const mod=load('inngest/functions/calendar/google-sync-connection.ts',name=>{
  if(name==='@/inngest/client')return{inngest:{createFunction:(_config,handler)=>handler}};
  if(name==='@/lib/prisma')return{prismadb:prisma};if(name==='@/lib/crm/calendar/google')return{getCalendarClientForConnection:()=>calendar};
  if(name==='@/lib/crm/calendar/google-normalize')return{normalizeGoogleEvent:normalize};if(name==='@/lib/crm/calendar/sync')return{upsertCalendarEvent:async e=>{imported.push(e.externalId);return{action:'created'}}};throw Error(name);
 });
 let result=null,failed=false;try{result=await mod.googleCalendarSyncConnection({event:{data:{connectionId:connection.id}},step:{run:(_name,fn)=>fn()}})}catch{failed=true;}
 entry.expected={failed,active:connection.isActive,cursor:connection.syncToken,queries,imported,result};
 }
 fs.writeFileSync(path.join(__dirname,'build/google-calendar-sync-reference.json'),JSON.stringify({now:now/1000,hashes,cases},null,2)+'\n');console.log(JSON.stringify({suite:'actual original Google sync orchestration',cases:cases.length}));
})().catch(e=>{console.error(e);process.exitCode=1;});
