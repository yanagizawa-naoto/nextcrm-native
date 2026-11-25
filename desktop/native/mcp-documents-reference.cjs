// Executes the original eight document handlers and actual object scopes. Only
// Prisma persistence is synthetic; unknown runtime imports fail closed.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module');
const ts=require('typescript'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../..'),cache=new Map(),hashes={};
const schema=fs.readFileSync(path.join(root,'prisma/schema.prisma'),'utf8');
const modelNames=new Set([...schema.matchAll(/^model (\w+)\s*\{/gm)].map(x=>x[1]));
const uid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const epoch='2026-01-02T03:04:05.678Z',RealDate=Date;
global.Date=class FixedDate extends RealDate{constructor(...a){super(...(a.length?a:[epoch]));}static now(){return RealDate.parse(epoch);}};
const stringify=x=>JSON.stringify(x,(_,v)=>typeof v==='bigint'?v.toString():v),clone=x=>JSON.parse(stringify(x));
const metadata=new Map();
function fields(model){
 if(metadata.has(model))return metadata.get(model);
 const block=schema.match(new RegExp('^model '+model+'\\s*\\{([\\s\\S]*?)^\\}','m'))[1];
 const result=block.split('\n').flatMap(line=>{const m=line.trim().match(/^(\w+)\s+(\w+)(\[\]|\?)?(.*)$/);if(!m||modelNames.has(m[2]))return[];return[{name:m[1],type:m[2],suffix:m[3],attributes:m[4]}];});metadata.set(model,result);return result;
}
function full(model,input){return Object.fromEntries(fields(model).map(({name,type,suffix,attributes})=>{
 const expr=attributes.match(/@default\(([^)]*)\)/)?.[1];let value=suffix==='[]'?[]:null;
 if(expr?.startsWith('uuid('))value=uid(9999);else if(expr?.startsWith('now(')||attributes.includes('@updatedAt'))value=epoch;
 else if(expr!==undefined){try{value=JSON.parse(expr);}catch{value=expr;}}
 if(Object.hasOwn(input,name)&&input[name]!==undefined)value=input[name];
 if(value!=null&&type==='DateTime')value=new Date(value);
 if(value!=null&&type==='BigInt')value=BigInt(value);
 if(value!=null&&type==='Decimal')value=String(value);
 return[name,value];
}));}
const seeds={},add=(model,rows)=>seeds[model]=rows.map(x=>full(model,x));
add('Boards',[
 {id:uid(301),user:uid(1),title:'Alice',position:42,sharedWith:[]},
 {id:uid(302),user:uid(2),title:'Bob private'},
 {id:uid(303),user:uid(2),title:'Shared',sharedWith:[uid(1)]},
 {id:uid(304),user:uid(2),title:'Public',visibility:'public'},
 {id:uid(305),user:uid(2),title:'Watcher only'},
 {id:uid(306),user:uid(1),title:'Deleted',deletedAt:epoch,deletedBy:uid(1)},
 {id:uid(307),user:uid(1),title:'Negative positions'},
 {id:uid(308),user:uid(1),title:'Overflow positions'},
 {id:uid(309),user:uid(1),title:'Empty'},
 {id:uid(310),user:uid(1),title:'Null date',createdAt:null},
 {id:uid(311),user:uid(1),title:'Hundred sections'},
 {id:uid(312),user:uid(1),title:'Null max'},
].map(x=>({v:0,description:'説明',createdBy:x.user,...x})));
add('Sections',[
 ...[301,302,303,304,305,306,307,308].map((b,i)=>({id:uid(401+i),board:uid(b),position:b===307?-2000:b===308?'9223372036854775807':1000,title:`Section ${b}`})),
 {id:uid(409),board:uid(301),position:2000,title:'Empty own'},
 {id:uid(410),board:uid(301),position:3000,title:'Complete only'},
 {id:uid(411),board:uid(301),position:null,title:'Null position'},
 {id:uid(412),board:uid(312),position:null,title:'Null max'},
].map(x=>({v:0,...x})));
add('Tasks',[
 {id:uid(501),section:uid(401),user:uid(2),title:'Owner controls others task',position:1000,tags:{ja:['内容']},likes:'9223372036854775807'},
 {id:uid(502),section:uid(402),user:uid(1),title:'Assignee without board read',position:1000},
 {id:uid(503),section:uid(402),user:uid(2),title:'Private unassigned',position:2000},
 {id:uid(504),section:uid(403),user:uid(2),title:'Shared read only',position:1000},
 {id:uid(505),section:uid(404),user:uid(2),title:'Public read only',position:1000},
 {id:uid(506),section:uid(405),user:uid(2),title:'Watcher read only',position:1000},
 {id:uid(507),section:uid(406),user:uid(1),title:'Assignee on deleted board',position:1000},
 {id:uid(508),section:null,user:uid(1),title:'Orphan',position:1000},
 {id:uid(509),section:uid(401),user:uid(1),title:'Complete',position:2000,taskStatus:'COMPLETE'},
 {id:uid(510),section:uid(401),user:uid(1),title:'Null status',position:3000,taskStatus:null,createdAt:null},
 {id:uid(511),section:uid(401),user:null,title:'Pending',position:4000,taskStatus:'PENDING'},
 {id:uid(512),section:uid(407),user:uid(1),title:'Negative',position:-2500},
 {id:uid(513),section:uid(408),user:uid(1),title:'Max position',position:'9223372036854775807'},
 {id:uid(514),section:uid(410),user:uid(1),title:'Complete only',position:1000,taskStatus:'COMPLETE'},
].map(x=>({v:0,priority:'Normal',createdBy:uid(2),...x})));
add('tasksComments',Array.from({length:25},(_,i)=>({id:uid(600+i),v:0,task:uid(501),user:uid(i===24?5:i%2?1:2),comment:`Comment ${i}`,createdAt:`2025-01-02T03:04:${String(i).padStart(2,'0')}.000Z`})));
add('crm_Leads',[{id:uid(701),lastName:'Deleted owned lead',assigned_to:uid(1),createdBy:uid(2),deletedAt:epoch},{id:uid(702),lastName:'Bob lead',assigned_to:uid(2),createdBy:uid(2)},{id:uid(703),lastName:'Owned live lead',assigned_to:uid(1),createdBy:uid(2)},{id:uid(704),lastName:'Account-only lead',assigned_to:uid(2),createdBy:uid(2),accountsIDs:uid(101)}]);
add('crm_Contacts',[{id:uid(711),last_name:'Owned contact',createdBy:uid(1),assigned_to:uid(2)},{id:uid(712),last_name:'Bob contact',createdBy:uid(2),assigned_to:uid(2)},{id:uid(713),last_name:'Deleted own contact',createdBy:uid(1),assigned_to:uid(2),deletedAt:epoch},{id:uid(714),last_name:'Account-only contact',createdBy:uid(2),assigned_to:uid(2),accountsIDs:uid(101)},...Array.from({length:105},(_,i)=>({id:uid(1700+i),last_name:'Nested '+i,createdBy:uid(2),assigned_to:uid(2)}))]);
add('crm_Opportunities',[{id:uid(721),name:'Owned opportunity',assigned_to:uid(1),createdBy:uid(2)},{id:uid(722),name:'Bob opportunity',assigned_to:uid(2),createdBy:uid(2)},{id:uid(723),name:'Deleted owned opportunity',assigned_to:uid(1),createdBy:uid(2),deletedAt:epoch}]);
add('Documents',[
 {id:uid(801),created_by_user:uid(1)},
 {id:uid(802),created_by_user:uid(2)},
 {id:uid(803),created_by_user:uid(2),visibility:'public'},
 {id:uid(804),created_by_user:uid(1),deletedAt:epoch},
 {id:uid(805),createdBy:uid(1)},
 {id:uid(806),assigned_user:uid(1)},
 ...Array.from({length:11},(_,i)=>({id:uid(807+i),created_by_user:uid(2)})),
 {id:uid(818),created_by_user:uid(2),parent_document_id:uid(801)},
 {id:uid(819),created_by_user:uid(1),parent_document_id:uid(802)},
 {id:uid(820),created_by_user:uid(2),visibility:'PUBLIC'},
 {id:uid(821),created_by_user:uid(1),key:null},{id:uid(822),created_by_user:uid(1),key:''},
 {id:uid(823),created_by_user:uid(1),key:'日本語/space+%?#.dat',document_file_mimeType:'application/custom'},
 {id:uid(824),created_by_user:uid(1),key:'k'.repeat(1025)},
 {id:uid(825),created_by_user:uid(2),visibility:'public'},
 {id:uid(826),created_by_user:uid(3)},{id:uid(827),created_by_user:uid(4)},
 {id:uid(828),created_by_user:uid(1),createdAt:null},{id:uid(829),created_by_user:uid(1),status:'DELETED'},
 {id:uid(830),createdBy:uid(1)},
 ...Array.from({length:105},(_,i)=>({id:uid(1800+i),created_by_user:uid(i%2?2:1)})),
].map(x=>({document_name:`Document ${x.id}`,document_file_mimeType:'text/plain',document_file_url:'https://public.invalid:9443/bucket/original',key:'documents/'+x.id+'.txt',content_text:'本文',connected_documents:[],...x})));
add('DocumentsToAccounts',[{document_id:uid(801),account_id:uid(101)},{document_id:uid(826),account_id:uid(102)},{document_id:uid(827),account_id:uid(105)},{document_id:uid(807),account_id:uid(101)},{document_id:uid(808),account_id:uid(103)},{document_id:uid(809),account_id:uid(105)},{document_id:uid(810),account_id:uid(102)},{document_id:uid(817),account_id:uid(104)}]);
add('DocumentsToLeads',[{document_id:uid(801),lead_id:uid(703)},{document_id:uid(811),lead_id:uid(701)},{document_id:uid(812),lead_id:uid(702)}]);
add('DocumentsToContacts',[{document_id:uid(801),contact_id:uid(711)},...Array.from({length:105},(_,i)=>({document_id:uid(801),contact_id:uid(1700+i)})),{document_id:uid(813),contact_id:uid(711)},{document_id:uid(814),contact_id:uid(712)}]);
add('DocumentsToOpportunities',[{document_id:uid(801),opportunity_id:uid(721)},{document_id:uid(815),opportunity_id:uid(721)},{document_id:uid(816),opportunity_id:uid(722)}]);
add('DocumentsToTasks',[{document_id:uid(801),task_id:uid(502)},{task_id:uid(501),document_id:uid(802)},{task_id:uid(501),document_id:uid(804)}]);
add('BoardWatchers',[{board_id:uid(305),user_id:uid(1)},{board_id:uid(301),user_id:uid(2)}]);
const accountReference=JSON.parse(fs.readFileSync(path.join(__dirname,'build/mcp-accounts-reference.json'),'utf8'));
const support={Users:accountReference.users,crm_Accounts:accountReference.seeds,AccountWatchers:accountReference.watchers};
let state={},actors=[],writes=[],currentActorFrame;
const key=row=>row.id??Object.keys(row).filter(k=>k.endsWith('_id')).sort().map(k=>row[k]).join(':');
const observed=()=>actors.push(currentActorFrame()?.actor);
const relations={
 Boards:{sections:['Sections','id','board',true],watchers:['BoardWatchers','id','board_id',true]},
 Sections:{tasks:['Tasks','id','section',true],board_relation:['Boards','board','id',false]},
 Tasks:{assigned_section:['Sections','section','id',false],comments:['tasksComments','id','task',true],documents:['DocumentsToTasks','id','task_id',true]},
 tasksComments:{assigned_user:['Users','user','id',false]},
 DocumentsToTasks:{document:['Documents','document_id','id',false]},
 Documents:{tasks:['DocumentsToTasks','id','document_id',true],accounts:['DocumentsToAccounts','id','document_id',true],leads:['DocumentsToLeads','id','document_id',true],contacts:['DocumentsToContacts','id','document_id',true],opportunities:['DocumentsToOpportunities','id','document_id',true]},
 DocumentsToAccounts:{account:['crm_Accounts','account_id','id',false]},
 DocumentsToLeads:{lead:['crm_Leads','lead_id','id',false]},
 DocumentsToContacts:{contact:['crm_Contacts','contact_id','id',false]},
 DocumentsToOpportunities:{opportunity:['crm_Opportunities','opportunity_id','id',false]},
 crm_Accounts:{watchers:['AccountWatchers','id','account_id',true]},
};
const rows=model=>state[model]??support[model];
function related(model,row,field){const r=relations[model]?.[field];assert.ok(r,'unknown relation '+model+'.'+field);return{model:r[0],many:r[3],rows:row[r[1]]==null?[]:rows(r[0]).filter(x=>x[r[2]]===row[r[1]])};}
function matches(model,row,where={}){return Object.entries(where).every(([field,value])=>{
 if(field==='OR')return value.some(x=>matches(model,row,x));if(field==='AND')return(Array.isArray(value)?value:[value]).every(x=>matches(model,row,x));
 if(field==='board_id_user_id'||field.startsWith('document_id_'))return matches(model,row,value);
 if(relations[model]?.[field]){const relation=related(model,row,field);return relation.rows.some(x=>matches(relation.model,x,value.some??value));}
 assert.ok(Object.hasOwn(row,field),'unknown scalar '+model+'.'+field);
 if(value&&typeof value==='object'){
  if('not' in value)return row[field]!=null&&row[field]!==value.not;
  if('in' in value)return value.in.includes(row[field]);
  if('has' in value)return row[field]?.includes(value.has)??false;
 }
 return row[field]===value;
});}
function pagination(args){for(const field of['take','skip'])if(args[field]!==undefined&&(!Number.isInteger(args[field])||args[field]>2147483647))throw Error('Invalid Prisma pagination');}
function order(list,orderBy){if(!orderBy)return list;const terms=Array.isArray(orderBy)?orderBy:[orderBy];return[...list].sort((a,b)=>{for(const term of terms){const[[f,d]]=Object.entries(term);let x=a[f],y=b[f];if(x instanceof Date)x=x.getTime();if(y instanceof Date)y=y.getTime();const c=x===y?0:x==null?1:y==null?-1:x<y?-1:1;if(c)return d==='desc'?-c:c;}return 0;});}
function query(model,list,args){pagination(args);return order(list.filter(x=>matches(model,x,args.where)),args.orderBy).slice(args.skip??0,args.take===undefined?undefined:(args.skip??0)+args.take).map(x=>project(model,x,args));}
function project(model,row,args={}){
 if(!row)return null;const result=args.select?{}:{...row};
 for(const[field,selection]of Object.entries(args.select??args.include??{})){
  if(field==='_count'){result._count=Object.fromEntries(Object.keys(selection.select).map(k=>[k,related(model,row,k).rows.length]));continue;}
  if(Object.hasOwn(row,field)){result[field]=row[field];continue;}
  const r=related(model,row,field),a=selection===true?{}:selection,list=query(r.model,r.rows,a);result[field]=r.many?list:list[0]??null;
 }return result;
}
function valid(model,row){for(const f of fields(model)){const value=row[f.name];if(f.type==='BigInt'&&value!=null)assert.ok(value>=-9223372036854775808n&&value<=9223372036854775807n,'Postgres bigint out of range');if(typeof value==='string')assert.ok(!value.includes('\0'),'Postgres text contains NUL');}}
function adapter(model){return{
 findFirst:async a=>{observed();return project(model,rows(model).find(x=>matches(model,x,a.where)),a);},
 findUnique:async a=>{observed();return project(model,rows(model).find(x=>matches(model,x,a.where)),a);},
 findMany:async a=>{observed();return query(model,rows(model),a);},
 count:async a=>{observed();return rows(model).filter(x=>matches(model,x,a.where)).length;},
 aggregate:async a=>{observed();const positions=rows(model).filter(x=>matches(model,x,a.where)&&x.position!=null).map(x=>x.position);return{_max:{position:positions.length?positions.reduce((a,b)=>a>b?a:b):null}};},
 create:async({data})=>{observed();const row=full(model,data);valid(model,row);assert.ok(!rows(model).some(x=>key(x)===key(row)),'duplicate composite key');rows(model).push(row);writes.push({model,action:'insert',key:key(row)});return{...row};},
 update:async({where,data})=>{observed();const row=rows(model).find(x=>matches(model,x,where));assert.ok(row);const stamps=Object.fromEntries(fields(model).filter(x=>x.attributes.includes('@updatedAt')).map(x=>[x.name,epoch]));const updated=full(model,{...row,...data,...stamps});valid(model,updated);Object.assign(row,updated);writes.push({model,action:'update',key:key(row)});return{...row};},
 delete:async({where})=>{observed();const row=rows(model).find(x=>matches(model,x,where));assert.ok(row,'missing delete');state[model]=rows(model).filter(x=>x!==row);writes.push({model,action:'delete',key:key(row)});if(model==='Tasks'){state.tasksComments=state.tasksComments.filter(x=>x.task!==row.id);state.DocumentsToTasks=state.DocumentsToTasks.filter(x=>x.task_id!==row.id);}return{...row};},
};}
const db=Object.fromEntries(Object.keys({...seeds,...support}).map(model=>[model[0].toLowerCase()+model.slice(1),adapter(model)]));
for(const model of Object.keys({...seeds,...support}).filter(x=>x.startsWith('crm_')))db[model]=adapter(model);
function load(relative){
 const filename=path.resolve(root,relative);assert.ok(filename.startsWith(root+'/lib/')&&filename.endsWith('.ts'));
 if(cache.has(filename))return cache.get(filename).exports;
 const source=fs.readFileSync(filename,'utf8'),mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;hashes[path.relative(root,filename)]=crypto.createHash('sha256').update(source).digest('hex');
 mod.require=name=>{if(name==='@/lib/prisma')return{prismadb:db};if(name==='@/lib/authz')return{...load('lib/authz/scopes/crm.ts'),...load('lib/authz/errors.ts')};if(name==='@/lib/minio')return provider;if(name==='crypto')return{randomUUID:()=>uid(9998)};if(name==='@/lib/plugins/i18n')return{translatePluginMessage:()=> 'Synthetic rule rejection'};if(name==='zod'||name==='node:async_hooks')return require(name);if(name.startsWith('@/lib/'))return load(name.slice(2)+'.ts');if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(filename),name+'.ts')));throw Error('Blocked runtime import: '+name);};
 mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,filename);return mod.exports;
}
function delta(before,after){const original=new Map(before.map(x=>[key(x),stringify(x)])),current=new Set(after.map(key));return{total:after.length,changed:after.filter(x=>stringify(x)!==original.get(key(x))),removed:before.filter(x=>!current.has(key(x))).map(key)};}
// These constants are synthetic fixture material, never app credentials.
Object.assign(process.env,{MINIO_ENDPOINT:'http://internal.invalid:9000',MINIO_PUBLIC_ENDPOINT:'https://public.invalid:9443/base',MINIO_ACCESS_KEY:'SYNTHETICACCESS',MINIO_SECRET_KEY:'synthetic-secret-not-real',MINIO_BUCKET:'fixture-bucket',NEXTCRM_DESKTOP:'1',NEXTCRM_STORAGE_MODE:'local',NEXTCRM_DESKTOP_TOKEN:'synthetic-local-secret-not-real',NEXT_PUBLIC_APP_URL:'http://127.0.0.1:45678/base'});
function storageModule(relative,localCache=new Map()){
 const filename=path.resolve(root,relative);if(localCache.has(filename))return localCache.get(filename).exports;
 const source=fs.readFileSync(filename,'utf8'),mod=new Module(filename,module);mod.filename=filename;mod.paths=module.paths;localCache.set(filename,mod);hashes[path.relative(root,filename)]=crypto.createHash('sha256').update(source).digest('hex');
 mod.require=name=>{if(name.startsWith('node:')||name.startsWith('@aws-sdk/'))return require(name);if(name.startsWith('.'))return storageModule(path.relative(root,path.resolve(path.dirname(filename),name+'.ts')),localCache);throw Error('Blocked storage import '+name);};
 mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,filename);return mod.exports;
}
const originalStorage=storageModule('lib/minio.ts');
let signingCalls=[],failSigning=false;
const provider={MINIO_BUCKET:originalStorage.MINIO_BUCKET,MINIO_PUBLIC_URL:originalStorage.MINIO_PUBLIC_URL,
 presignPut:async(key,contentType,expiresIn=600)=>{signingCalls.push({key,method:'PUT',contentType,expiresIn});if(failSigning)throw Error('Synthetic signing failure');return originalStorage.presignPut(key,contentType,expiresIn);},
 presignGet:async(key,expiresIn=300)=>{signingCalls.push({key,method:'GET',contentType:'',expiresIn});if(failSigning)throw Error('Synthetic signing failure');return originalStorage.presignGet(key,expiresIn);},
};
(async()=>{
 const tools=load('lib/mcp/tools/crm-documents.ts').crmDocumentTools,{runMcpToolCall}=load('lib/mcp/run-tool.ts');({currentActorFrame}=load('lib/plugins/actor.ts'));
 const requests=[],cases=[],roles={1:'user',2:'user',3:'manager',4:'admin'},add=(label,user,name,input,fail=false)=>requests.push({label,user:uid(user),role:roles[user],tool:'crm_'+name,input,failSigning:fail});
 for(const user of[1,2,3,4]){
  for(const input of[{},{limit:2,offset:1},{limit:100,offset:100}])add('list',user,'list_documents',input);
  for(const document of[801,802,803,804,805,806,807,808,809,810,811,812,813,814,815,816,817,818,819,820,821,822,823,824,825,826,827,828,829,830,9997]){
   for(const tool of['get_document','get_upload_url','get_download_url','delete_document'])add('document-owner-read-difference',user,tool,{id:uid(document)});
  }
 }
 for(const entity of[['account',101],['account',102],['account',103],['account',105],['contact',711],['contact',712],['contact',713],['contact',714],['lead',701],['lead',702],['lead',703],['lead',704],['opportunity',721],['opportunity',722],['opportunity',723],['task',501],['task',502],['task',503],['task',504],['task',507],['task',508],['task',9997]]){
  add('entity-filter',1,'list_documents',{entityType:entity[0],entityId:uid(entity[1])});
  for(const user of[1,3,4])for(const operation of['link_document','unlink_document'])add('target-write-gate',user,operation,{document_id:uid(user===3?826:user===4?827:801),entityType:entity[0],entityId:uid(entity[1])});
 }
 for(const document of[801,802,803,804,805,806,818,819,825,826,827,9997])for(const user of[1,3,4])for(const operation of['link_document','unlink_document'])add('owner-only-link',user,operation,{document_id:uid(document),entityType:'account',entityId:uid(101)});
 for(const input of[{entityType:'account'},{entityId:uid(102)},{entityType:'task',entityId:uid(501)},{entityType:'contact',entityId:uid(1700)}])add('optional-entity-filter',1,'list_documents',input);
 for(const type of Object.keys(load('lib/upload-content-types.ts').UPLOAD_EXTENSIONS))add('create-allowed-mime',1,'create_document',{document_name:' 資料 '+type,contentType:type,description:'説明',visibility:'custom',created_by_user:uid(2)});
 for(const type of['text/plain; charset=utf-8','TEXT/PLAIN',' text/plain','text/html','application/octet-stream','application/zip','constructor','__proto__'])add('create-rejected-mime',1,'create_document',{document_name:'資料',contentType:type});
 add('create-space-long',1,'create_document',{document_name:' ',contentType:'text/plain',description:'長'.repeat(700)});
 add('create-long',4,'create_document',{document_name:'長'.repeat(700),contentType:'application/pdf',visibility:''});
 add('create-nul',1,'create_document',{document_name:'bad\0name',contentType:'text/plain'});
 add('create-signing-failure-retains-record',1,'create_document',{document_name:'失敗',contentType:'text/plain'},true);
 add('upload-signing-failure',1,'get_upload_url',{id:uid(801)},true);add('download-signing-failure',1,'get_download_url',{id:uid(801)},true);
 for(const input of[{limit:1.5},{offset:0.5},{offset:2147483648}])add('pagination',1,'list_documents',input);
 for(const request of requests){
  state=Object.fromEntries(Object.entries(seeds).map(([m,list])=>[m,list.map(x=>({...x}))]));actors=[];writes=[];signingCalls=[];failSigning=request.failSigning;
  const tool=tools.find(x=>x.name===request.tool),args=tool.schema.parse(request.input),result=await runMcpToolCall(async()=>({id:request.user,role:request.role}),u=>tool.handler(args,u.id,u));
  assert.ok(actors.every(x=>x?.type==='token'&&x.userId===request.user&&x.role===request.role));
  cases.push(clone({...request,result,state:Object.fromEntries(Object.keys(seeds).map(m=>[m,delta(seeds[m],state[m])])),writes,signingCalls}));
 }
 const signatures=[];
 for(const mode of['local','s3']){
  process.env.NEXTCRM_STORAGE_MODE=mode;
  for(const objectKey of['documents/plain.txt','documents/日本語 space+%?#.pdf','documents/a//b/../c.txt','slash/!$&\'()*,:;=@[]~.txt'])for(const method of['GET','PUT']){
   const contentType=method==='PUT'?'text/plain':'',expiresIn=method==='PUT'?600:3600;
   signatures.push({mode,key:objectKey,method,contentType,expiresIn,url:method==='PUT'?await originalStorage.presignPut(objectKey,contentType,expiresIn):await originalStorage.presignGet(objectKey,expiresIn)});
  }
 }
 for(const endpoint of['https://public.invalid:443/base/','http://127.0.0.1:80','https://public.invalid/base%20path','HTTPS://PUBLIC.invalid:443/base']){
  process.env.NEXTCRM_STORAGE_MODE='s3';process.env.MINIO_PUBLIC_ENDPOINT=endpoint;
  const implementation=storageModule('lib/minio.ts');
  for(const contentType of['',' text/plain  ; charset=utf-8\t']){
   const objectKey='documents/a file.txt';signatures.push({mode:'s3',endpoint:implementation.MINIO_PUBLIC_URL,key:objectKey,method:'PUT',contentType,expiresIn:600,url:await implementation.presignPut(objectKey,contentType,600)});
  }
 }
 process.env.MINIO_PUBLIC_ENDPOINT='https://public.invalid:9443/base';
 process.env.NEXTCRM_STORAGE_MODE='local';
 const local=storageModule('lib/local-storage.ts'),validations=[];
 const base=local.localObjectUrl('documents/日本語 +.txt','PUT',600,'text/plain');
 for(const mutation of['valid','method','type','expired','signature','key','duplicate','uppercase-signature']){
  const url=new URL(base);let method='PUT',contentType='text/plain';
  if(mutation==='method')method='GET';if(mutation==='type')contentType='text/html';if(mutation==='expired')url.searchParams.set('expires',String(Math.floor(Date.now()/1000)));
  if(mutation==='signature')url.searchParams.set('signature','0'.repeat(64));if(mutation==='uppercase-signature')url.searchParams.set('signature',url.searchParams.get('signature').toUpperCase());
  if(mutation==='key')url.searchParams.set('key','another');if(mutation==='duplicate')url.searchParams.append('key','another');
  validations.push({mutation,url:url.toString(),method,contentType,key:local.validateLocalObjectUrl(url,method,contentType)});
 }
 const endpointCases=[{}, {MINIO_ENDPOINT:'http://internal.invalid///'}, {MINIO_ENDPOINT:'http://internal.invalid',NEXT_PUBLIC_MINIO_ENDPOINT:'https://legacy.invalid/'}, {MINIO_ENDPOINT:'http://internal.invalid',NEXT_PUBLIC_MINIO_ENDPOINT:'https://legacy.invalid/',MINIO_PUBLIC_ENDPOINT:'https://public.invalid///'}, {MINIO_PUBLIC_ENDPOINT:'',MINIO_ENDPOINT:'http://internal.invalid'}].map(environment=>({environment,url:originalStorage.minioPublicEndpoint(environment)}));
 for(const file of['prisma/schema.prisma','lib/authz/index.ts','app/api/storage/local/route.ts'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,seeds:clone(seeds),cases,signatures,validations,endpointCases,sourceSHA256:hashes},null,2)+'\n');
 console.log(JSON.stringify({sourceDocumentCases:cases.length,tools:tools.length,signatureCases:signatures.length,validationCases:validations.length,scope:'Actual original document handlers, scopes, MinIO/AWS SDK and local HMAC signing; synthetic Prisma, no external network.'}));
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
