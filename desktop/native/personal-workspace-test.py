#!/usr/bin/env python3
"""Production-direct personal owner/strict bootstrap tests; synthetic SQLite only.

No candidate fallback. Install beside the production Swift/schema inputs first.
The AppKit window stays offscreen; source tests need no provider or Keychain.
"""
from pathlib import Path
import hashlib,json,subprocess,tempfile,time
n=Path(__file__).resolve().parent;repo=n.parent.parent
names=['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativePersonalWorkspace','NativePersonalOwnerWindow','NativePersonalWorkspaceTests', 'MailReview']
sources=[n/(x+'.swift') for x in names]
inputs=sources+[n/'schema.json',n/'schema.sql']+sorted((repo/'prisma/initial-data').glob('*.json'))+[Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(repo)):sha(p) for p in inputs}
out=n/'build/personal-workspace-verification';out.mkdir(parents=True,exist_ok=True)
binary=out/'NativePersonalWorkspaceTests';log=out/'test.log';start=time.time()
command=['swiftc','-swift-version','5','-parse-as-library','-D','PERSONAL_OWNER_TEST','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','AppKit','-lsqlite3',*map(str,sources),'-o',str(binary)]
with log.open('w') as f:compileResult=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT)
if compileResult.returncode:print(json.dumps({'compileExit':compileResult.returncode,'log':str(log)}));raise SystemExit(compileResult.returncode)
with tempfile.TemporaryDirectory(prefix='NextCRMPersonalOwner-') as tmp:
 result=subprocess.run([str(binary),str(n),str(Path(tmp).resolve()),str(repo/'prisma')],capture_output=True,text=True,timeout=90,umask=0o077)
 with log.open('a') as f:f.write(result.stdout+result.stderr)
 if result.returncode:print(json.dumps({'runExit':result.returncode,'log':str(log),'error':result.stderr[-1200:]}));raise SystemExit(result.returncode)
 counts=json.loads(result.stdout)
stable=all(sha(p)==before[str(p.relative_to(repo))] for p in inputs)
proof={'status':'passed' if stable else 'drift','result':counts,'sourceSHA256':before,'allInputsStable':stable,'productionDirect':True,'compileCommand':command,'binarySHA256':sha(binary),'binaryBytes':binary.stat().st_size,'elapsedSeconds':round(time.time()-start,2),'temporaryFixturesRemoved':True,'visibleWindows':0,'limits':['OS/root/control/lease and explicit approval are injected host responsibilities, not authentication inferred from a descriptor.','Synthetic sealed snapshots come from sqlite3_backup; after all destination connections close, test fixture sealing removes only its own detached SHM and requires WAL absent.','Picker limits rows to 100 and projects only identity display fields. Original TEXT values are read through existing db.page before display truncation.','No normal application, installed data, real Keychain, mail/invitation or provider/network action is performed.']}
(out/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['status','result','allInputsStable','productionDirect','binaryBytes']}));assert stable
