// Run the real repository action with a fake provider and authentication.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require('typescript'), crypto = require('node:crypto');
const file = path.resolve(__dirname, '../../actions/campaigns/templates/generate-template.ts');
const source = fs.readFileSync(file, 'utf8');
class AuthenticationError extends Error {}
let active = true, key = 'qa-campaign-key', calls = [], answer, status = 200, timeout;
const moduleStub = { exports: {} };
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, {
  module: moduleStub, exports: moduleStub.exports, AbortController,
  require(name) {
    if (name === '@/lib/api-keys') return { getApiKey: async (provider, user) => { if (provider !== 'OPENAI' || user !== 'alice') throw Error('key selection'); return key; } };
    if (name === '@/lib/authz') return { AuthenticationError, requireAuthenticated: async () => { if (!active) throw new AuthenticationError(); return { id: 'alice' }; } };
    throw Error(name);
  },
  setTimeout(fn, ms) { timeout = ms; return 1; }, clearTimeout() {},
  async fetch(url, init) { calls.push({ url, method: init.method, headers: init.headers, body: JSON.parse(init.body) }); return { ok: status >= 200 && status < 300, statusText: 'fixture failure', json: async () => answer }; }
});
(async () => {
  const cases = [];
  for (const content of [JSON.stringify({ subject: 'ご案内😀', html: '<p style="color:red">{{company}}様</p>' }), '{}', '{"subject":null,"html":null}', '{"subject":"件名"}', null, 'not-json']) {
    answer = { choices: [{ message: { content } }] }; calls = [];
    const item = { prompt: '日本語で新サービスのご案内を作成してください。', response: answer };
    try { item.expected = await moduleStub.exports.generateTemplate(item.prompt); } catch { item.rejected = true; }
    item.request = calls[0]; cases.push(item);
  }
  let gates = 0;
  for (const state of [{ active: false, key: 'qa' }, { active: true, key: '' }]) {
    active = state.active; key = state.key; calls = [];
    try { await moduleStub.exports.generateTemplate('test'); throw Error('gate accepted'); } catch (e) { if (e.message === 'gate accepted') throw e; }
    if (calls.length) throw Error('gate sent request'); gates++;
  }
  if (timeout !== 30000) throw Error('deadline');
  fs.mkdirSync(path.join(__dirname, 'build'), { recursive: true });
  fs.writeFileSync(path.join(__dirname, 'build/campaign-ai-reference.json'), JSON.stringify({ sourceSHA256: crypto.createHash('sha256').update(source).digest('hex'), timeout, gates, cases }));
  console.log(JSON.stringify({ originalActionCases: cases.length, gates, timeout }));
})().catch(e => { console.error(e); process.exit(1); });
