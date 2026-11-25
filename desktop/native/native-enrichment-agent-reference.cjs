// Execute the full original agent with deterministic injected services.
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),ts=require('typescript'),crypto=require('node:crypto');
function load(file,overrides={}) {
  const filename=path.resolve(__dirname,'../..',file),mod=new Module(filename,module);
  mod.filename=filename;mod.paths=Module._nodeModulePaths(path.dirname(filename));
  const fallback=mod.require.bind(mod);mod.require=name=>name in overrides?overrides[name]:fallback(name);
  mod._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,filename);return mod.exports;
}
const normalized=text=>text.trim().replace(/\s+/g,' ');
const hash=text=>crypto.createHash('sha256').update(normalized(text)).digest('hex');
async function main(){
  const log=console.log;console.log=console.warn=console.error=()=>{};
  const sourceUtils=load('lib/enrichment/utils/source-context.ts'),parser=load('lib/enrichment/strategies/email-parser.ts');
  const {AgentOrchestrator}=load('lib/enrichment/agent-architecture/orchestrator.ts',{'../strategies/email-parser':parser,'../services/firecrawl':{FirecrawlService:class{}},'../services/openai':{OpenAIService:class{}},'../utils/source-context':sourceUtils});
  const field=(name,type='string',description='Company information')=>({name,displayName:name,description,type,required:false});
  const fields=[field('companyName'),field('companyWebsite'),field('companyDescription'),field('industry'),field('yearFounded','number'),field('employeeCount','number'),field('annualRevenue','number'),field('fundingStage'),field('techStack','array'),field('github'),field('ceo'),field('custom','string','The current custom product information')];
  const body='Acme provides business services and products.\nOur company has 150 employees and revenue of 2500000. Founded in 2005, our headquarters is in Tokyo.\nOur CEO is Aki Tanaka. We use Swift and SQLite for our tools.\nContact our team for more product information.';
  const site={markdown:body,html:'<script>__NEXT_DATA__</script>',metadata:{title:'Acme | Home',description:'Acme provides business services and products in Japan.'}};
  const page={url:'https://acme.invalid/about',title:'Acme about',markdown:body};
  const values={companyName:'Acme',companyWebsite:'https://acme.invalid',companyDescription:site.metadata.description,industry:'Software',yearFounded:2005,employeeCount:150,annualRevenue:2500000,fundingStage:'Series B',techStack:['website','Swift','SQLite','x'],github:'https://github.com/acme/tools',ceo:'Aki Tanaka',custom:'Product'};
  const cases=[];
  for(const spec of [
    {label:'all_phases',email:'aki.tanaka@acme.invalid',fields},
    {label:'search_discovery',email:'aki@acme.invalid',fields:fields.slice(0,4),failRoot:true},
    {label:'empty_inference',email:'aki@my-company.invalid',fields:fields.slice(0,3),failRoot:true,empty:true},
    {label:'parked_no_inference',email:'aki@acme.invalid',fields:fields.slice(0,3),failRoot:true,parked:true},
    {label:'general_only',email:'aki@acme.invalid',fields:fields.slice(-2)},
    {label:'company_only',companyName:'Acme',fields:fields.slice(0,4)},
    {label:'company_website',companyName:'Acme',website:'https://www.acme.invalid/path',fields:fields.slice(0,4)},
    {label:'empty_non_discovery',email:'aki@acme.invalid',fields:fields.slice(3),empty:true,failRoot:true},
    {label:'leadership_fallback',email:'aki@acme.invalid',fields:fields.slice(-2),failAbout:true},
    {label:'no_company_name',email:'aki@intranet',fields:fields.slice(3)},
    {label:'zero_and_false',email:'aki@acme.invalid',fields:[field('customZero','number'),field('customBool','boolean')],zero:true},
    {label:'duplicate_last_wins',email:'aki@acme.invalid',fields:[field('custom')],duplicates:true},
  ]){
    const trace=[],progress=[];let searchCount=0;
    const agent=new AgentOrchestrator('qa','qa');
    agent.firecrawl={search:async(query,options)=>{
      searchCount++;
      let reply=spec.empty?[]:spec.parked?[{...page,markdown:'Domain for sale. '.repeat(20)}]:query.startsWith('site:github.com')?[{url:'https://github.com/acme/tools',title:'Acme tools',markdown:body},{url:'https://github.com.evil.invalid/acme',title:'not github',markdown:body}]:[{...page},{url:'https://acme.invalid/news',title:'Acme news',markdown:body},{url:'https://linkedin.com/company/acme',title:'Social',markdown:body}];
      if(spec.duplicates)reply=[{...page,title:'Version '+searchCount,markdown:body+' Version '+searchCount}];
      trace.push({op:'search',query,limit:options.limit,reply:structuredClone(reply)});return reply;
    },scrapeUrl:async(url)=>{
      const failure=(spec.failRoot&&new URL(url).pathname==='/')||(spec.failAbout&&url.endsWith('/about'));
      trace.push({op:'scrape',url,...(failure?{failure:404}:{reply:structuredClone(site)})});
      if(failure)throw Object.assign(Error('page not found'),{status:404});return structuredClone(site);
    }};
    async function extract(content,requested,context,corroborated){
      const reply=Object.fromEntries(requested.map(f=>[f.name,{field:f.name,value:spec.zero?(f.type==='boolean'?false:0):(values[f.name]??'Value'),confidence:0.8,source:'https://acme.invalid/about',sourceContext:[{url:'https://acme.invalid/about',snippet:body}]}]));
      trace.push({op:'extract',fields:requested.map(f=>f.name),context:Object.fromEntries(Object.entries(context).map(([k,v])=>[k,normalized(v)])),corroborated,contentHash:hash(content),contentUnits:content.length,reply:structuredClone(reply)});return reply;
    }
    agent.openai={extractStructuredDataOriginal:(c,f,x)=>extract(c,f,x,false),extractStructuredDataWithCorroboration:(c,f,x)=>extract(c,f,x,true)};
    const result=await agent.enrichRow({email:spec.email??''},spec.fields,'email',(field,value)=>progress.push(field),()=>{},spec.companyName||spec.website?{companyName:spec.companyName,companyWebsite:spec.website}:undefined);
    cases.push({...spec,trace,result,progress});
  }
  const agent=new AgentOrchestrator('qa','qa');
  const routingFields=fields.concat([field('customCompany','string','The company name'),field('something','string','Which technology does it use'),field('position'),field('location'),field('valuation'),field('programming','string','Current programming tools')]);
  const categories=Object.fromEntries(Object.entries(agent.categorizeFields(routingFields)).map(([k,v])=>[k,v.map(f=>f.name)]));
  const identities=['john.smith@my-company.com','johnSmith@onetrust.com','first_middle-last@acme.invalid','qa@gmail.com','qa@GMAIL.COM','qa@intranet'].map(email=>({email,expected:agent.extractEmailContext(email)}));
  fs.writeFileSync(process.argv[2],JSON.stringify({year:new Date().getFullYear(),cases,routingFields,categories,identities},null,2)+'\n');
  log(`Original enrichment agents: ${cases.length} full pipelines, ${routingFields.length} field routes, ${identities.length} identities`);
}
main().catch(error=>{process.stderr.write(String(error.stack??error)+'\n');process.exitCode=1;});
