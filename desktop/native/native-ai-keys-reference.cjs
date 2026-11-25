const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const root = path.resolve(__dirname, '../..');
function original(relative, replacements = {}) {
  const filename = path.join(root, relative), mod = new Module(filename, module);
  mod.filename = filename; mod.paths = Module._nodeModulePaths(path.dirname(filename));
  const inherited = mod.require.bind(mod);
  mod.require = name => name in replacements ? replacements[name] : inherited(name);
  mod._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText, filename);
  return mod.exports;
}
(async () => {
  const env = original('lib/env-secret.ts');
  const envCases = ['', ' ', '\uFEFF key-1234 \uFEFF', 'sk-placeholder-test', 'PLACEHOLDER', 'your-openai-api-key', 'YOUR_key', '\u0085', 'real-key-1234', 'not-your-key'];
  const environment = envCases.map(input => {process.env.NEXTCRM_TEST_KEY = input; return {input, expected: env.envSecret('NEXTCRM_TEST_KEY') ?? null};});
  let system, personal;
  const helpers = original('lib/api-keys.ts', {
    '@/lib/env-secret':env,
    '@/lib/prisma':{prismadb:{apiKeys:{findFirst:async ({where}) => {
      const key = where.scope === 'SYSTEM' ? system : personal;
      return key ? {encryptedKey:'encrypted:'+key} : null;
    }}}},
    '@/lib/email-crypto':{decrypt:value => value.slice('encrypted:'.length)},
  });
  const cases = [];
  for (const provider of ['OPENAI','FIRECRAWL','ANTHROPIC','GROQ']) {
    for (const envValue of ['', 'your-api-key', 'env-key-0001']) {
      for (const systemSet of [false,true]) for (const personalSet of [false,true]) {
        system = systemSet ? 'system-key-0002' : undefined;
        personal = personalSet ? 'personal-key-0003' : undefined;
        process.env[provider+'_API_KEY'] = envValue;
        cases.push({provider,environment:envValue,system:system ?? null,personal:personal ?? null,expected:await helpers.getApiKey(provider,'test-user')});
      }
    }
  }
  fs.writeFileSync(process.argv[2],JSON.stringify({environment,cases},null,2)+'\n');
})().catch(error => {console.error(error);process.exitCode=1;});
