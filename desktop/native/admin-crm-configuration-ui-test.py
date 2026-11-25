#!/usr/bin/env python3
"""Production AppKit controls with isolated SQLite; no provider or Keychain."""
from pathlib import Path
import hashlib, json, subprocess, sys
native = Path(__file__).resolve().parent
root = native.parent.parent
names = ['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeCRMConfiguration','NativeCRMConfigurationQuery','NativeCRMConfigurationWindow','NativeCRMConfigurationUITests', 'MailReview']
sources = [native / (name + '.swift') for name in names]
original = root / 'app/[locale]/(routes)/admin/crm-settings/_components'
inputs = sources + [native/'schema.json',native/'schema.sql',Path(__file__).resolve()] + [original/name for name in ['ConfigList.tsx','ConfigAddDialog.tsx','ConfigEditDialog.tsx','ConfigDeleteDialog.tsx']]
hashes = lambda: {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes(); build = native/'build'; build.mkdir(exist_ok=True)
binary = build/'NativeCRMConfigurationUITests'
proof = {'exit':None,'sourcesSHA256':before,'verification':'Production AppKit controls and real isolated SQLite; no normal app data, external communication, or Keychain','originalUIDifference':'The original delete dialog requests replacements for all used kinds, but its backend rejects three kinds. Native requests replacement for the supported four and explicitly confirms SET NULL for the other three. The last-item UI rule is retained and transactionally rechecked.'}
try:
    compile = subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-target','arm64-apple-macos13.0','-framework','AppKit','-lsqlite3',*map(str,sources),'-o',str(binary)],capture_output=True,text=True)
    proof['compileExit']=compile.returncode
    if compile.returncode: raise RuntimeError(compile.stderr)
    run = subprocess.run([str(binary),str(native)],capture_output=True,text=True,timeout=90)
    proof.update(exit=run.returncode,stdout=run.stdout,stderr=run.stderr,binaryBytes=binary.stat().st_size)
    if run.returncode: raise RuntimeError(run.stderr)
    proof.update(json.loads(run.stdout)); proof['sourceHashesMatch']=before==hashes()
    assert proof['sourceHashesMatch'],'source drift during UI verification'
    proof['screenshots']={p.name:{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in build.glob('admin-crm-configuration-*.png')}
except Exception as e: proof.update(exit=1,error=str(e))
finally: (build/'admin-crm-configuration-ui-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['exit','compileExit','checks','sourceHashesMatch','error'] if k in proof},ensure_ascii=False))
sys.exit(proof['exit'])
