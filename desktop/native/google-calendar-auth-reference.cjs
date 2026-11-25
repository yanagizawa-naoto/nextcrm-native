const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('typescript'),crypto=require('node:crypto');
const file=path.resolve(__dirname,'../../lib/crm/calendar/google.ts'),source=fs.readFileSync(file,'utf8'),moduleStub={exports:{}};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module:moduleStub,exports:moduleStub.exports,require:name=>{if(name==='@/lib/email-crypto')return{decrypt:x=>x};throw Error(name);}},{filename:file,timeout:2000});
const read='https://www.googleapis.com/auth/calendar.readonly',write='https://www.googleapis.com/auth/calendar.events';
const scopeCases=[null,'',read,write,read+' '+write,write+' '+read,write+'x','prefix'+write,'https://www.googleapis.com/auth/calendar',write+' '+write].map(input=>({input,expected:moduleStub.exports.scopeLevelFromGrantedScopes(input)}));
const verifier='dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const syncFile=path.resolve(__dirname,'../../inngest/functions/calendar/google-sync-connection.ts'),syncSource=fs.readFileSync(syncFile,'utf8'),syncModule={exports:{}};
vm.runInNewContext(ts.transpileModule(syncSource,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{module:syncModule,exports:syncModule.exports,require:name=>{
  if(name==='@/inngest/client')return{inngest:{createFunction:()=>({})}};
  if(['@/lib/prisma','@/lib/crm/calendar/google','@/lib/crm/calendar/google-normalize','@/lib/crm/calendar/sync'].includes(name))return{};
  throw Error(name);
}},{filename:syncFile,timeout:2000});
const reasons=['invalid_grant','unauthorized_client','rateLimitExceeded','userRateLimitExceeded','quotaExceeded','forbiddenForNonOrganizer','forbidden for non-organizer','cannotChangeOrganizer','cannotChangeOwnAttendeeStatus','requiredAccessLevel','forbidden','insufficientPermissions','accessNotConfigured','unknown-secret-placeholder'];
const errors=[];
for(const status of [400,401,403,429,503])for(const reason of reasons)errors.push({status,body:{error:{errors:[{reason}]}}});
errors.push({status:400,body:{error:'invalid_grant'}},{status:403,body:{error:{message:'Forbidden for non-organizer'}}},{status:403,body:{error:{errors:[{reason:'unknown'},{reason:'rateLimitExceeded'}]}}},{status:403,body:{error:{message:'invalid_grant',errors:[{reason:'rateLimitExceeded'}]}}});
const errorCases=errors.map(x=>({...x,expected:syncModule.exports.isAuthRevocationError({code:x.status,response:{data:x.body}})}));
fs.writeFileSync(path.join(__dirname,'build/google-calendar-auth-reference.json'),JSON.stringify({sourceSHA256:crypto.createHash('sha256').update(source).digest('hex'),syncSourceSHA256:crypto.createHash('sha256').update(syncSource).digest('hex'),scopeCases,errorCases,pkce:{verifier,challenge:crypto.createHash('sha256').update(verifier).digest('base64url')}},null,2)+'\n');
console.log(JSON.stringify({suite:'actual original Google scopes and error classification',scopeChecks:scopeCases.length,errorChecks:errorCases.length}));
