const fs=require('fs'),path=require('path'),crypto=require('crypto'),{simpleParser}=require('mailparser');const MailParser=require('mailparser').MailParser;const out=process.argv[2]||__dirname;
(async()=>{const inputs=[];
for(const type of ['mixed','related','alternative'])for(const plain of ['Plain','日本語 & < > " \' 😀','first\nsecond\n\nthird','See https://example.test/a?x=1&y=2 or a@example.com','www.example.com and example.com.',' NBSP ','https://example.test/日本語','foo@example.invalid','one\ttwo   \n three']){const raw=`Content-Type: multipart/${type}; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${plain}\r\n--x\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>HTML</p>\r\n--x--`;inputs.push({name:type+'-'+inputs.length,raw});}
for(const count of [199,200,201,999,1000,1001])inputs.push({name:'parts-'+count,raw:'Content-Type: multipart/mixed; boundary=x\r\n\r\n'+Array.from({length:count},(_,i)=>'--x\r\nContent-Type: text/plain\r\n\r\npart'+i+'\r\n').join('')+'--x--'});
for(const depth of [11,12,13,100]){let raw='Content-Type: text/plain\r\n\r\nleaf';for(let i=0;i<depth;i++)raw=`Content-Type: multipart/mixed; boundary=b${i}\r\n\r\n--b${i}\r\n${raw}\r\n--b${i}--`;inputs.push({name:'depth-'+depth,raw});}
for(const size of [262143,262144,262145]){const header='Subject: '+ 'x'.repeat(size-9);inputs.push({name:'header-'+size,raw:header+'\r\nContent-Type: text/plain\r\n\r\nbody'});}
for(const boundary of ['x'.repeat(69),'x'.repeat(70),'x'.repeat(71)])inputs.push({name:'boundary-'+boundary.length,raw:'Content-Type: multipart/mixed; boundary='+boundary+'\r\n\r\n--'+boundary+'\r\nContent-Type: text/plain\r\n\r\nkept\r\n--'+boundary+'--'});
inputs.push({name:'multiple-html',raw:'Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/html\r\n\r\n<p>one</p>\r\n--x\r\nContent-Type: text/html\r\n\r\n<p>two</p>\r\n--x--'});
inputs.push({name:'delivery-status',raw:'Content-Type: message/delivery-status\r\n\r\nStatus: 5.0.0'});
for(const size of [1048575,1048576,1048577])inputs.push({name:'source-header-bound-'+size,raw:'Subject: '+'x'.repeat(size-13)+'\r\n\r\nbody'});
for(const size of [262144,262145])inputs.push({name:'subject-field-'+size,raw:'Subject: '+'x'.repeat(size)+'\r\n\r\nbody'});
for(const [name,html,images] of [
 ['cid-one','<p><img src="cid:logo"></p>',[['logo','YQ==']]],
 ['cid-duplicate','<img src="cid:logo"><img src="cid:logo">',[['logo','YQ=='],['logo','Yg==']]],
 ['cid-missing','<img src="cid:missing">',[['other','YQ==']]],
 ['cid-empty','<img src="cid:logo">',[['logo','']]],
 ['cid-unpadded','<img src="cid:logo">',[['logo','YQ']]],
 ['cid-noise','<img src="cid:logo">',[['logo','Y!Q= =']]]
]){const raw='Content-Type: multipart/related; boundary=x\r\n\r\n--x\r\nContent-Type: text/html\r\n\r\n'+html+'\r\n'+images.map(([cid,data])=>'--x\r\nContent-Type: image/png\r\nContent-ID: <'+cid+'>\r\nContent-Transfer-Encoding: base64\r\n\r\n'+data+'\r\n').join('')+'--x--';inputs.push({name,raw});}
inputs.push({name:'mixed-equivalent-entities',raw:'Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n© é é 🦊\r\n--x\r\nContent-Type: text/html\r\n\r\n<p>HTML</p>\r\n--x--'});
const cases=[];for(const x of inputs){try{const p=await simpleParser(x.raw);cases.push({...x,text:p.text||null,html:p.html||null,subject:p.subject??null});}catch(e){cases.push({...x,error:e.message});}}
const sourceHashes=Object.fromEntries(Object.keys(require.cache).filter(p=>p.includes('/node_modules/')&&fs.statSync(p).isFile()).map(p=>[path.relative(process.cwd(),p),crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex')]));fs.writeFileSync(path.join(out,'reference.json'),JSON.stringify({cases,sourceHashes},null,2));console.log('Source structure cases: '+cases.length);})();
