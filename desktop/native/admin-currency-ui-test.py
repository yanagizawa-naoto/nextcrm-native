#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,sys
n=Path(__file__).resolve().parent;root=n.parent.parent;b=n/'build';b.mkdir(exist_ok=True)
names=['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativePluginsTypes','NativeOdooMap','NativeCurrencyAdministration','NativeCurrencyAdministrationECB','NativeProviderRuntimeTasks','NativeCurrencyAdministrationRuntime','NativeCurrencyAdministrationWindow','NativeCurrencyAdministrationUITests', 'MailReview']
paths=[n/(x+'.swift') for x in names];original=root/'app/[locale]/(routes)/admin/currencies/_components'
watched=paths+[n/'schema.json',n/'schema.sql',Path(__file__).resolve()]+[original/x for x in ['CurrencyTable.tsx','ExchangeRatesTable.tsx','ECBToggle.tsx']]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
before=hashes();proof={'exit':None,'sources':before,'kind':'Production AppKit controls and real isolated SQLite; no runtime started, no external requests or normal user data.'};binary=b/'NativeCurrencyAdministrationUITests'
try:
 compile=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-target','arm64-apple-macos13.0','-framework','AppKit','-lsqlite3',*map(str,paths),'-o',str(binary)],capture_output=True,text=True);proof['compileExit']=compile.returncode
 if compile.returncode:raise RuntimeError(compile.stderr)
 run=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=90);proof.update(exit=run.returncode,stdout=run.stdout,stderr=run.stderr,binaryBytes=binary.stat().st_size)
 if run.returncode:raise RuntimeError(run.stderr)
 proof.update(json.loads(run.stdout));proof['sourceHashesMatch']=hashes()==before;assert proof['sourceHashesMatch'],'source drift'
 proof['screenshots']={p.name:{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in b.glob('admin-currency-*.png')}
except Exception as e:proof.update(exit=1,error=str(e))
finally:(b/'admin-currency-ui-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['exit','checks','compileExit','sourceHashesMatch','error'] if k in proof},ensure_ascii=False));sys.exit(proof['exit'])
