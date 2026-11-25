// Execute the original six handlers, authorization scopes and run-tool envelope
// against a synthetic in-memory Prisma adapter. No provider/database access.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
const epoch = '2026-01-02T03:04:05.678Z';
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const users = [
  { id: uid(1), name: 'alice', role: 'user', userStatus: 'ACTIVE' },
  { id: uid(2), name: 'bob', role: 'user', userStatus: 'ACTIVE' },
  { id: uid(3), name: 'manager', role: 'manager', userStatus: 'ACTIVE' },
  { id: uid(4), name: 'admin', role: 'admin', userStatus: 'ACTIVE' },
  { id: uid(5), name: 'inactive', role: 'user', userStatus: 'INACTIVE' },
  { id: uid(6), name: 'partner', role: 'partner', userStatus: 'ACTIVE' },
].map(x => ({ ...x, email: x.name + '@example.invalid', banned: false }));
const alice = users[0], bob = users[1];
const seeds = [
  { id: uid(101), name: 'Alice 東京', assigned_to: alice.id, createdBy: alice.id, website: 'https://EXAMPLE.jp/案件', email: 'visible@example.invalid' },
  { id: uid(102), name: 'Bob 秘密', assigned_to: bob.id, createdBy: bob.id, website: 'https://private.example' },
  { id: uid(103), name: 'ウォッチ企業', assigned_to: bob.id, createdBy: bob.id },
  { id: uid(104), name: '作成者の企業', assigned_to: bob.id, createdBy: alice.id },
  { id: uid(105), name: '削除済み', assigned_to: alice.id, createdBy: alice.id, deletedAt: epoch },
  { id: uid(106), name: 'Éclair 東京', assigned_to: alice.id, createdBy: alice.id },
  { id: uid(107), name: '100% 工業', assigned_to: alice.id, createdBy: alice.id },
  { id: uid(108), name: 'a_b', assigned_to: alice.id, createdBy: alice.id },
  { id: uid(109), name: 'acb', assigned_to: alice.id, createdBy: alice.id },
  { id: uid(110), name: 'a😀b', assigned_to: alice.id, createdBy: alice.id },
  { id: uid(111), name: 'email-only', email: 'only-match@example.invalid', description: 'description-only', assigned_to: alice.id, createdBy: alice.id },
].map(x => ({ v: 0, createdAt: epoch, updatedAt: epoch, status: 'Active', ...x }));
const watchers = [{ account_id: uid(103), user_id: alice.id }];
const fields = require('@prisma/client').Prisma.dmmf.datamodel.models.find(x => x.name === 'crm_Accounts').fields.filter(x => x.kind !== 'object');
const schemaText = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8');
const modelText = schemaText.match(/model crm_Accounts\s*\{([\s\S]*?)^\}/m)[1];
function full(values) {
  const row = Object.fromEntries(fields.map(x => [x.name, null]));
  for (const line of modelText.split('\n')) {
    const field = line.trim().split(/\s+/)[0]; if (!Object.hasOwn(row, field)) continue;
    const expression = line.match(/@default\(([^)]*)\)/)?.[1];
    if (expression?.startsWith('now(') || line.includes('@updatedAt')) row[field] = epoch;
    else if (expression?.startsWith('uuid(')) row[field] = uid(999);
    else if (expression !== undefined) { try { row[field] = JSON.parse(expression); } catch {} }
  }
  return { ...row, ...values };
}
let rows = [], actorReads = [];
function patternMatches(value, query) {
  if (value == null) return false;
  const pattern = '%' + query + '%'; let expression = '^', escape = false;
  for (const char of pattern) {
    if (escape) { expression += char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); escape = false; }
    else if (char === '\\') escape = true;
    else if (char === '%') expression += '[\\s\\S]*';
    else if (char === '_') expression += '[\\s\\S]';
    else expression += char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(expression + '$', 'iu').test(value);
}
function matches(row, where) {
  return Object.entries(where ?? {}).every(([key, value]) => {
    if (key === 'OR') return value.some(x => matches(row, x));
    if (key === 'AND') return value.every(x => matches(row, x));
    if (key === 'watchers') return watchers.some(w => w.account_id === row.id && matches(w, value.some));
    if (value && typeof value === 'object' && 'contains' in value) return patternMatches(row[key], value.contains);
    return row[key] === value;
  });
}
function projection(row, select) { return !row ? null : select ? Object.fromEntries(Object.keys(select).map(k => [k, row[k]])) : { ...row }; }
let currentActorFrame;
function observed() { actorReads.push(currentActorFrame()?.actor); }
const db = {
  crm_Accounts: {
    findFirst: async ({ where, select }) => { observed(); return projection(rows.find(x => matches(x, where)), select); },
    findMany: async ({ where, take, skip, orderBy }) => {
      observed(); assert.deepEqual(orderBy, [{ createdAt: 'desc' }, { id: 'desc' }]);
      if (!Number.isInteger(take) || !Number.isInteger(skip) || skip > 2147483647) throw Error('Prisma pagination requires representable integers');
      return rows.filter(x => matches(x, where)).sort((a, b) => b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id)).slice(skip, skip + take).map(x => ({ ...x }));
    },
    count: async ({ where }) => { observed(); return rows.filter(x => matches(x, where)).length; },
    create: async ({ data }) => { observed(); const row = full(data); rows.push(row); return { ...row }; },
    update: async ({ where, data }) => { observed(); const row = rows.find(x => matches(x, where)); assert.ok(row); Object.assign(row, data, { updatedAt: epoch }); return { ...row }; },
  },
  users: { findFirst: async ({ where, select }) => { observed(); return projection(users.find(x => matches(x, where)), select); } },
};
function load(relative) {
  const filename = path.resolve(root, relative);
  assert.ok(filename.startsWith(root + '/lib/') && filename.endsWith('.ts'));
  if (cache.has(filename)) return cache.get(filename).exports;
  const source = fs.readFileSync(filename, 'utf8'), mod = new Module(filename, module); cache.set(filename, mod);
  hashes[path.relative(root, filename)] = crypto.createHash('sha256').update(source).digest('hex');
  mod.filename = filename;
  mod.require = name => {
    if (name === '@/lib/prisma') return { prismadb: db };
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
  const { crmAccountTools } = load('lib/mcp/tools/crm-accounts.ts');
  const { runMcpToolCall } = load('lib/mcp/run-tool.ts');
  ({ currentActorFrame } = load('lib/plugins/actor.ts'));
  const cases = [], requests = [];
  function add(label, user, tool, input) { requests.push({ label, user: user.id, tool, input }); }
  for (const user of [alice, bob, users[2], users[3]]) {
    add('list-' + user.name, user, 'crm_list_accounts', {});
    add('paged-' + user.name, user, 'crm_list_accounts', { limit: 2, offset: 1 });
    for (const id of [101, 102, 103, 104, 105, 9999]) add('get-' + user.name + '-' + id, user, 'crm_get_account', { id: uid(id) });
  }
  for (const query of ['alice', 'example.JP', '東京', 'éclair', 'Bob', 'only-match', 'description-only', '%', 'a_b', 'a\\_b', '\\%', '100\\', "' OR 1=1 --"]) add('search-' + query, alice, 'crm_search_accounts', { query });
  for (const input of [{ name: '  日本語の企業  ' }, { name: ' ' }, { name: '長'.repeat(600), email: 'new@example.invalid', description: '説明', office_phone: '+81-3-0000', website: 'https://example.invalid', assigned_to: bob.id }]) add('create', alice, 'crm_create_account', input);
  for (const [user, id] of [[alice,101],[alice,102],[alice,103],[alice,105],[users[3],102]]) {
    add('update-' + user.name + '-' + id, user, 'crm_update_account', { id: uid(id), name: '  更新  ' });
    add('delete-' + user.name + '-' + id, user, 'crm_delete_account', { id: uid(id) });
  }
  for (const assigned_to of [null, bob.id, users[4].id, uid(9999), users[5].id]) add('reassign-' + assigned_to, alice, 'crm_update_account', { id: uid(101), assigned_to });
  for (const input of [{ limit: 1.5 }, { offset: 0.5 }, { offset: 2147483648 }]) add('fractional-or-large-pagination', alice, 'crm_list_accounts', input);
  for (const request of requests) {
    rows = seeds.map(full); actorReads = [];
    const user = users.find(x => x.id === request.user), tool = crmAccountTools.find(x => x.name === request.tool);
    const args = tool.schema.parse(request.input);
    const result = await runMcpToolCall(async () => ({ id: user.id, role: user.role }), mcpUser => tool.handler(args, mcpUser.id, mcpUser));
    assert.ok(actorReads.length > 0 && actorReads.every(x => x?.type === 'token' && x.userId === user.id && x.role === user.role));
    cases.push({ ...request, result, state: rows });
  }
  hashes['prisma/schema.prisma'] = crypto.createHash('sha256').update(schemaText).digest('hex');
  fs.writeFileSync(process.argv[2], JSON.stringify({ epoch, users, seeds, watchers, fields: fields.map(x => ({ name: x.name, type: x.type })), cases, sourceSHA256: hashes }, null, 2) + '\n');
  console.log(JSON.stringify({ sourceAccountCases: cases.length, sourceTools: crmAccountTools.length, sourceModules: Object.keys(hashes).length, scope: 'Actual original account handlers/scopes/run-tool with synthetic Prisma adapter; live PostgreSQL/plugins not exercised' }));
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
