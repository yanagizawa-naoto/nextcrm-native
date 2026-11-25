// Actual source enrichment API, keys, auth and workers; isolated database/provider boundaries.
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
    if (field.type === 'String' && (typeof value === 'string' ? value.includes('\0') : field.array && value.some(x=>x.includes('\0')))) throw Error('PostgreSQL text cannot contain NUL');
  }
  return row;
}
for(const name of ['OPENAI','FIRECRAWL','ANTHROPIC','GROQ','E2B'])delete process.env[name+'_API_KEY'];
const NativeDate=Date;global.Date=class extends NativeDate {constructor(...args){super(...(args.length?args:[epoch]));}static now(){return new NativeDate(epoch).getTime();}};
const users=shared.users,models=['crm_Contacts','crm_Targets','crm_Contact_Enrichment','crm_Target_Enrichment','crm_Target_Contact'];
const seeds=Object.fromEntries(models.map(m=>[m,[]]));
for(const [id,owner,extra] of [[301,1,{}],[302,2,{}],[303,2,{accountsIDs:uid(101)}],[304,2,{accountsIDs:uid(103)}],[305,1,{deletedAt:epoch}],[306,2,{accountsIDs:uid(105)}],[307,1,{email:null}],[308,1,{email:''}],[309,1,{email:' '}],[310,null,{}],[311,1,{description:'手入力',position:' \n　\uFEFF'}],[312,2,{createdBy:uid(1)}]])seeds.crm_Contacts.push(full('crm_Contacts',{id:uid(id),last_name:'連絡先'+id,assigned_to:owner?uid(owner):null,createdBy:owner?uid(owner):null,email:'person'+id+'@example.invalid',...extra}));
for(const [id,owner,extra] of [[401,1,{}],[402,2,{}],[403,1,{deletedAt:epoch}],[404,1,{email:null}],[405,1,{email:''}],[406,1,{email:' '}],[407,null,{}],[408,1,{company:null,email:null}],[409,1,{industry:'手入力',city:' \n　\uFEFF'}]])seeds.crm_Targets.push(full('crm_Targets',{id:uid(id),last_name:'営業対象'+id,first_name:'日本語',created_by:owner?uid(owner):null,email:'target'+id+'@example.invalid',company:'会社',...extra}));
let state,serial,events,actors,currentActorFrame,eventFailure,providerCalls,providerOutput,keyRows,keyReads,sandboxCalls;
function reset(){state=Object.fromEntries(models.map(m=>[m,seeds[m].map(x=>full(m,x))]));serial=9000;events=[];actors=[];eventFailure=false;providerCalls=0;keyRows=[];keyReads=[];sandboxCalls=[];}
function observed(){actors.push(currentActorFrame?.()?.actor);}
const accounts=shared.seeds;
function matches(row,where={}){return Object.entries(where).every(([key,value])=>{
 if(key==='OR')return value.some(x=>matches(row,x));if(key==='AND')return(Array.isArray(value)?value:[value]).every(x=>matches(row,x));
 if(key==='assigned_accounts')return accounts.some(x=>x.id===row.accountsIDs&&matches(x,value));
 if(key==='watchers')return shared.watchers.some(x=>x.account_id===row.id&&matches(x,value.some));
 if(key==='targetId_email'||key==='targetId_linkedinUrl')return matches(row,value);
 assert.ok(Object.hasOwn(row,key),'Unknown predicate '+key);
 if(value&&typeof value==='object'&&!(value instanceof NativeDate)){if('in'in value)return value.in.includes(row[key]);if('gte'in value)return new NativeDate(row[key]).getTime()>=new NativeDate(value.gte).getTime();throw Error('Unhandled predicate '+key);}
 return row[key]===value;
});}
const project=(row,select)=>!row?null:select?Object.fromEntries(Object.keys(select).map(k=>[k,row[k]])):{...row};
const db={};for(const model of models){db[model]={
 findFirst:async({where,select}={})=>{observed();return project(state[model].find(x=>matches(x,where)),select)},
 findUnique:async args=>db[model].findFirst(args),findMany:async({where,select}={})=>{observed();return state[model].filter(x=>matches(x,where)).map(x=>project(x,select));},
 create:async({data,select})=>{observed();const row=full(model,data,uid(serial++));state[model].push(row);return project(row,select)},
 update:async({where,data,select})=>{observed();const i=state[model].findIndex(x=>matches(x,where));assert.ok(i>=0);state[model][i]=full(model,{...state[model][i],...data,updatedAt:epoch});return project(state[model][i],select)},
 upsert:async({where,create,update,select})=>{const row=state[model].find(x=>matches(x,where));return row?db[model].update({where:{id:row.id},data:update,select}):db[model].create({data:create,select});}
};}
db.apiKeys={findFirst:async({where,select})=>{observed();keyReads.push(where);return project(keyRows.find(x=>matches(x,where)),select)}};
const strategy={AgentOrchestrator:class{async enrichRow(row,fields,by){providerCalls++;if(providerOutput.throwError)throw Error('Synthetic provider failure');return providerOutput;}}};
function load(relative){const filename=path.resolve(root,relative);assert.ok((filename.startsWith(root+'/lib/')||filename.startsWith(root+'/inngest/'))&&filename.endsWith('.ts'));if(cache.has(filename))return cache.get(filename).exports;
 const source=fs.readFileSync(filename,'utf8'),mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;hashes[path.relative(root,filename)]=crypto.createHash('sha256').update(source).digest('hex');mod.require=name=>{
 if(name==='@/lib/prisma')return{prismadb:db};if(name==='@/inngest/client')return{inngest:{createFunction:(_,fn)=>fn,send:async event=>{observed();events.push(event);if(eventFailure)throw Error('Synthetic queue failure');return{ids:['fake']}}}};
 if(name==='@/lib/email-crypto')return{decrypt:value=>{if(value==='CORRUPT')throw Error('Synthetic ciphertext error');return value;}};
 if(name==='../agent-architecture')return strategy;
 if(name==='@/lib/enrichment/e2b/agent-script')return{getAgentScript:()=> '// isolated script'};
 if(name==='e2b')return{Sandbox:{create:async(template,options)=>{sandboxCalls.push({template,options});return{files:{write:async()=>{}},commands:{run:async(command,options)=>{providerCalls++;sandboxCalls.push({command,options});return{exitCode:0,stdout:JSON.stringify(providerOutput),stderr:''}}},kill:async()=>{sandboxCalls.push({killed:true})}}}}};
 if(name==='@/lib/plugins/i18n')return{translatePluginMessage:()=> 'Synthetic rule rejection'};if(['zod','node:async_hooks','fs/promises','path'].includes(name))return require(name);if(name.startsWith('@/lib/'))return load(name.slice(2)+'.ts');if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(filename),name+'.ts')));throw Error('Blocked runtime import '+name);
 };mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,filename);return mod.exports;}
const visibleLog=console.log;console.log=()=>{};console.error=()=>{};const timeout=setTimeout;global.setTimeout=(...args)=>{const timer=timeout(...args);timer.unref();return timer};
const envAll={FIRECRAWL_API_KEY:'fixture-firecrawl',OPENAI_API_KEY:'fixture-openai',ANTHROPIC_API_KEY:'fixture-anthropic',E2B_API_KEY:'fixture-e2b'};
function env(values){for(const name of Object.keys(envAll))delete process.env[name];for(const[k,v]of Object.entries(values))if(v!==null)process.env[k]=v;}
const snapshot=()=>JSON.parse(JSON.stringify(state));
(async()=>{
 const tools=load('lib/mcp/tools/crm-enrichment.ts').crmEnrichmentTools,{runMcpToolCall}=load('lib/mcp/run-tool.ts');({currentActorFrame}=load('lib/plugins/actor.ts'));
 const workers={'enrich/contact.run':load('inngest/functions/enrich-contact.ts').enrichContact,'enrich/contacts.bulk':load('inngest/functions/enrich-contacts-bulk.ts').enrichContactsBulk,'enrich/target.run':load('inngest/functions/enrich-target.ts').enrichTarget,'enrich/targets.bulk':load('inngest/functions/enrich-targets-bulk.ts').enrichTargetsBulk};
 const requests=[],cases=[],defaultFields=[{name:'description',description:'日本語の会社説明'},{name:'position'}];
 const add=(tool,input,extra={})=>requests.push({tool,input,label:tool,user:uid(1),environment:envAll,...extra});
 for(const user of[1,2,3,4])for(const contact of[true,false]){
  const name='crm_enrich_'+(contact?'contact':'target'),singular=contact?'contactId':'targetId',plural=contact?'contactIds':'targetIds',ids=contact?[301,302,303,304,305,306,307,308,309,310,311,312,9998]:[401,402,403,404,405,406,407,408,409,9998];
  for(const id of ids){add(name,{[singular]:uid(id),fields:defaultFields},{user:uid(user)});add(name+'_bulk',{[plural]:[uid(id)],fields:defaultFields},{user:uid(user)});}
  for(const list of[[ids[0],ids[0]],[ids[0],ids[1]],[ids[0],9998],[ids[0],ids[2]]])add(name+'_bulk',{[plural]:list.map(uid),fields:defaultFields},{user:uid(user)});
 }
 for(const tool of tools){const contact=tool.name.includes('contact'),bulk=tool.name.endsWith('bulk'),key=(contact?'contact':'target')+(bulk?'Ids':'Id'),id=uid(contact?301:401);const base={[key]:bulk?[id]:id,fields:defaultFields};
  for(const environment of[{}, {FIRECRAWL_API_KEY:'only-firecrawl'}, {OPENAI_API_KEY:'only-openai'}, {ANTHROPIC_API_KEY:'only-anthropic'}, {E2B_API_KEY:'only-e2b'}, {...envAll,FIRECRAWL_API_KEY:'sk-placeholder-x'}, {...envAll,OPENAI_API_KEY:' your_openai_key '}, {...envAll,E2B_API_KEY:' '}, {...envAll,ANTHROPIC_API_KEY:' your-anthropic-key '}, {...envAll,OPENAI_API_KEY:' \ufefffixture-openai　'}]){add(tool.name,base,{environment,label:'key precedence'});add(tool.name,{...base,[key]:bulk?[uid(9998)]:uid(9998)},{environment,label:'key before scope'});}
  for(const fields of[[{name:''}],[{name:' '}],[{name:'自由😀',description:''}],[{name:'description'},{name:'description',description:'second'}],[{name:'description_confidence',type:'number',subject:'person',mcpRequested:false}],[{name:'x\0y'}],[{name:'description',description:'nul\0description'}]])add(tool.name,{...base,fields},{label:'free fields'});
  add(tool.name,base,{eventFailure:true,label:'outbox rollback distinction'});
 }
 const contactOutput={enrichments:{description:{field:'description',value:'取得した説明',confidence:.9},position:{field:'position',value:'部長',confidence:.8}},status:'completed'};
 const targetOutput={target:{company_website:'https://source.invalid',industry:'情報',employees:'100',city:'東京',company_phone:'03-0000',social_linkedin:'https://linkedin.invalid/company',social_x:'https://x.invalid/company',description:'説明',country:'日本'},confidence:{industry:.6,city:.59},contacts:[]};
 for(const target of[false,true])for(const bulk of[false,true])for(const mode of['normal','recent','boundary','old','empty']){
  const kind=target?'target':'contact',id=target?(mode==='empty'?408:409):(mode==='empty'?307:311),key=kind+(bulk?'Ids':'Id');if(!bulk&&mode==='empty')continue;
  add('crm_enrich_'+kind+(bulk?'_bulk':''),{[key]:bulk?[uid(id)]:uid(id),fields:target?[{name:'unrelated'},{name:'unrelated',description:'ignored by fixed agent'}]:defaultFields},{worker:true,providerOutput:target?targetOutput:contactOutput,label:'worker '+mode,age:mode==='recent'?86400000:mode==='boundary'?7*86400000:mode==='old'?7*86400000+1:undefined});
 }
 for(const status of['error','skipped'])add('crm_enrich_contact',{contactId:uid(301),fields:defaultFields},{worker:true,providerOutput:{...contactOutput,status,error:'synthetic '+status},label:'worker source completion '+status});
 for(const email of['qa@gmail.com','qa@example.edu','qa@protonmail.com'])add('crm_enrich_contact',{contactId:uid(301),fields:defaultFields},{worker:true,providerOutput:contactOutput,seedChanges:{crm_Contacts:[{id:uid(301),email}]},label:'source strategy skip '+email});
 add('crm_enrich_contact',{contactId:uid(301),fields:defaultFields},{worker:true,providerOutput:{throwError:true},label:'source strategy catches provider error'});
 add('crm_enrich_contact',{contactId:uid(301),fields:defaultFields},{worker:true,providerOutput:{enrichments:{description:{field:'description',value:null,confidence:.8}},status:'completed'},label:'source strategy filters null'});
 for(const target of[false,true]){const model=target?'crm_Targets':'crm_Contacts',kind=target?'target':'contact',ids=Array.from({length:100},(_,i)=>uid(7000+i)).reverse(),extraSeeds={[model]:ids.map(id=>full(model,{id,last_name:'bulk100',email:'person@example.invalid',[target?'created_by':'createdBy']:uid(1)}))};add('crm_enrich_'+kind+'_bulk',{[kind+'Ids']:ids,fields:defaultFields},{extraSeeds,label:'100 distinct authorized reverse order',worker:true,providerOutput:target?targetOutput:contactOutput});}
 for(const request of requests){reset();env(request.environment);providerOutput=request.providerOutput;eventFailure=!!request.eventFailure;
  for(const[m,rows]of Object.entries(request.extraSeeds??{}))state[m].push(...rows.map(x=>full(m,x)));
  if(request.age!==undefined){const target=request.tool.includes('target'),id=request.input[target?(request.tool.endsWith('bulk')?'targetIds':'targetId'):(request.tool.endsWith('bulk')?'contactIds':'contactId')];state[target?'crm_Target_Enrichment':'crm_Contact_Enrichment'].push(full(target?'crm_Target_Enrichment':'crm_Contact_Enrichment',{id:uid(8000),[target?'targetId':'contactId']:Array.isArray(id)?id[0]:id,status:'COMPLETED',fields:target?['title']:[],triggeredBy:request.user,createdAt:new Date(Date.now()-request.age)}));}
  for(const[m,rows]of Object.entries(request.seedChanges??{}))for(const change of rows){const row=state[m].find(x=>x.id===change.id);Object.assign(row,change);}
  const before=snapshot(),tool=tools.find(t=>t.name===request.tool),user=users.find(u=>u.id===request.user),args=tool.schema.parse(request.input);
  const result=await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>tool.handler(args,u.id,u));
  const apiState=snapshot(),apiEvents=JSON.parse(JSON.stringify(events));let workerResults=[];
  if(request.worker&&!result.isError){const step={run:async(_,fn)=>fn(),sendEvent:async(_,list)=>events.push(...list)};let at=0;while(at<events.length){const event=events[at++];assert.ok(workers[event.name]);workerResults.push(await workers[event.name]({event,step}));}}
  assert.ok(actors.every(x=>!x||x.type==='token'&&x.userId===user.id&&x.role===user.role));cases.push({...request,result,apiState,apiEvents,state:snapshot(),events,workerResults,providerCalls,keyReads,sandboxCalls,...(eventFailure?{nativeRollbackState:before}:{})});
 }
 const keyCases=[];const getApiKey=load('lib/api-keys.ts').getApiKey;
 for(const provider of['FIRECRAWL','OPENAI','ANTHROPIC'])for(const input of[{environment:' env-key ',system:'system-key',user:'user-key'},{environment:'your_key',system:'system-key',user:'user-key'},{system:'system-key',user:'user-key'},{user:'user-key'},{system:'CORRUPT',user:'user-key'},{}]){
  reset();env({[provider+'_API_KEY']:input.environment??null});keyRows=[...(input.system?[{scope:'SYSTEM',provider,userId:null,encryptedKey:input.system}]:[]),...(input.user?[{scope:'USER',provider,userId:uid(1),encryptedKey:input.user}]:[])];let value,error;try{value=await getApiKey(provider,uid(1))}catch{error='decrypt'}keyCases.push({provider,input,value,error,reads:keyReads});
 }
 for(const f of ['prisma/schema.prisma','node_modules/@prisma/client/package.json','node_modules/zod/package.json'])hashes[f]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex');
 fs.writeFileSync(process.argv[2],JSON.stringify({epoch,users,seeds,cases,keyCases,tools:tools.map(x=>x.name),sourceSHA256:hashes},null,2)+'\n');visibleLog(JSON.stringify({sourceCases:cases.length,workerCases:cases.filter(x=>x.worker).length,keyCases:keyCases.length,tools:tools.length}));
})().catch(error=>{process.stderr.write(JSON.stringify({error:error.stack})+'\n');process.exitCode=1});
