const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const {Client} = require('@modelcontextprotocol/sdk/client/index.js');
const {StreamableHTTPClientTransport} = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const progress = JSON.parse(fs.readFileSync(path.join(__dirname, '../artifacts/native-mcp-app-qa/progress.json'), 'utf8'));
const root = progress.root, mode = process.argv[2] || 'exercise';
assert.equal(fs.readFileSync(path.join(root, '.native-mail-test'), 'utf8'), 'NextCRM isolated mail QA\n');
const input = JSON.parse(fs.readFileSync(path.join(root, 'synthetic-inputs.json'), 'utf8'));
let checks = 0;
const clients = [];
function equal(a, b, label) { assert.deepEqual(a, b, label); checks++; }
function snapshot() {
  const script = `import sqlite3,json,sys
p=sys.argv[1]
d=sqlite3.connect('file:'+p+'/crm.sqlite?mode=ro',uri=True)
def meta(k):
 r=d.execute('SELECT value FROM native_metadata WHERE key=?',[k]).fetchone()
 return json.loads(r[0]) if r else None
print(json.dumps({'settings':meta('mcp.settings.v1'),'mail':meta('qaMailSend.last'),'jobs':[dict(event=r[0],status=r[1]) for r in d.execute("SELECT event,status FROM native_outbox WHERE event='crm.lead_assigned'")],'session':dict(d.execute('SELECT id,expiresAt FROM Session').fetchall())}))`;
  const child = spawnSync('python3', ['-c', script, root], {encoding: 'utf8'});
  assert.equal(child.status, 0, 'isolated SQLite inspection');
  return JSON.parse(child.stdout);
}
async function connect(url, cookie) {
  const client = new Client({name: 'Isolated integrated Mac app QA', version: '1'});
  clients.push(client);
  await client.connect(new StreamableHTTPClientTransport(new URL(url), {requestInit: {headers: {Authorization: 'Bearer ' + input.bearer, ...(cookie ? {Cookie: cookie} : {})}}}));
  return client;
}
async function call(client, name, args = {}) {
  const result = await client.callTool({name, arguments: args});
  return {failed: result.isError === true, body: JSON.parse(result.content[0].text)};
}
async function good(client, name, args) {
  const result = await call(client, name, args);
  equal(result.failed, false, name);
  return result.body.data;
}
async function run() {
  const before = snapshot(), settings = before.settings;
  assert.ok(settings?.enabled, 'Enable MCP in the isolated app settings first');
  const endpoint = `http://127.0.0.1:${settings.port}/api/mcp/mcp`;
  if (mode === 'stopped') {
    let refused = false;
    try { await fetch(endpoint, {signal: AbortSignal.timeout(2000)}); }
    catch (error) { refused = error.cause?.code === 'ECONNREFUSED'; }
    equal(refused, true, 'quitting the app releases its listener');
  } else {
    const client = await connect(endpoint);
    equal((await client.listTools()).tools.length, 123, 'packaged catalog and all real operations');
    if (mode === 'restart') {
      const previous = JSON.parse(fs.readFileSync(path.join(root, 'wire-state.json'), 'utf8'));
      equal((await good(client, 'crm_get_account', {id: previous.accountID})).name, 'アプリ統合確認の取引先', 'API data persists after app restart');
      const file = await fetch(previous.downloadURL);
      equal(file.status, 200, 'issued document capability survives app restart');
      equal(await file.text(), 'Macアプリから保存した本文', 'document content persists after restart');
    } else {
      const account = await good(client, 'crm_create_account', {name: 'アプリ統合確認の取引先'});
      equal((await good(client, 'crm_get_account', {id: account.id})).name, account.name, 'real app SQLite write/read');
      const document = await good(client, 'crm_create_document', {document_name: 'アプリ統合確認の文書', contentType: 'text/plain'});
      equal((await fetch(document.presignedUrl, {method: 'PUT', headers: {'content-type': 'text/plain'}, body: 'Macアプリから保存した本文'})).status, 200, 'real app signed upload');
      const download = await good(client, 'crm_get_download_url', {id: document.id});
      equal(await (await fetch(download.url)).text(), 'Macアプリから保存した本文', 'real app signed download');
      equal((await call(client, 'reports_run', {category: 'users'})).body.code, 'INTERNAL_ERROR', 'bearer alone does not grant browser-session authority');
      const secrets = JSON.parse(fs.readFileSync(path.join(root, '.mcp-qa-secrets.json'), 'utf8'));
      const signing = crypto.createHmac('sha256', secrets[settings.credentialID]).update('nextcrm-native-mcp-v1/better-auth-cookie').digest('base64');
      const signature = crypto.createHmac('sha256', signing).update(input.sessionValue).digest('base64');
      const browser = await connect(endpoint, 'better-auth.session_token=' + encodeURIComponent(input.sessionValue + '.' + signature));
      await good(browser, 'reports_run', {category: 'users'});
      equal(Date.parse(snapshot().session[input.sessionID]) > Date.now() + 6 * 86400000, true, 'signed browser session refresh passes through packaged app');
      await browser.close();
      const lead = await good(client, 'crm_create_lead', {lastName: '通知の接続確認'});
      await good(client, 'crm_update_lead', {id: lead.id, assigned_to: input.recipient});
      const deadline = Date.now() + 20000;
      let state;
      do {
        state = snapshot();
        if (state.jobs.some(x => x.status === 'done')) break;
        await new Promise(resolve => setTimeout(resolve, 150));
      } while (Date.now() < deadline);
      equal(state.jobs.some(x => x.status === 'done'), true, 'API commit wakes the existing native lead notification worker');
      equal(JSON.stringify(state.mail?.to).includes('recipient@example.invalid'), true, 'isolated fake delivery reaches assigned user');
      equal(state.mail?.network, false, 'QA worker makes no real delivery');
      fs.writeFileSync(path.join(root, 'wire-state.json'), JSON.stringify({accountID: account.id, downloadURL: download.url}), {mode: 0o600});
    }
  }
  const proof = {mode, checks, binarySHA256: progress.binarySHA256, scope: 'Actual packaged Mac app, isolated SQLite and fake provider/credential stores. Real MCP SDK, signed HTTP, session authentication, native job wake and app lifecycle. No installed app or production data.'};
  fs.writeFileSync(path.join(root, `wire-${mode}-verification.json`), JSON.stringify(proof, null, 2) + '\n');
  console.log(JSON.stringify(proof));
}
run().catch(error => { console.error(JSON.stringify({mode, checks, error: error instanceof assert.AssertionError ? error.message : error.constructor.name})); process.exitCode = 1; }).finally(async () => { await Promise.all(clients.map(client => client.close().catch(() => {}))); });
