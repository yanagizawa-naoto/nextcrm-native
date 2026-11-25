const fs=require('node:fs'),path=require('node:path'),{createSourceLoader}=require('./plugins-source-loader.cjs');
async function main(){
 const scenarios=[],sourceHashes={};
 for(const mode of ['chain','tie','allow-error','block-error','reject','self','disabled','other-entity','timeout-allow','timeout-block','depth']){
  const trace=[],logs=[],writer=mode==='self'?{type:'plugin',pluginId:'a-test'}:{type:'user',userId:'fixture-user',role:'user'},frame={actor:writer,depth:mode==='depth'?4:writer.type==='plugin'?1:0};
  const make=(id,priority)=>({definition:{id,extensions:{rules:[{entity:mode==='other-entity'?'contact':'account',operation:'beforeCreate',priority,onError:mode.endsWith('block')||mode==='block-error'?'block':'allow',handler:async({data})=>{
   trace.push(id);if(id==='a-test'){
    if(mode.includes('timeout'))await new Promise(resolve=>setTimeout(resolve,20));
    if(mode.endsWith('error'))throw Error('fixture rule error');
    if(mode==='reject')return {kind:'reject',messageKey:'blocked',params:{field:'name'}};
   }
   return {kind:'modify',patch:{description:(data.description??'')+id+';'}};
  }}],afters:[]}}});
  const definitions=[make('z-test',mode==='tie'?10:20),make('a-test',10)];
  const loader=createSourceLoader({'lib/plugins/actor.ts':{currentActorFrame:()=>frame},'lib/plugins/log.ts':{writePluginLog:(...args)=>logs.push(args)}});
  const source=loader.load('lib/plugins/rules.ts');let output;
  try{output={ok:true,value:await source.runBeforeRules({entity:'account',operation:'beforeCreate',data:{name:'Fixture'}},{getEnabledPlugins:async()=>mode==='disabled'?definitions.filter(x=>x.definition.id!=='a-test'):definitions,createPluginContext:async()=>({}),resolveActor:async()=>writer,timeoutMs:mode.includes('timeout')?1:500})}}catch(error){output={ok:false,error:error.messageKey?{pluginId:error.pluginId,messageKey:error.messageKey,params:error.params??null}:{message:error.message}}}
  scenarios.push({mode,trace,logs:logs.length,output});Object.assign(sourceHashes,loader.hashes);
 }
 fs.writeFileSync(path.join(__dirname,'build/plugins-rules-reference.json'),JSON.stringify({scenarios,sourceHashes}));console.log(JSON.stringify({scenarios:scenarios.length,sourceFiles:Object.keys(sourceHashes).length}));
}
main().catch(error=>{console.log(JSON.stringify({error:String(error)}));process.exit(1)});
