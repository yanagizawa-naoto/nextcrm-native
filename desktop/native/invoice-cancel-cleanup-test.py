#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,sys,re,tempfile,os,time
n=Path(__file__).resolve().parent;repo=n.parent.parent;p=n/'build';p.mkdir(exist_ok=True)
names=re.findall(r'\$native_dir/(\w+)\.swift',(n/'invoice-mail-test.sh').read_text())
names=[x for x in names if not x.endswith('Tests')]
sources=[n/(x+'.swift') for x in names]+[n/'InvoiceCancelCleanupTests.swift']
sha=lambda x:hashlib.sha256(x.read_bytes()).hexdigest()
tracked=sources+[n/'schema.json',n/'schema.sql',n/'invoice-mail-test.sh',repo/'actions/invoices/send-invoice-email.ts',Path(__file__).resolve()]
before={str(x.relative_to(repo)):sha(x) for x in tracked};original=sha(n/'CRMInvoiceMail.swift')
log=p/'invoice-cancel-cleanup-test.log';binary=p/'InvoiceCancelCleanupTests';proof={'actualProductionSources':True,'phases':[],'sourceSHA256':before,'externalRequests':0,'normalData':False};start=time.time();complete=False
try:
 with log.open('w') as out:r=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-framework','Security','-framework','CoreText','-framework','CoreGraphics','-lsqlite3',*map(str,sources),'-o',str(binary)],stdout=out,stderr=subprocess.STDOUT,timeout=600)
 proof['phases'].append({'name':'compile','exit':r.returncode});print(json.dumps(proof['phases'][-1]),flush=True)
 if r.returncode:raise RuntimeError(log.read_text()[-4500:])
 with tempfile.TemporaryDirectory(prefix='InvoiceCancelCleanup-',dir=p) as directory:
  os.chmod(directory,0o700);args=[str(binary),str(n),directory]
  r=subprocess.run(args,capture_output=True,text=True,timeout=60)
  with log.open('a') as out:out.write(r.stdout+r.stderr)
  proof['phases'].append({'name':'run','exit':r.returncode})
  if r.returncode:raise RuntimeError((r.stdout+r.stderr)[-4500:])
  proof.update(json.loads(r.stdout.strip()));proof['fixtureBytes']=sum(x.stat().st_size for x in Path(directory).rglob('*') if x.is_file())
 proof['fixtureRemoved']=not Path(directory).exists();complete=True
finally:
 proof['sourceHashesMatch']=all(sha(repo/x)==h for x,h in before.items());proof['productionUnchanged']=sha(n/'CRMInvoiceMail.swift')==original;proof['complete']=complete and proof['sourceHashesMatch'] and proof['productionUnchanged'];proof['binaryBytes']=binary.stat().st_size if binary.exists() else 0;proof['elapsedSeconds']=round(time.time()-start,2)
 (p/'invoice-cancel-cleanup-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
assert proof['complete'],'incomplete or source drift'
print(json.dumps({k:proof[k] for k in ['complete','checks','sourceHashesMatch','productionUnchanged']}))
