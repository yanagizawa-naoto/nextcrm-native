const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto'),ts=require('typescript');
const root=path.resolve(__dirname,'../..');
const {Decimal}=require('@prisma/client/runtime/client');
const sourceHashes={};const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
async function fixture(defaultCurrency){
  const cache=new Map(),actor={id:'00000000-0000-0000-0000-000000000001',role:'admin'};
  let saved,observed=[];
  const opportunities=[{budget:new Decimal('10'),currency:'USD',status:'CLOSED',created_on:new Date('2024-02-15T00:00:00Z'),close_date:new Date('2024-02-20T00:00:00Z'),deletedAt:null,assigned_sales_stage:{name:'Won'}}];
  const rates=[{fromCurrency:'USD',toCurrency:'CZK',rate:new Decimal('22')},{fromCurrency:'USD',toCurrency:'JPY',rate:new Decimal('150')}];
  const filtered=where=>opportunities.filter(row=>(!where.status||(typeof where.status==='string'?where.status===row.status:where.status.in.includes(row.status))));
  const db={crm_SystemSettings:{findUnique:async()=>defaultCurrency===null?null:{value:defaultCurrency}},exchangeRate:{findMany:async()=>rates},crm_Opportunities:{findMany:async({where})=>filtered(where),count:async({where})=>filtered(where).length},crm_Report_Config:{create:async({data})=>{saved={id:'legacy-config',...data};return saved}}};
  function load(file){
    if(cache.has(file))return cache.get(file);
    const absolute=path.join(root,file);sourceHashes[file]=hash(absolute);
    const code=ts.transpileModule(fs.readFileSync(absolute,'utf8'),{fileName:file,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText;
    const exports={};cache.set(file,exports);
    const requireMock=name=>{
      if(name==='react/jsx-runtime')return{jsx:(type,props)=>({type,props}),jsxs:(type,props)=>({type,props})};
      if(name==='@/lib/prisma')return{prismadb:db};
      if(name==='@prisma/client/runtime/client')return{Decimal};
      if(name==='@/lib/authz'||name==='@/lib/authz/scopes/report-scope')return{requireAuthenticated:async()=>actor,getReportScope:()=>({opportunity:{}}),isManagerOrAdmin:()=>true};
      if(name==='next/headers')return{cookies:async()=>({get:()=>undefined})};
      if(name==='next-intl/server')return{getTranslations:async()=>key=>key};
      if(name==='@/lib/authz/scopes/campaign-not-deleted')return{CAMPAIGN_NOT_DELETED:{}};
      if(name.startsWith('@/components/'))return new Proxy({},{get:(_t,k)=>String(k)});
      if(name==='@/actions/reports/sales'){
        const original=load('actions/reports/sales.ts');return new Proxy(original,{get:(t,k)=>k==='getRevenue'?async(...args)=>{const result=await t[k](...args);observed.push({currency:args[1],revenue:result});return result}:t[k]});
      }
      if(name.startsWith('@/'))return load(name.slice(2)+'.ts');
      if(name.startsWith('.'))return load(path.posix.normalize(path.posix.join(path.posix.dirname(file),name))+'.ts');
      throw Error('Unexpected dependency '+name);
    };
    vm.runInNewContext(code,{exports,require:requireMock,console,URLSearchParams,Date},{filename:file});return exports;
  }
  const filters=Object.fromEntries(new URLSearchParams('from=2024-02-01&to=2024-02-29&accountId=preserved-unused-key'));
  await load('actions/reports/config.ts').saveConfig({name:'移行前の売上',category:'sales',filters,isShared:true});
  await load('app/[locale]/(routes)/reports/sales/page.tsx').default({searchParams:Promise.resolve(saved.filters)});
  if(observed.length!==1)throw Error('Missing source page currency');
  return {name:defaultCurrency===null?'missing-default':defaultCurrency===''?'empty-default':'default-'+defaultCurrency,defaultCurrency,saved,expected:observed[0]};
}
(async()=>{
  const cases=[];for(const value of ['CZK','USD','JPY',null,''])cases.push(await fixture(value));
  for(const file of ['prisma/schema.prisma','actions/invoices/issue-invoice.ts','lib/invoices/pdf/build-pdf-data.ts','components/reports/SaveConfigDialog.tsx','inngest/functions/reports/send-scheduled.ts'])sourceHashes[file]=hash(path.join(root,file));
  sourceHashes[path.relative(root,__filename)]=hash(__filename);
  const invalidDefaults=[];for(const value of ['USDXYZ','usd',' USD ','USD\n','USD\r\n','USD\nBAD','USD\r\nBAD','USD'+'X'.repeat(512)]){try{const result=await fixture(value);invalidDefaults.push({value,status:'returned',expected:result.expected});}catch(error){invalidDefaults.push({value,status:'threw',name:error.name,message:error.message});}}
  const output=process.argv[2];if(!output)throw Error('Expected dedicated output path');
  fs.writeFileSync(output,JSON.stringify({sourceHashes,cases,invalidDefaults,scope:'Actual saveConfig and SalesReportPage/getDefaultCurrency/getRevenue; synthetic Prisma and no display_currency cookie, no provider'},null,2)+'\n');
  console.log(JSON.stringify({cases:cases.length,invalidDiagnostics:invalidDefaults.length,sources:Object.keys(sourceHashes).length}));
})().catch(e=>{console.error(e);process.exitCode=1});
