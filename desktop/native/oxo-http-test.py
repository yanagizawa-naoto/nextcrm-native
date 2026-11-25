#!/usr/bin/env python3
import hashlib,json,subprocess
from pathlib import Path
n=Path(__file__).resolve().parent
names=['NativePluginsTypes.swift','NativeOdooMap.swift','NativeOXOCountries.swift','NativeOXOMap.swift','NativeOXOClient.swift','NativeOXOHTTPTests.swift','NativeOXOTestJSON.swift','oxo-http-reference.cjs','plugins-source-loader.cjs','oxo-http-test.py']
inputs=[n/x for x in names];digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:digest(p) for p in inputs}
fixture=n/'build/oxo-http-reference.json';binary=n/'build/NativeOXOHTTPTests'
subprocess.run(['node',str(n/'oxo-http-reference.cjs'),str(fixture)],check=True)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O',*[str(p) for p in inputs if p.suffix=='.swift'],'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(fixture)],capture_output=True,text=True);print(r.stdout,end='');print(r.stderr[:2000],end='')
source=json.loads(fixture.read_text());stable=before=={p.name:digest(p) for p in inputs} and all(digest(n.parent.parent/p)==h for p,h in source['sourceSHA256'].items())
(n/'build/oxo-http-verification.json').write_text(json.dumps({'inputsSHA256':before,'sourceSHA256':source['sourceSHA256'],'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'sourceCases':len(source['scenarios']),'binaryBytes':binary.stat().st_size,'scope':'Injected transport only; actual HTTP protocol separately verified by common plugin HTTP suite; no external service.'},indent=2)+'\n')
assert r.returncode==0 and stable
