#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess, sys, time
native = Path(__file__).resolve().parent
candidate = native / 'build' / 'crm-automation-jobs'
candidate.mkdir(parents=True, exist_ok=True)
names = ['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath', 'MailReview']
paths = [native/(x+'.swift') for x in names] + [native/(x+'.swift') for x in ['NativeCRMAutomationJobs','NativeCRMAutomationJobsTests']]
watched = paths + [native/'schema.json', native/'schema.sql', Path(__file__).resolve()]
hashes = lambda: {str(p.relative_to(native)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
before = hashes()
result = {'status':'running','sourceSHA256':before,'normalData':False,'keychain':False,'network':False,'scope':'Production database/service and local automation admin service; no worker/runtime/App wiring proof.'}
proof = candidate/'verification.json'
proof.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
start = time.monotonic()
try:
    binary = candidate/'NativeCRMAutomationJobsTests'
    p = subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-target','arm64-apple-macos13.0','-lsqlite3',*map(str,paths),'-o',str(binary)],text=True,capture_output=True)
    (candidate/'compile.log').write_text(p.stdout+p.stderr)
    result['compileExit'] = p.returncode
    if p.returncode: raise RuntimeError(p.stderr[-7000:])
    p = subprocess.run([str(binary),str(native)],text=True,capture_output=True,timeout=90)
    result.update(exit=p.returncode,stdout=p.stdout,stderr=p.stderr)
    if p.returncode: raise RuntimeError(p.stderr[-7000:])
    result.update(json.loads(p.stdout))
    assert result['checks'] == 151, result
    result['sourceHashesMatch'] = before == hashes()
    assert result['sourceHashesMatch']
    result.update(status='passed',binaryBytes=binary.stat().st_size,binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest())
except Exception as error:
    result.update(status='failed',exit=1,error=str(error))
finally:
    result['elapsedSeconds'] = round(time.monotonic()-start,1)
    proof.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['status','exit','checks','compileExit','sourceHashesMatch','elapsedSeconds','error'] if k in result},ensure_ascii=False),flush=True)
sys.exit(result['exit'])
