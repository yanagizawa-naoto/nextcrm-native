#!/usr/bin/env python3
"""Focused production readonly credential cleanup boundary; no baseline/AI70 rerun."""
from pathlib import Path
import json,hashlib,re,subprocess,tempfile,time,os
native=Path(__file__).resolve().parent
output=native/'build/credential-readonly';output.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
names=re.search(r'sources=\(([^)]+)\)',(native/'ai-keys-test.sh').read_text()).group(1).split()
names=[n for n in names if not n.endswith('Tests')]+['NativeUserCredentialCleanup']
sources=[native/(name+'.swift') for name in dict.fromkeys(names)]+[native/'NativeCredentialReadOnlyTests.swift']
tracked=sources+[Path(__file__),native/'ai-keys-test.sh',native/'schema.json',native/'schema.sql']
before={str(p.relative_to(native)):sha(p) for p in tracked};start=time.monotonic();complete=False
proof={'kind':'production readonly cleanup boundaries with sealed SQLite and fake store','productionInputs':True,'sourceSHA256':before,'realKeychain':False,'normalData':False,'network':False,'phases':[]}
try:
 binary=output/'NativeCredentialReadOnlyTests'
 with (output/'compile.log').open('w') as log:
  r=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,sources),'-o',str(binary)],stdout=log,stderr=subprocess.STDOUT,timeout=300)
 proof['phases'].append({'name':'compile','exit':r.returncode});r.check_returncode()
 with tempfile.TemporaryDirectory(prefix='NextCRM-CredentialReadonly-') as tmp:
  os.chmod(tmp,0o700);r=subprocess.run([str(binary),str(native),str(Path(tmp).resolve())],capture_output=True,text=True,timeout=90,umask=0o077)
  (output/'run.log').write_text(r.stdout+r.stderr);proof['phases'].append({'name':'run','exit':r.returncode});r.check_returncode();proof.update(json.loads(r.stdout))
  assert proof['checks']==37 and proof['readonlyExplicitRemoveClosureInvocations']==0 and proof['readonlyAIStoreRemoveCalls']==0
  proof['fixtureBytes']=sum(p.stat().st_size for p in Path(tmp).rglob('*') if p.is_file())
 proof['fixtureRemoved']=not Path(tmp).exists();proof['binarySHA256']=sha(binary);complete=True
finally:
 proof['sourceHashesStable']=all(sha(native/p)==h for p,h in before.items());proof['complete']=complete and proof['sourceHashesStable'];proof['elapsedSeconds']=round(time.monotonic()-start,2)
 (output/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof.get(k) for k in ['complete','checks','sourceHashesStable','fixtureRemoved','elapsedSeconds']}))
assert proof['complete']
