// Execute the existing TypeScript actions/component against fake providers.
// No SMTP, DNS, credentials, database, or browser is used by this reference run.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require('typescript');
const root = path.resolve(__dirname, '../..');
const actionFile = 'actions/emails/messages.ts';
const composeFile = 'app/[locale]/(routes)/emails/components/ComposeModal.tsx';
let checks = 0;
function check(value, label) { assert.ok(value, label); checks++; }
function moduleFrom(file, requireMock) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const code = ts.transpileModule(source, {fileName: file, compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022,
    jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true,
  }}).outputText;
  const exports = {};
  vm.runInNewContext(code, {exports, require: requireMock, console, crypto}, {filename: file});
  return exports;
}
function plain(value) { return JSON.parse(JSON.stringify(value)); }
async function main() {
  const fixtures = [];
  for (const mode of ['new', 'reply', 'forward']) {
    let submitted;
    const jsx = (type, props) => ({type, props});
    const component = moduleFrom(composeFile, name => {
      if (name === 'react/jsx-runtime') return {jsx, jsxs: jsx};
      if (name === 'react') return {useState: initial => [initial, () => {}]};
      if (name === 'next/navigation') return {useRouter: () => ({refresh() {}})};
      if (name === '@/actions/emails/messages') return {sendEmail: async input => {submitted = plain(input);}};
      if (name.startsWith('@/components/ui/')) return new Proxy({}, {get: (_, key) => key});
      throw new Error('Unexpected component dependency: ' + name);
    });
    const source = {fromEmail:'customer@example.test',subject:'元の件名',bodyText:'元の日本語本文',rfcMessageId:'<original@example.test>'};
    const tree = component.ComposeModal({accountId:'account', mode, replyTo:source});
    function find(node) {
      if (!node || typeof node !== 'object') return null;
      if (node.props?.onClick) return node;
      const children = Array.isArray(node.props?.children) ? node.props.children : [node.props?.children];
      for (const child of children) { const found = find(child); if (found) return found; }
      return null;
    }
    await find(tree).props.onClick();
    check(submitted.accountId === 'account', 'original composer chooses active account');
    check(submitted.subject === (mode === 'new' ? '' : (mode === 'reply' ? 'Re: ' : 'Fwd: ') + source.subject), 'original subject ' + mode);
    check(JSON.stringify(submitted.to) === JSON.stringify(mode === 'reply' ? [source.fromEmail] : []), 'original recipient ' + mode);
    check(mode === 'reply' ? submitted.inReplyTo === source.rfcMessageId && submitted.references === source.rfcMessageId : !submitted.inReplyTo && !submitted.references, 'original threading ' + mode);
    check(mode === 'new' ? submitted.body === '' : submitted.body.endsWith(source.bodyText), 'original quotation ' + mode);
    fixtures.push({kind:'composer',mode,input:submitted,nativeDifference:'Quotation separator is translated to Japanese; HTML-only quotation also retains text.'});
  }
  class HostNotAllowedError extends Error {}
  for (const scenario of ['active','sync-paused','other-owner','missing-session','private-host']) {
    const account = {id:'account',userId:'owner',username:'owner@example.test',passwordEncrypted:'fake-reference',smtpHost:'smtp.example.test',smtpPort:587,smtpSsl:false,allowSelfSignedTls:false,isActive:scenario !== 'sync-paused'};
    let messages = [], saved = [], lookups = [];
    const actions = moduleFrom(actionFile, name => {
      if (name === '@/lib/auth-server') return {getSession:async () => scenario === 'missing-session' ? null : {user:{id:scenario === 'other-owner' ? 'stranger' : 'owner'}}};
      if (name === '@/lib/prisma') return {prismadb:{emailAccount:{findFirst:async ({where}) => {lookups.push(plain(where)); return where.id === account.id && where.userId === account.userId ? account : null;}},email:{create:async ({data}) => {saved.push(plain(data)); return data;}}}};
      if (name === '@/lib/email-crypto') return {decrypt:() => 'synthetic-only'};
      if (name === '@/lib/net/host-guard') return {HostNotAllowedError,assertPublicHost:async () => {if (scenario === 'private-host') throw new HostNotAllowedError(); return {address:'8.8.8.8',hostname:'smtp.example.test'};}};
      if (name === 'nodemailer') return {createTransport:() => ({sendMail:async message => {messages.push(plain(message)); return {messageId:'<sent@example.test>'};}})};
      if (name === '@prisma/client') return {EmailFolder:{INBOX:'INBOX',SENT:'SENT'}};
      throw new Error('Unexpected action dependency: ' + name);
    });
    let failure;
    try { await actions.sendEmail({accountId:'account',to:['to@example.test'],cc:['cc@example.test'],bcc:['bcc@example.test'],subject:'日本語の送信',body:'本文',inReplyTo:'<parent@example.test>',references:'<parent@example.test>'}); } catch (error) {failure = error;}
    if (['active','sync-paused'].includes(scenario)) {
      check(!failure && messages.length === 1 && saved.length === 1, 'original explicit send works: ' + scenario);
      check(messages[0].bcc === 'bcc@example.test' && saved[0].bccRecipients[0].email === 'bcc@example.test', 'original Bcc envelope/local copy');
      check(saved[0].folder === 'SENT' && saved[0].isRead && saved[0].bodyText === '本文', 'original sent copy');
      check(lookups[0].isActive === undefined, 'original sync toggle is not a sending authorization gate');
      fixtures.push({kind:'send',scenario,mail:messages[0],stored:saved[0]});
    } else {
      check(!!failure && messages.length === 0 && saved.length === 0, 'original rejects before send: ' + scenario);
      fixtures.push({kind:'rejection',scenario,noSend:true});
    }
  }
  function readActions(session, database, bodyProvider, events) {
    return moduleFrom(actionFile, name => {
      if (name === '@/lib/auth-server') return {getSession:async () => session};
      if (name === '@/lib/prisma') return {prismadb:database};
      if (name === '@/lib/email-crypto') return {decrypt:() => 'synthetic-only'};
      if (name === '@/lib/net/host-guard') return {HostNotAllowedError,assertPublicHost:() => {throw new Error('Unexpected host lookup');}};
      if (name === 'nodemailer') return {createTransport:() => {throw new Error('Unexpected send');}};
      if (name === '@prisma/client') return {EmailFolder:{INBOX:'INBOX',SENT:'SENT'}};
      if (name === '@/inngest/lib/imap-utils') return {fetchBodyByUid:bodyProvider};
      if (name === '@/inngest/client') return {inngest:{send:event => {events.push(plain(event)); return Promise.resolve();}}};
      throw new Error('Unexpected read dependency: ' + name);
    });
  }
  for (const search of ['', '顧客', '顧客名', '😀名']) {
    let query, countQuery;
    const actions = readActions({user:{id:'owner'}},{email:{
      findMany:async input => {query = plain(input); return [];},
      count:async input => {countQuery = plain(input); return 12_345;},
    }},() => {throw new Error('Unexpected body fetch');},[]);
    const page = plain(await actions.getEmails('account','SENT',2,search));
    check(query.skip === 50 && query.take === 50 && query.orderBy.sentAt === 'desc', 'original bounded header page');
    check(!query.select.bodyHtml && !query.select.bodyText && query.where.userId === 'owner' && query.where.isDeleted === false, 'original owner-only header projection');
    check(!!query.where.OR === (search.length >= 3), 'original search threshold uses JS UTF-16 length');
    check(JSON.stringify(query.where) === JSON.stringify(countQuery.where) && page.total === 10_000 && page.totalPages === 200, 'original matching count capped at ten thousand');
    fixtures.push({kind:'mail-list',search,query,page});
  }
  for (const scenario of ['cached','unloaded','sync-paused','fetch-failed','empty','other-owner','deleted','missing-session']) {
    const email = {id:'email',userId:'owner',emailAccountId:'account',imapUid:42,folder:'SENT',isDeleted:scenario === 'deleted',isRead:false,bodyText:scenario === 'cached' ? '保存済み本文' : null,bodyHtml:null,contacts:[{contact:{id:'contact',first_name:'山田',last_name:'太郎'}}],accounts:[]};
    const account = {username:'owner@example.test',passwordEncrypted:'fake',imapHost:'imap.example.test',imapPort:993,imapSsl:true,allowSelfSignedTls:false,sentFolderName:'送信済み',isActive:scenario !== 'sync-paused'};
    const userId = scenario === 'other-owner' ? 'stranger' : 'owner', updates = [], fetches = [], events = [], lookups = [];
    const actions = readActions(scenario === 'missing-session' ? null : {user:{id:userId}}, {
      email:{findFirst:async ({where}) => {lookups.push(plain(where)); return where.id === email.id && where.userId === email.userId && where.isDeleted === email.isDeleted ? structuredClone(email) : null;}, update:async input => {updates.push(plain(input)); return input.data;}},
      emailAccount:{findUnique:async input => {lookups.push(plain(input)); return account;}},
    }, async (...args) => {fetches.push(plain(args)); if (scenario === 'fetch-failed') throw new Error('Synthetic unavailable provider'); return scenario === 'empty' ? {} : {bodyText:'取得した日本語本文',bodyHtml:'<p>日本語</p>'};},events);
    let found, failure;
    try {found = plain(await actions.getEmail('email'));} catch (error) {failure = error;}
    if (['other-owner','deleted','missing-session'].includes(scenario)) {
      check(!!failure && fetches.length === 0 && updates.length === 0, 'original read privacy: ' + scenario);
    } else {
      check(!failure && updates.some(x => x.data.isRead === true), 'original read marks viewed message: ' + scenario);
      check(fetches.length === (scenario === 'cached' ? 0 : 1), 'original lazy body fetch: ' + scenario);
      if (fetches.length) check(fetches[0][1] === '送信済み' && fetches[0][2] === 42, 'original body uses configured sent folder and UID');
      if (['unloaded','sync-paused'].includes(scenario)) check(found.bodyText === '取得した日本語本文' && events.length === 1, 'original foreground fetch works while sync is paused, with linked embedding');
      if (['fetch-failed','empty'].includes(scenario)) check(found.bodyText === null && events.length === 0, 'original missing body fallback is not a loaded body');
    }
    fixtures.push({kind:'mail-read',scenario,found,failed:!!failure,updates,fetches,events,lookups});
  }
  for (const scenario of ['owner','other-owner','already-deleted']) {
    const updates = [], owner = scenario === 'other-owner' ? 'stranger' : 'owner';
    const actions = readActions({user:{id:owner}},{email:{findFirst:async ({where}) => where.userId === 'owner' && scenario !== 'already-deleted' ? {id:'email'} : null,update:async input => {updates.push(plain(input));}}},() => {throw new Error('Unexpected server mutation');},[]);
    let failed = false; try {await actions.deleteEmail('email');} catch {failed = true;}
    check(scenario === 'owner' ? !failed && updates.length === 1 && updates[0].data.isDeleted === true : failed && updates.length === 0, 'original local deletion: ' + scenario);
    fixtures.push({kind:'mail-delete',scenario,failed,updates});
  }
  const result = {checks,kind:'Actual original TS/TSX with isolated fake dependencies',network:false,
    sourcesSHA256:Object.fromEntries([actionFile,composeFile].map(file => [file,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex')])),fixtures};
  const output = path.join(__dirname,'build/native-mail-reference.json');
  fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n');
  console.log(JSON.stringify({checks,output}));
}
main().catch(error => {console.error(error); process.exitCode=1;});
