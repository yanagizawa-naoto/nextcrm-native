#!/usr/bin/env python3
"""Small real-SQLite UI projection checks; no ERP, Keychain or app launch."""
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
names=json.loads((n/'plugins-production-sources.json').read_text())+['NativeOdooMap','NativeOXOCatalog','NativeOXOClient','NativeOXOConnector','NativeOXOCountries','NativeOXOCustomers','NativeOXOMap','NativeOXOOrders','NativeOXOSync','NativeOXOUIData','NativePluginPresentation','NativeOXOPresentation','NativeOXOPresentationTests']
inputs=[n/(x+'.swift') for x in names]+[n/'oxo-presentation-test.py',n/'schema.json',n/'schema.sql']
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
inputs += [n/'plugins-production-sources.json']
before={p.name:digest(p) for p in inputs};binary=n/'build/NativeOXOPresentationTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macosx13.0',*[str(p) for p in inputs if p.suffix=='.swift'],'-lsqlite3','-framework','Security','-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n)],capture_output=True,text=True);print(r.stdout,end='');print(r.stderr[:1200],end='')
stable=before=={p.name:digest(p) for p in inputs}
(n/'build/oxo-presentation-verification.json').write_text(json.dumps({'inputsSHA256':before,'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:1200],'binaryBytes':binary.stat().st_size,'scope':'Japanese presentation DTOs with real SQLite, live identity/roles/record scope, disabled/absent slots, internal/external links, secrets/network no-access, read-only persistence. Rendering belongs to the shared AppKit window suite.'},indent=2)+'\n')
assert r.returncode==0 and stable
