// Use the already installed upstream dependencies. This is a test oracle only;
// the native application never invokes Node or loads these packages.
const fs = require('node:fs');
const crypto = require('node:crypto');
const nodemailer = require('nodemailer');
const { simpleParser } = require('mailparser');

function flat(values) {
  return values.flatMap(value => value.group ? flat(value.group) : [{ email: value.address, ...(value.name ? { name: value.name } : {}) }]);
}
const cases = [
  '"Last, First" <first@example.test>, second@example.test',
  '"営業部, 東京" <sales@example.test>',
  '"山田 \\"花子\\"" <hanako@example.test>'.replaceAll('\\\\', '\\'),
  '"a b"@example.test',
  '"a,@b"@example.test',
  '"a\\"b"@example.test',
  '担当者@例え.テスト',
  'Team: first@example.test, second@example.test;',
  'first@example.test (営業部)',
  'user@[127.0.0.1]',
  'user@[IPv6:2001:db8::1]',
  '=?UTF-8?B?5pel5pys6Kqe?= <jp@example.test>',
  Array.from({ length: 1501 }, (_, i) => `person${i}@example.test`).join(', '),
];
(async () => {
  const transport = nodemailer.createTransport({ streamTransport: true, buffer: true, newline: 'windows' });
  const samples = [];
  for (const input of cases) {
    const sent = await transport.sendMail({ from: 'sender@example.test', to: input, subject: '宛先互換試験', text: '本文', date: new Date(0), messageId: '<address-reference@example.test>' });
    const parsed = await simpleParser(sent.message);
    samples.push({ input, mime: sent.message.toString('base64'), expected: flat(parsed.to.value) });
  }
  const modules = ['nodemailer', 'mailparser'].map(name => {
    const path = require.resolve(name); return { name, entry: path, sha256: crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex') };
  });
  fs.writeFileSync(process.argv[2], JSON.stringify({ network: 'none; installed upstream packages, stream transport only', modules, samples }, null, 2) + '\n');
  console.log(JSON.stringify({ addressReferenceCases: samples.length, output: process.argv[2] }));
})().catch(error => { console.error(error); process.exitCode = 1; });
