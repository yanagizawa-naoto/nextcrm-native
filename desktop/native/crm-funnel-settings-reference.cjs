const fs = require('node:fs'), path = require('node:path'), Module = require('node:module'), crypto = require('node:crypto');
const root = path.resolve(process.argv[2]);
const ts = require(path.join(root, 'node_modules/typescript'));
const source = 'app/[locale]/(routes)/admin/funnel-settings/_actions/funnel-settings.ts';
const defaults = {killAfterDays:45,recycleAfterDays:90,cadenceTouch1BusinessDays:3,cadenceTouch2OffsetDays:7,cadenceTouch3OffsetDays:10,cadenceTouch4OffsetDays:15,cadenceTouch5OffsetDays:45,careCheckinDays:30,careReferralDays:90,careQuarterIntervalDays:90,careQuarterCount:8,renewalWindowDays:30};
const cases = [{name:'create-defaults',values:defaults,existing:false},{name:'update-all',values:Object.fromEntries(Object.keys(defaults).map(k=>[k,k==='careQuarterCount'?0:12])),existing:true}];
for(const key of Object.keys(defaults))for(const value of key==='careQuarterCount'?[-1,0,24,25]:[0,1,365,366])cases.push({name:key+'='+value,values:{...defaults,[key]:value},existing:true});
for(const role of ['user','manager','partner'])cases.push({name:'denied-'+role,role,values:defaults,existing:false});
cases.push({name:'inactive-admin',active:false,values:defaults,existing:false},{name:'banned-admin',banned:true,values:defaults,existing:false});
class AuthenticationError extends Error{}; class AuthorizationError extends Error{};
async function run(test){
 let data=null,method=null,authCalls=0,revalidated=0;
 const filename=path.join(root,source),m=new Module(filename,module);m.filename=filename;m.paths=Module._nodeModulePaths(path.dirname(filename));const inherited=m.require.bind(m);
 const replacements={
  '@/lib/prisma':{prismadb:{crm_FunnelSettings:{findFirst:async()=>test.existing?{id:'original'}:null,create:async arg=>{method='create';data=arg.data;},update:async arg=>{if(arg.where.id!=='original')throw Error('wrong row');method='update';data=arg.data;}}}},
  'next/cache':{revalidatePath:()=>revalidated++},
  '@/lib/authz':{AuthenticationError,AuthorizationError,requireRole:async()=>{authCalls++;if(test.active===false||test.banned)throw new AuthenticationError();if((test.role??'admin')!=='admin')throw new AuthorizationError();return{id:'00000000-0000-4000-8000-000000000001'};}}
 };
 m.require=name=>Object.hasOwn(replacements,name)?replacements[name]:inherited(name);
 m._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,filename);
 const result=await m.exports.updateFunnelSettings(test.values);
 return {...test,expected:{success:!result.error,error:result.error??null,data,method,authCalls,revalidated}};
}
(async()=>{const results=[];for(const test of cases)results.push(await run(test));const watched=[source,'lib/crm/funnel-settings.ts','lib/crm/funnel-timers.ts'];const sourceSHA256=Object.fromEntries(watched.map(p=>[p,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,p))).digest('hex')]));fs.writeFileSync(process.argv[3],JSON.stringify({sourceSHA256,cases:results,limits:['Actual source action and installed Zod; Prisma, authority and cache invalidation are isolated adapters, not live PostgreSQL or authentication.']}));console.log(JSON.stringify({sourceCases:results.length}));})().catch(e=>{console.error(e.stack);process.exit(1);});
