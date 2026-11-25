// Replay the actual TypeScript target handler with local fakes. No E2B/API calls.
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
  const apply = load('lib/enrichment/e2b/apply-result.ts'), field = load('lib/enrichment/utils/field-utils.ts'), presets = load('lib/enrichment/presets/target-fields.ts');
  const names = ['company_website','industry','employees','city','company_phone','social_linkedin','social_x','description'];
  const output = {target:Object.fromEntries(names.map((name,i)=>[name,'取得値'+i])), confidence:{industry:.6,city:.59,social_x:0},contacts:[
    {name:'山田 太郎',email:'yamada@example.invalid',title:'営業部長',linkedinUrl:'https://linkedin.com/in/yamada',phone:'03-0000-0000',source:'site'},
    {name:'佐藤 花子',email:'sato@example.invalid',title:null,linkedinUrl:null,phone:null,source:'site'},
    {name:'識別できない人',email:null,title:'代表',linkedinUrl:null,phone:null,source:'site'}
  ]};
  const cases = []; let skip;
  for (const [label,value] of [['null',null],['empty',''],['spaces',' \n　\uFEFF'],['filled','手入力'],['non_js_blank','\u0085']]) {
    const input = Object.fromEntries(names.map(name=>[name,value]));
    const history = {}, updates = {}, upserts = [], fanout = []; let killed = 0;
    const prismadb = {
      crm_Targets:{findUnique:async()=>({id:'target',company:'会社',email:'qa@example.invalid',first_name:'試験',last_name:'対象',...input}),update:async({data})=>Object.assign(updates,data)},
      crm_Target_Enrichment:{create:async()=>({id:'history'}),findFirst:async()=>null,update:async({data})=>Object.assign(history,data)},
      crm_Target_Contact:{upsert:async args=>{upserts.push(args);return {id:'person'+upserts.length,enrichStatus:args.create.enrichStatus}}}
    };
    const handler = load('inngest/functions/enrich-target.ts', {
      '@/inngest/client':{inngest:{createFunction:(_,fn)=>fn}}, '@/lib/prisma':{prismadb}, '@/lib/api-keys':{getApiKey:async()=> 'qa-anthropic'},
      '@/lib/enrichment/utils/field-utils':field, '@/lib/enrichment/e2b/agent-script':{getAgentScript:()=> '// fake script'}, '@/lib/enrichment/e2b/apply-result':apply,
      e2b:{Sandbox:{create:async()=>({files:{write:async()=>{}},commands:{run:async()=>({exitCode:0,stdout:JSON.stringify(output),stderr:''})},kill:async()=>{killed++}})}}
    });
    skip = handler.shouldSkipTargetEnrichment;
    const result = await handler.enrichTarget({event:{data:{targetId:'target',enrichmentId:'history',triggeredBy:'actor'}},step:{run:async(_,fn)=>fn(),sendEvent:async(_,events)=>fanout.push(...events)}});
    cases.push({label,input,updates,historyStatus:history.status,upserts:upserts.map(({where,create,update})=>({where,create:{...create,enrichedAt:!!create.enrichedAt},update:{...update,enrichedAt:!!update.enrichedAt}})),fanoutCount:fanout.length,killed,result});
  }
  const domainInputs = [
    ['https://www.example.jp/about','qa@gmail.com'],['https://EXAMPLE.JP:8443','qa@other.jp'],['bad url','qa@EXAMPLE.jp'],[null,'qa@gmail.com'],[null,'qa@ME.COM'],[null,'qa@example.edu'],[null,null]
  ];
  const domains = domainInputs.map(([companyWebsite,email])=>({companyWebsite,email,expected:apply.resolveCompanyDomain({companyWebsite,email,companyName:'会社'})}));
  const recent = [null,0,7*86400000-1,7*86400000,7*86400000+1,-1000].map(age=>({age,skip:skip(age===null?null:new Date(now-age))}));
  const keys = [[null,null],['a@example.invalid',null],[null,'https://linkedin.com/in/a'],['a@example.invalid','https://linkedin.com/in/a']].map(([email,linkedinUrl])=>{
    try { return {email,linkedinUrl,value:apply.buildContactUpsertKey('target',{email,linkedinUrl})}; } catch { return {email,linkedinUrl,value:null}; }
  });
  fs.writeFileSync(process.argv[2], JSON.stringify({now,output,cases,domains,recent,keys,columns:Object.keys(presets.FIELD_MAP),personalNames:presets.PERSONAL_PRESET_FIELDS.map(x=>x.name),companyNames:presets.COMPANY_PRESET_FIELDS.map(x=>x.name),personalDefaults:presets.PERSONAL_DEFAULTS,companyDefaults:presets.COMPANY_DEFAULTS},null,2)+'\n');
  console.log(`Original target enrichment: ${cases.length} worker, ${domains.length} domain, ${recent.length} dedup, ${keys.length} key cases`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
