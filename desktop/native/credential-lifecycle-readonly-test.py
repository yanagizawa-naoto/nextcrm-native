#!/usr/bin/env python3
"""Production-only sealed SQLite cleanup boundary for Plugin and MCP. No Keychain calls."""
from pathlib import Path
import datetime,hashlib,json,os,shutil,subprocess,tempfile,time
N=Path(__file__).resolve().parent;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();os.umask(0o077)
out=N/'build'/('credential-lifecycle-readonly-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir(parents=True);start=time.monotonic();native=out/'inputs';native.mkdir()
names=json.loads((N/'plugins-production-sources.json').read_text())+['NativePluginsCredentials','NativeMCPCredentials','NativeMCPSettings']
inputs=[N/(x+'.swift') for x in names]+[N/'schema.json',N/'schema.sql',N/'plugins-production-sources.json',N/'NativeCredentialLifecycleReadOnlyTests.swift',Path(__file__)]
before={p.name:sha(p) for p in inputs};proof={'sourceSHA256':before,'complete':False,'scope':'Production sealed SQLite and fake stores: readonly cleanup rejects before removal; writable current/future/queue-outside keys protected; failed remove retry retained. No new erase grant.'}
try:
 for p in inputs:shutil.copy2(p,native/p.name);assert sha(native/p.name)==before[p.name]
 cmd=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-module-cache-path',str(out/'cache'),*[str(native/(x+'.swift')) for x in names],str(native/'NativeCredentialLifecycleReadOnlyTests.swift'),'-o',str(out/'Tests')]
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=300);(out/'compile.log').write_text(r.stdout+r.stderr);proof['compileExit']=r.returncode;r.check_returncode()
 with tempfile.TemporaryDirectory(prefix='NextCRM-CredentialLifecycle-') as temp:
  r=subprocess.run([str(out/'Tests'),str(native),str(Path(temp).resolve())],capture_output=True,text=True,timeout=60,umask=0o077);(out/'run.log').write_text(r.stdout+r.stderr);proof.update({'exit':r.returncode,'binarySHA256':sha(out/'Tests')});r.check_returncode();proof.update(json.loads(r.stdout));assert proof['checks']==24 and proof['readonlyPluginRemovals']==0 and proof['readonlyMCPRemovals']==0
 proof['fixtureRemoved']=not Path(temp).exists();proof['inputsStable']=all(sha(p)==before[p.name] and sha(native/p.name)==before[p.name] for p in inputs);assert proof['inputsStable'];proof['complete']=True
finally:
 if (out/'cache').exists():shutil.rmtree(out/'cache')
 proof['seconds']=round(time.monotonic()-start,2);proof['retainedBytes']=sum(p.stat().st_size for p in out.rglob('*') if p.is_file());(out/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');(N/'build/credential-lifecycle-readonly-latest.json').write_text(json.dumps({'proof':str(out/'verification.json'),'sha256':sha(out/'verification.json'),'complete':proof['complete']},indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['complete','checks','seconds','retainedBytes']}))
