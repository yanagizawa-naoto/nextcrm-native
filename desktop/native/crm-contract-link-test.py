#!/usr/bin/env python3
"""Focused production parser/inbox/SQLite contract-link test. No App launch."""
from pathlib import Path
import re,json,hashlib,subprocess,time
native=Path(__file__).resolve().parent
output=native/'build/crm-contract-link';output.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
commands=(native/'test.sh').read_text().replace('\\\n',' ').splitlines()
command=next(x for x in commands if x.startswith('swiftc ') and 'CRMServiceTests.swift' in x)
names=[p for p in re.findall(r'\$native_dir/([^"\n]+\.swift)',command) if p!='CRMServiceTests.swift']
names+=['NativeCRMContractLink.swift','NativeCRMContractLinkAccess.swift','NativeCRMContractLinkTests.swift']
sources=[native/p for p in dict.fromkeys(names)]
inputs=sources+[native/'schema.json',native/'schema.sql',native/'test.sh',native/'NativeCRMTaskLink.swift',native/'NativeDeepLink.swift',Path(__file__)]
before={str(p.relative_to(native)):sha(p) for p in inputs};start=time.monotonic();complete=False
proof={'kind':'production contract-link parser/inbox and real SQLite access/revocation','productionInputs':True,'sourceSHA256':before,'normalData':False,'keychain':False,'network':False,'appLaunched':False,'phases':[]}
try:
 binary=output/'NativeCRMContractLinkTests'
 with (output/'compile.log').open('w') as log:
  result=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-lsqlite3',*map(str,sources),'-o',str(binary)],stdout=log,stderr=subprocess.STDOUT,timeout=300)
 proof['phases'].append({'name':'compile','exit':result.returncode});result.check_returncode()
 result=subprocess.run([str(binary),str(native)],capture_output=True,text=True,timeout=90)
 (output/'run.log').write_text(result.stdout+result.stderr);proof['phases'].append({'name':'run','exit':result.returncode});result.check_returncode()
 proof['checks']=int(re.search(r': (\d+) checks passed',result.stdout)[1]);assert proof['checks']==144
 proof.update(stdout=result.stdout,binarySHA256=sha(binary));complete=True
finally:
 proof['sourceHashesStable']=all(sha(native/p)==h for p,h in before.items());proof['complete']=complete and proof['sourceHashesStable'];proof['elapsedSeconds']=round(time.monotonic()-start,2)
 (output/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof.get(k) for k in ['complete','checks','sourceHashesStable','elapsedSeconds']}))
assert proof['complete']
