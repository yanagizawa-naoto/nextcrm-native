/* Real loopback sockets and the project-installed SDK; no provider calls. */
const assert = require('node:assert/strict');
const net = require('node:net');
const http = require('node:http');
const os = require('node:os');
const { spawn, spawnSync } = require('node:child_process');
const readline = require('node:readline');
const { setTimeout: delay } = require('node:timers/promises');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const fs = require('node:fs'), path = require('node:path');
let checks = 0;
function check(value, label) {
  assert.ok(value, label); checks++;
  fs.writeFileSync(path.join(__dirname, 'build/mcp-http-server-progress.json'), JSON.stringify({ checks, lastCheck: label, at: new Date().toISOString() }) + '\n');
}
const child = spawn(process.argv[2], [], { stdio: ['pipe', 'pipe', 'pipe'] });
let stderr = '', ended = false;
child.stderr.on('data', d => { stderr += d; });
const lines = [], readers = [];
readline.createInterface({ input: child.stdout }).on('line', line => {
  const item = JSON.parse(line);
  if (readers.length) readers.shift().resolve(item); else lines.push(item);
});
const childExit = new Promise(resolve => child.once('exit', (code, signal) => {
  ended = true; for (const reader of readers.splice(0)) reader.reject(new Error(`fixture exited ${code}/${signal}: ${stderr}`));
  resolve({ code, signal });
}));
async function nextLine() {
  if (lines.length) return lines.shift();
  if (ended) throw new Error('fixture already exited');
  return new Promise((resolve, reject) => readers.push({ resolve, reject }));
}
async function command(value) { child.stdin.write(value + '\n'); return nextLine(); }
let endpoint, port;
function ready(value) { assert.ok(value.ready, JSON.stringify(value)); endpoint = new URL(value.ready); port = Number(endpoint.port); }
async function stats() { return command('snapshot'); }
async function until(predicate, label, milliseconds = 3000) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) { const value = await stats(); if (predicate(value)) return value; await delay(30); }
  throw new Error(`Timed out: ${label}; ${JSON.stringify(await stats())}`);
}
const sockets = new Set();
async function socket() {
  const client = new net.Socket({ allowHalfOpen: true }); sockets.add(client);
  client.on('close', () => sockets.delete(client)); client.on('error', () => {});
  client.on('end', () => client.end()); client.resume();
  const connection = new Promise((resolve, reject) => { client.once('connect', resolve); client.once('error', reject); });
  client.connect(port, '127.0.0.1'); await connection; return client;
}
function closed(client) { return client.destroyed ? Promise.resolve() : new Promise(resolve => client.once('close', resolve)); }
function wire({ body = '', method = 'POST', path = '/api/mcp/mcp', fields = '', host = `127.0.0.1:${port}`, framed = true } = {}) {
  return Buffer.from(`${method} ${path} HTTP/1.1\r\nHost: ${host}\r\nAccept: application/json, text/event-stream\r\nContent-Type: application/json\r\n${framed ? `Content-Length: ${Buffer.byteLength(body)}\r\n` : ''}${fields}\r\n${body}`);
}
async function exchange(payload, { halfClose = false, fragmented = false } = {}) {
  const client = await socket(), received = [];
  client.setTimeout(6000, () => client.destroy(new Error('exchange timeout')));
  client.on('data', data => received.push(data));
  // With allowHalfOpen enabled, finish our write side once the server closes.
  client.on('end', () => client.end());
  const done = closed(client);
  if (fragmented) {
    for (let offset = 0; offset < payload.length; offset += 11) { client.write(payload.subarray(offset, offset + 11)); await delay(2); }
  } else client.write(payload);
  if (halfClose) client.end();
  await done; return Buffer.concat(received).toString('utf8');
}
function rpc(id, method, params) { return { jsonrpc: '2.0', id, method, ...(params ? { params } : {}) }; }
function call(id, args = {}) { return rpc(id, 'tools/call', { name: 'fixture_echo', arguments: { text: '日本語の顧客', ...args } }); }
async function httpPost(body, chunked = false) {
  return new Promise((resolve, reject) => {
    const bytes = Buffer.from(JSON.stringify(body));
    const request = http.request(endpoint, { method: 'POST', agent: false, headers: { accept: 'application/json, text/event-stream', 'content-type': 'application/json', ...(!chunked ? { 'content-length': bytes.length } : {}) } }, response => {
      const data = []; response.on('data', b => data.push(b));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, text: Buffer.concat(data).toString('utf8') }));
      response.on('error', reject);
    });
    request.on('error', reject);
    if (chunked) { for (let offset = 0; offset < bytes.length; offset += 5) request.write(bytes.subarray(offset, offset + 5)); request.end(); }
    else request.end(bytes);
  });
}
async function run() {
  ready(await nextLine());
  const inspection = spawnSync('/usr/sbin/lsof', ['-nP', '-a', '-p', String(child.pid), '-iTCP', '-sTCP:LISTEN', '-Fn'], { encoding: 'utf8' });
  check(inspection.status === 0 && inspection.stdout.includes(`n127.0.0.1:${port}`) && !inspection.stdout.includes('n*:'), 'actual listener bound only to IPv4 loopback');
  const ownAddress = Object.values(os.networkInterfaces()).flat().find(x => x.family === 'IPv4' && !x.internal)?.address;
  if (ownAddress) {
    const exposed = await new Promise(resolve => {
      const test = net.createConnection({ host: ownAddress, port });
      test.setTimeout(400); test.once('connect', () => { test.destroy(); resolve(true); });
      test.once('error', () => { test.destroy(); resolve(false); }); test.once('timeout', () => { test.destroy(); resolve(false); });
    });
    check(!exposed, 'same Mac LAN interface cannot reach listener');
  }
  check((await command('duplicate-start')).duplicateRejected, 'duplicate start rejected without disrupting listener');
  check((await command('bind-conflict')).bindConflictRejected, 'occupied port startup fails and cleans up');
  check((await command('cancel-start')).cancelledStartup, 'cancelled startup cleans up');
  const sdk = new Client({ name: 'Native interoperability fixture', version: '1' });
  const transport = new StreamableHTTPClientTransport(endpoint);
  await sdk.connect(transport);
  check(sdk.getServerVersion()?.name === 'NextCRM Native', 'installed SDK initialize over actual TCP');
  const listing = await sdk.listTools();
  check(listing.tools.length === 1 && listing.tools[0].name === 'fixture_echo', 'installed SDK lists actual catalog');
  const echo = await sdk.callTool({ name: 'fixture_echo', arguments: { text: '山田 太郎・日本語' } });
  check(echo.content[0].text === '山田 太郎・日本語', 'installed SDK calls tool with Japanese body/result');
  const unknown = await sdk.callTool({ name: 'missing_tool', arguments: {} });
  check(unknown.isError === true, 'installed SDK receives structured tool failure');
  await sdk.ping(); check(true, 'installed SDK ping');
  await sdk.close(); await until(x => x.snapshot.retainedPeers === 0, 'SDK shutdown');
  const chunks = await httpPost(call(10), true);
  check(chunks.status === 200 && chunks.text.includes('日本語の顧客'), 'real Node chunked request preserves split UTF-8');
  check(chunks.headers['transfer-encoding'] === 'chunked' && chunks.headers['content-length'] === undefined, 'streamed response uses chunk framing without Content-Length');
  const packet = await exchange(wire({ body: JSON.stringify(call(11)) }), { fragmented: true });
  check(packet.includes('日本語の顧客') && packet.endsWith('0\r\n\r\n'), 'fragmented TCP request and complete final response chunk');
  const half = await exchange(wire({ body: JSON.stringify(call(12, { delay: 0.2 })) }), { halfClose: true });
  check(half.includes('日本語の顧客') && half.endsWith('0\r\n\r\n'), 'write-half-closed client still receives delayed result');
  const largeComplete = await httpPost(call(13, { size: 8 * 1024 * 1024 }));
  const largeEvent = largeComplete.text.split('\n').find(line => line.startsWith('data: '));
  check(JSON.parse(largeEvent.slice(6)).result.content[0].text.length === 8 * 1024 * 1024, '8 MiB streamed result arrives complete before socket closes');
  const beforeInvalid = (await stats()).metrics.calls;
  const bad = [
    [wire({ method: 'GET', host: `evil.test:${port}` }), 403, 'Host'],
    [wire({ method: 'GET', fields: 'Origin: https://evil.test\r\n' }), 403, 'Origin'],
    [wire({ body: '{}', fields: 'Transfer-Encoding: chunked\r\n' }), 400, 'CL and TE'],
    [wire({ body: '{}', fields: 'Content-Length: 2\r\n' }), 400, 'duplicate CL'],
    [wire({ fields: 'Content-Length: 8388609\r\n', framed: false }), 413, 'oversized body before reading'],
    [wire({ method: 'GET', fields: 'X-Large: ' + 'x'.repeat(17000) + '\r\n' }), 431, 'oversized header'],
    [wire({ framed: false, fields: 'Transfer-Encoding: chunked\r\n', body: '0\r\nAuthorization: replaced\r\n\r\n' }), 400, 'forbidden trailer'],
    [wire({ body: '{}', path: '/api/mcp/sse' }), 501, 'legacy SSE'],
    [wire({ body: '{}', path: '/unknown' }), 404, 'unknown route'],
  ];
  for (const [input, status, label] of bad) {
    const reply = await exchange(input); check(reply.startsWith(`HTTP/1.1 ${status} `), `reject ${label}: ${reply.slice(0, 100)}`);
  }
  check((await stats()).metrics.calls === beforeInvalid, 'rejected input never reaches tool callback');
  const truncated = await exchange(wire({ framed: false, fields: 'Content-Length: 20\r\n', body: 'short' }), { halfClose: true });
  check(truncated.startsWith('HTTP/1.1 400 '), 'EOF during body rejected');
  await until(x => x.snapshot.retainedPeers === 0, 'all short requests released');
  const partial = await socket(); partial.write('POST /api/mcp/mcp HTTP/1.1\r\n');
  await closed(partial); check(true, 'absolute header timeout closes idle client');
  await until(x => x.snapshot.retainedPeers === 0, 'timed out peer released');
  const held = [];
  for (let i = 0; i < 4; i++) { const s = await socket(); s.write('G'); held.push(s); }
  await until(x => x.snapshot.connections === 4, 'four admitted connections');
  const extra = await socket(); extra.write(wire({ method: 'GET' })); await closed(extra);
  const limited = await stats();
  check(limited.snapshot.rejected >= 1 && limited.snapshot.peakConnections <= 4, 'concurrent connection admission bounded at four');
  for (const s of held) s.destroy(); await until(x => x.snapshot.retainedPeers === 0, 'held connections released');
  const beforeUncooperative = (await stats()).metrics;
  const stubborn = await socket(); stubborn.write(wire({ body: JSON.stringify(call(19, { hold: 0.9 })) }));
  await until(x => x.metrics.calls === beforeUncooperative.calls + 1, 'noncooperative handler begins'); stubborn.destroy();
  const retained = await until(x => x.snapshot.connections === 0 && x.snapshot.runningRequests === 1, 'canceled handler retaining slot');
  check(retained.snapshot.retainedPeers === 1, 'canceled but unfinished handler retains admission slot');
  const occupied = [];
  for (let i = 0; i < 3; i++) { const s = await socket(); s.write('G'); occupied.push(s); }
  await until(x => x.snapshot.retainedPeers === 4, 'three sockets plus unfinished handler');
  const refused = await socket(); refused.write(wire({ method: 'GET' })); await closed(refused);
  check((await stats()).snapshot.connections === 3, 'unfinished canceled work counts toward connection budget');
  for (const s of occupied) s.destroy();
  const finishedHold = await until(x => x.snapshot.retainedPeers === 0 && x.metrics.cancelled === beforeUncooperative.cancelled + 1, 'noncooperative fixture exits');
  check(finishedHold.metrics.completed === beforeUncooperative.completed, 'late cancellation checked before fixture effect');
  const beforeCancel = (await stats()).metrics;
  const abandoned = await socket(); abandoned.resume(); abandoned.write(wire({ body: JSON.stringify(call(20, { delay: 10 })) }));
  await until(x => x.metrics.calls === beforeCancel.calls + 1, 'slow handler begins'); abandoned.destroy();
  const cancelled = await until(x => x.metrics.cancelled === beforeCancel.cancelled + 1 && x.snapshot.retainedPeers === 0, 'full disconnect cancels active handler');
  check(cancelled.metrics.completed === beforeCancel.completed, 'disconnected handler does not complete its effect');
  const beforeDeadline = cancelled.metrics;
  const timed = await exchange(wire({ body: JSON.stringify(call(21, { delay: 10 })) }));
  const expired = await until(x => x.metrics.cancelled === beforeDeadline.cancelled + 1 && x.snapshot.retainedPeers === 0, 'request lifetime cancellation');
  check(timed.includes(': connected') && !timed.includes('"result"') && expired.metrics.completed === beforeDeadline.completed, 'request lifetime closes stream and cancels effect');
  const beforeSlow = expired.metrics.calls;
  const slow = await socket(); slow.pause(); slow.write(wire({ body: JSON.stringify(Array.from({ length: 20 }, (_, i) => call(100 + i, { size: 8 * 1024 * 1024 }))) }));
  await until(x => x.metrics.calls > beforeSlow, 'large response begins');
  await delay(180);
  const congested = await stats();
  check(congested.metrics.calls - beforeSlow < 20, 'slow reader prevents remaining batch handlers from running ahead');
  check(congested.snapshot.peakQueuedWrites <= 2, 'one response producer plus at most one heartbeat queued');
  const drained = await until(x => x.snapshot.retainedPeers === 0, 'send timeout clears producer and queued writes', 4500);
  check(drained.metrics.calls - beforeSlow < 20, 'send timeout stops remaining batch effects'); slow.destroy();
  const beforeStop = drained.metrics;
  const stopping = await socket(); stopping.resume(); stopping.write(wire({ body: JSON.stringify(call(300, { delay: 10 })) }));
  await until(x => x.metrics.calls === beforeStop.calls + 1, 'handler active at stop');
  check((await command('concurrent-stop')).stopped, 'concurrent stop calls complete'); stopping.destroy();
  const stopped = await stats();
  check(stopped.snapshot.retainedPeers === 0 && stopped.metrics.cancelled === beforeStop.cancelled + 1, 'stop waits for task cancellation and releases all peers');
  ready(await command('restart'));
  check((await httpPost(rpc(400, 'ping'))).text.includes('"result":{}'), 'same server restarts and serves requests');
  const restarted = await command('fixed-restart'); check(restarted.fixedPortReused, 'same configured port can be stopped and rebound twice'); ready(restarted);
  const sse = await socket(); sse.resume(); sse.write(wire({ method: 'GET' }));
  await until(x => x.snapshot.connections === 1, 'standalone SSE accepted');
  const start = Date.now(); check((await command('stop')).stopped, 'stop closes standalone SSE');
  check(Date.now() - start < 1000, 'standalone heartbeat canceled promptly'); sse.destroy();
  ready(await command('restart'));
  const last = await httpPost(call(500, { text: '再起動後' })); check(last.text.includes('再起動後'), 'final restart retains working transport');
  await command('quit'); const exit = await childExit;
  check(exit.code === 0 && exit.signal === null && stderr === '', 'fixture clean exit with no runtime warnings');
  const sdkVersion = JSON.parse(fs.readFileSync(path.join(path.dirname(require.resolve('@modelcontextprotocol/sdk/client/index.js')), '../../../package.json'), 'utf8')).version;
  console.log(JSON.stringify({ checks, sdk: sdkVersion, scope: 'Actual loopback HTTP and installed SDK transport with fixture-only handlers; no native token authentication or original123 handlers yet.' }));
}
const deadline = setTimeout(() => { for (const s of sockets) s.destroy(); child.kill('SIGTERM'); }, 90000);
run().catch(error => { console.error(`After ${checks} checks: ${error.stack}`); process.exitCode = 1; }).finally(async () => {
  clearTimeout(deadline); for (const s of sockets) s.destroy();
  if (!ended) { child.stdin.end(); const kill = setTimeout(() => child.kill('SIGTERM'), 1000); await childExit; clearTimeout(kill); }
});
