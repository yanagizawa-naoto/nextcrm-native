#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
commands=[['node',str(n/'plugins-account-reference.cjs')]]
for command in commands:subprocess.run(command,check=True)
production=json.loads((n/'plugins-production-sources.json').read_text())
sources=[n/(name+'.swift') for name in production+['NativePluginsAccountTests','NativePluginsHostTests']]
watched=sources+[n/'schema.json',n/'schema.sql',n/'plugins-production-sources.json',n/'plugins-test.py',n/'plugins-core-reference.cjs',n/'plugins-account-reference.cjs']
before={str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
binary=n/'build/plugins-account-tests'
command=['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)]
manifest=n/'build/plugins-account-build.json';cached=json.loads(manifest.read_text()) if manifest.exists() else {}
if not binary.exists() or cached.get('sources')!=before or cached.get('command')!=command or cached.get('binarySHA256')!=hashlib.sha256(binary.read_bytes()).hexdigest():
 r=subprocess.run(command,capture_output=True,text=True)
 if r.returncode:print(json.dumps({'compile':r.returncode,'diagnostic':r.stderr[-16000:]}));raise SystemExit(r.returncode)
 manifest.write_text(json.dumps({'sources':before,'command':command,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()}))
r=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=240)
unchanged=before=={str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
reference=json.loads((n/'build/plugins-account-reference.json').read_text())
proof={'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr[:1000],'sources':before,'sourceHashes':reference['sourceHashes'],'sourceScenarios':len(reference['scenarios']),'sourceActions':sum(len(s['actions']) for s in reference['scenarios']),'unchanged':unchanged,'binaryBytes':binary.stat().st_size,'referenceBytes':(n/'build/plugins-account-reference.json').stat().st_size,'scope':'Actual original account-protection rules/hooks/jobs/order calculations with synthetic data/notification boundaries; native actual SQLite store/records and common host transactional hooks/lifecycle/permissions/queues. Provider error descriptions and random notice-key ordering are normalized, log level/context and state are compared.'}
(n/'build/plugins-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sources','sourceHashes']},ensure_ascii=False));raise SystemExit(r.returncode if r.returncode else 0 if unchanged else 1)
