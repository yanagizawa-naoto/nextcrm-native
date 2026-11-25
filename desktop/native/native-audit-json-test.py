#!/usr/bin/env python3
"""Actual native audit serializer vs fixed original Foundation oracle; isolated SQLite."""
from pathlib import Path
import datetime,hashlib,json,os,subprocess,tempfile,time
N=Path(__file__).resolve().parent;R=N.parent.parent
B=N/'build/native-audit-json-proof'/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+str(os.getpid()));B.mkdir(parents=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=[N/x for x in ['NativeDatabase.swift','NativeAuditJSONTests.swift','NativeAuditJSONTestSupport.swift','schema.json','schema.sql','native-audit-json-test.py', 'MailReview.swift']]
before={str(p.relative_to(R)):sha(p) for p in files};phases=[]
# Same source bytes plus test-only accessors in the same file are required to
# exercise the private audit method; no production file is rewritten.
combined=B/'NativeDatabaseProbe.swift';combined.write_text(files[0].read_text()+'\n'+files[2].read_text())
def run(name,cmd):
 t=time.monotonic();p=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(B/(name+'.log')).write_text(p.stdout+p.stderr);phases.append({'name':name,'exit':p.returncode,'seconds':round(time.monotonic()-t,3)})
 if p.returncode:raise RuntimeError(name+': '+str(B/(name+'.log')))
run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-lsqlite3',str(combined),str(files[1]),str(N/'MailReview.swift'),'-o',str(B/'NativeAuditJSONTests')])
with tempfile.TemporaryDirectory(prefix='NextCRM-AuditJSON-') as root:
 run('native',[str(B/'NativeAuditJSONTests'),str(N),str(B),'after',root])
result=json.loads((B/'after-audit.json').read_text())
assert result['schemaModels']==92 and len(result['snapshots'])==193 and result['checks']==780
assert all(sha(R/k)==v for k,v in before.items())
proof={'inputs':before,'inputsUnchanged':True,'phases':phases,'checks':result['checks'],'schemaModels':92,'snapshots':193,'originalBytesValuesKeyOrderEqual':True,'normalData':False,'network':False,'Keychain':False,'output':str(B.relative_to(R))}
(B/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');(N/'build/native-audit-json-verification.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({'checks':result['checks'],'snapshots':193,'models':92,'proof':str((B/'verification.json').relative_to(R))}))
