// Executes the original implementations with an isolated in-memory Prisma adapter.
// All token material here is synthetic; no real database, session or network.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const crypto = require('node:crypto'), assert = require('node:assert/strict'), ts = require('typescript');
const root = path.resolve(__dirname, '../..');
function original(relative, replacements) {
  const filename = path.join(root, relative), mod = new Module(filename, module);
  mod.filename = filename; mod.paths = Module._nodeModulePaths(path.dirname(filename));
  const inherited = mod.require.bind(mod);
  mod.require = name => Object.hasOwn(replacements, name) ? replacements[name] : inherited(name);
  mod._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true,
  }}).outputText, filename);
  return mod.exports;
}
(async () => {
  const RealDate = Date, epoch = 1795000000000;
  global.Date = class extends RealDate { constructor(...args) { super(...(args.length ? args : [epoch])); } static now() { return epoch; } };
  let serial = 0, rows = [], user = {id: 'owner', role: 'user', userStatus: 'ACTIVE'}, session = {user};
  let authorization = '', updateFailure = false, checks = 0;
  const check = (value, label) => { assert.ok(value, label); checks++; };
  function matches(row, where) {
    return Object.entries(where).every(([k, v]) => {
      if (k === 'OR') return v.some(w => matches(row, w));
      if (v && typeof v === 'object' && 'gt' in v) return row[k] != null && row[k] > v.gt;
      return row[k] === v;
    });
  }
  const db = {apiToken: {
    count: async ({where}) => rows.filter(r => matches(r, where)).length,
    create: async ({data}) => { const r = {id: 'token-' + ++serial, createdAt: new Date(), revokedAt: null, lastUsedAt: null, ...data}; rows.push(r); return r; },
    findUnique: async ({where}) => rows.find(r => matches(r, where)) ?? null,
    update: async ({where, data}) => { if (updateFailure) throw Error('synthetic-last-use-error'); const r = rows.find(r => matches(r, where)); assert.ok(r); return Object.assign(r, data); },
    updateMany: async ({where, data}) => { const found = rows.filter(r => matches(r, where)); found.forEach(r => Object.assign(r, data)); return {count: found.length}; },
    findMany: async ({where, select}) => rows.filter(r => matches(r, where)).sort((a,b) => b.createdAt - a.createdAt).map(r => Object.fromEntries(Object.keys(select).map(k => [k,r[k]]))),
  }, users: {findUnique: async () => user}};
  const tokens = original('lib/api-tokens.ts', {'@/lib/prisma': {prismadb: db}, crypto: {
    ...crypto, randomBytes: n => Buffer.alloc(n, serial + 1),
  }});
  const outcome = async f => { try { return {value: await f()}; } catch (e) { return {error: e.message}; } };
  const issued = await tokens.generateApiToken('owner', '日本語の接続');
  check(/^nxtc__[0-9a-f]{48}$/.test(issued.rawToken), 'wire format');
  const row = rows[0];
  check(row.tokenHash === crypto.createHash('sha256').update(issued.rawToken).digest('hex'), 'hash algorithm');
  check(row.tokenPrefix === issued.rawToken.slice(6,14) && !Object.values(row).includes(issued.rawToken), 'hash-only persistence');
  const validation = [];
  for (const [label, expiryOffsetMS, revoked, raw] of [
    ['valid', null, false, issued.rawToken], ['future', 1, false, issued.rawToken],
    ['exact-expiry', 0, false, issued.rawToken], ['expired', -1, false, issued.rawToken],
    ['revoked', null, true, issued.rawToken], ['wrong-prefix', null, false, 'wrong'],
    ['unknown', null, false, 'nxtc__unknown'],
  ]) {
    row.expiresAt = expiryOffsetMS === null ? null : new Date(epoch + expiryOffsetMS);
    row.revokedAt = revoked ? new Date() : null;
    const result = await outcome(() => tokens.validateApiToken(raw));
    validation.push({label, expiryOffsetMS, revoked, raw, ...result});
  }
  check(validation[2].value === 'owner' && validation[3].error === 'Invalid token', 'source strict-less expiry edge');
  row.expiresAt = null; row.revokedAt = null; updateFailure = true;
  check(await tokens.validateApiToken(issued.rawToken) === 'owner', 'lastUsedAt write failure is nonfatal');
  updateFailure = false;
  const listing = await tokens.listApiTokens('owner');
  check(!('tokenHash' in listing[0]) && !('userId' in listing[0]), 'list excludes credential fields');
  check((await outcome(() => tokens.revokeApiToken(row.id, 'other'))).error === 'Not found', 'owner revoke isolation');
  for (let i = 1; i < 10; i++) await tokens.generateApiToken('owner', 'connection-' + i);
  check((await outcome(() => tokens.generateApiToken('owner', 'eleven'))).error === 'Maximum 10 active tokens allowed per user', 'ten token limit');
  rows[0].expiresAt = new Date(epoch);
  await tokens.generateApiToken('owner', 'equality-not-active');
  check(rows.length === 11, 'count uses strict greater expiry');
  check(await tokens.revokeAllApiTokens('owner') === 11, 'revoke all includes expired tokens');
  check(await tokens.revokeAllApiTokens('owner') === 0, 'repeat revoke all');
  row.revokedAt = null; row.expiresAt = null;
  const roleMap = original('lib/authz/roles.ts', {});
  const mcp = original('lib/mcp/auth.ts', {
    '@/lib/api-tokens': tokens, '@/lib/auth-server': {getSession: async () => session},
    '@/lib/prisma': {prismadb: db}, '@/lib/authz/roles': roleMap,
    'next/headers': {headers: async () => ({get: () => authorization})},
  });
  process.env.NODE_ENV = 'production'; authorization = 'Bearer ' + issued.rawToken;
  const authorizationCases = [];
  for (const role of ['admin','manager','user','partner','member','viewer','unknown']) {
    for (const status of ['ACTIVE','INACTIVE','PENDING']) {
      user = {id:'owner',role,userStatus:status};
      const result = await outcome(() => mcp.getMcpUser());
      authorizationCases.push({role,status,...result});
      check(Boolean(result.value) === (role !== 'partner' && status === 'ACTIVE'), 'fresh role/status ' + role + '/' + status);
    }
  }
  user = null; check((await outcome(() => mcp.getMcpUser())).error === 'Unauthorized', 'deleted user denied');
  user = {id:'owner',role:'user',userStatus:'ACTIVE'}; session = {user};
  for (const header of ['', issued.rawToken, 'bearer ' + issued.rawToken, 'Bearer wrong']) {
    authorization = header; check((await outcome(() => mcp.getMcpUser())).error === 'Unauthorized', 'production requires exact bearer');
  }
  const actions = original('actions/api-tokens.ts', {'@/lib/api-tokens':tokens, '@/lib/auth-server': {getSession:async () => session}});
  session = {user:{id:'owner',role:'partner'}};
  check((await actions.createApiToken({name:'partner'})).error === '操作する権限がありません', 'localized partner denial');
  session = null; check((await actions.createApiToken({name:'no-session'})).error === 'ログインが必要です', 'localized login denial');
  class AuthenticationError extends Error {} class AuthorizationError extends Error {}
  let actor = {id:'admin',role:'admin'};
  const admin = original('actions/admin/users/revoke-api-tokens.ts', {
    '@/lib/api-tokens':tokens, 'next/cache':{revalidatePath:() => {}}, '@/lib/authz': {
      AuthenticationError, AuthorizationError, requireRole: async allowed => {
        if (!actor) throw new AuthenticationError(); if (!allowed.includes(actor.role)) throw new AuthorizationError(); return actor;
      },
    },
  });
  actor = {id:'manager',role:'manager'}; check((await admin.revokeUserApiTokens('owner')).error === '操作する権限がありません', 'admin-only bulk revoke');
  actor = {id:'admin',role:'admin'}; check((await admin.revokeUserApiTokens('owner')).data.revoked === 1, 'admin bulk result');
  check((await admin.revokeUserApiTokens('')).error === 'ユーザーIDを入力してください', 'admin required target');
  global.Date = RealDate;
  const files = ['lib/api-tokens.ts','lib/mcp/auth.ts','lib/authz/roles.ts','actions/api-tokens.ts','actions/admin/users/revoke-api-tokens.ts'];
  const result = {checks, epoch, issued, storedHash: row.tokenHash, validation, authorizationCases,
    sourceSHA256:Object.fromEntries(files.map(f => [f,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex')]))};
  fs.writeFileSync(process.argv[2], JSON.stringify(result,null,2)+'\n');
  console.log(JSON.stringify({originalTokenReferenceChecks:checks, validationCases:validation.length, authorizationCases:authorizationCases.length}));
})().catch(error => { console.error(error); process.exitCode = 1; });
