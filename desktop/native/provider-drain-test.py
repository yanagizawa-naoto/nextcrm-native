#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,sys,tempfile,os,time,difflib
n=Path(__file__).resolve().parent;repo=n.parent.parent;p=n/'build';p.mkdir(exist_ok=True)
names=json.loads((n/'plugins-production-sources.json').read_text())+['NativePluginsCredentials','NativePluginsRuntime','NativeOdooMap','NativeCurrencyAdministration','NativeCurrencyAdministrationECB','NativeCurrencyAdministrationRuntime']
sources=[n/(x+'.swift') for x in names]+[n/'NativeProviderRuntimeTasks.swift',n/'NativeProviderDrainTests.swift']
inputs=sources+[n/'schema.json',n/'schema.sql',n/'plugins-production-sources.json',Path(__file__).resolve()]
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
before={str(x.relative_to(repo)):sha(x) for x in inputs};production={str(x.relative_to(repo)):sha(x) for x in [n/'NativePluginsRuntime.swift',n/'NativeCurrencyAdministrationRuntime.swift',n/'NativeProviderRuntimeTasks.swift']}
proof={'actualProductionSources':True,'phases':[],'sourceSHA256':before,'productionSHA256':production,'externalRequests':0,'ordinaryDataAccess':False,'normalKeychain':False,'limitations':['The stop caller is an external lifecycle owner. A callback cannot await the completion of its own Task by calling runtime.stop() from inside that same callback. Plugin SDK callbacks have no runtime.stop API.','Caller-created Tasks which invoke public start/wake/stop are owned by their callers. Provider-owned worker/timer/notification Tasks and plugin heartbeat are joined here.','No provider network, normal app launch, real Keychain, or production source modification; source tests use isolated SQLite and injected transports/delays.']}
start=time.time();log=p/'provider-drain-test.log';binary=p/'NativeProviderDrainTests';complete=False
try:
 command=['swiftc','-swift-version','5','-parse-as-library','-whole-module-optimization','-O','-target','arm64-apple-macos13.0','-D','RESTORE_PROVIDER_TESTING','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,sources),'-o',str(binary)]
 with log.open('w') as out:r=subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,timeout=600)
 proof['phases'].append({'name':'optimized-compile','exit':r.returncode});print(json.dumps(proof['phases'][-1]),flush=True)
 if r.returncode:raise RuntimeError(log.read_text()[-6000:])
 with tempfile.TemporaryDirectory(prefix='ProviderDrainFixtures-',dir=p) as fixture:
  os.chmod(fixture,0o700)
  r=subprocess.run([str(binary),str(n),fixture],capture_output=True,text=True,timeout=60,env={k:v for k,v in os.environ.items() if not k.startswith('NEXTCRM_')})
  with log.open('a') as out:out.write(r.stdout+r.stderr)
  proof['phases'].append({'name':'SQLite-and-cancellation-ignoring-providers','exit':r.returncode});print(json.dumps(proof['phases'][-1]),flush=True)
  if r.returncode:raise RuntimeError((r.stdout+r.stderr)[-4000:])
  proof.update(json.loads(r.stdout.strip().splitlines()[-1]))
 proof['fixtureRemoved']=not Path(fixture).exists();proof['binaryBytes']=binary.stat().st_size;complete=True
finally:
 proof['inputHashesMatch']=all(sha(repo/x)==h for x,h in before.items());proof['productionUnchanged']=all(sha(repo/x)==h for x,h in production.items());proof['elapsedSeconds']=round(time.time()-start,2)
 proof['complete']=complete and proof['inputHashesMatch'] and proof['productionUnchanged'];proof['runnerExit']=0 if proof['complete'] else 1
 (p/'provider-drain-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
assert proof['complete'],'Incomplete or source drift'
print(json.dumps({k:proof[k] for k in ['complete','checks','scenarios','inputHashesMatch','productionUnchanged']}))
