// Original five contract handlers, auth scopes and run-tool, with an isolated
// synthetic Prisma adapter. No live PostgreSQL or plugin code is invoked.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const { Prisma } = require('@prisma/client');
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
const shared = JSON.parse(fs.readFileSync(path.join(__dirname, 'build/mcp-accounts-reference.json'), 'utf8'));
const schema = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8'), epoch = shared.epoch;
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const definitions = new Map();
function fields(model) {
  if (definitions.has(model)) return definitions.get(model);
  const body = schema.match(new RegExp(`model ${model}\\s*\\{([\\s\\S]*?)^\\}`, 'm'))[1];
  const scalarNames = new Set(Prisma.dmmf.datamodel.models.find(x => x.name === model).fields.filter(x => x.kind !== 'object').map(x => x.name));
  const values = body.split('\n').map(line => {
    const match = line.match(/^\s*(\w+)\s+(\w+)(\[\]|\?)?(.*)$/); if (!match || !scalarNames.has(match[1])) return null;
    return { name: match[1], type: match[2], array: match[3] === '[]', optional: match[3] === '?', rest: match[4] };
  }).filter(Boolean);
  definitions.set(model, values); return values;
}
function full(model, values, generated = uid(9000)) {
  const row = {};
  for (const field of fields(model)) {
    const expression = field.rest.match(/@default\(([^)]*)\)/)?.[1];
    let value = field.array ? [] : null;
    if (field.rest.includes('@updatedAt') || expression?.startsWith('now(')) value = epoch;
    else if (expression?.startsWith('uuid(')) value = generated;
    else if (expression !== undefined) { try { value = JSON.parse(expression); } catch { value = expression; } }
    row[field.name] = value;
  }
  Object.assign(row, Object.fromEntries(Object.entries(values).filter(([,value])=>value!==undefined)));
  for (const field of fields(model)) {
    const value = row[field.name];
    if (value == null) { if (!field.optional && !field.array && !(field.type === 'Json' && value === null && Object.hasOwn(values, field.name))) throw Error('Missing required scalar ' + field.name); continue; }
    if (field.type === 'Decimal') {
      const [, precision, scale] = field.rest.match(/@db.Decimal\((\d+),\s*(\d+)\)/);
      const decimal = new Prisma.Decimal(value).toDecimalPlaces(Number(scale), Prisma.Decimal.ROUND_HALF_UP);
      if (decimal.abs().gte(new Prisma.Decimal(10).pow(Number(precision) - Number(scale)))) throw Error('numeric overflow');
      row[field.name] = decimal;
    }
    const enumBody = schema.match(new RegExp(`enum ${field.type}\\s*\\{([\\s\\S]*?)^\\}`, 'm'))?.[1];
    if (enumBody && !enumBody.split('\n').map(x=>x.trim().split(/\s+/)[0]).includes(value)) throw Error('invalid Prisma enum');
    if (field.type === 'Int' && (!Number.isInteger(value) || value < -2147483648 || value > 2147483647)) throw Error('integer overflow');
    if (field.type === 'DateTime') { const date = new Date(value); if (!Number.isFinite(date.getTime())) throw Error('invalid date'); row[field.name] = date; }
    if (field.rest.includes('@db.Uuid') && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw Error('invalid UUID');
    if (field.type === 'String' && typeof value === 'string' && value.includes('\0')) throw Error('PostgreSQL text cannot contain NUL');
  }
  return row;
}
const users=shared.users,models=['crm_campaigns','crm_campaign_templates','crm_campaign_steps','crm_campaign_sends','CampaignToTargetLists','crm_TargetLists','crm_Targets'];
const seeds=Object.fromEntries(models.map(m=>[m,[]]));
function seed(model,values){const row=full(model,values);seeds[model].push(row);return row;}
for(const[id,values]of[[1100,{name:'Alice本文',created_by:uid(1)}],[1101,{name:'Bob非公開本文',created_by:uid(2)}],[1102,{name:'削除本文',created_by:uid(1),deletedAt:epoch}],[1103,{name:'JSON null本文',created_by:uid(1),content_json:null}],[1104,{name:'管理者本文',created_by:uid(4)}]])seed('crm_campaign_templates',{id:uid(id),content_html:'<h1>{{first_name}}様</h1><p>日本語😀</p>',content_json:{type:'doc',content:[{type:'paragraph',content:[{type:'text',text:'日本語😀'}]}]},...values});
for(const[id,status,owner,extra]of[[1000,'draft',1],[1001,'draft',2],[1002,'sending',1],[1003,'paused',1],[1004,'scheduled',1],[1005,'sent',1],[1006,null,1],[1007,'deleted',1],[1008,'draft',1,{deletedAt:epoch}],[1009,'failed',1],[1010,'draft',1],[1011,'paused',1],[1012,'sending',2],[1013,'draft',null]])seed('crm_campaigns',{id:uid(id),v:7,name:'Campaign'+id,status,created_by:owner?uid(owner):null,template_id:uid(1100),scheduled_at:status==='scheduled'||status==='paused'?epoch:null,...extra});
for(const[id,campaign,order,template]of[[1200,1000,0,1100],[1201,1000,2,1101],[1202,1000,1,1102],[1203,1001,0,1101],[1204,1002,0,1100],[1205,1003,0,1100],[1206,1003,1,1100],[1207,1004,0,1100],[1208,1005,0,1100],[1209,1007,0,1100],[1210,1008,0,1100],[1211,1012,0,1101]])seed('crm_campaign_steps',{id:uid(id),campaign_id:uid(campaign),order,template_id:uid(template),subject:'件名 {{first_name}}',delay_days:order,send_to:order===2?'non_openers':'all'});
for(const[id,owner,deleted]of[[1300,1,false],[1301,2,false],[1302,1,true],[1303,null,false]])seed('crm_TargetLists',{id:uid(id),name:'TargetList'+id,created_by:owner?uid(owner):null,deletedAt:deleted?epoch:null});
for(let i=1400;i<1410;i++)seed('crm_Targets',{id:uid(i),last_name:'Target'+i,first_name:'日本語',email:'target'+i+'@example.invalid',created_by:uid(i===1401?2:1)});
for(const list of[1300,1301,1302])seed('CampaignToTargetLists',{campaign_id:uid(1000),target_list_id:uid(list)});
for(const[i,status]of['queued','sending','sent','delivered','bounced','failed','custom'].entries())seed('crm_campaign_sends',{id:uid(1500+i),campaign_id:uid(1000),step_id:uid(1200),target_id:uid(1400+i),email:'target'+(1400+i)+'@example.invalid',status,opened_at:i%2?epoch:null,clicked_at:i%3?null:epoch,unsubscribed_at:i===5?epoch:null,unsubscribe_token:uid(2500+i)});
for(const[i,status]of['sending','failed','sending'].entries())seed('crm_campaign_sends',{id:uid(1510+i),campaign_id:uid(1003),step_id:uid(1205),target_id:uid(1400+i),email:'target'+(1400+i)+'@example.invalid',status,unsubscribe_token:uid(2510+i)});
let state,actors=[],currentActorFrame,serial=9000,events=[],eventFailure=false;
const observed=()=>actors.push(currentActorFrame()?.actor);
function matches(row,where={}){return Object.entries(where).every(([key,value])=>{
 if(key==='OR')return value.some(x=>matches(row,x));if(key==='AND')return(Array.isArray(value)?value:[value]).every(x=>matches(row,x));
 if(key==='campaign_id_target_list_id')return matches(row,value);
 assert.ok(Object.hasOwn(row,key),'Unknown predicate '+key);
 if(value&&typeof value==='object'&&!(value instanceof Date)){if(Object.hasOwn(value,'not'))return row[key]!=null&&row[key]!==value.not;if(Object.hasOwn(value,'in'))return value.in.includes(row[key]);throw Error('Unhandled predicate '+key);}
 return row[key]===value;
});}
function order(rows,orderBy){if(!orderBy)return[...rows];return[...rows].sort((a,b)=>{for(const term of Array.isArray(orderBy)?orderBy:[orderBy]){const[[key,direction]]=Object.entries(term),av=a[key]instanceof Date?a[key].getTime():a[key],bv=b[key]instanceof Date?b[key].getTime():b[key];const cmp=av===bv?0:av==null?1:bv==null?-1:av<bv?-1:1;if(cmp)return direction==='desc'?-cmp:cmp;}return 0;});}
function projection(model,row,select,include){if(!row)return null;if(select)return Object.fromEntries(Object.keys(select).map(k=>[k,row[k]]));const result={...row};
 if(include?._count){result._count={};for(const name of Object.keys(include._count.select))result._count[name]=state[name==='steps'?'crm_campaign_steps':'crm_campaign_sends'].filter(x=>x.campaign_id===row.id).length;}
 if(include?.steps)result.steps=order(state.crm_campaign_steps.filter(x=>x.campaign_id===row.id),include.steps.orderBy).map(x=>projection('crm_campaign_steps',x,undefined,include.steps.include));
 if(include?.template)result.template=state.crm_campaign_templates.find(x=>x.id===row.template_id);
 if(include?.target_lists)result.target_lists=state.CampaignToTargetLists.filter(x=>x.campaign_id===row.id).map(x=>projection('CampaignToTargetLists',x,undefined,include.target_lists.include));
 if(include?.target_list)result.target_list=state.crm_TargetLists.find(x=>x.id===row.target_list_id);return result;
}
function jsonText(value){if(typeof value==='string'&&value.includes('\0'))throw Error('JSONB NUL');if(Array.isArray(value))value.forEach(jsonText);else if(value&&typeof value==='object')for(const[k,v]of Object.entries(value)){jsonText(k);jsonText(v);}}
function constraints(model,row,old){const relations={crm_campaigns:{template_id:'crm_campaign_templates.id'},crm_campaign_steps:{campaign_id:'crm_campaigns.id',template_id:'crm_campaign_templates.id'},crm_campaign_sends:{campaign_id:'crm_campaigns.id',step_id:'crm_campaign_steps.id',target_id:'crm_Targets.id'},CampaignToTargetLists:{campaign_id:'crm_campaigns.id',target_list_id:'crm_TargetLists.id'}};
 for(const[field,target]of Object.entries(relations[model]??{})){if(row[field]==null)continue;const[m,k]=target.split('.');if(!state[m].some(x=>x[k]===row[field]))throw Error('FK '+field);}
 if(model==='crm_campaign_steps'&&state[model].some(x=>x.id!==old?.id&&x.campaign_id===row.campaign_id&&x.order===row.order))throw Error('unique campaign order');
 if(model==='CampaignToTargetLists'&&state[model].some(x=>x.campaign_id===row.campaign_id&&x.target_list_id===row.target_list_id))throw Error('unique campaign target list');
 if(model==='crm_campaign_templates')jsonText(row.content_json);
}
const db={};for(const model of models){const client=model==='CampaignToTargetLists'?'campaignToTargetLists':model;db[client]={
 findFirst:async({where,select,include}={})=>{observed();return projection(model,state[model].find(x=>matches(x,where)),select,include);},findUnique:async args=>db[client].findFirst(args),
 findMany:async({where,select,include,orderBy,take,skip}={})=>{observed();if(take!==undefined&&(!Number.isInteger(take)||!Number.isInteger(skip??0)||(skip??0)>2147483647))throw Error('Prisma pagination');return order(state[model].filter(x=>matches(x,where)),orderBy).slice(skip??0,take===undefined?undefined:(skip??0)+take).map(x=>projection(model,x,select,include));},
 count:async({where})=>{observed();return state[model].filter(x=>matches(x,where)).length;},
 create:async({data})=>{observed();const row=full(model,data,uid(serial++));constraints(model,row);state[model].push(row);return{...row};},
 update:async({where,data})=>{observed();const index=state[model].findIndex(x=>matches(x,where));assert.ok(index>=0);const old=state[model][index],updated=fields(model).some(x=>x.name==='updatedAt')?{updatedAt:epoch}:{};const row=full(model,{...old,...data,...updated});constraints(model,row,old);state[model][index]=row;return{...row};},
 updateMany:async({where,data})=>{observed();const rows=state[model].filter(x=>matches(x,where));for(const row of rows)await db[client].update({where:{id:row.id},data});return{count:rows.length};},
 delete:async({where})=>{observed();const index=state[model].findIndex(x=>matches(x,where));assert.ok(index>=0);const row=state[model][index];if(model==='crm_campaign_steps'&&state.crm_campaign_sends.some(x=>x.step_id===row.id))throw Error('FK restrict sends');state[model].splice(index,1);return row;}
};}
function load(relative){const filename=path.resolve(root,relative);assert.ok(filename.startsWith(root+'/lib/')&&filename.endsWith('.ts'));if(cache.has(filename))return cache.get(filename).exports;const source=fs.readFileSync(filename,'utf8'),mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;hashes[path.relative(root,filename)]=crypto.createHash('sha256').update(source).digest('hex');mod.require=name=>{
 if(name==='@/lib/prisma')return{prismadb:db};if(name==='@/inngest/client')return{inngest:{send:async event=>{observed();events.push(event);if(eventFailure)throw Error('synthetic Inngest failure');return{ids:['isolated-event']}}}};
 if(name==='@/lib/plugins/i18n')return{translatePluginMessage:()=> 'Synthetic rule rejection'};if(['zod','node:async_hooks'].includes(name))return require(name);if(name.startsWith('@/lib/'))return load(name.slice(2)+'.ts');if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(filename),name+'.ts')));throw Error('Blocked runtime import '+name);
};mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,filename);return mod.exports;}
async function prismaJSONProbe(){const{PrismaClient}=require('@prisma/client');let query;const adapter={provider:'postgres',adapterName:'isolated-campaign-json',connect:async()=>({provider:'postgres',adapterName:'isolated-campaign-json',queryRaw:async value=>{query=value;throw Error('ISOLATED_ADAPTER')},dispose:async()=>{},getConnectionInfo:()=>({schemaName:'public',supportsRelationJoins:true})})};const client=new PrismaClient({adapter}),result=[];try{for(const[label,value]of[['missing',undefined],['null',null],['object',{body:['本文',null,true,0.005]}],['array',[]],['string','日本語'],['number',1.25],['boolean',false],['db-null',Prisma.DbNull]]){query=null;try{await client.crm_campaign_templates.create({data:{name:'isolated',content_html:'x',content_json:value}})}catch(error){const index=query?.argTypes.findIndex(x=>x.scalarType==='json')??-1;result.push({label,reachedAdapter:!!query,jsonArgument:index>=0?query.args[index]:null,validation:query?null:error.name});}}}finally{await client.$disconnect()}assert.deepEqual(result.map(x=>x.reachedAdapter),[false,true,true,true,true,true,true,false]);assert.equal(result[1].jsonArgument,'null');return result;}
(async()=>{
 const tools=load('lib/mcp/tools/campaigns.ts').campaignTools,{runMcpToolCall}=load('lib/mcp/run-tool.ts');({currentActorFrame}=load('lib/plugins/actor.ts'));const requests=[],cases=[],add=(user,tool,input,label=tool,extra={})=>requests.push({user:uid(user),tool,input,label,...extra});
 for(const user of[1,2,3,4]){
  for(const input of[{}, {limit:2,offset:1},{status:'draft'},{status:'sending'}])add(user,'campaigns_list',input);
  for(const id of[1000,1001,1006,1007,1008,1013,9998])add(user,'campaigns_get',{id:uid(id)});
  for(const input of[{}, {limit:2,offset:1}])add(user,'campaigns_list_templates',input);
  for(const id of[1100,1101,1102,1103,9998])add(user,'campaigns_get_template',{id:uid(id)});
  for(const id of[1000,1001,1002,1005,1006,1007,1008,9998]){add(user,'campaigns_update',{id:uid(id),name:'  更新  '});add(user,'campaigns_delete',{id:uid(id)});}
  for(const id of[1000,1001,1002,1003,1004,1005,1006,1007,1008,1009,1010,1011,9998])for(const tool of['campaigns_send','campaigns_pause','campaigns_resume'])add(user,tool,{id:uid(id)});
  for(const id of[1000,1001,1007,1008,9998])add(user,'campaigns_get_stats',{id:uid(id)});
  for(const id of[1100,1101,1102,9998]){add(user,'campaigns_update_template',{id:uid(id),name:'  更新本文  ',content_html:''});add(user,'campaigns_delete_template',{id:uid(id)});}
 }
 for(const changes of[{}, {name:'   ',description:'',from_name:'line\nbreak'},{template_id:uid(1100)},{template_id:uid(1101)},{template_id:uid(1102)},{template_id:uid(9998)},{from_name:'制御\u0001',reply_to:'test@example.invalid'},{description:'NUL\0bad'}])add(1,'campaigns_create',{name:'  日本語キャンペーン  ',...changes});
 add(1,'campaigns_update',{id:uid(1000),template_id:uid(1101)},'same template still checks scope',{seedChanges:{crm_campaigns:[{id:uid(1000),template_id:uid(1101)}]}});
 for(const content_json of[null,{},[],{type:'doc',content:[{text:'本文',value:0.005,nullable:null}]},'scalar',42,true,{'nested':['NUL\0']},{'NUL\0key':1}]){add(1,'campaigns_create_template',{name:'   ',content_html:'<script>keep exact HTML</script>',content_json});add(1,'campaigns_update_template',{id:uid(1100),content_json});}
add(1,'campaigns_update_template',{id:uid(1100)});
 const rawInputJSON='{"name":"raw JSON number","content_html":"x","content_json":{"x":0.00499999999999999999999,"values":[0.01499999999999999999999,true,null]}}';add(1,'campaigns_create_template',JSON.parse(rawInputJSON),'JSON uses JS Number',{rawInputJSON});
 const step={campaign_id:uid(1000),order:3,template_id:uid(1100),subject:'   '};
 for(const user of[1,2,3,4])for(const changes of[{}, {campaign_id:uid(1001)},{campaign_id:uid(1002)},{campaign_id:uid(1007)},{campaign_id:uid(9998)},{template_id:uid(1101)},{template_id:uid(1102)},{template_id:uid(9998)},{order:1},{delay_days:2147483647},{delay_days:2147483648},{order:2147483648}])add(user,'campaigns_create_step',{...step,...changes});
 for(const user of[1,2,3,4])for(const id of[1200,1201,1203,1204,1205,1206,1209,1210,9998]){add(user,'campaigns_update_step',{id:uid(id),subject:'変更'});add(user,'campaigns_update_step',{id:uid(id),order:3});add(user,'campaigns_delete_step',{id:uid(id)});}
 for(const changes of[{template_id:uid(1101)},{template_id:uid(1102)},{order:0},{order:2},{delay_days:2147483648}]){if(changes.order===0)continue;add(1,'campaigns_update_step',{id:uid(1202),...changes});}
 for(const user of[1,2,3,4])for(const campaign of[1000,1001,1002,1007,9998])for(const list of[1300,1301,1302,9998])for(const tool of['campaigns_assign_target_list','campaigns_remove_target_list'])add(user,tool,{campaign_id:uid(campaign),target_list_id:uid(list)});
 for(const tool of['campaigns_list','campaigns_list_templates'])for(const input of[{limit:1.5},{offset:0.5},{offset:2147483648}])add(1,tool,input);
 for(const[tool,id]of[['campaigns_send',1000],['campaigns_resume',1003],['campaigns_pause',1002],['campaigns_delete',1000]])add(3,tool,{id:uid(id)},'event failure source partial commit versus atomic native outbox',{eventFailure:true});
 const extraTargets=Array.from({length:105},(_,i)=>full('crm_Targets',{id:uid(3000+i),last_name:'Bulk'+i,email:'bulk'+i+'@example.invalid',created_by:uid(1)}));
 const extraSends=extraTargets.map((target,i)=>full('crm_campaign_sends',{id:uid(4000+i),campaign_id:uid(1003),step_id:uid(1205),target_id:target.id,email:target.email,status:'sending',unsubscribe_token:uid(5000+i)}));
 add(3,'campaigns_resume',{id:uid(1003)},'release all 107 abandoned claims',{extraSeeds:{crm_Targets:extraTargets,crm_campaign_sends:extraSends}});
 add(1,'campaigns_get_stats',{id:uid(1003)},'stats include all 108 sends',{extraSeeds:{crm_Targets:extraTargets,crm_campaign_sends:extraSends}});
 const extraSteps=Array.from({length:105},(_,i)=>full('crm_campaign_steps',{id:uid(6000+i),campaign_id:uid(1000),order:i+10,template_id:uid(1101),subject:'Bulk'+i}));add(1,'campaigns_get',{id:uid(1000)},'all 108 nested steps and private templates',{extraSeeds:{crm_campaign_steps:extraSteps}});
 for(const request of requests){state=Object.fromEntries(Object.entries(seeds).map(([m,rows])=>[m,rows.map(x=>({...x}))]));for(const[m,rows]of Object.entries(request.extraSeeds??{}))state[m].push(...rows);for(const[m,changes]of Object.entries(request.seedChanges??{}))for(const change of changes){const i=state[m].findIndex(x=>x.id===change.id);state[m][i]=full(m,{...state[m][i],...change});}actors=[];events=[];serial=9000;eventFailure=!!request.eventFailure;
 const before=Object.fromEntries(Object.entries(state).map(([m,rows])=>[m,rows.map(x=>({...x}))]));const user=users.find(x=>x.id===request.user),tool=tools.find(x=>x.name===request.tool),args=tool.schema.parse(request.input);const result=await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>tool.handler(args,u.id,u));if(actors.length)assert.ok(actors.every(x=>x?.type==='token'&&x.userId===user.id&&x.role===user.role));cases.push({...request,result,events,state,nativeRollbackState:eventFailure?before:undefined});}
 const jsonProbe=await prismaJSONProbe();for(const file of['prisma/schema.prisma','node_modules/@prisma/client/package.json','node_modules/@prisma/client/runtime/client.js','node_modules/zod/package.json'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,seeds,cases,jsonProbe,tools:tools.map(x=>x.name),sourceSHA256:hashes,scope:'Original campaign handlers/auth/first-step/run-tool with synthetic Prisma and fake Inngest. Actual installed Prisma query compiler verifies JSON acceptance without DB/network. Native durable outbox intentionally atomically commits enqueue and state; source Inngest failure leaves earlier Prisma writes committed.'})+'\n');console.log(JSON.stringify({sourceCampaignCases:cases.length,tools:tools.length,jsonProbe:jsonProbe.length,sourceFiles:Object.keys(hashes).length}));
})().catch(error=>{console.error(error.stack);process.exitCode=1});
