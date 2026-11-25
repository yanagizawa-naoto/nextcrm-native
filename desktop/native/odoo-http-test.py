#!/usr/bin/env python3
from pathlib import Path
import json,hashlib,subprocess
n=Path(__file__).resolve().parent
names=json.loads((n/'plugins-production-sources.json').read_text())
sources=[n/(s+'.swift') for s in names]+[n/(s+'.swift') for s in ['NativeOdooCatalog', 'NativeOdooClient', 'NativeOdooCompare', 'NativeOdooCustomerInfo', 'NativeOdooMap', 'NativeOdooOrdersIn', 'NativeOdooOrdersOut', 'NativeOdooOrdersStatus', 'NativeOdooPartners', 'NativeOdooPlugin', 'NativeOdooSync', 'NativeOdooViews']]+[n/'NativeOdooHTTPTests.swift']
inputs=sources+[n/'schema.json',n/'schema.sql',n/'odoo-reference.cjs',n/'odoo-http-reference.cjs',Path(__file__).resolve()]
inputs += [n/'plugins-production-sources.json']
before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs};oracle=n/'build/odoo-http-reference.json';binary=n/'build/NativeOdooHTTPTests'
subprocess.run(['node',str(n/'odoo-http-reference.cjs'),str(oracle)],check=True)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n),str(oracle)],text=True,capture_output=True,timeout=180)
print(r.stdout,end='');print(r.stderr[:3000],end='')
reference=json.loads(oracle.read_text());stable=before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs} and all(hashlib.sha256((n.parent.parent/p).read_bytes()).hexdigest()==h for p,h in reference['sourceSHA256'].items())
(n/'build/odoo-http-verification.json').write_text(json.dumps({'inputsSHA256':before,'sourceSHA256':reference['sourceSHA256'],'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:3000],'binaryBytes':binary.stat().st_size,'scope':'Actual original JSON2 client versus native client, fake response transport, real isolated SQLite pause state; no network. HTTP reason phrases are preserved by the shared NativePluginHTTPStatusText protocol; this suite exercises the default client reader with conforming fake responses. Plain URLSession fallback remains empty; the common pinned HTTP transport is independently verified.'},indent=2)+'\n')
assert r.returncode==0 and stable
