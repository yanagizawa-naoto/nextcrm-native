const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const child = spawn(process.argv[2], [process.argv[3]], { stdio: ['pipe', 'pipe', 'pipe'] });
const lines = [], pending = [], clients = [];
let stderr = '', ended = false, checks = 0;
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
child.stderr.on('data', data => { stderr += data; });
readline.createInterface({ input: child.stdout }).on('line', line => {
  const value = JSON.parse(line); if (pending.length) pending.shift().resolve(value); else lines.push(value);
});
const exited = new Promise(resolve => child.on('exit', (code, signal) => {
  ended = true; for (const reader of pending.splice(0)) reader.reject(new Error(`fixture exited ${code}/${signal}: ${stderr}`));
  resolve({ code, signal });
}));
function next() { return lines.length ? Promise.resolve(lines.shift()) : new Promise((resolve, reject) => pending.push({ resolve, reject })); }
async function command(command, fields = {}) { child.stdin.write(JSON.stringify({ command, ...fields }) + '\n'); return next(); }
async function waitForPeers(maximum) {
  const deadline = Date.now() + 3000;
  do {
    if ((await command('stats')).retained <= maximum) { checks++; return; }
    await new Promise(resolve => setTimeout(resolve, 20));
  } while (Date.now() < deadline);
  throw new Error('Closed SDK client retained its admission slot');
}
function equal(actual, expected, label) { assert.deepEqual(actual, expected, label); checks++; }
async function connect(url, raw) {
  const client = new Client({ name: 'Isolated native account integration', version: '1' }); clients.push(client);
  await client.connect(new StreamableHTTPClientTransport(new URL(url), raw ? { requestInit: { headers: { Authorization: 'Bearer ' + raw } } } : {}));
  return client;
}
async function call(client, name, arguments = {}) {
  const result = await client.callTool({ name, arguments });
  return { body: JSON.parse(result.content[0].text), failed: result.isError === true };
}
async function run() {
  const ready = await next(); assert.ok(ready.ready, 'fixture startup');
  const anonymous = await connect(ready.ready);
  equal((await anonymous.listTools()).tools.map(x => x.name).sort(), ['crm_create_account','crm_delete_account','crm_get_account','crm_list_accounts','crm_search_accounts','crm_update_account','crm_create_contact','crm_delete_contact','crm_get_contact','crm_list_contacts','crm_search_contacts','crm_update_contact','crm_list_users'].sort(), 'only real operations advertised');
  equal((await call(anonymous, 'crm_list_accounts')).body.code, 'UNAUTHORIZED', 'anonymous discovery grants no data authority');
  await anonymous.close(); await waitForPeers(0);
  const alice = await connect(ready.ready, ready.credentials[id(1)]), bob = await connect(ready.ready, ready.credentials[id(2)]);
  const list = await call(alice, 'crm_list_accounts', { limit: 2, offset: 1 });
  equal(list.failed, false, 'authenticated list succeeds'); equal(list.body.total, 9, 'scoped total');
  equal(list.body.data.map(x => x.id), [id(110), id(109)], 'stable paged order'); equal(list.body.offset, 1, 'offset preserved');
  const searched = await call(alice, 'crm_search_accounts', { query: 'éclair' });
  equal(searched.body.data.map(x => x.id), [id(106)], 'Unicode case insensitive search');
  const [denied, allowed] = await Promise.all([call(alice, 'crm_get_account', { id: id(102) }), call(bob, 'crm_get_account', { id: id(102) })]);
  equal(denied.body.code, 'NOT_FOUND', 'simultaneous Alice request remains scoped'); equal(allowed.body.data.id, id(102), 'simultaneous Bob request retains own authority');
  const name = '  日本語企業' + '長'.repeat(600) + '  ';
  const created = await call(alice, 'crm_create_account', { name, email: 'wire@example.invalid', assigned_to: id(2) });
  equal(created.failed, false, 'real create'); equal(created.body.data.name, name, 'original whitespace and long Unicode name retained');
  equal(created.body.data.assigned_to, id(1), 'unknown create owner field stripped');
  const accountID = created.body.data.id;
  const stored = await command('stored', { id: accountID });
  equal(stored.row, created.body.data, 'API response matches independent reopened SQLite connection'); equal(stored.actor, id(1), 'audit actor follows token');
  const updated = await call(alice, 'crm_update_account', { id: accountID, description: '通信経由の更新', assigned_to: id(2) });
  equal(updated.body.data.description, '通信経由の更新', 'real update'); equal(updated.body.data.assigned_to, id(2), 'real reassign');
  equal((await call(bob, 'crm_get_account', { id: accountID })).body.data.id, accountID, 'new owner immediately sees account');
  const removed = await call(bob, 'crm_delete_account', { id: accountID });
  equal(removed.failed, false, 'real soft deletion'); equal(Object.keys(removed.body.data).sort(), ['deletedAt', 'id'], 'delete response projection');
  equal((await call(alice, 'crm_get_account', { id: accountID })).body.code, 'NOT_FOUND', 'deleted hidden from creator');
  equal((await command('stored', { id: accountID })).actor, id(2), 'deletion attributed to new owner');
  const invalid = await alice.callTool({ name: 'crm_create_account', arguments: { name: '' } });
  equal(invalid.isError, true, 'invalid input rejected over SDK');
  equal((await call(alice, 'crm_list_accounts')).body.total, 9, 'invalid and deleted operations leave expected rows');
  const people = await call(alice, 'crm_list_users', { status: 'ALL' });
  equal(people.failed, false, 'real assignee list');
  equal(people.body.data.every(row => Object.keys(row).sort().join(',') === 'avatar,id,name'), true, 'members receive only public user fields');
  equal(people.body.data.some(row => row.id === id(5)), false, 'members cannot request inactive users');
  const contact = await call(alice, 'crm_create_contact', { last_name: ' 通信用の連絡先 ', first_name: '花子', mobile_phone: '090-0000' });
  equal(contact.failed, false, 'real contact creation'); equal(contact.body.data.last_name, ' 通信用の連絡先 ', 'contact name whitespace retained');
  const contactID = contact.body.data.id;
  equal((await call(alice, 'crm_list_contacts')).body.data.map(x => x.id), [contactID], 'real contact list');
  equal((await call(alice, 'crm_search_contacts', { query: '090-0000' })).body.data.map(x => x.id), [contactID], 'contact phone search');
  equal((await call(alice, 'crm_update_contact', { id: contactID, account: id(102) })).body.code, 'NOT_FOUND', 'forbidden parent relink');
  const linked = await call(alice, 'crm_update_contact', { id: contactID, account: id(101), assigned_to: id(2) });
  equal(linked.body.data.accountsIDs, id(101), 'writes actual relation FK'); equal(linked.body.data.account, null, 'legacy account field unchanged');
  equal((await call(bob, 'crm_get_contact', { id: contactID })).body.data.id, contactID, 'contact reassignment visible immediately');
  equal((await call(bob, 'crm_delete_contact', { id: contactID })).failed, false, 'real contact soft deletion');
  equal((await call(alice, 'crm_get_contact', { id: contactID })).body.code, 'NOT_FOUND', 'deleted contact hidden');
  await bob.close(); await waitForPeers(1);
  const manager = await connect(ready.ready, ready.credentials[id(3)]);
  const privilegedUsers = await call(manager, 'crm_list_users', { status: 'ALL' });
  equal(privilegedUsers.body.data.some(row => row.id === id(5) && row.userStatus === 'INACTIVE'), true, 'manager sees requested inactive users');
  equal(privilegedUsers.body.data.every(row => 'email' in row && 'role' in row && !('password' in row)), true, 'manager projection excludes secrets');
  equal((await call(manager, 'crm_get_account', { id: id(102) })).body.data.id, id(102), 'manager read');
  equal((await command('role', { id: id(3), role: 'user' })).changed, true, 'role changed');
  equal((await call(manager, 'crm_get_account', { id: id(102) })).body.code, 'NOT_FOUND', 'same connected client uses fresh downgraded role');
  equal((await command('revoke', { id: id(1) })).revoked, true, 'token revoked');
  equal((await call(alice, 'crm_create_account', { name: 'revoked-must-not-write' })).body.code, 'UNAUTHORIZED', 'connected client cannot mutate after revocation');
  await Promise.all(clients.map(client => client.close()));
  await waitForPeers(0);
  equal((await command('quit')).stopped, true, 'server shut down'); equal(await exited, { code: 0, signal: null }, 'fixture exits cleanly'); equal(stderr, '', 'no fixture errors');
  console.log(JSON.stringify({ checks, realTools: 13, scope: 'Installed MCP SDK over native TCP with real account/contact/user handlers, token/role/SQLite effects, independent persisted-state reads and audit actors; full app/plugins pending.' }));
}
const timeout = setTimeout(() => child.kill('SIGTERM'), 60000);
run().catch(async error => { console.error(`After ${checks} checks: ${error.stack}`); console.error(JSON.stringify({ cause: error.cause?.code, detail: error.cause?.message, server: ended ? null : await command('stats') })); process.exitCode = 1; }).finally(async () => {
  clearTimeout(timeout); await Promise.all(clients.map(client => client.close().catch(() => {})));
  if (!ended) { child.stdin.end(); const kill = setTimeout(() => child.kill('SIGTERM'), 1000); await exited; clearTimeout(kill); }
});
