// Run the actual original lead MCP handlers + shared service, scopes, domain
// audit and actor wrapper. Prisma, email and Inngest are isolated capture sinks.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
process.env.NEXT_PUBLIC_APP_URL = 'https://fixture.invalid'; process.env.EMAIL_FROM = 'fixture@example.invalid';
const schema = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8');
const shared = JSON.parse(fs.readFileSync(path.join(__dirname, 'build/mcp-accounts-reference.json'), 'utf8'));
const models = require('@prisma/client').Prisma.dmmf.datamodel.models;
const epoch = shared.epoch, uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
function full(model, values) {
  const fields = models.find(x => x.name === model).fields.filter(x => x.kind !== 'object');
  const row = Object.fromEntries(fields.map(x => [x.name, null]));
  const block = schema.match(new RegExp('model ' + model + '\\s*\\{([\\s\\S]*?)^\\}', 'm'))[1];
  for (const line of block.split('\n')) {
    const [field, type] = line.trim().split(/\s+/); if (!Object.hasOwn(row, field)) continue;
    const expression = line.match(/@default\(([^)]*)\)/)?.[1];
    if (type.endsWith('[]')) row[field] = [];
    if (expression?.startsWith('now(') || line.includes('@updatedAt')) row[field] = epoch;
    else if (expression?.startsWith('uuid(')) row[field] = uid(9999);
    else if (expression !== undefined) { try { row[field] = JSON.parse(expression); } catch { row[field] = expression; } }
  }
  return { ...row, ...values };
}
const users = shared.users.map(x => full('Users', x));
const accounts = shared.seeds.map(x => full('crm_Accounts', x));
const optionNames = ['crm_Lead_Statuses', 'crm_Lead_Sources', 'crm_Lead_Types'];
const options = Object.fromEntries(optionNames.map((model, modelIndex) => [model, JSON.parse(fs.readFileSync(path.join(root, 'prisma/initial-data/' + model + '.json'), 'utf8')).map((x, index) => full(model, { id: uid(10000 + modelIndex * 1000 + index), ...x }))]));
options.crm_Lead_Statuses.push(...Array.from({ length: 205 }, (_, i) => full('crm_Lead_Statuses', { id: uid(20000 + i), name: 'ZZ-fixture-' + String(i).padStart(3, '0') })));
const seeds = [
  { id: uid(401), firstName: 'Éclair', lastName: 'Alice 東京', email: 'lead@example.invalid', company: '営業株式会社', phone: 'phone-only', description: 'description-only', assigned_to: uid(1), createdBy: uid(1), lead_status_id: options.crm_Lead_Statuses[0].id },
  { id: uid(402), lastName: 'Bob 秘密', assigned_to: uid(2), createdBy: uid(2) },
  { id: uid(403), lastName: '企業所有で閲覧', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(101) },
  { id: uid(404), lastName: 'ウォッチで閲覧', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(103) },
  { id: uid(405), lastName: '削除済み', assigned_to: uid(1), createdBy: uid(1), deletedAt: epoch },
  { id: uid(406), lastName: '削除された親企業', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(105) },
  { id: uid(407), lastName: '作成者で閲覧', assigned_to: uid(2), createdBy: uid(1) },
  { id: uid(408), lastName: '秘密の企業', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(102) },
  { id: uid(409), lastName: '所有者なしの関連先', accountsIDs: uid(101), createdAt: null },
  { id: uid(410), lastName: '古い作成日', assigned_to: uid(1), createdBy: uid(1), createdAt: '2000-01-01T00:00:00.000Z' },
  { id: uid(411), lastName: '現在の担当者は無効', assigned_to: uid(5), createdBy: uid(1) },
].map(x => full('crm_Leads', { v: 0, ...x }));
let uiUser;
let leads = [], audit = [], events = [], mails = [], actorReads = [], currentActorFrame;
function observed() { actorReads.push(currentActorFrame()?.actor); }
function pattern(value, query) {
  if (value == null) return false;
  let expression = '^', escape = false;
  for (const char of '%' + query + '%') {
    if (escape) { expression += char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); escape = false; }
    else if (char === '\\') escape = true;
    else if (char === '%') expression += '[\\s\\S]*';
    else if (char === '_') expression += '[\\s\\S]';
    else expression += char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(expression + '$', 'iu').test(value);
}
function matches(row, where = {}) {
  return Object.entries(where).every(([key, value]) => {
    if (key === 'OR') return value.some(x => matches(row, x));
    if (key === 'AND') return value.every(x => matches(row, x));
    if (key === 'assigned_accounts') return accounts.some(x => x.id === row.accountsIDs && matches(x, value));
    if (key === 'watchers') return shared.watchers.some(x => x.account_id === row.id && matches(x, value.some));
    assert.ok(Object.hasOwn(row, key), 'unimplemented oracle field ' + key);
    if (value && typeof value === 'object' && 'contains' in value) return pattern(row[key], value.contains);
    return row[key] === value;
  });
}
function projection(row, select) { return !row ? null : select ? Object.fromEntries(Object.keys(select).map(k => [k, row[k]])) : { ...row }; }
function adapter(model, rows) {
  const find = async ({ where, select }) => { observed(); return projection(rows().find(x => matches(x, where)), select); };
  return {
    findFirst: find, findUnique: find,
    findMany: async ({ where, select, orderBy, take, skip }) => {
      observed(); const unpaged = take === undefined && skip === undefined;
      if (!unpaged && (!Number.isInteger(take) || !Number.isInteger(skip) || skip > 2147483647)) throw Error('Prisma pagination requires representable integers');
      const terms = Array.isArray(orderBy) ? orderBy : [orderBy];
      const ordered = rows().filter(x => matches(x, where)).sort((a, b) => {
        for (const term of terms) { const [[key, direction]] = Object.entries(term), av = a[key], bv = b[key];
          const cmp = av === bv ? 0 : av == null ? 1 : bv == null ? -1 : av < bv ? -1 : 1;
          if (cmp) return direction === 'desc' ? -cmp : cmp;
        } return 0;
      });
      return (unpaged ? ordered : ordered.slice(skip, skip + take)).map(x => projection(x, select));
    },
    count: async ({ where }) => { observed(); return rows().filter(x => matches(x, where)).length; },
    create: async ({ data }) => { observed(); const row = full(model, data); rows().push(row); return { ...row }; },
    update: async ({ where, data }) => { observed(); const row = rows().find(x => matches(x, where)); assert.ok(row); Object.assign(row, data, { updatedAt: epoch }); return { ...row }; },
  };
}
const db = { crm_Leads: adapter('crm_Leads', () => leads), crm_Accounts: adapter('crm_Accounts', () => accounts), users: adapter('Users', () => users),
  crm_AuditLog: { create: async ({ data }) => { observed(); audit.push({ ...data, changes: data.changes ?? null }); return data; } },
  ...Object.fromEntries(optionNames.map(model => [model, adapter(model, () => options[model])])),
};
function load(relative) {
  const filename = path.resolve(root, relative); assert.ok((filename.startsWith(root + '/lib/') || filename.startsWith(root + '/actions/crm/leads/')) && filename.endsWith('.ts'));
  if (cache.has(filename)) return cache.get(filename).exports;
  const source = fs.readFileSync(filename, 'utf8'), mod = new Module(filename, module); cache.set(filename, mod); mod.filename = filename;
  hashes[path.relative(root, filename)] = crypto.createHash('sha256').update(source).digest('hex');
  mod.require = name => {
    if (name === 'next/cache') return { revalidatePath: () => {} };
    if (name === '@/lib/authz') return { ...load('lib/authz/errors.ts'), requireAuthenticated: async () => uiUser };
    if (name === '@/lib/plugins/action-errors') return { pluginRuleErrorMessage: async () => null };
    if (name === '@/lib/prisma') return { prismadb: db };
    if (name === '@/lib/sendmail') return { default: async value => { observed(); mails.push(value); } };
    if (name === '@/inngest/client') return { inngest: { send: async value => { observed(); events.push(value); } } };
    if (name === '@/lib/plugins/i18n') return { translatePluginMessage: () => 'Synthetic rule rejection' };
    if (name === 'zod' || name === 'node:async_hooks') return require(name);
    if (name.startsWith('@/lib/')) return load(name.slice(2) + '.ts');
    if (name.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(filename), name + '.ts')));
    throw Error('Blocked runtime import: ' + name);
  };
  mod._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, filename);
  return mod.exports;
}
(async () => {
  const tools = load('lib/mcp/tools/crm-leads.ts').crmLeadTools, { runMcpToolCall } = load('lib/mcp/run-tool.ts');
  ({ currentActorFrame } = load('lib/plugins/actor.ts'));
  const requests = [], cases = [], add = (user, tool, input, label = tool) => requests.push({ user: uid(user), tool, input, label });
  for (const user of [1, 2, 3, 4]) {
    add(user, 'crm_list_lead_options', {});
    for (const input of [{}, { limit: 2, offset: 1 }]) add(user, 'crm_list_leads', input);
    for (const row of [401,402,403,404,405,406,409,411,9998]) add(user, 'crm_get_lead', { id: uid(row) });
  }
  for (const query of ['alice','éclair','東京','lead@','営業','phone-only','description-only','%','秘密']) add(1, 'crm_search_leads', { query });
  add(1, 'crm_create_lead', { lastName: '  日本語  ', firstName: '長'.repeat(600), email: 'new@example.invalid', company: '会社', phone: '+81', jobTitle: '担当', description: '説明', campaign: '案件', refered_by: '紹介者', accountsIDs: uid(102), assigned_to: uid(2) });
  add(1, 'crm_create_lead', { lastName: ' ' });
  add(1, 'crm_create_lead', { lastName: '設定付き', lead_status_id: options.crm_Lead_Statuses[0].id, lead_source_id: options.crm_Lead_Sources[0].id, lead_type_id: options.crm_Lead_Types[0].id });
  for (const key of ['lead_status_id','lead_source_id','lead_type_id']) {
    add(1, 'crm_create_lead', { lastName: '無効な設定', [key]: uid(9998) });
    add(1, 'crm_update_lead', { id: uid(401), [key]: uid(9998) });
    add(1, 'crm_update_lead', { id: uid(401), [key]: null });
  }
  for (const [user, row] of [[1,401],[1,402],[1,403],[1,404],[1,405],[1,406],[1,407],[1,409],[4,402]]) {
    add(user, 'crm_update_lead', { id: uid(row), lastName: ' 更新 ', firstName: '名前' });
    add(user, 'crm_delete_lead', { id: uid(row) });
  }
  for (const assigned_to of [null,uid(1),uid(2),uid(5),uid(6),uid(9998)]) add(1, 'crm_update_lead', { id: uid(401), assigned_to }, 'reassign');
  add(1, 'crm_update_lead', { id: uid(407), assigned_to: uid(2) }, 'same-assignee-no-mail');
  add(1, 'crm_update_lead', { id: uid(411), assigned_to: uid(5) }, 'unchanged-inactive-assignee-allowed');
  for (const input of [{ limit: 1.5 }, { offset: 0.5 }, { offset: 2147483648 }]) add(1, 'crm_list_leads', input);
  for (const request of requests) {
    leads = seeds.map(x => ({ ...x })); audit = []; events = []; mails = []; actorReads = [];
    const user = users.find(x => x.id === request.user), tool = tools.find(x => x.name === request.tool), args = tool.schema.parse(request.input);
    const result = await runMcpToolCall(async () => ({ id: user.id, role: user.role }), u => tool.handler(args, u.id, u));
    assert.ok(actorReads.length && actorReads.every(x => x?.type === 'token' && x.userId === user.id && x.role === user.role));
    cases.push({ ...request, result, state: leads, audit, events, mails });
  }
  const uiCases = [], uiRequests = [];
  const createLead = load('actions/crm/leads/create-lead.ts').createLead, updateLead = load('actions/crm/leads/update-lead.ts').updateLead;
  for (const user of [1,3,4]) {
    for (const assigned_to of [undefined,uid(user),uid(2),uid(5),uid(9998)]) uiRequests.push({user:uid(user),create:true,input:{last_name:'画面で新規作成',first_name:'日本語',assigned_to}});
    for (const [row,assigned_to] of [[401,uid(2)],[401,uid(user)],[401,uid(5)],[401,uid(9998)],[407,uid(2)],[411,uid(5)],[402,uid(2)]]) uiRequests.push({user:uid(user),create:false,input:{id:uid(row),lastName:'画面で更新',assigned_to}});
  }
  for (const request of uiRequests) {
    leads = seeds.map(x => ({...x})); audit=[]; events=[]; mails=[]; actorReads=[]; uiUser=users.find(x=>x.id===request.user);
    const result=await (request.create?createLead:updateLead)(request.input);
    uiCases.push({...request,result,mails,events});
  }
  for (const f of ['prisma/schema.prisma', ...optionNames.map(x => 'prisma/initial-data/' + x + '.json'), 'node_modules/@prisma/client/package.json', 'node_modules/zod/package.json']) hashes[f] = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, f))).digest('hex');
  fs.writeFileSync(process.argv[2], JSON.stringify({ epoch, users, seeds, options, cases, uiCases, tools: tools.map(x => x.name), sourceSHA256: hashes }, null, 2) + '\n');
  console.log(JSON.stringify({ sourceLeadCases: cases.length, sourceUIActions: uiCases.length, tools: tools.length, scope: 'Actual original lead handlers/service/scopes/audit/notification decisions with synthetic Prisma/email/Inngest; no external activity.' }));
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
