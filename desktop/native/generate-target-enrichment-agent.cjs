// Adapt the original remote script; no runtime inputs are interpolated into code.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module'), ts = require('typescript');
function load(relative) {
  const file = path.resolve(__dirname,'../..',relative), m = new Module(file,module); m.filename=file; m.paths=Module._nodeModulePaths(path.dirname(file));
  m._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,file); return m.exports;
}
let script = load('lib/enrichment/e2b/agent-script.ts').getAgentScript();
function replaceOnce(before, after) { if (script.split(before).length !== 2) throw Error('Original enrichment script changed: '+before); script=script.replace(before,after); }
const allowed = Object.keys(load('lib/enrichment/presets/target-fields.ts').FIELD_MAP);
const prefix = `// Native NextCRM additions: structured progress and requested target fields.\n`+
`const nativeAllowedFields = new Set(${JSON.stringify(allowed)});\n`+
`function nativeProgress(message, sourceURL) { process.stderr.write('@@NEXTCRM_PROGRESS@@' + JSON.stringify({message,kind:'agent',sourceURL}) + '\\n'); }\n`+
`function nativeFieldsInstruction() {\n`+
`  const fields = JSON.parse(process.env.NEXTCRM_ENRICHMENT_FIELDS || '[]');\n`+
`  if (!Array.isArray(fields) || fields.length>18 || fields.some(f=>!f || !nativeAllowedFields.has(f.name))) throw new Error('Invalid requested fields');\n`+
`  return fields.length ? '\\nThe requested target fields replace the target object schema above. Research all these fields and return only these keys in target, with string or null values. Keep contacts and confidence in the same format. Field definitions: ' + JSON.stringify(fields) : '';\n`+
`}\n`;
replaceOnce('system: systemPrompt,','system: systemPrompt + nativeFieldsInstruction(),');
replaceOnce('    const response = await client.messages.create({',"    nativeProgress('企業・担当者の情報を調べています。');\n    const response = await client.messages.create({");
replaceOnce('function executeTool(name, input) {',"function executeTool(name, input) {\n  if (name === 'browser_open') { try { const url = new URL(input.url); if (!['http:','https:'].includes(url.protocol) || url.username || url.password) return 'Only HTTP(S) URLs without embedded credentials are allowed.'; } catch { return 'Invalid website URL.'; } }\n  nativeProgress('公開情報を確認しています。', name === 'browser_open' && typeof input.url === 'string' ? input.url.slice(0,8000) : undefined);");
const last = script.split('\n').find(line=>line.startsWith('main().catch(')); if (!last) throw Error('Original main catch missing');
replaceOnce(last,"main().catch(e => { process.stderr.write('@@NEXTCRM_ERROR@@' + JSON.stringify({status:Number.isInteger(e.status) ? e.status : null}) + '\\n'); process.exit(1); });");
script = prefix + script + '\n';
const destination=process.argv[2] || path.join(__dirname,'build/TargetEnrichmentAgent.mjs'); fs.mkdirSync(path.dirname(destination),{recursive:true}); fs.writeFileSync(destination,script);
console.log('Generated original E2B agent with native field selection/progress');
