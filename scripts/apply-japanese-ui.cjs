const fs = require('node:fs');
const cp = require('node:child_process');
const os = require('node:os');
const path = require('node:path');
const file = path.join(os.tmpdir(), 'nextcrm-ui-literals.json');
cp.execFileSync(process.execPath, ['scripts/japanese-audit.cjs', file]);
const entries = JSON.parse(fs.readFileSync(file, 'utf8'));
const translations = JSON.parse(fs.readFileSync('scripts/ja-ui-translations.json', 'utf8'));
for (const line of fs.readFileSync('scripts/ja-ui-extra.tsv', 'utf8').split('\n')) {
  const separator = line.indexOf('\t');
  if (separator >= 0) translations[line.slice(0, separator)] = line.slice(separator + 1);
}
const changes = new Map();
for (const [text, occurrences] of Object.entries(entries)) {
  if (!(text in translations) || translations[text] === text) continue;
  for (const item of occurrences) {
    // Preserve API error codes, validators and protocol descriptions. The
    // desktop UI is a Japanese edition; translation keys remain untouched.
    if (!/^(app\/(?!api\/)|components\/|emails\/|actions\/|lib\/(?:spreadsheet|enrichment\/presets|crm\/funnel)|types\/)/.test(item.file)) continue;
    const list = changes.get(item.file) || [];
    const replacement = JSON.stringify(translations[text]);
    list.push({...item, replacement:item.kind === 'JsxText' ? `{${replacement}}` : replacement});
    changes.set(item.file, list);
  }
}
for (const [file, edits] of changes) {
  let source = fs.readFileSync(file, 'utf8');
  for (const edit of edits.sort((a,b)=>b.start-a.start)) {
    source = source.slice(0,edit.start)+edit.replacement+source.slice(edit.end);
  }
  fs.writeFileSync(file, source);
}
console.log(JSON.stringify({files:changes.size, edits:[...changes.values()].reduce((n,v)=>n+v.length,0)}));
