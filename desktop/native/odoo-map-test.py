#!/usr/bin/env python3
"""Actual Odoo connector pure-function oracle versus Foundation-only native mapping."""
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
inputs=[n/x for x in ['NativePluginsTypes.swift','NativeOdooMap.swift','NativeOdooMapTests.swift','odoo-reference.cjs','odoo-map-test.py']]
before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
oracle=n/'build/odoo-reference.json';binary=n/'build/NativeOdooMapTests'
subprocess.run(['node',str(n/'odoo-reference.cjs'),str(oracle)],check=True)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O',*[str(p) for p in inputs if p.suffix=='.swift'],'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(oracle)],text=True,capture_output=True)
print(r.stdout,end='');print(r.stderr[:2000],end='')
source=json.loads(oracle.read_text())
stable=before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs} and all(hashlib.sha256((n.parent.parent/p).read_bytes()).hexdigest()==h for p,h in source['sourceSHA256'].items())
(n/'build/odoo-map-verification.json').write_text(json.dumps({'inputsSHA256':before,'sourceSHA256':source['sourceSHA256'],'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:2000],'sourceCases':len(source['cases']),'scope':'Mapping, graph ordering, sampling, status, notes, local time only. Settings cases are reserved for the host integration suite; no database, live Odoo or external I/O.','binaryBytes':binary.stat().st_size},indent=2)+'\n')
assert r.returncode==0 and stable
