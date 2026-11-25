const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const readline = require('node:readline');
const {Client} = require('@modelcontextprotocol/sdk/client/index.js');
const {StreamableHTTPClientTransport} = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
async function run(binary,args,shouldWork) {
 const child=spawn(binary,args,{stdio:['pipe','pipe','pipe']});
 const lines=[], readers=[]; let output='', ended=false;
 child.stderr.on('data',b=>output+=b);
 readline.createInterface({input:child.stdout}).on('line',line=>{const v=JSON.parse(line);readers.length?readers.shift()(v):lines.push(v)});
 const end=new Promise(resolve=>child.on('exit',code=>{ended=true;resolve(code)}));
 const next=()=>lines.length?Promise.resolve(lines.shift()):new Promise(resolve=>readers.push(resolve));
 const command=async text=>{child.stdin.write(text+'\n');return await next()};
 const client=new Client({name:'isolated minimum connection proof',version:'1'});
 let checks=0;
 try {
  const ready=await next(); assert.ok(ready.ready);checks++;
  const transport=new StreamableHTTPClientTransport(new URL(ready.ready),{requestInit:{headers:ready.bearer?{Authorization:ready.bearer}:{}},reconnectionOptions:{maxReconnectionDelay:50,initialReconnectionDelay:50,reconnectionDelayGrowFactor:1,maxRetries:0}});
  let failure;
  try {
   await client.connect(transport,{timeout:2000});
   let s;
   for(let i=0;i<100;i++){s=await command('stats');if(s.connections===1)break;await new Promise(r=>setTimeout(r,20));}
   assert.equal(s.connections,1,'SDK retains background GET stream');checks++;
   const list=await client.listTools(undefined,{timeout:2000});
   if(ready.tools)assert.equal(list.tools.length,ready.tools);
   const value=await client.callTool({name:ready.tool,arguments:{}},undefined,{timeout:2000});
   assert.notEqual(value.isError,true);checks+=2;
  } catch(e) { failure=e; }
  if(shouldWork)assert.equal(failure,undefined,'minimum two slots must support SDK GET + POST');
  else {assert.ok(failure,'one slot reproduces SDK failure');const s=await command('stats');if(!s.rejected)throw new Error('baseline reason: '+failure.message+' stats '+JSON.stringify(s));assert.ok(s.rejected>0);checks++;}
  checks++;
  await client.close(); const stopped=await command('quit');assert.equal(stopped.stopped,true);assert.equal(await end,0);checks+=2;
  return {maximum:ready.maximum,checks,outcome:shouldWork?'SDK list/call passed':'one-slot rejection reproduced'};
 } finally {await client.close().catch(()=>{});if(!ended)child.kill('SIGTERM');}
}
(async()=>{
 const args=process.argv.slice(2); const results=[];
 if(args[0]==='--runtime')results.push(await run(args[1],[args[2],'--sdk-runtime'],true));
 else {results.push(await run(args[0],['1'],false));results.push(await run(args[0],['2'],true));}
 console.log(JSON.stringify({sdkAdmission:results}));
})().catch(e=>{console.error('MCP SDK admission assertion failed: '+e.message);process.exitCode=1});
