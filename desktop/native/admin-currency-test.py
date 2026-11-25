#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,sys
n=Path(__file__).resolve().parent;root=n.parent.parent;b=n/'build';b.mkdir(exist_ok=True)
names=['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativePluginsTypes','NativeOdooMap','NativeCurrencyAdministration','NativeCurrencyAdministrationECB','NativeProviderRuntimeTasks','NativeCurrencyAdministrationRuntime','NativeCurrencyAdministrationQA','NativeCurrencyAdministrationTests', 'MailReview']
paths=[n/(x+'.swift') for x in names];watched=paths+[n/'schema.json',n/'schema.sql',n/'admin-currency-reference.cjs',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
before=hashes();proof={'exit':None,'sources':before,'limits':['Actual TypeScript actions/ECB worker with isolated Prisma adapter; no live PostgreSQL/provider/Keychain/normal user data.','Native listing is paginated; Currency code sorting uses existing native SQL. Locale-dependent PostgreSQL ordering is not claimed.','Source retry defaults belong to deployed Inngest; native uses a bounded five-attempt, restart-safe read-only fetch policy.','Native additionally fences configuration revision, task cancellation, job lease and a queued manual actor after HTTP awaits.']};binary=b/'NativeCurrencyAdministrationTests'
try:
 original=subprocess.run(['node',str(n/'admin-currency-reference.cjs'),str(b/'admin-currency-reference.json')],capture_output=True,text=True);proof['sourceExit']=original.returncode
 if original.returncode:raise RuntimeError(original.stderr)
 ref=json.loads((b/'admin-currency-reference.json').read_text());proof.update(sourceCases=len(ref['cases']),fixedCases=len(ref['fixed']),sourceHashes=ref['sourceHashes'])
 compile=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-target','arm64-apple-macos13.0','-lsqlite3',*map(str,paths),'-o',str(binary)],capture_output=True,text=True);proof['compileExit']=compile.returncode
 if compile.returncode:raise RuntimeError(compile.stderr)
 run=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=120);proof.update(exit=run.returncode,stdout=run.stdout,stderr=run.stderr,binaryBytes=binary.stat().st_size)
 if run.returncode:raise RuntimeError(run.stderr)
 proof.update(json.loads(run.stdout));proof['sourceHashesMatch']=hashes()==before
 assert proof['sourceHashesMatch'] and all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in ref['sourceHashes'].items()),'source drift'
except Exception as e:proof.update(exit=1,error=str(e))
finally:(b/'admin-currency-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['exit','sourceCases','fixedCases','checks','compileExit','sourceHashesMatch','error'] if k in proof},ensure_ascii=False));sys.exit(proof['exit'])
