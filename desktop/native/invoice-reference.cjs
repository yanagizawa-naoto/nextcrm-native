// Golden values come from the original TypeScript implementation, using locked local dependencies.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const { Decimal } = require('decimal.js');
const file = path.resolve(__dirname, '../../lib/invoices/totals.ts');
const reference = new Module(file, module);
reference.filename = file;
reference.paths = Module._nodeModulePaths(path.dirname(file));
reference._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, file);
const { computeLineTotal, computeInvoiceTotals } = reference.exports;
let seed = 14537;
const next = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0);
const cases = [[], [{ quantity: '1', unitPrice: '0.005', discountPercent: '0', taxRate: '10' }],
  [{ quantity: '1', unitPrice: '100', discountPercent: '100', taxRate: '21' }],
  [{ quantity: '2', unitPrice: '100', discountPercent: '0', taxRate: '21' }]];
for (let n = 0; n < 250; n++) {
  cases.push(Array.from({ length: 1 + next() % 12 }, () => ({
    quantity: new Decimal(1 + next() % 200000).div(10000).toString(),
    unitPrice: new Decimal(next() % 1000000).div(100).toString(),
    discountPercent: new Decimal(next() % 10001).div(100).toString(),
    taxRate: ['0', '8', '10', '12', '21'][next() % 5],
  })));
}
const result = cases.map(inputs => {
  const values = inputs.map(line => Object.fromEntries(Object.entries(line).map(([key, value]) => [key, new Decimal(value)])));
  return { inputs, lines: values.map(computeLineTotal), total: computeInvoiceTotals(values) };
});
fs.writeFileSync(path.join(__dirname, 'build/invoice-reference.json'), JSON.stringify(result));
console.log(JSON.stringify({ referenceCases: result.length, source: 'lib/invoices/totals.ts' }));
