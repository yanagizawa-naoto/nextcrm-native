// Extract a compact, closed vocabulary from the actual Zod definitions. Node
// is used at build/test time only; the native app never imports these modules.
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict'), crypto = require('node:crypto');
const { getTools, hashes, root } = require('./mcp-tools-reference.cjs');
const { getParseErrorMessage } = require('@modelcontextprotocol/sdk/server/zod-compat.js');
const sourceTools = getTools();
const discovery = JSON.parse(fs.readFileSync(path.join(__dirname, 'build/mcp-tools-reference.json'), 'utf8'));
assert.deepEqual(discovery.sourceSHA256, hashes, 'discovery source changed; regenerate first');
const nodes = [], interned = new Map();
function exactKeys(object, allowed, label) {
  for (const key of Object.keys(object)) assert.ok(allowed.includes(key), `Unsupported ${label} field ${key}`);
}
function compileCheck(check) {
  const d = check._zod.def, out = { kind: d.check };
  switch (d.check) {
    case 'greater_than': case 'less_than':
      exactKeys(d, ['check', 'value', 'inclusive'], d.check);
      Object.assign(out, { value: d.value, inclusive: d.inclusive }); break;
    case 'min_length': case 'max_length': case 'length_equals':
      exactKeys(d, ['check', 'minimum', 'maximum', 'length', 'when'], d.check);
      out.value = d.minimum ?? d.maximum ?? d.length; break;
    case 'number_format':
      exactKeys(d, ['type', 'check', 'abort', 'format'], d.check);
      assert.equal(d.format, 'safeint'); out.format = d.format; break;
    case 'string_format':
      exactKeys(d, ['type', 'check', 'abort', 'format', 'pattern', 'offset', 'local', 'precision'], d.check);
      assert.ok(['uuid', 'email', 'datetime'].includes(d.format));
      assert.equal(d.pattern.flags, '');
      Object.assign(out, { format: d.format, pattern: d.pattern.source }); break;
    default: throw new Error(`Unsupported Zod check ${d.check}`);
  }
  return out;
}
function compile(schema) {
  const d = schema._zod.def, node = { type: d.type };
  const allowed = ['type', 'checks'];
  switch (d.type) {
    case 'object':
      allowed.push('shape');
      node.properties = Object.entries(d.shape).map(([name, child]) => ({ name, node: compile(child), optional: child._zod.optin === 'optional' })); break;
    case 'default':
      allowed.push('defaultValue'); node.value = d.defaultValue;
      // Fall through: wrappers preserve their order, unlike JSON Schema.
    case 'optional': case 'nullable':
      allowed.push('innerType'); node.inner = compile(d.innerType); break;
    case 'array': allowed.push('element'); node.inner = compile(d.element); break;
    case 'enum':
      allowed.push('entries'); node.values = Object.values(d.entries);
      assert.ok(node.values.every(x => typeof x === 'string')); break;
    case 'string': case 'number': case 'boolean': case 'any': break;
    default: throw new Error(`Unsupported Zod type ${d.type}`);
  }
  exactKeys(d, allowed, d.type);
  if (d.checks?.length) node.checks = d.checks.map(compileCheck);
  const key = JSON.stringify(node);
  if (!interned.has(key)) { interned.set(key, nodes.length); nodes.push(node); }
  return interned.get(key);
}
const tools = sourceTools.map(tool => ({ ...discovery.tools.find(x => x.name === tool.name), schema: compile(tool.schema) }));
const runtimeFiles = ['node_modules/zod/v4/core/checks.cjs', 'node_modules/zod/v4/core/schemas.cjs', 'node_modules/zod/v4/core/util.cjs', 'node_modules/zod/v4/core/regexes.cjs', 'node_modules/zod/v4/locales/en.cjs', 'node_modules/@modelcontextprotocol/sdk/dist/cjs/server/zod-compat.js'];
const runtimeSHA256 = Object.fromEntries(runtimeFiles.map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex')]));
const semantics = { stringLength: 'codePoints', objectUnknownFields: 'strip', regex: 'ECMAScriptNoFlags' };
const catalog = { version: 1, semantics, tools, nodes, sourceSHA256: hashes, runtimeSHA256 };
const clone = value => JSON.parse(JSON.stringify(value));
const uuid = '11111111-1111-4111-8111-111111111111';
function example(schema) {
  const d = schema._zod.def;
  if (d.type === 'default') return d.defaultValue;
  if (d.type === 'optional' || d.type === 'nullable') return example(d.innerType);
  if (d.type === 'object') return Object.fromEntries(Object.entries(d.shape).map(([k, v]) => [k, example(v)]));
  if (d.type === 'enum') return Object.values(d.entries)[0];
  if (d.type === 'boolean') return true;
  if (d.type === 'any') return { 日本語: ['任意', 1, null, true, { nested: '保持' }] };
  const checks = (d.checks ?? []).map(x => x._zod.def);
  if (d.type === 'array') return Array.from({ length: Math.max(1, ...checks.filter(x => x.check === 'min_length').map(x => x.minimum)) }, () => example(d.element));
  if (d.type === 'number') return Math.max(1, ...checks.filter(x => x.check === 'greater_than').map(x => x.value + (x.inclusive ? 0 : 1)));
  if (d.type === 'string') {
    const format = checks.find(x => x.check === 'string_format')?.format;
    if (format === 'uuid') return uuid;
    if (format === 'email') return 'test@example.com';
    if (format === 'datetime') return '2024-02-29T12:30:45.123Z';
    const length = checks.find(x => x.check === 'length_equals')?.length;
    return length ? 'J'.repeat(length) : '日本語';
  }
  throw new Error('No example for ' + d.type);
}
function mutate(base, segments, value, remove = false) {
  if (!segments.length) return value;
  const copy = clone(base); let cursor = copy;
  for (const part of segments.slice(0, -1)) cursor = cursor[part];
  if (remove) delete cursor[segments.at(-1)]; else cursor[segments.at(-1)] = clone(value);
  return copy;
}
function variations(schema) {
  let d = schema._zod.def;
  while (['optional', 'nullable', 'default'].includes(d.type)) d = d.innerType._zod.def;
  const result = [null, true, 0, '', [], {}];
  const checks = (d.checks ?? []).map(x => x._zod.def);
  if (checks.some(x => ['min_length', 'max_length', 'length_equals'].includes(x.check))) {
    for (const length of [0, 3, null, false, '3', 'x', [], [3], '0x3', '\u0085', 'Infinity']) result.push({ length });
  }
  if (d.type === 'number') {
    result.push(-1, 1.5, -1.5, 9007199254740991, 9007199254740992, -9007199254740992, '20');
    for (const c of checks) if (c.value !== undefined) result.push(c.value - 0.5, c.value, c.value + 0.5, c.value - 1, c.value + 1);
  }
  if (d.type === 'string') {
    result.push(' ', '😀', '😀a', '😀ab', 'e\u0301', '日'.repeat(101));
    const format = checks.find(x => x.check === 'string_format')?.format;
    if (format === 'uuid') result.push(uuid, uuid.toUpperCase(), '00000000-0000-0000-0000-000000000000', 'ffffffff-ffff-ffff-ffff-ffffffffffff', uuid.replace('-4111-', '-0111-'), uuid.replace('-8111-', '-7111-'), uuid + '\n', uuid + '\r\n', uuid + '\u0085', uuid + '\u2028');
    if (format === 'email') result.push('a@b.co', 'a+b@example.com', "o'neil@example.com", '.a@example.com', 'a..b@example.com', '日本@example.com', 'a@example.com\n', 'a@example.com\r\n', 'a@example.com\u0085');
    if (format === 'datetime') result.push('2024-02-29T00:00:00Z', '2000-02-29T12:30:45Z', '1900-02-29T12:30:45Z', '2023-02-29T12:30:45Z', '2024-04-31T12:30:45Z', '2024-01-01T24:00:00Z', '2024-01-01T12:30:45+09:00', '2024-01-01', '2024-01-01T12:30:45Z\n', '２０２４-01-01T12:30:45Z', '2024-01-01T١٢:30:45Z', '0000-02-29T00:00:00Z');
  }
  if (d.type === 'enum') result.push(...Object.values(d.entries), '__invalid', Object.values(d.entries)[0].toLowerCase());
  if (d.type === 'boolean') result.push(false, 'false', 1);
  if (d.type === 'any') result.push(['自由', { deep: [true, null, 4.5] }]);
  if (d.type === 'array') {
    result.push([null], ['bad'], [example(d.element)]);
    for (const c of checks) {
      const bound = c.minimum ?? c.maximum;
      if (bound !== undefined) for (const length of [Math.max(0, bound - 1), bound, bound + 1]) result.push(Array.from({ length }, () => example(d.element)));
    }
  }
  return result;
}
const validation = [];
for (const tool of sourceTools) {
  const base = example(tool.schema); assert.ok(tool.schema.safeParse(base).success, 'valid baseline: ' + tool.name);
  const samples = new Map();
  function add(input, label) {
    const key = JSON.stringify(input);
    // The transport is JSON: sparse array slots become null, not undefined.
    if (!samples.has(key)) samples.set(key, { input: JSON.parse(key), label });
  }
  add(base, 'valid-all-fields'); add({}, 'missing-fields'); add({ ...base, __unknown: 'strip-me' }, 'strip-unknown-root');
  for (const value of [null, true, 42, 'bad', []]) add(value, 'root-type');
  function walk(schema, segments) {
    if (segments.length) {
      add(mutate(base, segments, undefined, true), 'omit:' + segments.join('.'));
      for (const value of variations(schema)) add(mutate(base, segments, value), 'value:' + segments.join('.'));
    }
    let d = schema._zod.def;
    while (['optional', 'nullable', 'default'].includes(d.type)) d = d.innerType._zod.def;
    if (d.type === 'object') {
      if (segments.length) {
        let value = base; for (const part of segments) value = value[part];
        add(mutate(base, segments, { ...value, __unknown: 'strip-nested' }), 'strip-unknown-nested');
      }
      for (const [name, child] of Object.entries(d.shape)) walk(child, [...segments, name]);
    } else if (d.type === 'array') walk(d.element, [...segments, 0]);
  }
  walk(tool.schema, []);
  const cases = [...samples.values()].map(({ input, label }) => {
    const result = tool.schema.safeParse(input);
    return result.success ? { label, input, data: result.data } : {
      label, input, issues: result.error.issues.map(x => ({ path: x.path, message: x.message })), message: getParseErrorMessage(result.error),
    };
  });
  validation.push({ name: tool.name, cases });
}
// Preserve the literal bytes: Foundation JSON can retain more decimal digits
// than the original JavaScript server's JSON.parse binary64 value.
function firstNumber(schema, path = []) {
  let d = schema._zod.def;
  while (['optional', 'nullable', 'default'].includes(d.type)) d = d.innerType._zod.def;
  if (d.type === 'number') return path;
  if (d.type === 'array') return firstNumber(d.element, [...path, 0]);
  if (d.type === 'object') for (const [name, child] of Object.entries(d.shape)) {
    const found = firstNumber(child, [...path, name]); if (found) return found;
  }
  return null;
}
const rawNumbers = [];
for (const name of ['crm_create_contract', 'crm_create_product', 'crm_upsert_price_list_rule']) {
  const tool = sourceTools.find(x => x.name === name), at = firstNumber(tool.schema); assert.ok(at);
  const base = mutate(example(tool.schema), at, '__RAW_NUMBER__');
  for (const literal of ['0.0049999999999999999999', '0.0149999999999999999999', '1.00000000000000000000001', '9007199254740993', '1e-7', '0.015', '-0.005']) {
    const raw = JSON.stringify(base).replace('"__RAW_NUMBER__"', literal), result = tool.schema.safeParse(JSON.parse(raw));
    rawNumbers.push(result.success ? { name, raw, data: result.data } : { name, raw, issues: result.error.issues.map(x => ({ path: x.path, message: x.message })), message: getParseErrorMessage(result.error) });
  }
}
fs.writeFileSync(process.argv[2], JSON.stringify(catalog, null, 2) + '\n');
fs.writeFileSync(process.argv[3], JSON.stringify({ sourceSHA256: hashes, runtimeSHA256, validation, rawNumbers }, null, 2) + '\n');
console.log(JSON.stringify({ tools: tools.length, uniqueRuleNodes: nodes.length, cases: validation.reduce((n, x) => n + x.cases.length, 0), catalogBytes: fs.statSync(process.argv[2]).size, referenceBytes: fs.statSync(process.argv[3]).size }));
