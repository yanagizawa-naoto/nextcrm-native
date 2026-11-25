// Execute the repository's actual provider and account actions, with isolated
// HTTP/auth/plugin-context inputs. No provider request leaves this process.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto'), vm = require('node:vm');
const ts = require('typescript');
const root = path.resolve(__dirname, '../..'), hashes = {}, cache = new Map();
let providers = [], authFailure = false, contextFailure = false, actionLog = [];
const stubs = {
  'next-intl/server': {getTranslations: async () => key => key},
  '@/lib/authz': {requireAuthenticated: async () => { if (authFailure) throw Error('Unauthenticated'); return {id: 'qa-user', role: 'user'}; }},
  '@/lib/plugins/slots': {getCompanyRegistryProviders: async () => providers},
  '@/lib/plugins/context': {createPluginContext: async () => { if (contextFailure) throw Error('context unavailable'); return {http: {fetch: fetchFixture}, log: {error: text => actionLog.push(text)}}; }},
};
function load(relative) {
  if (cache.has(relative)) return cache.get(relative);
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  hashes[relative] = crypto.createHash('sha256').update(source).digest('hex');
  const code = ts.transpileModule(source, {compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS}}).outputText;
  const module = {exports: {}};
  const requireSource = name => {
    if (stubs[name]) return stubs[name];
    if (name.startsWith('.')) return load(path.posix.join(path.posix.dirname(relative), name + '.ts'));
    throw Error('Unexpected provider dependency: ' + name);
  };
  vm.runInNewContext('(function(require,module,exports){' + code + '\n})', {console: {error: (...args) => actionLog.push(args.map(String).join(' '))}}, {filename: relative})(requireSource, module, module.exports);
  cache.set(relative, module.exports); return module.exports;
}
const ares = load('plugins/registry-ares/ares.ts'), vies = load('plugins/registry-ares/vies.ts');
const actions = load('actions/crm/accounts/lookup-company.ts');
let scenario, requests;
async function fetchFixture(url, init = {}) {
  requests.push({url, method: init.method || 'GET', headers: Object.fromEntries(Object.entries(init.headers || {}).map(([k,v]) => [k.toLowerCase(),v])), ...(init.body ? {body: JSON.parse(init.body)} : {})});
  if (scenario.networkError) throw Error('offline fixture');
  return {status: scenario.status ?? 200, ok: (scenario.status ?? 200) >= 200 && (scenario.status ?? 200) < 300, json: async () => { if (scenario.invalidJSON) throw SyntaxError('invalid fixture JSON'); return scenario.reply; }};
}
const base = {ico: '27082440', obchodniJmeno: 'Alza.cz a.s.', dic: 'CZ27082440', sidlo: {nazevUlice: 'Jankovcova', nazevCastiObce: 'Holešovice', cisloDomovni: 1522, cisloOrientacni: 53, nazevObce: 'Praha', psc: 17000}};
const cases = [];
async function add(op, input, config = {}) {
  scenario = config; requests = []; actionLog = []; authFailure = !!config.authFailure; contextFailure = !!config.contextFailure;
  providers = config.disabled ? [] : [{plugin: {}, provider: {countries: ['CZ'], lookup: (number, cc, ctx) => ares.lookupAres(number, ctx), validateVat: (number, ctx) => vies.validateVies(number, ctx)}}];
  let result;
  try {
    if (op === 'normalize') result = ares.normalizeIco(input);
    else if (op === 'map') result = ares.mapAres(input, '27082440');
    else if (op === 'lookup') result = await ares.lookupAres(input, {http: {fetch: fetchFixture}});
    else if (op === 'vat') result = await vies.validateVies(input, {http: {fetch: fetchFixture}});
    else if (op === 'actionLookup') result = await actions.lookupCompany(input.country, input.number);
    else if (op === 'actionVat') result = await actions.validateVatNumber(input);
    else if (op === 'countries') result = await actions.getRegistryCountries();
    else if (op === 'canValidate') result = await actions.canValidateVat();
  } catch (e) { result = {thrown: e.name === 'Error' ? e.message : e.name}; }
  cases.push({op, input, config, result, requests, logged: actionLog.length > 0});
}
(async () => {
  for (const input of ['', '0', '1', '19', '27082440', '27082441', '123456789', 'CZ27082440', '２７０８２４４０', '+27082440', '2708.2440', '27082440\0']) await add('normalize', input);
  for (let n = 0; n < 170; n++) {
    const front = String(n * 59831 % 10000000).padStart(7, '0');
    const sum = [...front].reduce((s, d, i) => s + Number(d) * (8-i), 0), check = (11 - sum%11)%10;
    await add('normalize', front + check); await add('normalize', front + ((check + 1)%10));
  }
  for (const cp of [9,10,11,12,13,32,0xA0,0x1680,...Array.from({length:11},(_,i)=>0x2000+i),0x2028,0x2029,0x202F,0x205F,0x3000,0xFEFF,0x85,0x180E,0x200B]) {
    const ws = String.fromCodePoint(cp); await add('normalize', ws+'2708'+ws+'2440'+ws);
  }
  await add('map', base); await add('map', {obchodniJmeno: '株式会社サンプル'});
  for (const field of ['nazevUlice','nazevCastiObce','cisloDomovni','cisloOrientacni','cisloOrientacniPismeno','nazevObce','psc']) {
    for (const value of [null, '', 0, false, true, '日本語', 1.5, [], ['a',null,'b'], 1e21]) await add('map', {...base,sidlo:{...base.sidlo,[field]:value}});
    const value=structuredClone(base); delete value.sidlo[field]; await add('map',value);
  }
  for (const subject of [{}, {sidlo:null}, {sidlo:[],obchodniJmeno:null,dic:false}, [], false, 'unexpected']) await add('map',subject);
  for (const status of [200,201,204,299,300,400,401,404,429,500,503]) await add('lookup',' 19 ',{status,reply:base});
  for (const input of ['bad', '', '27082441', '27082440']) for (const config of [{reply:base},{reply:{}},{reply:null},{invalidJSON:true},{networkError:true}]) await add('lookup',input,config);
  const vats=['cz 270.824-40','GR094014201','EL094014201','GB980780684','CHE-116.281.710','CZ12','27082440','CZ','', ' CZ \u0085 ', 'cz😀', 'cZ\uFEFF19', 'ß12', 'C\u0301Z19', 'CZ\u030119', 'CZ. -', ...'AT BE BG CY DE DK EE ES FI FR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK XI'.split(' ').map(c=>c+'12')];
  for (const input of vats) await add('vat',input,{reply:{valid:true}});
  for (const reply of [{valid:false},{valid:1},{valid:'true'}, {},{valid:true,errorWrappers:[{error:'INVALID_INPUT'}]},{errorWrappers:[{error:'INVALID_INPUT'}]}, ...['MS_UNAVAILABLE','SERVICE_UNAVAILABLE','TIMEOUT','MS_MAX_CONCURRENT_REQ','UNKNOWN'].map(error=>({errorWrappers:[{error}]})),{errorWrappers:[{error:null}]},{errorWrappers:[]},{errorWrappers:[{error:0}]},null,[]]) await add('vat','CZ19',{reply});
  for (const status of [200,299,400,404,429,500,503]) await add('vat','CZ19',{status,reply:{valid:true}});
  for (const config of [{networkError:true},{invalidJSON:true}]) await add('vat','CZ19',config);
  for (const input of [{country:' cz ',number:' 19 '},{country:'DE',number:'19'},{country:'CZ',number:'bad'}]) for (const config of [{reply:base},{reply:null},{status:404},{status:500},{disabled:true},{authFailure:true},{contextFailure:true}]) await add('actionLookup',input,config);
  for (const input of ['CZ19','DE12','GB12','CZ','2708',' \u0085CZ19','CZ-']) for (const config of [{reply:{valid:true}},{reply:{valid:false}},{reply:{}},{status:500},{disabled:true},{authFailure:true},{contextFailure:true}]) await add('actionVat',input,config);
  for (const op of ['countries','canValidate']) for (const config of [{},{disabled:true},{authFailure:true}]) await add(op,'',config);
  fs.writeFileSync(process.argv[2],JSON.stringify({sourceSHA256:hashes,cases},null,2)+'\n');
  console.log(JSON.stringify({sourceFiles:Object.keys(hashes).length,cases:cases.length}));
})().catch(error=>{ console.error(error);process.exitCode=1; });
