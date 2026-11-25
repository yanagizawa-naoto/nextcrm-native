// Original five activity handlers, auth scopes and run-tool, with an isolated
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
  Object.assign(row, values);
  for (const field of fields(model)) {
    const value = row[field.name];
    if (value == null) { if (!field.optional && !field.array) throw Error('Missing required scalar ' + field.name); continue; }
    if (field.type === 'Decimal') {
      const [, precision, scale] = field.rest.match(/@db.Decimal\((\d+),\s*(\d+)\)/);
      const decimal = new Prisma.Decimal(value).toDecimalPlaces(Number(scale), Prisma.Decimal.ROUND_HALF_UP);
      if (decimal.abs().gte(new Prisma.Decimal(10).pow(Number(precision) - Number(scale)))) throw Error('numeric overflow');
      row[field.name] = decimal;
    }
    if (field.type === 'Int' && (!Number.isInteger(value) || value < -2147483648 || value > 2147483647)) throw Error('integer overflow');
    if (field.type === 'DateTime') { const date = new Date(value); if (!Number.isFinite(date.getTime())) throw Error('invalid date'); row[field.name] = date.toISOString(); }
    if (field.type === 'String' && typeof value === 'string' && value.includes('\0')) throw Error('PostgreSQL text cannot contain NUL');
  }
  return row;
}
const users = shared.users;
const accounts = shared.seeds.map(x => full('crm_Accounts', x));
const parents = {};
for (const [model, start, owner, title] of [
  ['crm_Contacts',200,'createdBy',{last_name:'連絡先'}],
  ['crm_Leads',300,'createdBy',{lastName:'リード'}],
  ['crm_Opportunities',400,'createdBy',{name:'商談'}],
  ['crm_Contracts',500,'createdBy',{title:'契約',v:0,value:0}],
  ['crm_Targets',600,'created_by',{last_name:'対象'}],
  ['crm_TargetLists',700,'created_by',{name:'リスト'}],
]) {
  parents[model] = [1,2,3,4].map(i => full(model,{...title,id:uid(start+i),[owner]:uid(i===2?2:1),...(i===3?{deletedAt:epoch}:{})}));
}
const seeds = [
  {id:uid(801),title:'Alice meeting',type:'meeting',createdBy:uid(1),updatedBy:uid(1),date:'2026-01-01T00:00:00.000Z'},
  {id:uid(802),title:'Bob note',type:'note',createdBy:uid(2),updatedBy:uid(2),date:'2026-01-01T00:00:00.000Z'},
  {id:uid(803),title:'deleted',type:'meeting',createdBy:uid(1),deletedAt:epoch,date:'2026-03-01T00:00:00.000Z'},
  {id:uid(804),title:'cancelled meeting',type:'meeting',createdBy:uid(1),status:'cancelled',date:'2025-01-01T00:00:00.000Z'},
  {id:uid(805),title:'admin activity',type:'call',createdBy:uid(4),date:'2027-01-01T00:00:00.000Z'},
  {id:uid(806),title:'creator absent',type:'visit',date:'2026-02-01T00:00:00.000Z'},
  {id:uid(807),title:'completed',type:'email',createdBy:uid(1),status:'completed',date:'2026-06-01T00:00:00.000Z'},
].map(x=>full('crm_Activities',x));
const linkSeeds = [
  ...[801,802,803,806].map((activity,i)=>({id:uid(1001+i),activityId:uid(activity),entityType:'account',entityId:uid(101)})),
  ...Object.entries(parents).flatMap(([model,rows],i)=>rows.flatMap((row,j)=>[0,1].map(k=>({id:uid(1100+i*10+j*2+k),activityId:uid(801+k),entityType:['contact','lead','opportunity','contract','target','target_list'][i],entityId:row.id})))),
  {id:uid(1300),activityId:uid(802),entityType:'unknown',entityId:uid(9998)},
  ...Array.from({length:105},(_,i)=>({id:uid(1400+i),activityId:uid(807),entityType:'account',entityId:uid(101)})),
].map(x=>full('crm_ActivityLinks',x));
let activities=[], links=[], events=[], actors=[], currentActorFrame, rejectEvents=false;
function observed() { actors.push(currentActorFrame()?.actor); }
function matches(row,where={}) {
  return Object.entries(where).every(([key,value])=>{
    if (key==='OR') return value.some(x=>matches(row,x));
    if (key==='AND') return (Array.isArray(value)?value:[value]).every(x=>matches(row,x));
    if (key==='NOT') return !matches(row,value);
    if (key==='watchers') return shared.watchers.some(x=>x.account_id===row.id&&matches(x,value.some));
    if (key==='assigned_account'||key==='assigned_accounts') return accounts.some(x=>x.id===row[key==='assigned_account'?'account':'accountsIDs']&&matches(x,value));
    if (key==='links') return links.some(x=>x.activityId===row.id&&matches(x,value.some));
    assert.ok(Object.hasOwn(row,key),'Unknown oracle predicate '+key); return row[key]===value;
  });
}
function projection(row,select,include) {
  if (!row) return null;
  if (select) return Object.fromEntries(Object.keys(select).map(key=>[key,row[key]]));
  const result={...row}; if (include?.links) result.links=links.filter(x=>x.activityId===row.id).map(x=>({...x})); return result;
}
function order(rows,terms) {
  return [...rows].sort((a,b)=>{for(const term of terms){const [[key,dir]]=Object.entries(term), av=a[key],bv=b[key]; const cmp=av===bv?0:av==null?1:bv==null?-1:av<bv?-1:1;if(cmp)return dir==='desc'?-cmp:cmp;}return 0;});
}
const db={crm_Accounts:{findFirst:async({where,select})=>{observed();return projection(accounts.find(x=>matches(x,where)),select);}}};
for(const [model,rows] of Object.entries(parents))db[model]={findFirst:async({where,select})=>{observed();return projection(rows.find(x=>matches(x,where)),select);}};
db.crm_Activities={
  findFirst:async({where,select,include})=>{observed();return projection(activities.find(x=>matches(x,where)),select,include);},
  findMany:async({where,take,skip,orderBy,include})=>{observed();if(!Number.isInteger(take)||!Number.isInteger(skip)||skip>2147483647)throw Error('Prisma integer pagination');return order(activities.filter(x=>matches(x,where)),orderBy).slice(skip,skip+take).map(x=>projection(x,undefined,include));},
  count:async({where})=>{observed();return activities.filter(x=>matches(x,where)).length;},
  create:async({data,include})=>{observed();const {links:related,...values}=data;const row=full('crm_Activities',values);const items=(related?.createMany.data??[]).map((x,i)=>full('crm_ActivityLinks',{...x,activityId:row.id},uid(9100+i)));activities.push(row);links.push(...items);return projection(row,undefined,include);},
  update:async({where,data})=>{observed();const index=activities.findIndex(x=>matches(x,where));assert.ok(index>=0);const row=full('crm_Activities',{...activities[index],...data,updatedAt:epoch});activities[index]=row;return projection(row);},
};
function load(relative) {
  const filename = path.resolve(root, relative); assert.ok(filename.startsWith(root + '/lib/') && filename.endsWith('.ts'));
  if (cache.has(filename)) return cache.get(filename).exports;
  const source = fs.readFileSync(filename, 'utf8'), mod = new Module(filename, module); cache.set(filename, mod); mod.filename = filename;
  hashes[path.relative(root, filename)] = crypto.createHash('sha256').update(source).digest('hex');
  mod.require = name => {
    if (name === '@/inngest/client') return { inngest: { send: async event => { if (rejectEvents) throw Error('synthetic event outage'); events.push(event); } } };
    if (name === '@/lib/prisma') return { prismadb: db };
    if (name === '@/lib/plugins/i18n') return { translatePluginMessage: () => 'Synthetic rule rejection' };
    if (name === 'zod' || name === 'node:async_hooks') return require(name);
    if (name.startsWith('@/lib/')) return load(name.slice(2) + '.ts');
    if (name.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(filename), name + '.ts')));
    throw Error('Blocked runtime import: ' + name);
  };
  mod._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, filename); return mod.exports;
}
(async()=>{
  const {crmActivityTools:tools}=load('lib/mcp/tools/crm-activities.ts'),{runMcpToolCall}=load('lib/mcp/run-tool.ts');
  ({currentActorFrame}=load('lib/plugins/actor.ts'));
  const requests=[],cases=[],add=(user,tool,input,label=tool,extra={})=>requests.push({user:uid(user),tool,input,label,...extra});
  for(const user of [1,2,3,4]){
    for(const input of [{},{limit:2,offset:1},{type:'meeting'},{status:'cancelled'},{type:'email',status:'completed'},{entityType:'account',entityId:uid(101)},{entityType:'ACCOUNT',entityId:uid(101)},{entityType:'account',entityId:uid(102)},{entityType:'account',entityId:uid(105)},{entityType:'unknown',entityId:uid(9998)},{entityType:''},{entityId:uid(101)}])add(user,'crm_list_activities',input);
    for(const id of [801,802,803,804,805,806,807,9998])add(user,'crm_get_activity',{id:uid(id)});
    for(const [type,start] of [['contact',200],['lead',300],['opportunity',400],['contract',500],['target',600],['target_list',700],['targetlist',700]])for(const i of [1,2,3,9])add(user,'crm_list_activities',{entityType:type,entityId:uid(start+i)});
  }
  for(const user of [1,2,3,4])for(const id of [801,802,803,804,805,806,9998]){
    add(user,'crm_update_activity',{id:uid(id),title:'  更新  ',status:'completed'});add(user,'crm_delete_activity',{id:uid(id)});
  }
  const creation={type:'meeting',title:'  日本語の活動  ',date:'2026-11-01T03:04:05.123456Z'};
  for(const type of ['call','meeting','note','email','visit'])for(const status of ['scheduled','completed','cancelled'])add(1,'crm_create_activity',{...creation,type,status});
  for(const date of ['0000-01-01T00:00:00Z','0001-01-01T00:00:00Z','1582-10-10T00:00:00Z','9999-12-31T23:59:59.999999Z'])add(1,'crm_create_activity',{...creation,date});
  add(1,'crm_create_activity',{...creation,title:'長'.repeat(700),description:'  説明  ',duration:2147483647,outcome:'結果',unknown:'strip'});
  add(1,'crm_create_activity',{...creation,duration:2147483648});
  add(1,'crm_create_activity',{...creation,title:'bad\0text'});
  for(const user of [1,4])for(const [type,start] of [['account',100],['contact',200],['lead',300],['opportunity',400],['contract',500]])for(const i of [1,2,3,5,9])add(user,'crm_create_activity',{...creation,links:[{entityType:type,entityId:uid(start+i)}]});
  add(1,'crm_create_activity',{...creation,links:[{entityType:'account',entityId:uid(101)},{entityType:'account',entityId:uid(9998)}]},'later-link-permission-failure');
  add(1,'crm_create_activity',{...creation,links:Array.from({length:105},()=>({entityType:'account',entityId:uid(101)}))},'duplicate-links-allowed-all105');
  add(1,'crm_create_activity',{...creation},'best-effort-event-failure',{rejectEvents:true});
  for(const status of [undefined,'cancelled','completed'])add(1,'crm_update_activity',{id:uid(804),...(status===undefined?{}:{status})},'update-cancelled-meeting');
  add(1,'crm_update_activity',{id:uid(801),date:creation.date,duration:0,description:'',outcome:'',type:'note'},'immutable-type-and-zero');
  add(1,'crm_update_activity',{id:uid(801),duration:2147483648},'update-integer-overflow');
  for(const input of [{limit:1.5},{offset:0.5},{offset:2147483648}])add(1,'crm_list_activities',input);
  for(const request of requests){
    activities=seeds.map(x=>({...x}));links=linkSeeds.map(x=>({...x}));events=[];actors=[];rejectEvents=!!request.rejectEvents;
    const user=users.find(x=>x.id===request.user),tool=tools.find(x=>x.name===request.tool),args=tool.schema.parse(request.input);
    const result=await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>tool.handler(args,u.id,u));
    assert.ok(actors.every(x=>x?.type==='token'&&x.userId===user.id&&x.role===user.role));
    cases.push({...request,result,activities,links,events});
  }
  for(const file of ['prisma/schema.prisma','node_modules/@prisma/client/package.json','node_modules/zod/package.json'])hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
  fs.writeFileSync(process.argv[2],JSON.stringify({epoch,seeds,linkSeeds,parents,cases,tools:tools.map(x=>x.name),sourceSHA256:hashes},null,2)+'\n');
  console.log(JSON.stringify({sourceActivityCases:cases.length,tools:tools.length,scope:'Original TS handlers/scopes/run-tool/calendar emitter; isolated synthetic Prisma and fake event transport. No live providers, PostgreSQL or plugin lifecycle.'}));
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
