const fs=require('node:fs'),path=require('node:path'),{load,hashes}=require('./odoo-reference.cjs');
const {jsonClient,testConnection}=load('plugins/odoo-connector/odoo.ts'),cases=[];
const {PluginStoreError,PluginRuleError}=load('lib/plugins/errors.ts');
const settings={url:'https://odoo.example.invalid///',database:'fixture-db'},secrets={apiKey:'fake-fixture-key'};
async function add(input){let calls=[],sleeps=[],store={'meta:sendPaused':{reason:'fixture'}},i=0;
 const ctx={settings,secrets,http:{fetch:async(url,init)=>{calls.push({url,method:init.method,headers:Object.fromEntries(Object.entries(init.headers).map(([k,v])=>[k.toLowerCase(),v])),body:JSON.parse(init.body),timeoutMs:init.timeoutMs});const p=input.plan[Math.min(i++,input.plan.length-1)];if(p.error){if(p.kind==='store')throw new PluginStoreError(p.error);if(p.kind==='rule')throw new PluginRuleError('fixture','blocked',undefined,p.error);throw Error(p.error);}return new Response(p.raw??JSON.stringify(p.json??{}),{status:p.status??200,statusText:p.statusText??''});}},store:{delete:async k=>delete store[k]},t:(k,p)=>k+':'+JSON.stringify(p)};
 const client=jsonClient(ctx,async ms=>{sleeps.push(ms)});let result;
 try{result={ok:true,value:input.operation==='version'?await client.version():input.operation==='connection'?await testConnection(ctx,client):await client.call(input.model??'res.partner',input.method??'search_read',input.body??{},input.once?{once:true}:{})};}
 catch(e){result={ok:false,error:{name:e.name,message:e.message,status:e.status}};}
 cases.push({input,result,calls,sleeps,store});
}
(async()=>{
for(const once of [false,true])for(const plan of [[{json:[{id:1,name:'日本語'}]}],[{raw:'invalid JSON'}],[{json:null,raw:'null'}],[{error:'ECONNRESET'}],[{error:'timeout'},{json:[]}],[{status:500},{status:502},{json:[]}],[{status:503}],[{status:401,json:{message:'private provider text'}}],[{status:403,json:{message:'No right'}},{json:[]}],[{status:403,raw:'bad',statusText:'Forbidden'}],[{status:422,json:{message:'Invalid field'}},{json:[]}],[{status:429,json:{message:'Retry later'}}],[{status:404}],[{status:302,statusText:'Moved'}]])await add({once,plan,body:{domain:[],fields:['id','名前']}});
for(const kind of ['store','rule'])for(const once of [false,true])await add({once,plan:[{kind,error:'fixture failure'}]});
for(const plan of [[{json:{result:{server_version:'19.0+e'}}}],[{json:{}}],[{raw:'null'}],[{status:502},{json:{result:{server_version:'18.0'}}}]])await add({operation:'version',plan});
await add({operation:'connection',plan:[{json:{uid:7}},{json:[{name:'API利用者'}]},{json:{result:{server_version:'19.0'}}}]});
await add({operation:'connection',plan:[{json:{}},{json:{result:{server_version:'19.0'}}}]});
await add({operation:'connection',plan:[{json:{uid:7}},{status:403,json:{message:'No user access'}}]});
fs.writeFileSync(process.argv[2]??path.join(__dirname,'build/odoo-http-reference.json'),JSON.stringify({settings,secrets,cases,sourceSHA256:hashes},null,2)+'\n');console.log(JSON.stringify({cases:cases.length,sourceFiles:Object.keys(hashes).length}));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
