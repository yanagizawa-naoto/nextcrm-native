// Test-only oracle for the real incoming mailparser path; never used by the app.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const { simpleParser } = require('mailparser');
const fromParser = createRequire(require.resolve('mailparser'));
const libmime = fromParser('libmime');
const hash = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const cases = [];
function word(bytes, kind, charset = 'UTF-8') {
  const data = kind === 'B' ? bytes.toString('base64') : [...bytes].map(b => '=' + b.toString(16).toUpperCase().padStart(2, '0')).join('');
  return `=?${charset}?${kind}?${data}?=`;
}
for (const text of ['礎', '日本語', 'A😀B', 'é é']) {
  const bytes = Buffer.from(text);
  for (const kind of ['B', 'Q']) for (let split = 1; split < bytes.length; split++) {
    cases.push({ name: `${kind}-${text}-${split}`, input: word(bytes.subarray(0, split), kind) + ' \t' + word(bytes.subarray(split), kind) });
  }
}
for (const kind of ['B', 'Q']) {
  const b = Buffer.from('日本語');
  cases.push({ name: 'one-byte-' + kind, input: [...b].map(x => word(Buffer.from([x]), kind)).join('\r\n ') });
  cases.push({ name: 'prefix-suffix-' + kind, input: 'prefix ' + word(b.subarray(0, 1), kind) + ' ' + word(b.subarray(1), kind) + ' suffix' });
  cases.push({ name: 'case-alias-' + kind, input: word(b.subarray(0, 1), kind, 'utf-8') + ' ' + word(b.subarray(1), kind.toLowerCase() === 'b' ? 'B' : 'Q', 'UTF8') });
}
for (const [name, input] of [
  ['plain', 'Plain subject'], ['valid-japanese', '=?UTF-8?B?5pel5pys6Kqe?='],
  ['iso2022', '=?ISO-2022-JP?B?GyRCRnxLXDhsGyhC?='],
  ['mixed-charsets', '=?ISO-8859-1?Q?caf=E9?= =?utf-8?B?5pel?='],
  ['different-encoding-complete', '=?UTF-8?Q?=E6=97=A5?= =?UTF-8?B?5pys?='],
  ['plain-between', '=?UTF-8?B?5pel?= middle =?UTF-8?B?5pys?='],
  ['empty-word', '=?UTF-8?B??= =?UTF-8?B?5pel?='],
]) cases.push({ name, input });
(async () => {
  for (const item of cases) {
    const raw = `From: ${item.input} <sender@example.test>\r\nTo: receiver@example.test\r\nSubject: ${item.input}\r\n\r\nbody`;
    const parsed = await simpleParser(raw);
    item.expected = libmime.decodeWords(item.input);
    item.subject = parsed.subject;
    item.fromName = parsed.from.value[0].name;
  }
  const parser = require.resolve('mailparser'), mime = fromParser.resolve('libmime');
  const source = path.resolve(__dirname, '../../inngest/lib/imap-utils.ts');
  const parserFiles = ['lib/simple-parser.js', 'lib/mail-parser.js'].map(p => path.join(path.dirname(parser), p));
  const charset = path.join(path.dirname(mime), 'charset.js');
  const dependencies = Object.fromEntries([...parserFiles, charset].map(p => [p, hash(p)]));
  const records = { network: false, sourceHashes: { ...dependencies, [parser]: hash(parser), [mime]: hash(mime), [source]: hash(source), [__filename]: hash(__filename) }, cases };
  fs.writeFileSync(process.argv[2], JSON.stringify(records, null, 2) + '\n');
  console.log(JSON.stringify({ cases: cases.length }));
})().catch(e => { console.error(e); process.exitCode = 1; });
