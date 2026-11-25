const fs=require('node:fs'),path=require('node:path');
const {createSourceLoader}=require('./plugins-source-loader.cjs');
async function main(){
 const scenarios=[],sourceHashes={};
 for(const kind of ['cron','event','after','install'])for(const mode of ['enabled','disabled','failure',...(kind==='event'?['self']:[])]){
  const trace=[],logs=[],audit=[];let status=mode==='disabled'?'DISABLED':'ENABLED',actor;
  const handler=label=>async(ctx)=>{trace.push({label,actor:actor??null,contextActor:ctx.actor});if(mode==='failure')throw Error('fixture failure')};
  const definition={id:'runtime-test',extensions:{crons:[{id:'tick',schedule:'*/5 * * * *',handler:handler('cron')}],events:[{event:'crm/order.saved',handler:(_data,ctx)=>handler('event')(ctx)}],afters:[{entity:'account',operation:'created',handler:(_data,ctx)=>handler('after1')(ctx)},{entity:'account',operation:'updated',handler:(_data,ctx)=>handler('ignored')(ctx)},{entity:'account',operation:'created',handler:(_data,ctx)=>handler('after2')(ctx)}]},onInstall:handler('install')},plugin={definition};
  const loader=createSourceLoader({
   '@/inngest/client':{inngest:{createFunction:(options,handler)=>({options,handler})}},
   '@/lib/prisma-base':{prismaBase:{installedPlugin:{updateMany:async({data})=>{status=data.status;return {count:1}}},pluginLog:{deleteMany:async()=>({count:0})}}},
   '@/lib/audit-log':{writeAuditLog:async input=>audit.push(input.action)},
   'lib/plugins/registry.ts':{getRegistry:()=>[plugin],findPlugin:()=>plugin},
   'lib/plugins/state.ts':{getPluginState:async()=>({status}),invalidatePluginCache:()=>{}},
   'lib/plugins/context.ts':{createPluginContext:async({actor})=>({actor,log:{error:message=>logs.push(message)}})},
   'lib/plugins/actor.ts':{runAsActor:async(a,body)=>{actor=a;try{return await body()}finally{actor=undefined}}},
   'lib/plugins/log.ts':{writePluginLog:(_id,_level,message)=>logs.push(message)},
  });
  const source=loader.load('lib/plugins/inngest.ts'),fns=source.buildPluginFunctions([plugin]);
  const fn=kind==='install'?source.pluginInstallFunction:fns[{cron:0,event:1,after:2}[kind]];
  let failed=false;try{await fn.handler({event:{data:{pluginId:'runtime-test',entity:'account',operation:'created',recordId:'fixture',source:mode==='self'?'runtime-test':'other'}}})}catch{failed=true}
  scenarios.push({kind,mode,retries:fn.options.retries,trace,status,audit,logCount:logs.length,failed});Object.assign(sourceHashes,loader.hashes);
 }
 const out={scenarios,sourceHashes,scope:'Actual lib/plugins/inngest.ts callback registration and handlers; injected Inngest/context/state/persistence boundaries. Scheduling engine retry delays are a native choice.'};
 fs.writeFileSync(path.join(__dirname,'build/plugins-runtime-reference.json'),JSON.stringify(out));console.log(JSON.stringify({scenarios:scenarios.length,sourceFiles:Object.keys(sourceHashes).length}));
}
main().catch(error=>{console.log(JSON.stringify({error:String(error)}));process.exit(1)});
