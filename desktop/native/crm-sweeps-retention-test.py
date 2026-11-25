#!/usr/bin/env python3
"""Production-only snapshot retention suite. Runs123checks, not the sweep oracle/suite."""
import hashlib,json,pathlib,shutil,subprocess,time
HERE=pathlib.Path(__file__).resolve().parent
N=next((p for p in [HERE,*HERE.parents] if (p/'schema.json').is_file() and (p/'CRMService.swift').is_file()),None)
if N is None:raise SystemExit('Native source directory not found')
R=N.parent.parent
names='NativeDatabase CRMModules InvoiceModules CatalogModules LineItemModules LineItemMath CRMLineItems CRMCatalog ProductCSV PricingEngine CRMService OrderModules OrderWorkflow OrderDraftStore CRMOrders InvoiceMath InvoiceMailCredentials NativeCRMAutomationSettings InvoiceMail MailReview NativeCRMSweepNotices NativeCRMSweepLink NativeCRMSweepJobs NativeCRMSweepNavigation NativeCRMSweepMailWorker NativeCRMSweepSnapshotRetention'.split()
production=[N/(name+'.swift') for name in names]
fixture=HERE/'crm-sweeps-retention-fixtures.json';test=HERE/'NativeCRMSweepSnapshotRetentionTests.swift'
missing=[str(p) for p in production+[fixture,test] if not p.is_file()]
if missing:raise SystemExit('Formal source promotion required; no candidate fallback: '+', '.join(missing))
O=N/'build/crm-sweeps-retention-test';O.mkdir(parents=True,exist_ok=True)
hash=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
reference=json.loads(fixture.read_text());original=reference['provenance']['originalSourceSHA256']
sourceDrift=[p for p,h in original.items() if not (R/p).is_file() or hash(R/p)!=h]
if sourceDrift:raise SystemExit('Retention fixture provenance changed; refresh from verified source reference: '+', '.join(sourceDrift))
files=production+[test];evidence=files+[fixture,pathlib.Path(__file__).resolve(),N/'schema.json',N/'schema.sql']
before={str(p.relative_to(R)):hash(p) for p in evidence};start=time.time()
proof={'productionOnly':True,'candidateFallback':False,'scope':'retention123 only','sourceOracleReexecuted':False,'sweep1315Reexecuted':False,'comparison48226Reexecuted':False,'originalSourceSHA256':original,'fixtureCases':len(reference['cases'])}
shutil.copyfile(fixture,O/'reference.json')
def run(name,args):
 with (O/(name+'.log')).open('w') as log:code=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT).returncode
 proof[name]=code;return code==0
if run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,files),'-o',str(O/'NativeCRMSweepSnapshotRetentionTests')]):
 if run('native',[str(O/'NativeCRMSweepSnapshotRetentionTests'),str(N),str(O)]):
  result=json.loads((O/'native-results.json').read_text());proof.update(result);proof['expectedCheckCountMatches']=result.get('checks')==123
proof['sourceSHA256']=before;proof['sourceUnchanged']=all(hash(R/p)==h for p,h in before.items())
proof['originalSourceUnchanged']=all(hash(R/p)==h for p,h in original.items());proof['seconds']=round(time.time()-start,1)
(O/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceSHA256','originalSourceSHA256']},ensure_ascii=False))
raise SystemExit(0 if proof.get('compile')==0 and proof.get('native')==0 and proof.get('expectedCheckCountMatches') and proof['sourceUnchanged'] and proof['originalSourceUnchanged'] else 1)
