// Actual contact/user handlers and authorization executed against synthetic
// Prisma storage. This is a source oracle, not a live PostgreSQL comparison.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const crypto = require('node:crypto'), ts = require('typescript'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
const shared = JSON.parse(fs.readFileSync(path.join(__dirname, 'build/mcp-accounts-reference.json'), 'utf8'));
const models = require('@prisma/client').Prisma.dmmf.datamodel.models;
const schemaText = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8');
const epoch = shared.epoch, uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
function full(model, values) {
  const fields = models.find(x => x.name === model).fields.filter(x => x.kind !== 'object');
  const row = Object.fromEntries(fields.map(f => [f.name, f.isList ? [] : null]));
  // The installed Prisma runtime DMMF omits defaults and list metadata.
  const block = schemaText.match(new RegExp('model ' + model + '\\s*\\{([\\s\\S]*?)^\\}', 'm'))[1];
  for (const line of block.split('\n')) {
    const [field, type] = line.trim().split(/\s+/); if (!Object.hasOwn(row, field)) continue;
    if (type.endsWith('[]')) row[field] = [];
    const expression = line.match(/@default\(([^)]*)\)/)?.[1];
    if (expression?.startsWith('now(') || line.includes('@updatedAt')) row[field] = epoch;
    else if (expression?.startsWith('uuid(')) row[field] = uid(9999);
    else if (expression !== undefined) { try { row[field] = JSON.parse(expression); } catch { row[field] = expression; } }
  }
  return { ...row, ...values };
}
const users = [...shared.users, { id: uid(7), name: null, email: 'null@example.invalid', role: 'user', userStatus: 'ACTIVE' },
  { id: uid(8), name: 'pending', email: 'pending@example.invalid', role: 'user', userStatus: 'PENDING' },
  { id: uid(9), name: 'banned', email: 'banned@example.invalid', role: 'user', userStatus: 'ACTIVE', banned: true },
  { id: uid(10), name: 'alice', email: 'another@example.invalid', role: 'user', userStatus: 'ACTIVE' },
  { id: uid(11), name: 'Éclair 東京', email: 'unicode@example.invalid', role: 'user', userStatus: 'ACTIVE' },
].map(x => full('Users', { password: 'synthetic-never-expose', banReason: 'synthetic-private', ...x }));
const seeds = [
  { id: uid(301), last_name: 'Alice 東京', first_name: 'Éclair', assigned_to: uid(1), createdBy: uid(1), email: 'contact@example.invalid', office_phone: '03-1234', mobile_phone: '090-5678', description: 'description-only' },
  { id: uid(302), last_name: 'Bob 秘密', assigned_to: uid(2), createdBy: uid(2) },
  { id: uid(303), last_name: '企業所有で閲覧', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(101) },
  { id: uid(304), last_name: 'ウォッチで閲覧', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(103) },
  { id: uid(305), last_name: '削除された連絡先', assigned_to: uid(1), createdBy: uid(1), deletedAt: epoch },
  { id: uid(306), last_name: '削除された親企業', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(105) },
  { id: uid(307), last_name: '作成者で閲覧', assigned_to: uid(2), createdBy: uid(1) },
  { id: uid(308), last_name: '秘密の企業', assigned_to: uid(2), createdBy: uid(2), accountsIDs: uid(102) },
  { id: uid(309), last_name: '所有者なしの関連先', accountsIDs: uid(101) },
  { id: uid(310), last_name: '旧列は権限に使わない', assigned_to: uid(2), createdBy: uid(2), account: uid(101) },
  { id: uid(311), last_name: '古い作成日', assigned_to: uid(1), createdBy: uid(1), created_on: '2000-01-01T00:00:00.000Z' },
].map(x => full('crm_Contacts', x));
const accounts = shared.seeds.map(x => full('crm_Accounts', x));
const emailAccounts = [
  { id: uid(401), userId: uid(1), label: '仕事用メール', isActive: true },
  { id: uid(402), userId: uid(1), label: '別のメール', isActive: true },
  { id: uid(403), userId: uid(1), label: '無効なメール', isActive: false },
  { id: uid(404), userId: uid(2), label: '他人のメール', isActive: true },
  { id: uid(405), userId: uid(3), label: '管理者自身のメール', isActive: true },
].map(x => full('EmailAccount', { imapHost: 'imap.example.invalid', imapPort: 993, imapSsl: true, smtpHost: 'smtp.example.invalid', smtpPort: 465, smtpSsl: true, username: 'fixture@example.invalid', passwordEncrypted: 'synthetic-secret-never-expose', sentFolderName: 'Sent', ...x }));
let contacts = [], actorReads = [], currentActorFrame;
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
function project(row, select) { return !row ? null : select ? Object.fromEntries(Object.keys(select).map(k => [k, row[k]])) : { ...row }; }
function adapter(model, rows) {
  function observed() { actorReads.push(currentActorFrame()?.actor); }
  return {
    findFirst: async ({ where, select }) => { observed(); return project(rows().find(x => matches(x, where)), select); },
    findMany: async ({ where, select, orderBy, take, skip }) => {
      observed(); assert.ok(Array.isArray(orderBy));
      if (!Number.isInteger(take) || !Number.isInteger(skip) || skip > 2147483647) throw Error('Prisma pagination requires representable integers');
      const ordered = rows().filter(x => matches(x, where)).sort((a, b) => {
        for (const term of orderBy) { const [[key, direction]] = Object.entries(term), av = a[key], bv = b[key];
          const cmp = av === bv ? 0 : av == null ? 1 : bv == null ? -1 : av < bv ? -1 : 1;
          if (cmp) return direction === 'desc' ? -cmp : cmp;
        } return 0;
      });
      return ordered.slice(skip, skip + take).map(x => project(x, select));
    },
    count: async ({ where }) => { observed(); return rows().filter(x => matches(x, where)).length; },
    create: async ({ data }) => { observed(); const row = full(model, data); rows().push(row); return { ...row }; },
    update: async ({ where, data }) => { observed(); const row = rows().find(x => matches(x, where)); assert.ok(row); Object.assign(row, data, { updatedAt: epoch }); return { ...row }; },
  };
}
const db = { crm_Contacts: adapter('crm_Contacts', () => contacts), crm_Accounts: adapter('crm_Accounts', () => accounts), users: adapter('Users', () => users), emailAccount: adapter('EmailAccount', () => emailAccounts) };
function load(relative) {
  const filename = path.resolve(root, relative); assert.ok(filename.startsWith(root + '/lib/') && filename.endsWith('.ts'));
  if (cache.has(filename)) return cache.get(filename).exports;
  const source = fs.readFileSync(filename, 'utf8'), mod = new Module(filename, module); cache.set(filename, mod); mod.filename = filename;
  hashes[path.relative(root, filename)] = crypto.createHash('sha256').update(source).digest('hex');
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
  const tools = [...load('lib/mcp/tools/crm-contacts.ts').crmContactTools, ...load('lib/mcp/tools/crm-users.ts').crmUserTools, ...load('lib/mcp/tools/crm-email-accounts.ts').crmEmailAccountTools];
  const { runMcpToolCall } = load('lib/mcp/run-tool.ts'); ({ currentActorFrame } = load('lib/plugins/actor.ts'));
  const requests = [], cases = [];
  const add = (user, tool, input, label = tool) => requests.push({ user: uid(user), tool, input, label });
  for (const user of [1, 2, 3, 4]) {
    add(user, 'crm_list_email_accounts', {});
    add(user, 'crm_list_email_accounts', { limit: 1, offset: 1 });
    for (const input of [{}, { limit: 2, offset: 1 }]) add(user, 'crm_list_contacts', input);
    for (const row of [301, 302, 303, 304, 305, 306, 309, 310, 9998]) add(user, 'crm_get_contact', { id: uid(row) });
    for (const status of [undefined, 'ACTIVE', 'INACTIVE', 'PENDING', 'ALL']) add(user, 'crm_list_users', status ? { status } : {});
  }
  for (const query of ['alice','éclair','東京','contact@','03-1234','090-5678','description-only','%','秘密']) add(1, 'crm_search_contacts', { query });
  for (const query of ['ALICE','éclair','%','inactive']) add(1, 'crm_list_users', { query, status: 'ALL' });
  add(3, 'crm_list_users', { limit: 2, offset: 1, status: 'ALL' });
  add(1, 'crm_create_contact', { last_name: '  日本語  ', first_name: '長'.repeat(600), email: 'new@example.invalid', office_phone: '+81', mobile_phone: '090', position: '担当', account: uid(102), assigned_to: uid(2) });
  add(1, 'crm_create_contact', { last_name: ' ' });
  for (const [user, row] of [[1,301],[1,302],[1,303],[1,304],[1,305],[1,306],[1,307],[1,309],[4,302]]) {
    add(user, 'crm_update_contact', { id: uid(row), last_name: ' 更新 ', first_name: '名前' });
    add(user, 'crm_delete_contact', { id: uid(row) });
  }
  for (const account of [null, uid(101), uid(102), uid(103), uid(105), uid(9998)]) add(1, 'crm_update_contact', { id: uid(301), account }, 'relink');
  for (const assigned_to of [null, uid(2), uid(5), uid(6), uid(9998)]) add(1, 'crm_update_contact', { id: uid(301), assigned_to }, 'reassign');
  for (const tool of ['crm_list_contacts', 'crm_list_users']) for (const input of [{ limit: 1.5 }, { offset: 0.5 }, { offset: 2147483648 }]) add(1, tool, input);
  for (const request of requests) {
    contacts = seeds.map(x => ({ ...x })); actorReads = [];
    const user = users.find(x => x.id === request.user), tool = tools.find(x => x.name === request.tool);
    const args = tool.schema.parse(request.input);
    const result = await runMcpToolCall(async () => ({ id: user.id, role: user.role }), u => tool.handler(args, u.id, u));
    assert.ok(actorReads.length && actorReads.every(x => x?.type === 'token' && x.userId === user.id && x.role === user.role));
    cases.push({ ...request, result, state: contacts });
  }
  for (const f of ['prisma/schema.prisma', 'node_modules/@prisma/client/package.json', 'node_modules/zod/package.json']) hashes[f] = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, f))).digest('hex');
  const { Decimal } = require('@prisma/client').Prisma;
  const decimalCases = ['0','-0','000.000','1.2300','-12.3400','0.0000001','0.000001','-0.00000001','100000000000000000000','1000000000000000000000','123456789.12345678','00012.34000','0.000000123400','99999999999999999999999999999999999999','-1000.00'].map(input => ({ input, output: new Decimal(input).toJSON() }));
  const utcCases = ['0000-01-01T00:00:00Z','0000-02-29T23:59:59.1234Z','0001-01-01T00:00:00Z','1582-10-10T03:04:05.98765Z','9999-12-31T23:59:59.99999Z','2026-01-02T03:04Z','2026-01-02T03:04:05.1Z','2026-01-02T03:04:05.12Z','2026-01-02T03:04:05.000Z'].map(input => ({ input, output: new Date(input).toISOString() }));
  fs.writeFileSync(process.argv[2], JSON.stringify({ epoch, users, seeds, emailAccounts, cases, decimalCases, utcCases, tools: tools.map(x => x.name), sourceSHA256: hashes }, null, 2) + '\n');
  console.log(JSON.stringify({ sourcePeopleCases: cases.length, tools: tools.length, scope: 'Actual original contact/user handlers and scopes; synthetic Prisma, no live PostgreSQL/plugins.' }));
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
