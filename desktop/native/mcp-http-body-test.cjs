const assert = require('node:assert/strict'), http = require('node:http'), net = require('node:net'), crypto = require('node:crypto');
const {spawn} = require('node:child_process'), readline = require('node:readline');
const child = spawn(process.argv[2], [], {stdio:['pipe','pipe','pipe']});
let stderr='', ended=false, checks=0; const waiting=[], lines=[];
child.stderr.on('data',x=>stderr+=x);
readline.createInterface({input:child.stdout}).on('line',line=>{const value=JSON.parse(line); if(waiting.length)waiting.shift().resolve(value);else lines.push(value);});
const exited=new Promise(resolve=>child.on('exit',(code,signal)=>{ended=true;for(const reader of waiting.splice(0))reader.reject(Error(`fixture exit ${code}/${signal}: ${stderr}`));resolve({code,signal});}));
function next(){return lines.length?Promise.resolve(lines.shift()):new Promise((resolve,reject)=>waiting.push({resolve,reject}));}
async function command(value){child.stdin.write(value+'\n');return next();}
function equal(actual,expected,label){assert.deepEqual(actual,expected,label);checks++;}
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label){const end=Date.now()+5000;while(Date.now()<end){const status=await command('stats');if(test(status)){checks++;return status;}await sleep(25);}throw Error(label);}
let base;
function request(path,{method='GET',headers={},blocks=[]}={}){
  return new Promise((resolve,reject)=>{
    const req=http.request(new URL(path,base),{method,headers,agent:false},res=>{
      const hash=crypto.createHash('sha256');let bytes=0,body='';
      res.on('data',data=>{bytes+=data.length;hash.update(data);if(path.startsWith('/upload'))body+=data.toString();});
      res.on('aborted',()=>reject(Error('response aborted')));res.on('error',reject);
      res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,bytes,sha256:hash.digest('hex'),body}));
    });req.on('error',reject);
    (async()=>{for(const block of blocks){if(!req.write(block))await new Promise((resolve,reject)=>{const drain=()=>{req.off('error',failed);resolve();};const failed=error=>{req.off('drain',drain);reject(error);};req.once('drain',drain);req.once('error',failed);});}req.end();})().catch(reject);
  });
}
async function rawRequest(text){return new Promise((resolve,reject)=>{const socket=net.connect({host:base.hostname,port:Number(base.port)});let result='';socket.on('connect',()=>socket.end(text));socket.on('data',x=>result+=x.toString());socket.on('error',reject);socket.on('end',()=>resolve(result));});}
async function run(){
  const ready=await next();assert.ok(ready.ready);base=new URL(ready.ready);
  equal((await request('/upload',{method:'PUT',headers:{'content-length':'1000000000'}})).status,403,'unauthorized upload rejected before body');
  equal((await command('stats')).bodies.opened,0,'no consumer created before authorization');
  const empty=await request('/upload?key=empty',{method:'PUT',headers:{'content-length':'0','x-fixture-allowed':'yes'}});
  equal(empty.status,200,'empty PUT');equal(JSON.parse(empty.body).sha256,crypto.createHash('sha256').digest('hex'),'empty hash');
  const block=Buffer.alloc(16384);for(let i=0;i<block.length;i++)block[i]=i%256;
  const pieces=641, digest=crypto.createHash('sha256');for(let i=0;i<pieces;i++)digest.update(block);const expected=digest.digest('hex');
  for(const chunked of [false,true]){
    const headers={'x-fixture-allowed':'yes','content-type':'application/octet-stream'};if(!chunked)headers['content-length']=String(block.length*pieces);
    const result=await request('/upload?key=a%2Fb%2B%26&signed=exact',{method:'PUT',headers,blocks:Array(pieces).fill(block)});
    equal(result.status,200,'large streamed PUT '+chunked);const object=JSON.parse(result.body);
    equal(object.bytes,block.length*pieces,'upload byte count');equal(object.sha256,expected,'upload content preserved');equal(object.target,'/upload?key=a%2Fb%2B%26&signed=exact','query preserved through live TCP');
  }
  let status=await until(s=>s.bodies.active===0&&s.server.retained===0,'upload cleanup retained resources');
  equal(status.bodies.completed,3,'only successful uploads published');equal(status.bodies.largestAppend<=16384,true,'append chunk memory bound');
  const count=9*1024*1024+17, reference=crypto.createHash('sha256');for(let left=count;left>0;left-=Math.min(left,block.length))reference.update(block.subarray(0,Math.min(left,block.length)));const downloadHash=reference.digest('hex');
  for(const path of ['/bytes','/bytes-chunked']){
    const result=await request(path);equal(result.status,200,'binary GET status');equal(result.bytes,count,'no SSE heartbeat bytes in binary response');equal(result.sha256,downloadHash,'all binary bytes preserved');
    equal(result.headers['content-type'],'application/octet-stream','binary content type');
    if(path==='/bytes')equal(result.headers['content-length'],String(count),'known exact length');else equal(result.headers['transfer-encoding'],'chunked','unknown length framed without whole-body buffering');
  }
  const metadata=await request('/bytes',{method:'HEAD'});equal(metadata.bytes,0,'HEAD has no binary body or stream framing');equal(metadata.headers['content-length'],String(count),'HEAD preserves representation length');
  for(const path of ['/bytes-short','/bytes-extra']){let rejected=false;try{await request(path);}catch{rejected=true;}equal(rejected,true,'invalid binary producer length terminates response '+path);}
  const before=(await command('stats')).bodies;
  const truncated=await rawRequest(`PUT /upload HTTP/1.1\r\nHost: ${base.host}\r\nX-Fixture-Allowed: yes\r\nContent-Length: 5\r\n\r\nabc`);
  equal(truncated.startsWith('HTTP/1.1 400 '),true,'truncated PUT rejected');
  status=await until(s=>s.bodies.active===0&&s.server.retained===0,'truncated upload not cleaned');equal(status.bodies.completed,before.completed,'truncated input not published');
  const held=net.connect({host:base.hostname,port:Number(base.port)});held.on('error',()=>{});await new Promise(resolve=>held.on('connect',resolve));
  held.write(`PUT /upload HTTP/1.1\r\nHost: ${base.host}\r\nX-Fixture-Allowed: yes\r\nX-Fixture-Hold: yes\r\nContent-Length: 10\r\n\r\nx`);
  await until(s=>s.bodies.active===1&&s.server.running===1,'blocking consumer never started');
  equal((await request('/stats')).status,200,'disk consumer cannot block other sockets');
  await sleep(800);held.destroy();
  status=await command('stats');equal(status.server.retained,1,'cancelled noncooperative append retains admission slot');equal(status.bodies.completed,before.completed,'blocked cancelled upload not published');
  equal((await command('release')).released,true,'release blocked test consumer');
  status=await until(s=>s.server.retained===0&&s.bodies.active===0,'cancelled append not released');equal(status.bodies.completed,before.completed,'append cancellation prevents finish');
  equal(status.server.peakWrites<=2,true,'bounded response write queue');
  equal((await command('quit')).stopped,true,'server shutdown');equal(await exited,{code:0,signal:null},'clean child exit');equal(stderr,'','no fixture errors');
  console.log(JSON.stringify({checks,scope:'Actual native TCP fixed/chunked uploads over10MiB, raw downloads over9MiB, exact binary contents and length enforcement, authentication before body, backpressure, cancellation cleanup and bounded admission. Synthetic consumers; real document storage integration tested separately.'}));
}
const timeout=setTimeout(()=>child.kill('SIGTERM'),60000);
run().catch(error=>{console.error(`After ${checks} checks: ${error.stack}`);process.exitCode=1;}).finally(async()=>{clearTimeout(timeout);if(!ended){child.stdin.write('release\n');child.stdin.end();const timer=setTimeout(()=>child.kill('SIGTERM'),1000);await exited;clearTimeout(timer);}});
