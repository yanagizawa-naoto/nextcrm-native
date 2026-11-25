const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const child = spawn(process.argv[2], [process.argv[3]], { stdio: ['pipe', 'pipe', 'pipe'] });
const reference = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const discovery = JSON.parse(fs.readFileSync(process.argv[5], 'utf8'));
let stderr = '', ended = false, valid = 0, invalid = 0;
const startedAt = Date.now();
function progress(stage) { fs.writeFileSync(path.join(__dirname, 'build/mcp-input-wire-progress.json'), JSON.stringify({ stage, valid, invalid, elapsedSeconds: (Date.now() - startedAt) / 1000 }) + '\n'); }
const lines = [], pending = [];
child.stderr.on('data', data => { stderr += data; });
readline.createInterface({ input: child.stdout }).on('line', line => { const value = JSON.parse(line); if (pending.length) pending.shift().resolve(value); else lines.push(value); });
const exited = new Promise(resolve => child.on('exit', (code, signal) => { ended = true; for (const reader of pending.splice(0)) reader.reject(new Error(`fixture exited ${code}/${signal}: ${stderr}`)); resolve({ code, signal }); }));
function next() { return lines.length ? Promise.resolve(lines.shift()) : new Promise((resolve, reject) => pending.push({ resolve, reject })); }
async function command(text) { child.stdin.write(text + '\n'); return next(); }
const client = new Client({ name: 'Native full input catalog fixture', version: '1' });
async function run() {
  const ready = await next(); assert.ok(ready.ready, JSON.stringify(ready));
  progress('ready');
  await client.connect(new StreamableHTTPClientTransport(new URL(ready.ready)));
  progress('connected');
  const listing = await client.listTools();
  assert.deepEqual(listing.tools, discovery.tools, 'all original tool discovery metadata remains identical');
  for (const tool of reference.validation) {
    for (const label of ['valid-all-fields', 'strip-unknown-root']) {
      const sample = tool.cases.find(x => x.label === label);
      const result = await client.callTool({ name: tool.name, arguments: sample.input });
      assert.notEqual(result.isError, true, tool.name + ' ' + label);
      assert.deepEqual(JSON.parse(result.content[0].text), sample.data, tool.name + ' normalized payload'); valid++;
      progress(tool.name + ':' + label);
    }
    const bad = tool.cases.find(x => x.issues && x.input && !Array.isArray(x.input) && typeof x.input === 'object');
    if (bad) {
      const result = await client.callTool({ name: tool.name, arguments: bad.input });
      assert.equal(result.isError, true, tool.name + ' invalid args');
      assert.equal(result.content[0].text, `MCP error -32602: Input validation error: Invalid arguments for tool ${tool.name}: ${bad.message}`); invalid++;
    }
  }
  for (const sample of reference.rawNumbers) {
    const response = await fetch(ready.ready, { method: 'POST', headers: { accept: 'application/json, text/event-stream', 'content-type': 'application/json' },
      body: `{"jsonrpc":"2.0","id":"raw-number","method":"tools/call","params":{"name":${JSON.stringify(sample.name)},"arguments":${sample.raw}}}` });
    assert.equal(response.status, 200);
    const text = await response.text(), event = text.split('\n').find(x => x.startsWith('data: '));
    const result = JSON.parse(event.slice(6)).result;
    if (sample.data) { assert.notEqual(result.isError, true); assert.deepEqual(JSON.parse(result.content[0].text), sample.data); valid++; }
    else { assert.equal(result.isError, true); assert.equal(result.content[0].text, `MCP error -32602: Input validation error: Invalid arguments for tool ${sample.name}: ${sample.message}`); invalid++; }
  }
  const stats = await command('stats'); assert.equal(stats.effects, valid, 'invalid calls never reach effect');
  await client.close(); const stopped = await command('quit'); assert.equal(stopped.stopped, true);
  const exit = await exited; assert.deepEqual(exit, { code: 0, signal: null }); assert.equal(stderr, '');
  console.log(JSON.stringify({ wireCatalogTools: listing.tools.length, validCalls: valid, invalidCalls: invalid, effects: stats.effects, scope: 'Installed SDK over native TCP; original schemas with synthetic normalized echoes only, no original handlers/auth.' }));
}
const timeout = setTimeout(() => child.kill('SIGTERM'), 60000);
run().catch(error => { console.error(`After ${valid} valid/${invalid} invalid calls in ${(Date.now() - startedAt) / 1000}s: ${error.stack}`); process.exitCode = 1; }).finally(async () => {
  clearTimeout(timeout); await client.close().catch(() => {});
  if (!ended) { child.stdin.end(); const kill = setTimeout(() => child.kill('SIGTERM'), 1000); await exited; clearTimeout(kill); }
});
