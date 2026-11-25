// Original five contract handlers, auth scopes and run-tool, with an isolated
// synthetic Prisma adapter. No live PostgreSQL or plugin code is invoked.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module');
const ts = require('typescript'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const { Prisma } = require('@prisma/client');
const root = path.resolve(__dirname, '../..'), cache = new Map(), hashes = {};
const shared = JSON.parse(fs.readFileSync(path.join(__dirname, 'build/mcp-accounts-reference.json'), 'utf8'));
const schema = fs.readFileSync(path.join(root, 'prisma/schema.prisma'), 'utf8'), epoch = shared.epoch;
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const definitions = new Map();
function fields(model) {
  if (definitions.has(model)) return definitions.get(model);
  const body = schema.match(new RegExp(`model ${model}\\s*\\{([\\s\\S]*?)^\\}`, 'm'))[1];
  const scalarNames = new Set(Prisma.dmmf.datamodel.models.find(x => x.name === model).fields.filter(x => x.kind !== 'object').map(x => x.name));
  const values = body.split('\n').map(line => {
    const match = line.match(/^\s*(\w+)\s+(\w+)(\[\]|\?)?(.*)$/); if (!match || !scalarNames.has(match[1])) return null;
    return { name: match[1], type: match[2], array: match[3] === '[]', optional: match[3] === '?', rest: match[4] };
  }).filter(Boolean);
  definitions.set(model, values); return values;
}
function full(model, values, generated = uid(9000)) {
  const row = {};
  for (const field of fields(model)) {
    const expression = field.rest.match(/@default\(([^)]*)\)/)?.[1];
    let value = field.array ? [] : null;
    if (field.rest.includes('@updatedAt') || expression?.startsWith('now(')) value = epoch;
    else if (expression?.startsWith('uuid(')) value = generated;
    else if (expression !== undefined) { try { value = JSON.parse(expression); } catch { value = expression; } }
    row[field.name] = value;
  }
  Object.assign(row, values);
  for (const field of fields(model)) {
    const value = row[field.name];
    if (value == null) { if (!field.optional && !field.array) throw Error('Missing required scalar ' + field.name); continue; }
    if (field.type === 'Decimal') {
      const [, precision, scale] = field.rest.match(/@db.Decimal\((\d+),\s*(\d+)\)/);
      const decimal = new Prisma.Decimal(value).toDecimalPlaces(Number(scale), Prisma.Decimal.ROUND_HALF_UP);
      if (decimal.abs().gte(new Prisma.Decimal(10).pow(Number(precision) - Number(scale)))) throw Error('numeric overflow');
      row[field.name] = decimal;
    }
    if (field.type === 'Int' && (!Number.isInteger(value) || value < -2147483648 || value > 2147483647)) throw Error('integer overflow');
    if (field.type === 'DateTime') { const date = new Date(value); if (!Number.isFinite(date.getTime())) throw Error('invalid date'); row[field.name] = date.toISOString(); }
    if (field.type === 'String' && typeof value === 'string' && value.includes('\0')) throw Error('PostgreSQL text cannot contain NUL');
  }
  return row;
}
const users = shared.users;
const accounts = shared.seeds.map(x => full('crm_Accounts', x));
const products = [full('crm_Products', { id: uid(600), name: '保存済み商品', type: 'PRODUCT', unit_price: '500', currency: 'JPY' })];
const seeds = [
  { id: uid(401), title: 'Alice 契約', assigned_to: uid(1), createdBy: uid(1), createdAt: null, snapshot_rate: '0.00000001' },
  { id: uid(402), title: 'Bob 秘密', assigned_to: uid(2), createdBy: uid(2), status: 'SIGNED' },
  { id: uid(403), title: '親企業所有で閲覧', assigned_to: uid(2), createdBy: uid(2), account: uid(101) },
  { id: uid(404), title: 'ウォッチで閲覧', assigned_to: uid(2), createdBy: uid(2), account: uid(103) },
  { id: uid(405), title: '削除済み契約', assigned_to: uid(1), createdBy: uid(1), deletedAt: epoch },
  { id: uid(406), title: '削除された親企業', assigned_to: uid(2), createdBy: uid(2), account: uid(105) },
  { id: uid(407), title: '所有者から関連企業の限定情報', assigned_to: uid(2), createdBy: uid(1), account: uid(102), status: 'INPROGRESS' },
  { id: uid(408), title: 'Alice 担当', assigned_to: uid(1), createdBy: uid(2) },
  { id: uid(409), title: '他人の企業', assigned_to: uid(2), createdBy: uid(2), account: uid(102) },
  { id: uid(410), title: '無担当の関連契約', account: uid(101) },
].map(x => full('crm_Contracts', { v: 0, value: '1234.5', currency: 'JPY', ...x }));
const lineSeeds = [
  { id: uid(501), contractId: uid(401), name: '後の明細', sort_order: 20, productId: uid(600), unit_price: '12.5', line_total: '11.1', discount_value: '1.4' },
  { id: uid(502), contractId: uid(401), name: '先の明細', sort_order: 10, unit_price: '20', line_total: '987.65' },
  { id: uid(503), contractId: uid(407), name: '関連企業が非公開でも契約の明細を返す', sort_order: 0, unit_price: '50', line_total: '50' },
].map(x => full('crm_ContractLineItems', { currency: 'JPY', createdBy: uid(1), ...x }));
let contracts = [], lines = [], actors = [], currentActorFrame;
function observed() { actors.push(currentActorFrame()?.actor); }
function matches(row, where = {}) {
  return Object.entries(where).every(([key, value]) => {
    if (key === 'OR') return value.some(x => matches(row, x));
    if (key === 'AND') return value.every(x => matches(row, x));
    if (key === 'watchers') return shared.watchers.some(x => x.account_id === row.id && matches(x, value.some));
    if (key === 'assigned_account') return accounts.some(x => x.id === row.account && matches(x, value));
    assert.ok(Object.hasOwn(row, key), 'Unknown oracle predicate ' + key); return row[key] === value;
  });
}
function order(rows, orderBy) {
  const terms = Array.isArray(orderBy) ? orderBy : [orderBy];
  return [...rows].sort((a, b) => {
    for (const term of terms) { const [[key, direction]] = Object.entries(term), av = a[key], bv = b[key];
      const cmp = av === bv ? 0 : av == null ? 1 : bv == null ? -1 : av < bv ? -1 : 1;
      if (cmp) return direction === 'desc' ? -cmp : cmp;
    } return 0;
  });
}
function projection(row, select, include) {
  if (!row) return null;
  if (select) return Object.fromEntries(Object.keys(select).map(key => [key, row[key]]));
  const result = { ...row };
  if (include?.lineItems) { const related = lines.filter(x => x.contractId === row.id); result.lineItems = include.lineItems.orderBy ? order(related, include.lineItems.orderBy) : related; }
  if (include?.assigned_account) result.assigned_account = projection(accounts.find(x => x.id === row.account), include.assigned_account.select);
  return result;
}
function foreignKeys(row, model) {
  if (model === 'crm_Contracts') {
    if (row.account && !accounts.some(x => x.id === row.account)) throw Error('FK account');
    if (row.assigned_to && !users.some(x => x.id === row.assigned_to)) throw Error('FK assignee');
    if (row.currency && !['JPY','USD','EUR','CZK'].includes(row.currency)) throw Error('FK currency');
  } else if (row.productId && !products.some(x => x.id === row.productId)) throw Error('FK product');
}
const db = {
  crm_Accounts: { findFirst: async ({ where, select }) => { observed(); return projection(accounts.find(x => matches(x, where)), select); } },
  crm_Contracts: {
    findFirst: async ({ where, select, include }) => { observed(); return projection(contracts.find(x => matches(x, where)), select, include); },
    findUnique: async ({ where, select }) => { observed(); return projection(contracts.find(x => matches(x, where)), select); },
    findMany: async ({ where, orderBy, take, skip, include }) => {
      observed(); if (!Number.isInteger(take) || !Number.isInteger(skip) || skip > 2147483647) throw Error('Prisma integer pagination');
      return order(contracts.filter(x => matches(x, where)), orderBy).slice(skip, skip + take).map(x => projection(x, undefined, include));
    },
    count: async ({ where }) => { observed(); return contracts.filter(x => matches(x, where)).length; },
    create: async ({ data, include }) => {
      observed(); const { lineItems, ...values } = data, row = full('crm_Contracts', values); foreignKeys(row, 'crm_Contracts');
      const items = (lineItems?.create ?? []).map((x, i) => { const item = full('crm_ContractLineItems', { ...x, contractId: row.id }, uid(9100 + i)); foreignKeys(item, 'crm_ContractLineItems'); return item; });
      // Nested create is atomic, including a failing later line.
      contracts.push(row); lines.push(...items); return projection(row, undefined, include);
    },
    update: async ({ where, data }) => {
      observed(); const index = contracts.findIndex(x => matches(x, where)); assert.ok(index >= 0);
      const row = full('crm_Contracts', { ...contracts[index], ...data, updatedAt: epoch }); foreignKeys(row, 'crm_Contracts');
      contracts[index] = row; return { ...row };
    },
  },
};
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
  mod._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, filename); return mod.exports;
}
(async () => {
  const { crmContractTools: tools } = load('lib/mcp/tools/crm-contracts.ts'), { runMcpToolCall } = load('lib/mcp/run-tool.ts');
  ({ currentActorFrame } = load('lib/plugins/actor.ts'));
  const requests = [], cases = [], add = (user, tool, input, label = tool) => requests.push({ user: uid(user), tool, input, label });
  for (const user of [1,2,3,4]) {
    for (const input of [{},{limit:2,offset:1},{status:'SIGNED'},{account:uid(101)},{status:'INPROGRESS',account:uid(102)}]) add(user,'crm_list_contracts',input);
    for (const row of [401,402,403,404,405,406,407,410,9998]) add(user,'crm_get_contract',{id:uid(row)});
  }
  for (const [user,row] of [[1,401],[1,402],[1,403],[1,404],[1,405],[1,406],[1,407],[1,408],[4,402],[4,405]]) {
    add(user,'crm_update_contract',{id:uid(row),title:'  更新契約  ',value:1.005,status:'SIGNED'});
    add(user,'crm_delete_contract',{id:uid(row)});
  }
  add(1,'crm_create_contract',{title:'  日本語契約  ',value:0});
  add(1,'crm_create_contract',{title:'長'.repeat(600),value:123.456,startDate:'2026-01-02T03:04:05.678999Z',endDate:'2027-01-02T03:04:05Z',currency:'JPY',type:'任意',description:'そのままの説明'});
  for (const startDate of ['0000-01-01T00:00:00.000Z','0001-01-01T00:00:00Z','1582-10-10T00:00:00.123456Z','9999-12-31T23:59:59.999Z']) add(1,'crm_create_contract',{title:'Gregorian date',value:1,startDate,endDate:startDate},'calendar-boundaries');
  for (const amount of [0.004,0.005,0.015,2.675,5e-324,99999999999999.98,1e16]) add(1,'crm_create_contract',{title:'decimal',value:amount},'numeric-rounding');
  for (const rawInputJSON of ['{"title":"raw double rounding","value":0.00499999999999999999999}', '{"title":"raw precision boundary","value":0.01499999999999999999999}']) {
    add(1,'crm_create_contract',JSON.parse(rawInputJSON),'raw-json-number'); requests.at(-1).rawInputJSON = rawInputJSON;
  }
  for (const account of [uid(101),uid(102),uid(103),uid(105),uid(9998)]) add(1,'crm_create_contract',{title:'企業リンク',value:1,account});
  for (const assigned_to of [uid(2),uid(5),uid(6),uid(9998)]) add(1,'crm_create_contract',{title:'担当者',value:1,assigned_to});
  for (const account of [uid(101),uid(102),uid(103),uid(105),uid(9998)]) add(1,'crm_update_contract',{id:uid(407),account},'unchanged-versus-relinked-parent');
  for (const assigned_to of [uid(5),uid(9998)]) add(1,'crm_update_contract',{id:uid(401),assigned_to});
  add(1,'crm_update_contract',{id:uid(401),startDate:'2001-02-03T04:05:06.1239Z',endDate:'2000-01-01T00:00:00Z',lineItems:[{name:'must-strip'}]},'date-and-no-lines-update');
  const line = { name:'明細',unit_price:1.005,line_total:999.995,currency:'JPY' };
  add(1,'crm_create_contract',{title:'明細付き',value:999,lineItems:[{...line,productId:uid(600),sort_order:20},{...line,name:'先の明細',sort_order:10,quantity:2,discount_type:'FIXED',discount_value:1.115}]});
  add(1,'crm_create_contract',{title:'後の明細が失敗',value:10,lineItems:[line,{...line,productId:uid(9998)}]},'atomic-foreign-key-failure');
  add(1,'crm_create_contract',{title:'多い明細',value:0,lineItems:Array.from({length:105},(_,i)=>({...line,name:'明細'+i,sort_order:104-i}))},'all105-lines');
  add(1,'crm_create_contract',{title:'明細なし',value:0,lineItems:[]});
  add(1,'crm_create_contract',{title:'quantity overflow',value:1,lineItems:[{...line,quantity:2147483648}]});
  add(1,'crm_create_contract',{title:'unknown currency',value:1,currency:'ZZZ'});
  for (const input of [{limit:1.5},{offset:0.5},{offset:2147483648}]) add(1,'crm_list_contracts',input);
  for (const request of requests) {
    contracts = seeds.map(x=>({...x})); lines = lineSeeds.map(x=>({...x})); actors=[];
    const user = users.find(x=>x.id===request.user), tool=tools.find(x=>x.name===request.tool), args=tool.schema.parse(request.input);
    const result = await runMcpToolCall(async()=>({id:user.id,role:user.role}),u=>tool.handler(args,u.id,u));
    assert.ok(actors.length && actors.every(x=>x?.type==='token' && x.userId===user.id && x.role===user.role));
    cases.push({...request,result,contracts,lines});
  }
  for (const file of ['prisma/schema.prisma','node_modules/@prisma/client/package.json','node_modules/@prisma/client/runtime/client.js','node_modules/zod/package.json']) hashes[file]=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
  fs.writeFileSync(process.argv[2],JSON.stringify({epoch,seeds,lineSeeds,products,cases,tools:tools.map(x=>x.name),sourceSHA256:hashes,numericSemantics:'PostgreSQL numeric declared scale, ties away from zero: https://www.postgresql.org/docs/current/datatype-numeric.html'},null,2)+'\n');
  console.log(JSON.stringify({sourceContractCases:cases.length,tools:tools.length,scope:'Original handlers/auth/run-tool with synthetic Prisma, declared numeric-scale emulation, real Prisma Decimal JSON; live PostgreSQL/plugins untested.'}));
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
