// Capture the installed, locked E2B SDK's real HTTP/Connect requests without a network.
const fs = require('node:fs');
const configNames = ['E2B_API_URL','E2B_SANDBOX_URL','E2B_ACCESS_TOKEN','E2B_DOMAIN','E2B_DEBUG','E2B_API_KEY'];
for (const name of configNames) delete process.env[name];
const frames = value => { const body = Buffer.from(JSON.stringify(value)); const header = Buffer.alloc(5); header.writeUInt32BE(body.length,1); return Buffer.concat([header,body]); };
const endStream = frames({}); endStream[0] = 2;
const output = {target:{industry:'情報通信'},contacts:[],confidence:{industry:0.8}};
const stdout = JSON.stringify(output), events = [{event:{start:{pid:123}}},{event:{data:{stdout:Buffer.from(stdout).toString('base64')}}},{event:{end:{exitCode:0}}}];
const requests = []; let version = '0.3.0', responseDomain = 'e2b.app', responseToken = 'qa-envd';
global.fetch = async (input, init) => {
  const req = new Request(input, init), url = new URL(req.url), headers = Object.fromEntries(req.headers), bytes = Buffer.from(await req.clone().arrayBuffer());
  const item = {url:req.url,method:req.method,headers}; requests.push(item);
  if (url.pathname.endsWith('/sandboxes') && req.method === 'POST') {
    item.json = JSON.parse(bytes.toString());
    return Response.json({sandboxID:'qa-sandbox',templateID:'nextcrm-enrichment',envdVersion:version,envdAccessToken:responseToken,domain:responseDomain});
  }
  if (url.pathname.endsWith('/files') && req.method === 'POST') {
    const form = await req.formData(), file = form.get('file'); item.file = {name:file.name,text:await file.text()};
    return Response.json([{name:'agent.mjs',path:'/home/user/agent.mjs',type:'file'}]);
  }
  if (url.pathname.endsWith('/Start') && req.method === 'POST') {
    item.frameFlags = bytes[0]; item.json = JSON.parse(bytes.subarray(5).toString());
    const data = Buffer.concat([...events.map(frames),endStream]);
    return new Response(new ReadableStream({start(c){ for (let i=0;i<data.length;i+=7) c.enqueue(data.subarray(i,i+7)); c.close(); }}),{headers:{'Content-Type':'application/connect+json'}});
  }
  if (url.pathname.endsWith('/sandboxes/qa-sandbox') && req.method === 'DELETE') return new Response(null,{status:204});
  throw Error('Unexpected fake E2B request');
};
const {Sandbox} = require('e2b');
async function main() {
  const cases = [];
  const specs = ['0.3.0','0.4.0'].flatMap(version => ['automatic','contact'].map(mode => ({name:`standard-${version}-${mode}`,version,mode,environment:{},domain:'e2b.app',token:'qa-envd'})));
  specs.push(
    {name:'custom-domain-port',environment:{E2B_DOMAIN:'corp.invalid:8443'},domain:'',token:'qa-envd'},
    {name:'absolute-domain',environment:{E2B_DOMAIN:'corp.invalid.'},domain:'',token:'qa-envd'},
    {name:'unicode-domain',environment:{E2B_DOMAIN:'例え.テスト'},domain:'',token:'qa-envd'},
    {name:'uppercase-url',environment:{E2B_API_URL:'HTTPS://CONTROL.EXAMPLE.INVALID/api',E2B_SANDBOX_URL:'HTTPS://WORKER.EXAMPLE.INVALID/engine'},domain:'unused.invalid',token:'qa-envd'},
    {name:'ipv6-http',environment:{E2B_API_URL:'http://[::1]:3100/api',E2B_SANDBOX_URL:'http://[::1]:49980/engine'},domain:'unused.invalid',token:'qa-envd'},
    {name:'response-domain',environment:{E2B_DOMAIN:'corp.invalid'},domain:'edge.invalid',token:'qa-envd'},
    {name:'custom-url-prefix-bearer',environment:{E2B_API_URL:'https://control.example.invalid/gateway/v1/',E2B_SANDBOX_URL:'https://worker.example.invalid/proxy/',E2B_ACCESS_TOKEN:'qa-access'},domain:'unused.invalid',token:'qa-envd'},
    {name:'explicit-http',version:'0.3.0',mode:'contact',environment:{E2B_API_URL:'http://localhost:3100/api',E2B_SANDBOX_URL:'http://127.0.0.1:49980/engine'},domain:'unused.invalid',token:'qa-envd'},
    {name:'debug',environment:{E2B_DEBUG:'TrUe'},domain:'unused.invalid',token:null},
    {name:'debug-custom-url',mode:'contact',environment:{E2B_DEBUG:'true',E2B_API_URL:'http://localhost:3100/control',E2B_SANDBOX_URL:'http://localhost:45000/custom'},domain:'unused.invalid',token:null},
    {name:'legacy-no-envd-token',version:'0.3.0',environment:{},domain:'e2b.app',token:null}
  );
  for (const spec of specs) {
    for (const name of configNames) delete process.env[name];
    Object.assign(process.env,spec.environment);
    version = spec.version || '0.4.0'; const mode = spec.mode || 'automatic'; responseDomain = spec.domain; responseToken = spec.token;
    requests.length = 0;
    const sandbox = await Sandbox.create('nextcrm-enrichment',{apiKey:'qa-e2b',timeoutMs:300000});
    await sandbox.files.write('/home/user/agent.mjs','// 日本語の検証用スクリプト\n');
    const envs = {ANTHROPIC_API_KEY:'qa-anthropic',COMPANY_NAME:'試験株式会社',COMPANY_WEBSITE:'https://example.invalid',TARGET_EMAIL:'qa@example.invalid',TARGET_NAME:'山田 太郎',KNOWN_DOMAIN:'example.invalid'};
    const result = await sandbox.commands.run('node /home/user/agent.mjs',{envs,...(mode==='automatic'?{timeoutMs:0}:{})});
    await sandbox.kill();
    if (result.stdout !== stdout || result.exitCode !== 0) throw Error('Unexpected SDK command result');
    cases.push({name:spec.name,version,mode,environment:spec.environment,sandbox:{sandboxID:'qa-sandbox',envdVersion:version,envdAccessToken:responseToken,domain:responseDomain},requests:JSON.parse(JSON.stringify(requests)),result});
  }
  fs.writeFileSync(process.argv[2],JSON.stringify({sdkVersion:'2.18.0',cases,events,output,streamBase64:Buffer.concat([...events.map(frames),endStream]).toString('base64')},null,2)+'\n');
  console.log(`E2B SDK: ${cases.length} captured create/write/run/kill flows; no network`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
