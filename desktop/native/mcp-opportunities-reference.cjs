// Execute actual MCP handlers, authorization, approval gate, stage transition
// and business audit code against isolated synthetic Prisma storage.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const { Decimal } = require('@prisma/client').Prisma;
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
const schemaText = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8');
const modelNames = new Set([...schemaText.matchAll(/^model (\w+)\s*\{/gm)].map(x => x[1]));
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const epoch = '2026-01-02T03:04:05.678Z', previousStage = '2000-01-01T00:00:00.000Z';
const NativeDate = Date;
global.Date = class FixedDate extends NativeDate { constructor(...args) { super(...(args.length ? args : [epoch])); } static now() { return NativeDate.parse(epoch); } };
const shared = JSON.parse(fs.readFileSync(path.join(__dirname, 'build/mcp-accounts-reference.json'), 'utf8'));
function fields(model) {
  return schemaText.match(new RegExp('^model ' + model + '\\s*\\{([\\s\\S]*?)^\\}', 'm'))[1].split('\n').flatMap(line => {
    const m = line.trim().match(/^(\w+)\s+(\w+)(\[\]|\?)?(.*)$/); if (!m || modelNames.has(m[2])) return [];
    return [{ name: m[1], type: m[2], array: m[3] === '[]', attributes: m[4] }];
  });
}
function convert(field, value) {
  if (value == null) return null;
  if (field.type === 'Decimal') return new Decimal(value);
  if (field.type === 'DateTime') return new Date(value);
  return value;
}
function full(model, values) {
  return Object.fromEntries(fields(model).map(f => {
    let value = f.array ? [] : null;
    const expression = f.attributes.match(/@default\(([^)]*)\)/)?.[1];
    if (expression?.startsWith('uuid(')) value = uid(9999);
    else if (expression?.startsWith('now(') || f.attributes.includes('@updatedAt')) value = epoch;
    else if (expression !== undefined) { try { value = JSON.parse(expression); } catch { value = expression; } }
    if (Object.hasOwn(values, f.name) && values[f.name] !== undefined) value = values[f.name];
    return [f.name, convert(f, value)];
  }));
}
const users = shared.users.map(x => full('Users', x)), accounts = shared.seeds.map(x => full('crm_Accounts', x));
const stages = [
  { id: uid(501), name: 'New', order: 1, probability: 10, stage_kind: 'new' },
  { id: uid(502), name: 'Qualified', order: 2, probability: 30, stage_kind: 'qualified' },
  { id: uid(503), name: 'Closed', order: null, probability: 100, stage_kind: 'won' },
  ...Array.from({ length: 105 }, (_, i) => ({ id: uid(600 + i), name: `Stage ${String(i).padStart(3, '0')}`, order: 3 + i, probability: null, stage_kind: null })),
].map(x => full('crm_Opportunities_Sales_Stages', x));
const types = [{ id: uid(801), name: 'New', order: 1 }, { id: uid(802), name: 'Existing', order: null }].map(x => full('crm_Opportunities_Type', x));
const contacts = [
  { id: uid(301), v: 0, last_name: 'Alice', assigned_to: uid(1), createdBy: uid(1) },
  { id: uid(302), v: 0, last_name: 'Bob', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(101) },
  { id: uid(303), v: 0, last_name: 'Deleted', assigned_to: uid(1), createdBy: uid(1), deletedAt: epoch },
].map(x => full('crm_Contacts', x));
const seeds = [
  { id: uid(401), name: 'Alice 東京', assigned_to: uid(1), createdBy: uid(1), budget: '123456789012.25', expected_revenue: '9007199254740991', status: 'CLOSED', sales_stage: uid(501), stage_entered_at: previousStage },
  { id: uid(402), name: 'Bob 秘密', assigned_to: uid(2), createdBy: uid(2) },
  { id: uid(403), name: 'Linked account', assigned_to: uid(2), createdBy: uid(2), account: uid(101), description: 'Éclair 日本語' },
  { id: uid(404), name: 'Watched account', assigned_to: uid(2), createdBy: uid(2), account: uid(103) },
  { id: uid(405), name: 'Deleted', assigned_to: uid(1), createdBy: uid(1), deletedAt: epoch },
  { id: uid(406), name: 'Deleted parent', assigned_to: uid(2), createdBy: uid(2), account: uid(105) },
  { id: uid(407), name: 'Approved', assigned_to: uid(1), createdBy: uid(1), approval_status: 'APPROVED', sales_stage: uid(501), stage_entered_at: previousStage, status: 'CLOSED' },
  { id: uid(408), name: 'Stay qualified', assigned_to: uid(1), createdBy: uid(1), approval_status: 'NONE', sales_stage: uid(502), stage_entered_at: previousStage, status: 'INACTIVE' },
  { id: uid(409), name: 'Creator', assigned_to: uid(2), createdBy: uid(1) },
].map(x => full('crm_Opportunities', x));
let opportunities = [], audits = [], events = [], actors = [], currentActorFrame;
const snapshot = value => JSON.parse(JSON.stringify(value));
function pattern(value, query) {
  if (value == null) return false; let expression = '^', escaped = false;
  for (const char of '%' + query + '%') {
    if (escaped) { expression += char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); escaped = false; }
    else if (char === '\\') escaped = true;
    else if (char === '%') expression += '[\\s\\S]*';
    else if (char === '_') expression += '[\\s\\S]';
    else expression += char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  } return new RegExp(expression + '$', 'iu').test(value);
}
function matches(row, where = {}) {
  return Object.entries(where).every(([key, value]) => {
    if (key === 'OR') return value.some(x => matches(row, x));
    if (key === 'AND') return value.every(x => matches(row, x));
    if (key === 'watchers') return shared.watchers.some(x => x.account_id === row.id && matches(x, value.some));
    if (key === 'assigned_account') return accounts.some(x => x.id === row.account && matches(x, value));
    if (key === 'assigned_accounts') return accounts.some(x => x.id === row.accountsIDs && matches(x, value));
    assert.ok(Object.hasOwn(row, key), 'unknown oracle field ' + key);
    if (value && typeof value === 'object' && 'contains' in value) return pattern(row[key], value.contains);
    return row[key] === value;
  });
}
function projection(row, select) { return !row ? null : select ? Object.fromEntries(Object.keys(select).map(k => [k, row[k]])) : { ...row }; }
function observed() { actors.push(currentActorFrame()?.actor); }
function adapter(model, rows) {
  const find = async ({ where, select }) => { observed(); return projection(rows().find(x => matches(x, where)), select); };
  return {
    findFirst: find, findUnique: find,
    findMany: async ({ where, select, take, skip, orderBy }) => {
      observed(); if (take !== undefined && !Number.isInteger(take) || skip !== undefined && (!Number.isInteger(skip) || skip > 2147483647)) throw Error('Invalid Prisma pagination');
      const terms = Array.isArray(orderBy) ? orderBy : [orderBy];
      const data = rows().filter(x => matches(x, where)).sort((a, b) => {
        for (const term of terms) { const [[key, direction]] = Object.entries(term); let av = a[key], bv = b[key];
          if (av instanceof Date) av = av.getTime(); if (bv instanceof Date) bv = bv.getTime();
          const cmp = av === bv ? 0 : av == null ? 1 : bv == null ? -1 : av < bv ? -1 : 1; if (cmp) return direction === 'desc' ? -cmp : cmp;
        } return 0;
      }); return data.slice(skip ?? 0, take === undefined ? undefined : (skip ?? 0) + take).map(x => projection(x, select));
    },
    count: async ({ where }) => { observed(); return rows().filter(x => matches(x, where)).length; },
    create: async ({ data }) => { observed(); const row = full(model, data); rows().push(row); return { ...row }; },
    update: async ({ where, data }) => { observed(); const row = rows().find(x => matches(x, where)); assert.ok(row); const converted = full(model, { ...row, ...data, updatedAt: epoch }); Object.assign(row, converted); return { ...row }; },
  };
}
const db = { crm_Opportunities: adapter('crm_Opportunities', () => opportunities), crm_Accounts: adapter('crm_Accounts', () => accounts), crm_Contacts: adapter('crm_Contacts', () => contacts),
  crm_Opportunities_Sales_Stages: adapter('crm_Opportunities_Sales_Stages', () => stages), crm_Opportunities_Type: adapter('crm_Opportunities_Type', () => types), users: adapter('Users', () => users),
  crm_AuditLog: { create: async ({ data }) => { observed(); audits.push(snapshot({ ...data, changes: data.changes ?? null })); return data; } } };
function load(relative) {
  const filename = path.resolve(root, relative); assert.ok(filename.startsWith(root + '/lib/') && filename.endsWith('.ts'));
  if (cache.has(filename)) return cache.get(filename).exports;
  const source = fs.readFileSync(filename, 'utf8'), mod = new Module(filename, module); cache.set(filename, mod); mod.filename = filename;
  hashes[path.relative(root, filename)] = crypto.createHash('sha256').update(source).digest('hex');
  mod.require = name => {
    if (name === '@/lib/prisma') return { prismadb: db };
    if (name === '@/inngest/client') return { inngest: { send: async event => { observed(); events.push(snapshot(event)); return { ids: [] }; } } };
    if (name === '@/lib/plugins/i18n') return { translatePluginMessage: () => 'Synthetic rule rejection' };
    if (name === 'zod' || name === 'node:async_hooks') return require(name);
    if (name.startsWith('@/lib/')) return load(name.slice(2) + '.ts');
    if (name.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(filename), name + '.ts')));
    throw Error('Blocked runtime import: ' + name);
  };
  mod._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, filename); return mod.exports;
}
(async () => {
  const { crmOpportunityTools: tools } = load('lib/mcp/tools/crm-opportunities.ts'), { runMcpToolCall } = load('lib/mcp/run-tool.ts'); ({ currentActorFrame } = load('lib/plugins/actor.ts'));
  const requests = [], cases = [], add = (label, user, tool, input) => requests.push({ label, user: uid(user), tool, input });
  for (const user of [1,2,3,4]) {
    add('options', user, 'crm_list_opportunity_options', {});
    for (const input of [{}, { limit: 2, offset: 1 }]) add('list', user, 'crm_list_opportunities', input);
    for (const id of [401,402,403,404,405,406,409,9998]) add('get', user, 'crm_get_opportunity', { id: uid(id) });
  }
  for (const query of ['alice','éclair','日本語','秘密','%','_','none']) add('search',1,'crm_search_opportunities',{query});
  for (const input of [
    { name: '  日本語  ' }, { name: '長'.repeat(600), budget: 9007199254740991, expected_revenue: 0, currency: 'JPY', next_step: '次', close_date: '2026-06-07T08:09:10.1239Z', sales_stage_id: uid(501), type_id: uid(801) },
    { name: 'qualified blocked', sales_stage_id: uid(502) }, { name: 'unknown stage', sales_stage_id: uid(9998) }, { name: 'unknown type', type_id: uid(9998) },
  ]) add('create',1,'crm_create_opportunity',input);
  for (const close_date of ['0000-01-01T00:00:00Z', '0001-01-01T00:00:00Z', '1582-10-10T03:04:05.1234Z', '9999-12-31T23:59:59.9999Z']) {
    add('proleptic-date-create',1,'crm_create_opportunity',{name:'日付の保存',close_date});
    add('proleptic-date-update',1,'crm_update_opportunity',{id:uid(401),close_date});
  }
  for (const [user,id] of [[1,401],[1,402],[1,403],[1,404],[1,405],[1,406],[1,409],[4,402]]) {
    add('update',user,'crm_update_opportunity',{id:uid(id),name:'  更新  ',budget:0,expected_revenue:42});
    add('delete',user,'crm_delete_opportunity',{id:uid(id)});
  }
  for (const [id,stage] of [[401,502],[407,502],[408,502],[401,501],[401,503],[401,null],[401,9998]]) add('stage',1,'crm_update_opportunity',{id:uid(id),sales_stage_id:stage===null?null:uid(stage)});
  add('no-stage-argument',1,'crm_update_opportunity',{id:uid(408),description:'must keep status and entry time'});
  for (const [field, values] of [['account',[null,101,102,103,105,9998]],['contact',[null,301,302,303,9998]],['assigned_to',[null,2,5,6,9998]],['type_id',[null,801,9998]]]) {
    for (const value of values) add('relation-'+field,1,'crm_update_opportunity',{id:uid(401),[field]:value===null?null:uid(value)});
  }
  for (const input of [{limit:1.5},{offset:0.5},{offset:2147483648}]) add('pagination',1,'crm_list_opportunities',input);
  for (const request of requests) {
    opportunities=seeds.map(x=>({...x}));audits=[];events=[];actors=[];
    const user=users.find(x=>x.id===request.user),tool=tools.find(x=>x.name===request.tool),args=tool.schema.parse(request.input);
    const result=await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>tool.handler(args,u.id,u));
    assert.ok(actors.length&&actors.every(x=>x?.type==='token'&&x.userId===user.id&&x.role===user.role));
    cases.push(snapshot({...request,result,state:opportunities,audits,events}));
  }
  hashes['prisma/schema.prisma']=crypto.createHash('sha256').update(schemaText).digest('hex');
  fs.writeFileSync(process.argv[2],JSON.stringify({epoch,previousStage,stages: snapshot(stages),types:snapshot(types),contacts:snapshot(contacts),seeds:snapshot(seeds),cases,sourceSHA256:hashes},null,2)+'\n');
  console.log(JSON.stringify({sourceOpportunityCases:cases.length,tools:tools.length,stages:stages.length,scope:'Actual original handlers/scopes/approval/stage/audit; synthetic Prisma and Inngest sinks, not live providers/plugins.'}));
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
