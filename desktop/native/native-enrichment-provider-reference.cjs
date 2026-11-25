// Execute original extraction and the project-locked SDK with injected responses.
// All fixtures are synthetic. No provider, network, credentials, or downloads.
const fs=require('node:fs'), path=require('node:path'), Module=require('node:module'), ts=require('typescript');
function load(file,overrides={}) {
  const filename=path.resolve(__dirname,'../..',file), mod=new Module(filename,module);
  mod.filename=filename; mod.paths=Module._nodeModulePaths(path.dirname(filename));
  const fallback=mod.require.bind(mod); mod.require=name=>name in overrides?overrides[name]:fallback(name);
  mod._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}}).outputText,filename);
  return mod.exports;
}
async function main() {
  const log=console.log; console.log=console.warn=console.error=()=>{};
  let reply={}, captured=[];
  class AI { constructor(){this.chat={completions:{create:async body=>{captured.push(body);return {choices:[{message:{content:JSON.stringify(reply)}}]};}}};} }
  const contextUtils=load('lib/enrichment/utils/source-context.ts');
  const {OpenAIService}=load('lib/enrichment/services/openai.ts',{'openai':AI,'../utils/source-context':contextUtils});
  const ai=new OpenAIService('qa-unused');
  const field=(name,type='string',required=false)=>({name,displayName:name,description:'description '+name,type,required});
  const fields=[field('companyName','string',true),field('employeeCount','number'),field('yearFounded','number'),field('fundingStage'),field('enabled','boolean'),field('techStack','array'),field('optional')];
  const flat=[];
  const cases=[['standard',{companyName:'Acme',employeeCount:150,yearFounded:2005,fundingStage:'series b round',enabled:true,techStack:['Swift','SQLite'],optional:null}],
    ['zero_false',{companyName:'',employeeCount:0,yearFounded:1800,fundingStage:'preseed round',enabled:false,techStack:[],optional:'-'}],
    ['invalid',{companyName:'/',employeeCount:1000001,yearFounded:1700,fundingStage:'seed round',optional:'N/A'}],
    ['future',{companyName:'日本商事',employeeCount:1000000,yearFounded:9999,fundingStage:'pre-seed',optional:'n/a'}]];
  for(const [label,values] of cases) {
    reply={}; for(const f of fields){reply[f.name]=values[f.name]??null;reply[f.name+'_confidence']=0.8;reply[f.name+'_sources']=f.name==='companyName'?[{url:'https://acme.invalid/about',quote:'Acme is our company.'}]:null;}
    if(label==='zero_false')reply.employeeCount_confidence=0.31;
    const input=structuredClone(reply), result=await ai.extractStructuredDataOriginal('Company body.',fields,{targetDomain:'acme.invalid',name:'A Person'});
    flat.push({label,input,result});
  }
  for(const confidence of [0,0.2,0.3,0.300001,1]) {
    reply={optional:'value',optional_confidence:confidence,optional_sources:[]};
    flat.push({label:'threshold_'+confidence,input:structuredClone(reply),result:await ai.extractStructuredDataOriginal('Body',fields,{})});
  }
  const flatRequest=captured[0]; captured=[];
  const corroborated=[], url='https://acme.invalid/about', count=[field('employeeCount','number')];
  for(const [label,quote,source,confidence,consensus] of [
    ['sentence','Our company employs 150 people in its Tokyo office.',url,0.8,0.9],
    ['title','Acme | 150 employees',url,0.8,0.9],
    ['empty','',url,0.8,0.9],
    ['low_evidence','Our company employs 150 people.',url,0.19,0.9],
    ['low_consensus','Our company employs 150 people.',url,0.8,0.2],
    ['placeholder','Our company employs 150 people.','https://example.com/a',0.8,0.9],
    ['mismatch','Our company is based in Tokyo with no staff count published.',url,0.8,0.9],
    ['hallucination','Our leading provider of innovative solutions employs 150 people.',url,0.8,0.9]
  ]) {
    reply={employeeCount:{evidence:[{value:150,source_url:source,exact_text:quote,confidence}],consensus_value:150,consensus_confidence:consensus,sources_agree:true}};
    corroborated.push({label,input:structuredClone(reply),pages:[{url,markdown:quote}],result:await ai.extractStructuredDataWithCorroboration(quote,count,{targetDomain:'acme.invalid'})});
  }
  const corroboratedRequest=captured[0];
  const sdk=require('@mendable/firecrawl-js'); const Client=sdk.default??sdk;
  const app=new Client({apiKey:'qa-unused'}), wire=[];
  const searchData={web:[{url,title:'Acme',markdown:'body'},'https://acme.invalid/url-only']};
  app.http.post=async(endpoint,body,options)=>{wire.push({endpoint,body,options});return {status:200,data:{success:true,data:endpoint.endsWith('search')?searchData:{markdown:'site body',html:'<p>site</p>'}}};};
  const search=await app.search('Acme company',{limit:3,highlights:false,scrapeOptions:{formats:['markdown','links','html']}});
  const scrape=await app.scrape('https://acme.invalid',{formats:['markdown','html'],timeout:30000,autoResume:false});
  const {webResults}=load('lib/enrichment/services/firecrawl.ts');
  const {AgentOrchestrator}=load('lib/enrichment/agent-architecture/orchestrator.ts',{'../strategies/email-parser':{},'../services/firecrawl':{FirecrawlService:class{}},'../services/openai':{OpenAIService:class{}}});
  const agent=new AgentOrchestrator('qa','qa');
  const pages=[{url:'https://acme.invalid',markdown:'About Acme. Our company offers services and products. '.repeat(8),metadata:{title:'Acme | Official Site',description:'Acme provides products and services.'}},
    {url:'https://parked.invalid',markdown:'This domain is for sale. '.repeat(20)}, {url:'https://short.invalid',markdown:'About us.'}];
  const sites=pages.map(page=>({page,valid:agent.isValidCompanyWebsite(page),name:agent.extractCompanyName(page),description:agent.extractDescription(page)}));
  const contents=[{pages:[],limit:500},{pages:[{url:'https://a.invalid',title:'A',markdown:'Hello body.'}],limit:100},{pages:[{url:'https://a.invalid',markdown:'a'.repeat(3000)},{url:'https://b.invalid',title:'B',markdown:'b'.repeat(1100)}],limit:2500}].map(item=>({...item,expected:agent.trimSearchResultsContent(item.pages,item.limit)}));
  fs.writeFileSync(process.argv[2],JSON.stringify({fields,flat,corroborated,flatRequest,corroboratedRequest,wire,search: webResults(search),scrape,sites,contents},null,2)+'\n');
  log(`Original enrichment providers: ${flat.length} flat, ${corroborated.length} corroborated, ${wire.length} SDK requests, ${sites.length} sites, ${contents.length} content cases`);
}
main().catch(error=>{process.stderr.write(String(error.stack??error)+'\n');process.exitCode=1;});
