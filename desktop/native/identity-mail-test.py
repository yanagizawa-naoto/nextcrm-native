#!/usr/bin/env python3
from pathlib import Path
import datetime,hashlib,json,os,shutil,subprocess,sys,tempfile,time
N=Path(__file__).resolve().parent;C=N/'build/identity-mail';C.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
out=C/('run-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+str(os.getpid()));out.mkdir(mode=0o700)
inputs=[N/x for x in ['NativeDatabase.swift','NativeIdentity.swift','schema.json','schema.sql','InvoiceMail.swift','NativeIdentityMail.swift','NativeIdentityMailWorker.swift','NativeIdentityMailTransport.swift','NativeIdentityMailTests.swift','identity-mail-test.py', 'MailReview.swift']]
before={str(p):sha(p)for p in inputs};native=out/'inputs';native.mkdir();cache=out/'cache';cache.mkdir();tmp=out/'tmp';tmp.mkdir(mode=0o700)
for p in inputs:shutil.copy2(p,native/p.name)
profile=out/'test.sb';quote=lambda x:json.dumps(str(x))
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n(allow file-write* (subpath '+quote(out)+') (subpath "/dev/fd") (literal "/dev/null"))\n(deny file-read* (subpath '+quote(Path.home()/'Library/Keychains')+'))\n')
env=os.environ.copy();env.update(TMPDIR=str(tmp)+'/',CLANG_MODULE_CACHE_PATH=str(cache/'clang'),SWIFT_MODULECACHE_PATH=str(cache/'swift'),PYTHONDONTWRITEBYTECODE='1')
launcher=[] if env.get('NEXTCRM_NATIVE_INHERITED_SANDBOX')=='1' else ['/usr/bin/sandbox-exec','-f',str(profile)]
proof={'sandbox':'inherited' if not launcher else 'owned', 'complete':False,'sourceSHA256':before,'scope':'Actual SQLite queue and in-memory Resend transport with synthetic authority/callback; no active login issuer, app wiring, live sender, or normal data.','phases':[],'externalRequests':0,'diskOTPSpools':0};start=time.monotonic()
try:
 sources=[p for p in native.iterdir()if p.suffix=='.swift'];binary=out/'Tests'
 command=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-lsqlite3',*map(str,sources),'-o',str(binary)]
 with (out/'compile.log').open('w')as log:r=subprocess.run(launcher+command,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=420)
 proof['phases'].append({'name':'compile','exit':r.returncode});r.check_returncode()
 with tempfile.TemporaryDirectory(prefix='identity-mail-',dir=tmp)as td:
  os.chmod(td,0o700)
  r=subprocess.run(launcher+[str(binary),str(native),td],text=True,capture_output=True,env=env,timeout=90)
  (out/'run.log').write_text(r.stdout+r.stderr);proof['phases'].append({'name':'actual-queue','exit':r.returncode});r.check_returncode();proof['result']=json.loads(r.stdout)
 proof['fixtureRemoved']=not Path(td).exists();proof['inputsUnchanged']=all(sha(Path(p))==h for p,h in before.items());assert proof['inputsUnchanged'];proof['complete']=True
finally:
 proof['seconds']=round(time.monotonic()-start,2)
 proof['cacheBytesRemoved']=sum(p.stat().st_size for p in cache.rglob('*')if p.is_file());shutil.rmtree(cache)
 if tmp.exists():shutil.rmtree(tmp)
 proof['retainedBytes']=sum(p.stat().st_size for p in out.rglob('*')if p.is_file())
 (out/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
 (C/'latest.json').write_text(json.dumps({'path':str(out/'verification.json'),'sha256':sha(out/'verification.json'),'complete':proof['complete']})+'\n')
 print(json.dumps({k:proof[k]for k in ['complete','phases','seconds','retainedBytes']},ensure_ascii=False),flush=True)
