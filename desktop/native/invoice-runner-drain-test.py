#!/usr/bin/env python3
"""Isolated real SQLite/file effects with cancellation-ignoring fake transports."""
from pathlib import Path
import hashlib,json,re,subprocess,time
n=Path(__file__).resolve().parent;root=n.parent.parent;b=n/'build'
sources=[n/x for x in ['NativeDatabase.swift','InvoiceJobRunner.swift','NativeInvoiceJobRunnerDrainTests.swift', 'MailReview.swift']]
inputs=sources+[n/'schema.json',n/'schema.sql',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):sha(p) for p in inputs};phases=[];start=time.time()
result={'sourcesSHA256':before,'optimized':True,'phases':phases,'externalRequests':0,'ordinaryDataAccess':False,'keychainAccess':False}
log=b/'invoice-runner-drain-test.log';binary=b/'NativeInvoiceJobRunnerDrainTests';success=False
log.write_text('')
try:
 for name,args in [('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0',*map(str,sources),'-lsqlite3','-o',str(binary)]),('sqlite-file-drain',[str(binary),str(n)])]:
  with log.open('a') as out:r=subprocess.run(args,stdout=out,stderr=subprocess.STDOUT,timeout=180)
  phases.append({'name':name,'exit':r.returncode});print(json.dumps(phases[-1]),flush=True)
  if r.returncode:raise RuntimeError(log.read_text()[-5000:])
 result['checks']=int(re.search(r'Invoice runner drain: (\d+) checks passed',log.read_text()).group(1));result['binaryBytes']=binary.stat().st_size;success=True
finally:
 result['inputsUnchanged']=all(sha(root/p)==h for p,h in before.items());result['elapsedSeconds']=round(time.time()-start,2)
 result['complete']=success and result['inputsUnchanged'];result['runnerExitCode']=0 if result['complete'] else 1
 (b/'invoice-runner-drain-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
assert result['complete'],'Source drift or incomplete checks'
print(json.dumps({'complete':True,'checks':result['checks'],'hashesMatch':True,'elapsedSeconds':result['elapsedSeconds']}))
