#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
n=Path(__file__).resolve().parent
subprocess.run(['node',str(n/'plugins-runtime-reference.cjs')],check=True)
subprocess.run(['node',str(n/'plugins-decimal-reference.cjs')],check=True)
subprocess.run(['node',str(n/'plugins-rules-reference.cjs')],check=True)
names=json.loads((n/'plugins-production-sources.json').read_text())+['NativePluginsCredentials','NativeProviderRuntimeTasks','NativePluginsRuntime','NativePluginsRulesTests','NativePluginsRuntimeTests']
sources=[n/(name+'.swift') for name in names]
watched=sources+[n/'schema.json',n/'schema.sql',n/'plugins-runtime-test.py',n/'plugins-runtime-reference.cjs',n/'plugins-decimal-reference.cjs',n/'plugins-rules-reference.cjs',n/'plugins-source-loader.cjs',n/'plugins-source-database.cjs']
before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
binary=n/'build/plugins-runtime-tests'
command=['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,sources),'-o',str(binary)]
cache=n/'build/plugins-runtime-build.json';previous=json.loads(cache.read_text()) if cache.exists() else {}
if not binary.exists() or previous.get('hashes')!=before or previous.get('command')!=command or previous.get('binarySHA256')!=hashlib.sha256(binary.read_bytes()).hexdigest():
 result=subprocess.run(command,capture_output=True,text=True)
 if result.returncode:print(json.dumps({'compile':result.returncode,'error':result.stderr[-12000:]}));raise SystemExit(result.returncode)
 cache.write_text(json.dumps({'hashes':before,'command':command,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()}))
result=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=180)
reference=json.loads((n/'build/plugins-runtime-reference.json').read_text())
decimals=json.loads((n/'build/plugins-decimal-reference.json').read_text());reference['sourceHashes'].update(decimals['sourceHashes'])
rules=json.loads((n/'build/plugins-rules-reference.json').read_text());reference['sourceHashes'].update(rules['sourceHashes'])
proof={'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr[-1000:],'hashes':before,'unchanged':before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched},'sourceHashes':reference['sourceHashes'],'sourceScenarios':len(reference['scenarios']),'binaryBytes':binary.stat().st_size,'scope':'Actual source Inngest callbacks + native actual SQLite queues, local fake secret backing, cancellation/authority/lifecycle fences. No external provider requests or normal Keychain access.'}
proof['decimalCases']=len(decimals['cases'])
proof['ruleScenarios']=len(rules['scenarios'])
(n/'build/plugins-runtime-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['hashes','sourceHashes']},ensure_ascii=False));raise SystemExit(result.returncode or (0 if proof['unchanged'] else 1))
