#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,time,tempfile,os,signal,select
n=Path(__file__).resolve().parent;repo=n.parent.parent;p=n/'build/mail-temporary-runtime';p.mkdir(parents=True,exist_ok=True)
names=json.loads((n/'RuntimeDrainSources.json').read_text())
if 'NativeMailTemporaryFiles.swift' not in names:names.append('NativeMailTemporaryFiles.swift')
sources=[n/name for name in names]+[n/'NativeMailTemporaryRuntimeTests.swift']
tracked=sources+[Path(__file__),n/'RuntimeDrainSources.json',n/'schema.json',n/'schema.sql',n/'NativeBridges.h',n/'NativeMailTransport.c',n/'NativeMailTransport.h',n/'CampaignHTML.c',n/'CampaignHTML.h',n/'CampaignHTMLEntities.inc',n/'NativePluginsHTTP.h']
sha=lambda x:hashlib.sha256(x.read_bytes()).hexdigest();before={str(x.relative_to(repo)):sha(x) for x in tracked};proof={'actualProductionSources':True,'existing96ChecksRepeated':False,'sourceSHA256':before,'phases':[],'normalData':False,'externalRequests':0,'realKeychain':False};start=time.time();success=False;log=p/'runtime-test.log';binary=p/'NativeMailTemporaryRuntimeTests'
def phase(name,args):
 with log.open('a') as f:r=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT,timeout=600)
 proof['phases'].append({'name':name,'exit':r.returncode});print(json.dumps(proof['phases'][-1]),flush=True)
 if r.returncode:raise RuntimeError(log.read_text()[-6000:])
try:
 log.write_text('');sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 flags=['xcrun','clang','-O2','-std=c11','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk]
 phase('isolated-object html C',flags+['-I'+sdk+'/usr/include/libxml2','-c',str(n/'CampaignHTML.c'),'-o',str(p/'RuntimeCampaignHTML.o')])
 phase('isolated-object mail C',flags+['-c',str(n/'NativeMailTransport.c'),'-o',str(p/'RuntimeNativeMailTransport.o')])
 phase('production runtime compile',['swiftc','-D','RUNTIME_DRAIN_TESTS','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-framework','Network','-lsqlite3','-lxml2','-lcurl','-import-objc-header',str(n/'NativeBridges.h'),str(p/'RuntimeNativeMailTransport.o'),str(p/'RuntimeCampaignHTML.o'),*map(str,sources),'-o',str(binary)])
 with tempfile.TemporaryDirectory(prefix='runtime-synthetic-',dir=p) as tmp:
  os.chmod(tmp,0o700);base=Path(tmp);spools=base/'spools';spools.mkdir(mode=0o700)
  child=subprocess.Popen([str(binary),'child',str(spools)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  try:
   if not select.select([child.stdout],[],[],10)[0]:raise RuntimeError('spool producer startup timed out')
   line=child.stdout.readline()
   if line.strip()!='ready':raise RuntimeError(child.stderr.read())
   child.kill();child.wait(timeout=10);assert child.returncode==-signal.SIGKILL
  finally:
   if child.poll() is None:child.kill();child.wait(timeout=10)
  for i in range(150):(spools/'NextCRM-MailSpools-v1'/('unknown-'+str(i))).mkdir()
  phase('dedicated actual worker + recovery lifecycle tests',[str(binary),str(n),str(spools)])
  proof['checks']=json.loads(log.read_text().strip().splitlines()[-1])['checks'];proof['fixtureBytes']=sum(x.stat().st_size for x in base.rglob('*') if x.is_file())
 proof['fixtureRemoved']=not base.exists();success=True
finally:
 proof['sourceHashesMatch']=all(sha(repo/x)==h for x,h in before.items());proof['complete']=success and proof['sourceHashesMatch'];proof['elapsedSeconds']=round(time.time()-start,2);proof['artifactBytes']=sum(x.stat().st_size for x in p.rglob('*') if x.is_file());(n/'build/mail-temporary-runtime-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
assert proof['complete'];print(json.dumps({k:proof[k] for k in ['complete','checks','sourceHashesMatch']}))
