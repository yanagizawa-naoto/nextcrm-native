#!/usr/bin/env python3
import hashlib,json,pathlib,subprocess,sys,time
HERE=pathlib.Path(__file__).resolve().parent
N=next((p for p in [HERE,*HERE.parents] if (p/'schema.json').is_file() and (p/'CRMService.swift').is_file()),None)
if N is None:raise SystemExit('Native source directory not found')
R=N.parent.parent
names='NativeDatabase CRMModules InvoiceModules CatalogModules LineItemModules LineItemMath CRMLineItems CRMCatalog ProductCSV PricingEngine CRMService OrderModules OrderWorkflow OrderDraftStore CRMOrders InvoiceMath InvoiceMailCredentials NativeCRMAutomationSettings InvoiceMail MailReview NativeCRMSweepNotices NativeCRMSweepLink NativeCRMSweepJobs NativeCRMSweepNavigation NativeCRMSweepMailWorker'.split()
production=[N/(name+'.swift') for name in names]
missing=[str(p) for p in production if not p.is_file()]
if missing:raise SystemExit('Formal source promotion required; no candidate fallback: '+', '.join(missing))
O=N/'build/crm-sweeps-test';O.mkdir(parents=True,exist_ok=True)
hash=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=production+[HERE/'NativeCRMSweepTests.swift'];evidence=files+[HERE/'crm-sweeps-reference.cjs',HERE/'crm-sweeps-compare.py',pathlib.Path(__file__).resolve(),N/'schema.json',N/'schema.sql']
before={str(p.relative_to(R)):hash(p) for p in evidence};start=time.time();proof={'productionOnly':True,'candidateFallback':False}
def run(name,args):
 with (O/(name+'.log')).open('w') as log:code=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT).returncode
 proof[name]=code;return code==0
def finish():
 proof['sourceSHA256']=before;proof['sourceUnchanged']=all(hash(R/p)==h for p,h in before.items());proof['seconds']=round(time.time()-start,1)
 (O/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceSHA256','originalSourceSHA256']},ensure_ascii=False))
 return all(proof.get(k)==0 for k in ['oracle','compile','native','compare']) and proof['sourceUnchanged'] and proof.get('originalSourceUnchanged')
if not run('oracle',['node',str(HERE/'crm-sweeps-reference.cjs'),str(O/'reference.json'),str(N)]):finish();raise SystemExit(1)
ref=json.loads((O/'reference.json').read_text());proof['originalSourceSHA256']=ref['sourceSHA256']
if run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,files),'-o',str(O/'NativeCRMSweepTests')]):
 if run('native',[str(O/'NativeCRMSweepTests'),str(N),str(O)]):
  if run('compare',['python3',str(HERE/'crm-sweeps-compare.py'),str(O)]):
   value=json.loads((O/'comparison.json').read_text());proof.update({k:value[k] for k in ['sourceCases','nativeChecks','comparisonChecks']})
proof['originalSourceUnchanged']=all(hash(R/p)==h for p,h in ref['sourceSHA256'].items())
raise SystemExit(0 if finish() else 1)
