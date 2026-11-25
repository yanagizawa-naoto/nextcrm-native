// Original target/list handlers and object authorization, executed in isolation.
// Fixtures parse actual schema defaults rather than the reduced runtime DMMF.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
const schema = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8');
const modelNames = new Set([...schema.matchAll(/^model (\w+)\s*\{/gm)].map(x => x[1]));
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const epoch = '2026-01-02T03:04:05.678Z', RealDate = Date;
global.Date = class FixedDate extends RealDate { constructor(...args) { super(...(args.length ? args : [epoch])); } static now() { return RealDate.parse(epoch); } };
const clone = x => JSON.parse(JSON.stringify(x));
function full(model, input) {
  const block = schema.match(new RegExp('^model ' + model + '\\s*\\{([\\s\\S]*?)^\\}', 'm'))[1];
  return Object.fromEntries(block.split('\n').flatMap(line => {
    const m = line.trim().match(/^(\w+)\s+(\w+)(\[\]|\?)?(.*)$/); if (!m || modelNames.has(m[2])) return [];
    const [, name, type, suffix, attributes] = m, expression = attributes.match(/@default\(([^)]*)\)/)?.[1];
    let value = suffix === '[]' ? [] : null;
    if (expression?.startsWith('uuid(')) value = uid(9999);
    else if (expression?.startsWith('now(') || attributes.includes('@updatedAt')) value = epoch;
    else if (expression !== undefined) { try { value = JSON.parse(expression); } catch { value = expression; } }
    if (Object.hasOwn(input, name) && input[name] !== undefined) value = input[name];
    if (value != null && type === 'DateTime') value = new Date(value);
    return [[name, value]];
  }));
}
const targetSeeds = [
  { id: uid(201), last_name: 'Alice 東京', first_name: 'Éclair', created_by: uid(1), email: 'target@example.invalid', company: '企業', mobile_phone: 'phone-only', description: 'description-only', tags: ['日本語'], notes: ['note'], do_not_email: true, do_not_email_at: epoch },
  { id: uid(202), last_name: 'Bob 秘密', created_by: uid(2) },
  { id: uid(203), last_name: 'Deleted Alice', created_by: uid(1), deletedAt: epoch },
  { id: uid(204), last_name: 'Deleted Bob', created_by: uid(2), deletedAt: epoch },
  { id: uid(205), last_name: 'Admin own', created_by: uid(4) },
  { id: uid(206), last_name: 'Manager own', created_by: uid(3) },
  { id: uid(207), last_name: 'No creator', created_by: null },
  { id: uid(208), last_name: 'Null created date', created_by: uid(1), created_on: null, status: false },
  ...Array.from({ length: 100 }, (_, i) => ({ id: uid(1100 + i), last_name: `Batch ${i}`, created_by: uid(i % 2 ? 2 : 1), deletedAt: i % 3 ? null : epoch })),
].map(x => full('crm_Targets', x));
const listSeeds = [
  { id: uid(301), name: 'Alice members', created_by: uid(1) },
  { id: uid(302), name: 'Bob list', created_by: uid(2) },
  { id: uid(303), name: 'Deleted list', created_by: uid(1), deletedAt: epoch },
  { id: uid(304), name: 'Empty Alice', created_by: uid(1) },
  { id: uid(305), name: 'Null created', created_by: uid(1), created_on: null },
  { id: uid(306), name: 'No creator list', created_by: null },
].map(x => full('crm_TargetLists', x));
const linkSeeds = [201, 202, 203, ...Array.from({length:100},(_,i)=>1100+i)].map(n=>({target_id:uid(n),target_list_id:uid(301)}));
linkSeeds.push({target_id:uid(202),target_list_id:uid(302)}, {target_id:uid(201),target_list_id:uid(303)});
let targets=[],lists=[],links=[],actors=[],writes=[],currentActorFrame;
const key = row => row.id ?? row.target_list_id + ':' + row.target_id;
const observed = () => actors.push(currentActorFrame()?.actor);
function pattern(value, query) {
  if (value == null) return false; let expression='^',escaped=false;
  for (const char of '%' + query + '%') {
    if(escaped){expression+=char.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');escaped=false;}
    else if(char==='\\')escaped=true;
    else if(char==='%')expression+='[\\s\\S]*';else if(char==='_')expression+='[\\s\\S]';
    else expression+=char.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  } return new RegExp(expression+'$','iu').test(value);
}
function matches(row,where={}) {
  return Object.entries(where).every(([field,value])=>{
    if(field==='OR')return value.some(x=>matches(row,x));if(field==='AND')return value.every(x=>matches(row,x));
    assert.ok(Object.hasOwn(row,field),'unknown oracle field '+field);
    if(value&&typeof value==='object'&&'in' in value)return value.in.includes(row[field]);
    if(value&&typeof value==='object'&&'contains' in value)return pattern(row[field],value.contains);
    return row[field]===value;
  });
}
function pagination(args) {
  for(const field of ['take','skip'])if(args[field]!==undefined&&(!Number.isInteger(args[field])||args[field]>2147483647))throw Error('Invalid Prisma pagination');
}
function order(rows,orderBy) {
  if(!orderBy)return rows;
  const terms=Array.isArray(orderBy)?orderBy:[orderBy];
  return [...rows].sort((a,b)=>{
    for(const term of terms){const [[field,direction]]=Object.entries(term);let av=a[field],bv=b[field];if(av instanceof Date)av=av.getTime();if(bv instanceof Date)bv=bv.getTime();
      const cmp=av===bv?0:av==null?1:bv==null?-1:av<bv?-1:1;if(cmp)return direction==='desc'?-cmp:cmp;
    } return 0;
  });
}
function projection(row,select,include) {
  if(!row)return null;
  const result=select?Object.fromEntries(Object.keys(select).map(k=>[k,row[k]])):{...row};
  if(include?._count)result._count={targets:links.filter(x=>x.target_list_id===row.id).length};
  if(include?.targets){const args=include.targets;pagination(args);result.targets=order(links.filter(x=>x.target_list_id===row.id),args.orderBy).slice(args.skip??0,(args.skip??0)+(args.take??links.length)).map(x=>({...x,target:{...targets.find(t=>t.id===x.target_id)}}));}
  return result;
}
function adapter(model,rows) {
  return {
    findFirst:async({where,select,include})=>{observed();if(include?.targets)pagination(include.targets);return projection(rows().find(x=>matches(x,where)),select,include);},
    findMany:async args=>{observed();pagination(args);return order(rows().filter(x=>matches(x,args.where)),args.orderBy).slice(args.skip??0,args.take===undefined?undefined:(args.skip??0)+args.take).map(x=>projection(x,args.select,args.include));},
    count:async({where})=>{observed();return rows().filter(x=>matches(x,where)).length;},
    create:async({data})=>{observed();const row=full(model,data);rows().push(row);writes.push({model,action:'insert',key:key(row)});return{...row};},
    update:async({where,data})=>{observed();const row=rows().find(x=>matches(x,where));assert.ok(row);Object.assign(row,full(model,{...row,...data,updatedAt:epoch}));writes.push({model,action:'update',key:key(row)});return{...row};},
  };
}
const db={crm_Targets:adapter('crm_Targets',()=>targets),crm_TargetLists:adapter('crm_TargetLists',()=>lists),targetsToTargetLists:{
  createMany:async({data,skipDuplicates})=>{observed();assert.equal(skipDuplicates,true);let count=0;for(const row of data){if(!links.some(x=>key(x)===key(row))){links.push({...row});writes.push({model:'TargetsToTargetLists',action:'insert',key:key(row)});count++;}}return{count};},
  deleteMany:async({where})=>{observed();const removed=links.filter(x=>matches(x,where));for(const row of removed)writes.push({model:'TargetsToTargetLists',action:'delete',key:key(row)});links=links.filter(x=>!matches(x,where));return{count:removed.length};},
}};
function load(relative) {
  const filename=path.resolve(root,relative);assert.ok(filename.startsWith(root+'/lib/')&&filename.endsWith('.ts'));
  if(cache.has(filename))return cache.get(filename).exports;
  const source=fs.readFileSync(filename,'utf8'),mod=new Module(filename,module);cache.set(filename,mod);mod.filename=filename;
  hashes[path.relative(root,filename)]=crypto.createHash('sha256').update(source).digest('hex');
  mod.require=name=>{
    if(name==='@/lib/prisma')return{prismadb:db};if(name==='@/lib/plugins/i18n')return{translatePluginMessage:()=> 'Synthetic rule rejection'};
    if(name==='zod'||name==='node:async_hooks')return require(name);
    if(name.startsWith('@/lib/'))return load(name.slice(2)+'.ts');if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(filename),name+'.ts')));
    throw Error('Blocked runtime import: '+name);
  };
  mod._compile(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,filename);return mod.exports;
}
function delta(before,after) {
  const original=new Map(before.map(x=>[key(x),JSON.stringify(x)])),current=new Set(after.map(key));
  return{total:after.length,changed:after.filter(x=>JSON.stringify(x)!==original.get(key(x))),removed:before.filter(x=>!current.has(key(x))).map(key)};
}
(async()=>{
  const tools=[...load('lib/mcp/tools/crm-targets.ts').crmTargetTools,...load('lib/mcp/tools/crm-target-lists.ts').crmTargetListTools];
  const {runMcpToolCall}=load('lib/mcp/run-tool.ts');({currentActorFrame}=load('lib/plugins/actor.ts'));
  const requests=[],cases=[],roles={1:'user',2:'user',3:'manager',4:'admin'},add=(label,user,tool,input)=>requests.push({label,user:uid(user),role:roles[user],tool,input});
  for(const user of [1,2,3,4]){
    for(const input of [{},{limit:2,offset:1}]){add('target-list',user,'crm_list_targets',input);add('lists',user,'crm_list_target_lists',input);}
    for(const row of [201,202,203,205,206,207,208,9998])add('target-get',user,'crm_get_target',{id:uid(row)});
    for(const row of [301,302,303,304,305,306,9998])add('list-get',user,'crm_get_target_list',{id:uid(row)});
  }
  for(const query of ['alice','éclair','東京','target@','企業','description-only','phone-only','%','_','秘密'])add('search',1,'crm_search_targets',{query});
  for(const [user,row] of [[1,201],[1,202],[1,203],[1,205],[3,206],[3,201],[4,205],[4,201],[1,208]]){
    add('target-update',user,'crm_update_target',{id:uid(row),last_name:' 更新 ',company:'会社'});add('target-delete',user,'crm_delete_target',{id:uid(row)});
  }
  for(const [user,row] of [[1,301],[1,302],[1,303],[3,302],[4,306],[2,302],[2,301]]){
    add('list-update',user,'crm_update_target_list',{id:uid(row),name:' 更新 ',description:'説明'});add('list-delete',user,'crm_delete_target_list',{id:uid(row)});
  }
  for(const user of [1,4]){
    add('target-create',user,'crm_create_target',{last_name:' 日本語 ',first_name:'長'.repeat(600),email:'new@example.invalid',mobile_phone:'090',office_phone:'03',company:'会社',position:'担当',created_by:uid(2)});
    add('list-create',user,'crm_create_target_list',{name:' リスト '+ '長'.repeat(600),description:'説明',created_by:uid(2)});
  }
  add('target-space',1,'crm_create_target',{last_name:' '});add('list-space',1,'crm_create_target_list',{name:' '});
  for(const [user,list,ids] of [[1,301,[201,201,202,203,9998]],[1,304,[201,202,203,204,207,9998]],[1,302,[201]],[1,303,[201]],[3,302,[201,202,203,204,207,9998]],[4,304,[201,202,203,204,207]],[2,302,[201,202,202,204]],[4,306,[207]]]){
    for(const action of ['add_to','remove_from'])add('membership',user,`crm_${action}_target_list`,{target_list_id:uid(list),target_ids:ids.map(uid)});
  }
  const batch=Array.from({length:100},(_,i)=>uid(1100+i));
  for(const [user,list] of [[1,304],[4,304],[1,301],[4,301]])for(const action of ['add_to','remove_from'])add('batch100',user,`crm_${action}_target_list`,{target_list_id:uid(list),target_ids:batch});
  for(const input of [{limit:100,offset:100},{limit:2,offset:1},{limit:1.5},{offset:0.5},{offset:2147483648}])add('member-pagination',1,'crm_get_target_list',{id:uid(301),...input});
  add('missing-fractional-page',1,'crm_get_target_list',{id:uid(9998),limit:1.5});
  for(const tool of ['crm_list_targets','crm_list_target_lists'])for(const input of [{limit:1.5},{offset:0.5},{offset:2147483648}])add('pagination',1,tool,input);
  for(const request of requests){
    targets=targetSeeds.map(x=>({...x}));lists=listSeeds.map(x=>({...x}));links=linkSeeds.map(x=>({...x}));actors=[];writes=[];
    const tool=tools.find(x=>x.name===request.tool),args=tool.schema.parse(request.input);
    const result=await runMcpToolCall(async()=>({id:request.user,role:request.role}),u=>tool.handler(args,u.id,u));
    assert.ok(actors.length&&actors.every(x=>x?.type==='token'&&x.userId===request.user&&x.role===request.role));
    cases.push(clone({...request,result,state:{targets:delta(targetSeeds,targets),lists:delta(listSeeds,lists),links:delta(linkSeeds,links)},writes}));
  }
  hashes['prisma/schema.prisma']=crypto.createHash('sha256').update(schema).digest('hex');
  fs.writeFileSync(process.argv[2],JSON.stringify({epoch,seeds:{targets:clone(targetSeeds),lists:clone(listSeeds),links:clone(linkSeeds)},cases,sourceSHA256:hashes},null,2)+'\n');
  console.log(JSON.stringify({sourceTargetCases:cases.length,tools:tools.length,targets:targetSeeds.length,links:linkSeeds.length,scope:'Actual original target/list handlers and scopes; synthetic Prisma, no plugins/live PostgreSQL.'}));
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
