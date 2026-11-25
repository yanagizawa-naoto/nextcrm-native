#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,sys
n=Path(__file__).resolve().parent;root=n.parent.parent;b=n/'build';b.mkdir(exist_ok=True)
names=['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeAdminAudit','NativeAdminAuditReader','NativeAdminAuditSafety','NativeAdminAuditTests', 'MailReview']
paths=[n/(p+'.swift') for p in names];watched=paths+[n/'schema.json',n/'schema.sql',n/'admin-audit-reference.cjs',Path(__file__).resolve()];hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched};before=hashes();proof={'exit':None,'sources':before,'limits':['Actual source TypeScript actions with isolated Prisma adapter; no live PostgreSQL or normal user data.','Business and native stores remain separately counted; native audit-table self-records excluded.','Read-only connection sees committed data; call through the service outside a pre-existing uncommitted write transaction.','Sensitive fields/models, credential-like scalar values and unsupported nested object values are withheld. Safe scalar content has complete 4096-character paging; source records unchanged.','SQLite JSON traversal occurs only for a selected detail; Swift results are bounded, SQLite parser peak for one very large source JSON is not independently benchmarked.']};binary=b/'NativeAdminAuditTests'
try:
 source=subprocess.run(['node',str(n/'admin-audit-reference.cjs'),str(b/'admin-audit-reference.json')],capture_output=True,text=True);proof['sourceExit']=source.returncode
 if source.returncode:raise RuntimeError(source.stderr)
 ref=json.loads((b/'admin-audit-reference.json').read_text());proof.update(sourceCases=len(ref['cases']),supplementalCases=len(ref['supplemental']),sourceHashes=ref['sourceHashes'])
 compile=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-target','arm64-apple-macos13.0','-lsqlite3',*map(str,paths),'-o',str(binary)],capture_output=True,text=True);proof['compileExit']=compile.returncode
 if compile.returncode:raise RuntimeError(compile.stderr)
 run=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=120);proof.update(exit=run.returncode,runExit=run.returncode,stdout=run.stdout,stderr=run.stderr,binaryBytes=binary.stat().st_size)
 if run.returncode:raise RuntimeError(run.stderr)
 proof.update(json.loads(run.stdout));proof['sourceHashesMatch']=hashes()==before and all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in ref['sourceHashes'].items());assert proof['sourceHashesMatch'],'source drift'
except Exception as e:proof.update(exit=1,error=str(e))
finally:(b/'admin-audit-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['exit','sourceCases','checks','compileExit','sourceHashesMatch','error'] if k in proof},ensure_ascii=False));sys.exit(proof['exit'])
