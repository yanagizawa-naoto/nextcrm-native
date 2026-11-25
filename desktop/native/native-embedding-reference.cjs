// Execute the actual original helpers with the already installed TypeScript
// compiler. No API calls, packages, runtimes, or fixture downloads.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const sourcePath = path.resolve(__dirname, '../../inngest/lib/embedding-utils.ts');
const compiled = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;
const original = new Module(sourcePath, module);
original.filename = sourcePath;
original.paths = Module._nodeModulePaths(path.dirname(sourcePath));
original._compile(compiled, sourcePath);
const { buildEmbeddingText, computeContentHash } = original.exports;
const texts = [
  [], [null, '', ' \n\t', '　'], ['  株式会社日本  ', '担当者\n山田', null, '営業@example.invalid'],
  ['\uFEFF', '\u0085', '\u200B'], ['か\u3099', 'が', '👩‍💻'],
  ['\u2028\u2029', '\u00A0', '\u1680', '\u202F', '\u205F', '\u200A'],
].map(fields => { const text = buildEmbeddingText(fields); return { fields, text, hash: computeContentHash(text) }; });
const a = Float32Array.from({length:1536}, (_,i) => Math.sin(i * .73) * (i % 5 + 1));
const b = Float32Array.from({length:1536}, (_,i) => Math.cos(i * .31) * (i % 7 + 1));
let dot = 0, aa = 0, bb = 0;
for (let i = 0; i < a.length; i++) { dot += a[i]*b[i]; aa += a[i]*a[i]; bb += b[i]*b[i]; }
const encode = values => { const bytes = Buffer.alloc(values.length*4); values.forEach((v,i) => bytes.writeFloatLE(v,i*4)); return bytes.toString('base64'); };
fs.writeFileSync(process.argv[2], JSON.stringify({texts, a:encode(a), b:encode(b), similarity:dot/Math.sqrt(aa*bb)},null,2)+'\n');
