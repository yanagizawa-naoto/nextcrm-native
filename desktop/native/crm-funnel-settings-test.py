#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess, sys, time
native = Path(__file__).resolve().parent
root = native.parent.parent
candidate = native / 'build/crm-funnel-settings'
candidate.mkdir(parents=True, exist_ok=True)
names = ['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath', 'MailReview']
settings = native/'NativeCRMAutomationSettings.swift'
paths = [native/(x+'.swift') for x in names]+[settings]+[native/(x+'.swift') for x in ['NativeCRMFunnelSettings','NativeCRMFunnelSettingsWindow','NativeCRMFunnelSettingsTests']]
watched = paths+[native/'schema.json',native/'schema.sql',native/'crm-funnel-settings-reference.cjs',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
before=hashes(); result={'status':'running','exit':None,'sourcesSHA256':before,'normalData':False,'keychain':False,'network':False,'limitations':['Actual original TypeScript/Zod action with isolated Prisma/auth/cache adapters; native real SQLite and offscreen AppKit controls; not full application menu/runtime wiring or live identity proof.','Native retained form adds optimistic concurrency protection; source action overwrites by ID.']};start=time.monotonic()
proof=candidate/'verification.json';proof.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
try:
 p=subprocess.run(['node',str(native/'crm-funnel-settings-reference.cjs'),str(root),str(candidate/'reference.json')],text=True,capture_output=True)
 result['sourceExit']=p.returncode;print(json.dumps({'stage':'original source oracle','exit':p.returncode,'stdout':p.stdout}),flush=True)
 if p.returncode: raise RuntimeError(p.stderr)
 reference=json.loads((candidate/'reference.json').read_text());result['sourceCases']=len(reference['cases']);result['originalSourceHashes']=reference['sourceSHA256']
 binary=candidate/'NativeCRMFunnelSettingsTests'
 p=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-target','arm64-apple-macos13.0','-framework','AppKit','-lsqlite3',*map(str,paths),'-o',str(binary)],text=True,capture_output=True)
 result['compileExit']=p.returncode;(candidate/'compile.log').write_text(p.stdout+p.stderr);print(json.dumps({'stage':'compile','exit':p.returncode}),flush=True)
 if p.returncode: raise RuntimeError(p.stderr[-12000:])
 p=subprocess.run([str(binary),str(native),str(candidate)],text=True,capture_output=True,timeout=120)
 result.update(exit=p.returncode,stdout=p.stdout,stderr=p.stderr,binaryBytes=binary.stat().st_size,binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest())
 if p.returncode: raise RuntimeError(p.stderr[-12000:])
 result.update(json.loads(p.stdout));result['sourceHashesMatch']=before==hashes();result['originalHashesMatch']=all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in reference['sourceSHA256'].items())
 assert result['sourceHashesMatch'] and result['originalHashesMatch'],'source changed during test'
 result['status']='passed'
except Exception as e: result.update(exit=1,status='failed',error=str(e))
finally:
 result['elapsedSeconds']=round(time.monotonic()-start,1);proof.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['status','exit','sourceCases','compileExit','checks','sourceHashesMatch','error','elapsedSeconds'] if k in result},ensure_ascii=False),flush=True)
sys.exit(result['exit'])
