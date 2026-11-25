// Test-only: actual installed mailparser plus actual original CRM link function.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), crypto = require('node:crypto');
const ts = require('typescript'), { simpleParser } = require('mailparser'), { createRequire } = require('node:module');
const root = path.resolve(__dirname, '../..');
const src = 'inngest/functions/emails/link-crm.ts';
const code = ts.transpileModule(fs.readFileSync(path.join(root, src),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const specimens = [
  ['ascii', 'User@EXAMPLE.test'], ['japanese-domain', 'user@xn--r8jz45g.xn--zckzah'],
  ['japanese-local', '担当者@xn--r8jz45g.xn--zckzah'], ['unicode-domain', '担当者@例え.テスト'],
  ['unicode-ascii-case', 'USER@xn--r8jz45g.EXAMPLE'], ['german', 'person@xn--bcher-kva.example'],
  ['sharp-s', 'person@xn--fa-hia.de'], ['emoji', 'person@xn--e28h.test'],
  ['cyrillic', 'person@xn--e1afmkfd.xn--p1ai'], ['accented', 'person@xn--caf-dma.example'],
  ['upper-prefix-stays', 'person@XN--BCHER-KVA.example'], ['upper-later-prefix-stays', 'person@xn--r8jz45g.XN--ZCKZAH'],
  ['ascii-first-label-stays', 'person@sub.xn--bcher-kva.example'],
  ['quoted-local', '"a b"@xn--bcher-kva.example'], ['unicode-local-nfd', 'e\u0301@xn--bcher-kva.example']
];
(async()=>{
  const cases=[];
  for(const [name,input] of specimens){
    const raw=`From: 営業 <${input}>\r\nTo: ${input}\r\nCc: ${input}\r\nBcc: secret@xn--r8jz45g.xn--zckzah\r\nSubject: IDN\r\n\r\n`;
    const parsed=await simpleParser(raw), expected=parsed.from.value[0].address;
    const email={fromEmail:expected,toRecipients:parsed.to.value.map(r=>({email:r.address})),ccRecipients:parsed.cc.value.map(r=>({email:r.address})),imapUid:null,folder:'INBOX',emailAccountId:'mail-account'};
    const targets=[{id:'matching',email:expected.toLowerCase()},{id:'bcc-only',email:'secret@例え.テスト'}];
    let contacts=[],accounts=[],queries=[];
    const prisma={email:{findUnique:async()=>email},crm_Contacts:{findMany:async({where})=>{queries.push(where);return targets.filter(x=>where.email.in.includes(x.email)).map(({id})=>({id}))}},crm_Accounts:{findMany:async({where})=>targets.filter(x=>where.email.in.includes(x.email)).map(({id})=>({id}))},emailsToContacts:{createMany:async({data})=>{contacts=data}},emailsToAccounts:{createMany:async({data})=>{accounts=data}}};
    const exports={};
    vm.runInNewContext(code,{exports,require:n=>{
      if(n==='@/inngest/client')return{inngest:{createFunction:(_options,fn)=>fn}};
      if(n==='@/lib/prisma')return{prismadb:prisma};
      if(n==='@/lib/email-crypto')return{decrypt:()=>{throw Error('unexpected secrets')}};
      if(n==='@/inngest/lib/imap-utils')return{fetchBodyByUid:()=>{throw Error('unexpected provider')}};
      throw Error(n);
    },console},{filename:src});
    const result=await exports.emailLinkCrm({event:{data:{emailId:'email'}},step:{run:async(_n,fn)=>fn(),sendEvent:()=>{throw Error('unexpected embed')}}});
    cases.push({name,input,raw,expected,expectedFromName:parsed.from.value[0].name,crmAddress:expected.toLowerCase(),linked:result.linked,contacts:contacts.map(x=>x.contactId),accounts:accounts.map(x=>x.accountId)});
  }
  const parser=require.resolve('mailparser'),req=createRequire(parser),puny=req.resolve('punycode.js');
  const files=[__filename,path.join(root,src),path.join(root,'inngest/lib/imap-utils.ts'),parser,path.join(path.dirname(parser),'lib/mail-parser.js'),puny];
  fs.writeFileSync(process.argv[2],JSON.stringify({sourceHashes:Object.fromEntries(files.map(p=>[p,hash(p)])),cases,scope:'Actual mailparser and actual TS link handler; exact-string synthetic Prisma query adapter, no PostgreSQL, no external mail/provider'},null,2)+'\n');
  console.log(JSON.stringify({cases:cases.length}));
})().catch(e=>{console.error(e);process.exitCode=1});
