#!/usr/bin/env python3
"""Verify public cancellation/review preserves immutable bodies until commit."""
from pathlib import Path
import hashlib,json,re,shutil,subprocess,tempfile,time
n=Path(__file__).resolve().parent;c=n/'build/mail-terminal-cleanup';c.mkdir(exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
scripts=[n/'invoice-mail-test.sh',n/'campaign-mail-test.sh']
names=list(dict.fromkeys(x for script in scripts for x in re.findall(r'\$native_dir/(\w+)\.swift',script.read_text()) if not x.endswith('Tests')))
fixture=c/'InvoiceFixture.swift';original=n/'InvoiceCancelCleanupTests.swift'
text=original.read_text();assert text.count('@main enum InvoiceCancelCleanupTests')==1
fixture.write_text(text.replace('@main enum InvoiceCancelCleanupTests','enum InvoiceCancelCleanupTests'))
sources=[n/(name+'.swift') for name in names]+[fixture,n/'MailTerminalCleanupTests.swift']
inputs=sources+scripts+[original,n/'CampaignHTML.c',n/'CampaignHTML.h',n/'schema.json',n/'schema.sql',Path(__file__).resolve()]
before={str(p.relative_to(n)):sha(p) for p in inputs}
proof={'productionSourcesDirect':True,'sourceSHA256':before,'networkRequests':0,'normalData':False,'phases':[],
       'fixtureTransformation':'Only remove @main from existing InvoiceCancelCleanupTests; fixture construction and assertions unchanged.'}
log=c/'test.log';binary=c/'MailTerminalCleanupTests';start=time.monotonic();complete=False
try:
 with log.open('w') as out:result=subprocess.run(['zsh',str(n/'build-campaign-html.sh')],stdout=out,stderr=subprocess.STDOUT,timeout=120)
 proof['phases'].append({'name':'html-object','exit':result.returncode});result.check_returncode()
 obj=c/'CampaignHTML.o';shutil.copy2(n/'build/CampaignHTML.o',obj);proof['objectSHA256']=sha(obj)
 command=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-framework','Security','-framework','CoreText','-framework','CoreGraphics','-framework','LocalAuthentication','-lsqlite3','-lxml2','-import-objc-header',str(n/'CampaignHTML.h'),str(obj),*map(str,sources),'-o',str(binary)]
 with log.open('a') as out:result=subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,timeout=600)
 proof['phases'].append({'name':'compile','exit':result.returncode});print(json.dumps(proof['phases'][-1]),flush=True)
 if result.returncode:raise RuntimeError(log.read_text()[-5500:])
 with tempfile.TemporaryDirectory(prefix='fixture-',dir=c) as folder:
  result=subprocess.run([str(binary),str(n),folder],capture_output=True,text=True,timeout=120)
  with log.open('a') as out:out.write(result.stdout+result.stderr)
  proof['phases'].append({'name':'run','exit':result.returncode})
  if result.returncode:raise RuntimeError((result.stdout+result.stderr)[-5500:])
  proof.update(json.loads(result.stdout.strip().splitlines()[-1]));assert proof['differences']==[]
 proof['fixtureRemoved']=not Path(folder).exists();proof['binarySHA256']=sha(binary);complete=True
finally:
 proof['inputsUnchanged']=all(sha(n/name)==value for name,value in before.items())
 proof['complete']=complete and proof['inputsUnchanged'];proof['elapsedSeconds']=round(time.monotonic()-start,1)
 (c/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
assert proof['complete']
print(json.dumps({k:proof[k] for k in ['complete','checks','inputsUnchanged','fixtureRemoved']}))
