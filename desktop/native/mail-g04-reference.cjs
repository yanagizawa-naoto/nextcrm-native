const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=path.resolve(__dirname,'../..');
const output=path.resolve(process.argv[2]);
const {createSourceLoader}=require('./plugins-source-loader.cjs');
const {simpleParser}=require('mailparser'),nodemailer=require('nodemailer');
const SMTP=require('nodemailer/lib/smtp-connection');
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
(async()=>{
 const mime=[];
 function add(name,raw){mime.push({name,raw});}
 add('plain','Content-Type: text/plain; charset=utf-8\r\n\r\n本文');
 add('body_only','本文だけ');add('empty','');add('header_only','Subject: test\r\n');
 add('empty_separator','\r\n本文');add('bare_lf','Content-Type: text/plain\n\nbody');
 const multi=close=>'Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\nfirst\r\n--x\r\nContent-Type: text/plain\r\n\r\nsecond'+(close?'\r\n--x--\r\n':'');
 add('multipart_closed',multi(true));add('multipart_truncated',multi(false));add('multipart_no_boundary','Content-Type: multipart/mixed; boundary=x\r\n\r\npreamble');add('multipart_empty','Content-Type: multipart/mixed; boundary=x\r\n\r\n--x--\r\n');
 for(const [name,body] of [['base64_valid','SGk='],['base64_unpadded','SGk'],['base64_noise','S!Gk='],['base64_invalid','%%%'],['base64_short','S'],['base64_extra','SGk===']])add(name,'Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n'+body);
 for(const body of ['a=2Gb','a=','a=0D=0Ab','a=\r\nb'])add('qp_'+Buffer.from(body).toString('hex'),'Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n'+body);
 add('unknown_transfer','Content-Type: text/plain\r\nContent-Transfer-Encoding: nonsense\r\n\r\ntext');
 add('unknown_charset','Content-Type: text/plain; charset=made-up\r\n\r\n日本語');
 add('invalid_utf8','Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n/0E=');
 for(const [name,raw] of [
 ['base64_urlsafe','Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n_0E='],
 ['qp_shorthex','Content-Transfer-Encoding: quoted-printable\r\n\r\nabc=A'],
 ['qp_trailingws','Content-Transfer-Encoding: quoted-printable\r\n\r\na= \r\nb'],
 ['plain_crlf','Content-Type: text/plain\r\n\r\none\r\ntwo\rthree'],
 ['html_crlf','Content-Type: text/html\r\n\r\n<p>one</p>\r\n<p>two</p>'],
 ['zero_text','Content-Type: text/plain\r\n\r\n'],
 ['zero_html','Content-Type: text/html\r\n\r\n'],
 ['multipart_partial','Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\n\r\ntext'],
 ['multipart_empty_last','Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\nfirst\r\n--x\r\n'],
 ['utf8_bad_sequence','Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n4oJB'],
 ])add(name,raw);
 for(const c of mime){try{let p=await simpleParser(Buffer.from(c.raw));c.source={text:p.text??null,html:p.html||null};}catch(e){c.source={error:String(e.message)}}}
 const smtp=[];
 for(const [name,from,to,reply] of [['ascii','a@example.com','b@example.com','<ascii@example.com>'],['header_only_utf8','a@example.com','b@example.com','<日本@example.com>'],['envelope_utf8','日本@example.com','b@example.com','<ascii@example.com>']]){
  let c=new SMTP({});c._supportedExtensions=['SMTPUTF8'];c._sendCommand=s=>smtp.push({name,command:s});c._setEnvelope({from,to:[to]},()=>{});
  const info=await nodemailer.createTransport({streamTransport:true,buffer:true}).sendMail({from,to,subject:'日本語',text:'body',inReplyTo:reply});
  smtp.at(-1).rawHeaderUTF8=info.message.subarray(0,info.message.indexOf('\r\n\r\n')).some(v=>v>127);
 }
 const emitted=[];let persisted;
 const loader=createSourceLoader({'@/lib/auth-server':{getSession:async()=>({user:{id:'actor'}})},'@/lib/prisma':{prismadb:{emailAccount:{findFirst:async()=>({username:'a@example.com',smtpHost:'example.com',smtpPort:587,passwordEncrypted:'synthetic'})},email:{create:async x=>{persisted=x.data;return x.data}}}},'@/lib/email-crypto':{decrypt:()=> 'synthetic'},'@/lib/net/host-guard':{assertPublicHost:async()=>({address:'192.0.2.1',hostname:'example.com'}),HostNotAllowedError:class extends Error{}},nodemailer:{createTransport:()=>({sendMail:async x=>{emitted.push(x);return {messageId:'<synthetic@example.com>'}}})},'@/lib/crm/calendar/calendly-settings':{getCalendlySettings:async()=>({signingKey:'synthetic'})},'@/inngest/client':{inngest:{send:async x=>{emitted.push(x)}}},'next/server':{NextResponse:{json:(body,options)=>({body,status:options?.status??200})}}});
 const send=loader.load('actions/emails/messages.ts').sendEmail;
 const recipients=[];
 for(const n of [3000,4000,5000,5035,5036,6000]){let to=Array.from({length:n},(_,i)=>`r${String(i).padStart(5,'0')}@example.com`);await send({accountId:'a',to,subject:'s',body:'body'});recipients.push({count:n,accepted:persisted.toRecipients.length===n,storedBytes:Buffer.byteLength(JSON.stringify(persisted.toRecipients))});}
 const normalize=loader.load('lib/crm/calendar/google-normalize.ts').normalizeGoogleEvent;
 const calendly=loader.load('app/api/crm/calendar/webhooks/calendly/route.ts').POST;
 const calendar=[];
 function padded(base,n){base.padding='';let s=JSON.stringify(base);base.padding='x'.repeat(n-Buffer.byteLength(s));return JSON.stringify(base)}
 const stamp=Math.floor(Date.now()/1000);
 for(const bytes of [1048575,1048576,1048577]){
  let google=padded({id:'g',summary:'Meeting',start:{dateTime:'2026-01-01T00:00:00Z'},attendees:[{email:'outside@example.net'}]},bytes);
  let calendlyBody=padded({event:'invitee.created',payload:{uri:'c',email:'outside@example.net',scheduled_event:{name:'Meeting',start_time:'2026-01-01T00:00:00Z'}}},bytes);
  let signature=`t=${stamp},v1=${crypto.createHmac('sha256','synthetic').update(stamp+'.'+calendlyBody).digest('hex')}`;
  const before=emitted.length;let response=await calendly({text:async()=>calendlyBody,headers:{get:()=>signature}});
  calendar.push({bytes,googleAccepted:normalize(JSON.parse(google),{connectionId:'c',accountEmail:'self@example.com'}).externalId==='g',calendlyAccepted:response.status===200&&emitted.length===before+1,googleSHA256:hash(google),calendlySHA256:hash(calendlyBody)});
 }
 const legacy=[];
 const legacyLoader=createSourceLoader({'@/inngest/client':{inngest:{createFunction:(_a,fn)=>fn}},'@/lib/prisma':{prismadb:{email:{findUnique:async()=>({fromEmail:legacy.at(-1).stored,toRecipients:[],ccRecipients:[],imapUid:null})},crm_Contacts:{findMany:async q=>q.where.email.in.includes('person@bücher.de')?[{id:'contact'}]:[]},crm_Accounts:{findMany:async()=>[]},emailsToContacts:{createMany:async()=>{}},emailsToAccounts:{createMany:async()=>{}}}},'@/lib/email-crypto':{decrypt:()=>''},'@/inngest/lib/imap-utils':{fetchBodyByUid:async()=>{throw Error('unexpected external')}}});
 const link=legacyLoader.load('inngest/functions/emails/link-crm.ts').emailLinkCrm;
 for(const stored of ['person@xn--bcher-kva.de','person@bücher.de']){legacy.push({stored});legacy.at(-1).source=await link({event:{data:{emailId:'mail'}},step:{run:(_n,fn)=>fn(),sendEvent:async()=>{throw Error('unexpected event')}}});}
 const bounds=[];
 for(const bytes of [262143,262144,262145]){let raw='X-Test: '+'x'.repeat(bytes-8)+'\r\n\r\nbody';let parsed=await simpleParser(Buffer.from(raw));bounds.push({kind:'header',bytes,sourceText:parsed.text});}
 for(const count of [199,200,201]){let raw='Content-Type: multipart/mixed; boundary=x\r\n\r\n'+Array.from({length:count},()=> '--x\r\nContent-Type: text/plain\r\n\r\na\r\n').join('')+'--x--\r\n';let p=await simpleParser(Buffer.from(raw));bounds.push({kind:'parts',count,sourceTextBytes:Buffer.byteLength(p.text??'')});}
 for(const depth of [11,12,13]){let raw='Content-Type: text/plain\r\n\r\nx';for(let i=0;i<depth;i++)raw=`Content-Type: multipart/mixed; boundary=b${i}\r\n\r\n--b${i}\r\n${raw}\r\n--b${i}--\r\n`;let p=await simpleParser(Buffer.from(raw));bounds.push({kind:'depth',depth,sourceText:p.text});}
 const watched=['inngest/lib/imap-utils.ts' ,'desktop/native/NativeMailTransport.c'];
 let sourceHashes={...loader.hashes,...legacyLoader.hashes};for(const f of watched)sourceHashes[f]=hash(fs.readFileSync(path.join(root,f)));
 for(const p of [require.resolve('mailparser'),require.resolve('nodemailer'),require.resolve('nodemailer/lib/smtp-connection')])sourceHashes[path.relative(root,p)]=hash(fs.readFileSync(p));
 fs.writeFileSync(path.join(output,'source-reference.json'),JSON.stringify({mime,smtp,recipients,calendar,legacy,bounds,sourceHashes,networkCalls:0},null,2));console.log(JSON.stringify({mime:mime.length,smtp,recipients,calendar:calendar.map(({bytes,googleAccepted,calendlyAccepted})=>({bytes,googleAccepted,calendlyAccepted}))}));
})().catch(e=>{console.error(e);process.exit(1)});
