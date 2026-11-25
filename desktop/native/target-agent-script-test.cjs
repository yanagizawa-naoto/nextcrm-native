const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'NextCRM-target-agent-'));
try {
  const script=fs.readFileSync(process.argv[2],'utf8'), sdk=path.join(root,'node_modules/@anthropic-ai/sdk'); fs.mkdirSync(sdk,{recursive:true});
  fs.writeFileSync(path.join(root,'agent.mjs'),script);
  fs.writeFileSync(path.join(sdk,'package.json'),JSON.stringify({name:'@anthropic-ai/sdk',type:'module',exports:'./index.mjs'}));
  fs.writeFileSync(path.join(sdk,'index.mjs'),`import fs from 'node:fs'; let calls=0; export default class Anthropic { messages={create:async request=>{fs.appendFileSync(process.env.QA_REQUESTS,JSON.stringify(request)+'\\n'); if(process.env.QA_FAIL) throw Object.assign(new Error('secret-must-not-be-logged'),{status:401}); if(calls++===0) return {stop_reason:'tool_use',content:[{type:'tool_use',id:'tool1',name:'browser_open',input:{url:process.env.QA_TOOL_URL}}]}; return {stop_reason:'end_turn',content:[{type:'text',text:JSON.stringify({target:{position:'営業部長'},contacts:[],confidence:{position:.9}})}]};}}; }`);
  const bin=path.join(root,'bin'); fs.mkdirSync(bin); const browser=path.join(bin,'agent-browser');
  fs.writeFileSync(browser,"#!/usr/bin/env node\nrequire('node:fs').appendFileSync(process.env.QA_ARGV,JSON.stringify(process.argv.slice(2))+'\\n'); process.stdout.write('公開情報');\n"); fs.chmodSync(browser,0o700);
  const marker=path.join(root,'must-not-exist'), malicious='https://example.invalid/$(touch '+marker+')?x=`touch '+marker+'`';
  const env={...process.env,PATH:bin+path.delimiter+process.env.PATH,ANTHROPIC_API_KEY:'qa-anthropic',COMPANY_NAME:'会社 ${process.exit(77)} `name`',TARGET_NAME:'山田 太郎',QA_TOOL_URL:malicious,QA_REQUESTS:path.join(root,'requests'),QA_ARGV:path.join(root,'argv'),NEXTCRM_ENRICHMENT_FIELDS:JSON.stringify([{name:'position',displayName:'役職',description:'本人の役職',type:'string',required:false}])};
  delete env.QA_FAIL;
  const run=cp.spawnSync(process.execPath,[path.join(root,'agent.mjs')],{env,encoding:'utf8',timeout:10000});
  if(run.status!==0 || JSON.parse(run.stdout).target.position!=='営業部長') throw Error('Agent result failed: '+run.stderr);
  const calls=fs.readFileSync(env.QA_REQUESTS,'utf8').trim().split('\n').map(JSON.parse), argv=JSON.parse(fs.readFileSync(env.QA_ARGV,'utf8').trim());
  if(fs.existsSync(marker) || argv.at(-1)!==malicious || argv[0]!=='--ignore-https-errors') throw Error('Unsafe browser argv');
  if(calls.length!==2 || calls[0].model!=='claude-sonnet-4-6' || calls[0].max_tokens!==4096 || calls[0].tools.length!==5 || !calls[0].system.includes('requested target fields') || !calls[0].system.includes('本人の役職') || !calls[0].system.includes(env.COMPANY_NAME)) throw Error('Original agent or selection lost');
  if(!run.stderr.includes('@@NEXTCRM_PROGRESS@@')) throw Error('Progress missing');
  const failure=cp.spawnSync(process.execPath,[path.join(root,'agent.mjs')],{env:{...env,QA_FAIL:'1'},encoding:'utf8',timeout:10000});
  if(failure.status!==1 || failure.stderr.includes('secret-must-not-be-logged') || !failure.stderr.includes('"status":401')) throw Error('Unsanitized agent error');
  const fileURL=cp.spawnSync(process.execPath,[path.join(root,'agent.mjs')],{env:{...env,QA_TOOL_URL:'file:///etc/passwd'},encoding:'utf8',timeout:10000});
  const last=fs.readFileSync(env.QA_REQUESTS,'utf8').trim().split('\n').map(JSON.parse).at(-1);
  if(fileURL.status!==0 || fs.readFileSync(env.QA_ARGV,'utf8').trim().split('\n').length!==1 || !JSON.stringify(last).includes('Only HTTP(S)')) throw Error('Local-file navigation was not blocked');
  console.log('Native remote agent: original tools/model/limits, selected fields, Japanese result/progress, literal argv and sanitized errors passed');
} finally { fs.rmSync(root,{recursive:true,force:true}); }
