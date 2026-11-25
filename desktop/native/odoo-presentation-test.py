#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
names=json.loads((n/'plugins-production-sources.json').read_text())
sources=[n/(s+'.swift') for s in names]+sorted(p for p in n.glob('NativeOdoo*.swift') if 'Tests' not in p.name)+[n/'NativePluginPresentation.swift',n/'NativeOdooPresentationTests.swift']
inputs=sources+[n/'schema.json',n/'schema.sql',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
inputs += [n/'plugins-production-sources.json']
before={p.name:sha(p)for p in inputs};binary=n/'build/NativeOdooPresentationTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n)],text=True,capture_output=True,timeout=60)
print(r.stdout,end='');print(r.stderr[:2500],end='')
stable=before=={p.name:sha(p)for p in inputs}
(n/'build/odoo-presentation-verification.json').write_text(json.dumps({'inputsSHA256':before,'inputsUnchanged':stable,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:2500],'binaryBytes':binary.stat().st_size,'scope':'Isolated real SQLite Japanese Odoo presentation DTOs; current identity, roles, related record access, disabled state, no secret read or external I/O. AppKit table rendering and click-time reauthorization belong to app integration.'},indent=2)+'\n')
assert r.returncode==0 and stable
