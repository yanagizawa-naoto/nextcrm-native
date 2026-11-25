#!/usr/bin/env python3
"""Run the existing invoice/mail/job suite unchanged after runner lifecycle work."""
from pathlib import Path
import hashlib,json,re,subprocess,time
n=Path(__file__).resolve().parent;root=n.parent.parent;b=n/'build';script=n/'invoice-mail-test.sh'
names=re.findall(r'\$native_dir/([^"\s]+\.swift)',script.read_text())
inputs=[script,n/'project-notifications-reference.cjs',n/'schema.json',n/'schema.sql',Path(__file__).resolve()]+[n/x for x in names]+[root/'actions/projects'/x for x in ['create-task.ts','update-task.ts','add-comment-to-task.ts']]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):sha(p) for p in inputs};start=time.time();log=b/'invoice-runner-regression-test.log'
result={'command':['zsh','desktop/native/invoice-mail-test.sh'],'sourcesSHA256':before,'externalRequests':0,'ordinaryDataAccess':False,'keychainAccess':False}
try:
 with log.open('w') as output:r=subprocess.run(['zsh',str(script)],stdout=output,stderr=subprocess.STDOUT,timeout=600)
 result['exitCode']=r.returncode
 if r.returncode:raise RuntimeError(log.read_text()[-5000:])
 result['checks']=int(re.search(r'Invoice mail/jobs: (\d+) checks passed',log.read_text()).group(1))
 result['binaryBytes']=(b/'InvoiceMailTests').stat().st_size
finally:
 result['inputsUnchanged']=all(sha(root/p)==h for p,h in before.items());result['elapsedSeconds']=round(time.time()-start,2)
 result['complete']=result.get('exitCode')==0 and result['inputsUnchanged'] and result.get('checks',0)>0
 (b/'invoice-runner-regression-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
assert result['complete'],'Incomplete suite or source drift'
print(json.dumps({k:result[k] for k in ['complete','exitCode','checks','inputsUnchanged','elapsedSeconds']}))
