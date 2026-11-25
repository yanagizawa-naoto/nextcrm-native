#!/usr/bin/env python3
from pathlib import Path
import json,hashlib,subprocess
n=Path(__file__).resolve().parent
subprocess.run(['node',str(n/'plugins-core-reference.cjs')],check=True)
sources=[n/(name+'.swift') for name in ['NativePluginsTypes','NativePluginsSettings','NativeAccountProtectionState','NativeAccountProtectionRegions','NativePluginsCoreTests']]
watched=sources+[n/'plugins-core-reference.cjs',n/'plugins-core-test.py']
before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
binary=n/'build/plugins-core-tests'
result=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',*map(str,sources),'-o',str(binary)],capture_output=True,text=True)
if result.returncode:print(json.dumps({'compile':result.returncode,'error':result.stderr[-5000:]}));raise SystemExit(result.returncode)
result=subprocess.run([str(binary),str(n/'build/plugins-core-reference.json')],capture_output=True,text=True)
reference=json.loads((n/'build/plugins-core-reference.json').read_text())
proof={'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr[-1000:],'sources':before,'sourceHashes':reference['sourceHashes'],'cases':len(reference['cases']),'unchanged':before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched},'binaryBytes':binary.stat().st_size}
(n/'build/plugins-core-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sources','sourceHashes']}));raise SystemExit(result.returncode or (0 if proof['unchanged'] else 1))
