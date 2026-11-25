#!/usr/bin/env python3
"""Verify production AI runtimes; --candidate retains the isolated review mode."""
from pathlib import Path
import hashlib,json,re,subprocess,time,sys
n=Path(__file__).resolve().parent;root=n.parent.parent;b=n/'build';c=b/'ai-runtime-drain-candidate'
names=['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeEmbeddingVector','NativeEmbeddingClient','NativeDocumentAIText','NativeOpenAIChatClient','NativeDocumentAIWorker','NativeEmbeddingIndex','NativeAICredentials', 'NativeUserCredentialCleanup','NativeE2BSettings','NativeE2BConfiguration','NativeAIQAServices','NativeEmbeddingJobs','NativeEmbeddingWorker','NativeEnrichmentPolicy','NativeContactEnrichment','NativeContactEnrichmentWorker','NativeTargetEnrichment','NativeTargetEnrichmentWorker','NativeEnrichmentWeb','NativeEnrichmentText','NativeEnrichmentIdentity','NativeEnrichmentPrompts','NativeEnrichmentOpenAI','NativeEnrichmentOrchestrator','NativeE2BHTTP','NativeE2BClient','InvoiceJobRunner', 'MailReview']
wrappers=['NativeEmbeddingRuntime.swift','NativeContactEnrichmentRuntime.swift','NativeTargetEnrichmentRuntime.swift']
candidate='--candidate' in sys.argv;quick='--quick' in sys.argv;runtime_dir=c if candidate else n
sources=[n/(x+'.swift') for x in names]+[runtime_dir/x for x in wrappers+['NativeRuntimeControlTasks.swift','NativeAIRuntimeDrainTests.swift']]
assert len({p.name for p in sources})==len(sources)
inputs=sources+([n/x for x in wrappers] if candidate else [])+[n/'schema.json',n/'schema.sql',c/'README.md' if candidate else n/'NativeAIRuntimeDrain.md',Path(__file__).resolve()]
inputs += [root/'prisma/initial-data'/(x+'.json') for x in ['crm_Industry_Type','crm_Contact_Types','crm_Lead_Sources','crm_Lead_Statuses','crm_Lead_Types','crm_Opportunities_Sales_Stages','crm_Opportunities_Type']]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):sha(p) for p in inputs};phases=[];start=time.time();log=b/'ai-runtime-drain-test.log';binary=b/('NativeAIRuntimeDrainQuickTests' if quick else 'NativeAIRuntimeDrainCandidateTests' if candidate else 'NativeAIRuntimeDrainTests');success=False
result={'sourcesSHA256':before,'candidateOnly':candidate,'optimized':not quick,'phases':phases,'externalRequests':0,'ordinaryDataAccess':False,'keychainAccess':False,'limits':['Distinct cancellation-ID bursts have no hard memory bound; duplicate IDs coalesce and no accepted distinct request is silently dropped.','Application termination/root-switch integration is owned and verified separately.']}
log.write_text('')
try:
 for name,args in [('compile',['swiftc','-swift-version','5','-parse-as-library',*(['-Onone'] if quick else ['-O','-whole-module-optimization']),'-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication',*map(str,sources),'-lsqlite3','-o',str(binary)]),('sqlite-controls-and-providers',[str(binary),str(n)])]:
  with log.open('a') as output:r=subprocess.run(args,stdout=output,stderr=subprocess.STDOUT,timeout=300)
  phases.append({'name':name,'exit':r.returncode});print(json.dumps(phases[-1]),flush=True)
  if r.returncode:raise RuntimeError(log.read_text()[-6000:])
 result['checks']=int(re.search(r'AI runtime drain: (\d+) checks passed',log.read_text()).group(1));result['binaryBytes']=binary.stat().st_size;success=True
finally:
 result['inputsUnchanged']=all(sha(root/p)==h for p,h in before.items());result['elapsedSeconds']=round(time.time()-start,2)
 result['complete']=success and result['inputsUnchanged'];result['runnerExitCode']=0 if result['complete'] else 1
 proof='ai-runtime-drain'+('-candidate' if candidate else '')+('-quick' if quick else '')+'-verification.json'
 (b/proof).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
assert result['complete'],'Source drift or incomplete checks'
print(json.dumps({'complete':True,'candidateOnly':candidate,'checks':result['checks'],'hashesMatch':True,'elapsedSeconds':result['elapsedSeconds']}))
