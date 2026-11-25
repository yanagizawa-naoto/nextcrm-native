// Execute the actual upstream handlers with in-memory Prisma/providers. No network.
const fs = require('node:fs'), path = require('node:path'), Module = require('node:module'), ts = require('typescript');
function load(file, overrides = {}) {
  const filename = path.resolve(__dirname, '../..', file), mod = new Module(filename, module);
  mod.filename = filename; mod.paths = Module._nodeModulePaths(path.dirname(filename));
  const fallback = mod.require.bind(mod); mod.require = name => name in overrides ? overrides[name] : fallback(name);
  mod._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText, filename);
  return mod.exports;
}
async function main() {
  const now = 1_800_000_000_000; Date.now = () => now;
  const utils = load('lib/enrichment/utils/field-utils.ts');
  const presetSource = fs.readFileSync(path.resolve(__dirname,'../../app/[locale]/(routes)/crm/contacts/components/EnrichFieldSelector.tsx'),'utf8');
  const fields = [...presetSource.matchAll(/\{ name: "([^"]+)"[^\n]*description: "([^"]+)"/g)].map(m=>({name:m[1],displayName:m[1],description:m[2],type:'string',required:false}));
  if(fields.length!==9) throw Error('Expected original 9 fields');
  const requested = fields.concat({name:'custom_count',displayName:'従業員数',description:'人数',type:'number',required:false});
  const cases = [];
  for (const [label,current] of [['null',null],['empty',''],['spaces',' \n　\uFEFF'],['filled','手入力'],['non_js_blank','\u0085']]) {
    const input = Object.fromEntries(fields.map(f=>[f.name,current]));
    const enrichments = Object.fromEntries(requested.map((f,i)=>[f.name,{field:f.name,value:i===9?123:'取得値'+i,confidence:0.8,source:'https://example.invalid/source',sourceContext:[{url:'https://example.invalid/source',snippet:'参照した本文'}]}]));
    cases.push({label,input,output:{status:'completed',enrichments}});
  }
  for (const [label,value] of [['false',false],['true',true],['zero',0],['number',123.5],['array',['a','日本語']],['empty_array',[]],['empty_result',''],['null_result',null]]) {
    cases.push({label,input:{},output:{status:'completed',enrichments:{position:{field:'position',value,confidence:0.6}}}});
  }
  for (const item of cases) {
    let updates = {}, history = {}, calls = 0;
    const module = load('inngest/functions/enrich-contact.ts', {
      '@/inngest/client':{inngest:{createFunction:(_,fn)=>fn}},
      '@/lib/api-keys':{getApiKey:async()=> 'qa-never-sent'},
      '@/lib/enrichment/utils/field-utils':utils,
      '@/lib/enrichment/strategies/agent-enrichment-strategy':{AgentEnrichmentStrategy:class{async enrichRow(){calls++;return item.output;}}},
      '@/lib/prisma':{prismadb:{crm_Contacts:{findUnique:async()=>({id:'contact',email:'qa@example.invalid',...item.input}),update:async({data})=>{updates=data;}},
        crm_Contact_Enrichment:{findFirst:async()=>null,update:async({data})=>{Object.assign(history,data);}}}}
    });
    await module.enrichContact({event:{data:{contactId:'contact',enrichmentId:'enrichment',fields:requested,triggeredBy:'actor'}}});
    Object.assign(item,{updates,historyStatus:history.status,providerCalls:calls});
  }
  const skip = load('lib/enrichment/utils/skip-list.ts');
  // This checkout has no app/fire-enrich/skip-list.txt. Exercise the original
  // loader's fallback instead of inventing a resource that is not deployed.
  const domains = await skip.loadSkipList();
  const skips = ['qa@gmail.com','qa@GMAIL.COM','qa@example.edu','qa@example.ac.uk','qa@example.invalid','not-an-email','qa@sub.gmail.com'].map(email=>({email,skip:skip.shouldSkipEmail(email,domains),reason:skip.getSkipReason(email,domains)}));
  const timeModule = load('inngest/functions/enrich-contact.ts', {'@/inngest/client':{inngest:{createFunction:(_,fn)=>fn}},'@/lib/prisma':{prismadb:{}},'@/lib/api-keys':{},'@/lib/enrichment/utils/field-utils':utils,'@/lib/enrichment/strategies/agent-enrichment-strategy':{}});
  const recent = [null,0,7*86400000-1,7*86400000,7*86400000+1,-1000].map(age=>({age,skip:timeModule.shouldSkipBulkEnrichment(age===null?null:new Date(now-age))}));
  const conversions = [false,true,0,-0,1,123.5,1e-6,1e-7,1e20,1e21,1.2345678901234567,[],['a','日本語'],null,''].map(value=>({value,text:String(value),truthy:!!value}));
  fs.writeFileSync(process.argv[2],JSON.stringify({now,fields:requested,cases,recent,skips,skipDomains:[...domains],conversions},null,2)+'\n');
  console.log(`Original contact enrichment: ${cases.length} worker, ${recent.length} dedup, ${skips.length} skip-list, ${conversions.length} conversion cases`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
