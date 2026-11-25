#!/usr/bin/env python3
from pathlib import Path
import subprocess,hashlib,json,sys
n=Path(__file__).resolve().parent;r=n/'build/avatar-worker';r.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
decoders=[n/(x+'.swift')for x in ['NativeUserAvatarAnimation','NativeUserAvatarWebPAnimation','NativeUserAvatarAPNGAnimation']]
protocol=n/'NativeUserAvatarWorkerProtocol.swift';client=n/'NativeUserAvatarWorkerClient.swift';main=n/'NativeUserAvatarWorkerMain.swift'
tests=[n/'NativeUserAvatarWorkerTests.swift',n/'NativeUserAvatarWorkerPermitTests.swift'];fake=n/'NativeUserAvatarWorkerFake.swift'
sources=[*decoders,protocol,client,main,*tests,fake,Path(__file__).resolve(),n/'user-avatar-worker-reference.cjs',*[n/('user-avatar-'+x+'-reference.cjs')for x in ['animation','apng','streaming']],*[n/('user-avatar-worker-'+x+'.py')for x in ['fixtures','protocol-test','bounds-test']]]
before={str(p.relative_to(n)):sha(p)for p in sources}
base=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO']
if '--run-only'not in sys.argv:
 with(r/'build.log').open('w')as log:
  subprocess.run(base+['-D','AVATAR_DECODER_WORKER',*map(str,decoders),str(protocol),str(main),'-o',str(r/'NextCRMAvatarDecoder')],check=True,stdout=log,stderr=log)
  subprocess.run(base+[str(protocol),str(fake),'-o',str(r/'WorkerFake')],check=True,stdout=log,stderr=log)
  subprocess.run(base+['-D','AVATAR_WORKER_TESTING',*map(str,decoders),str(protocol),str(client),*map(str,tests),'-o',str(r/'WorkerTests')],check=True,stdout=log,stderr=log)
 assert before=={str(p.relative_to(n)):sha(p)for p in sources}
 (r/'build.json').write_text(json.dumps({'sourceSHA256':before,'binarySHA256':{name:sha(r/name)for name in ['NextCRMAvatarDecoder','WorkerFake','WorkerTests']}},indent=2)+'\n')
if '--compile-only'in sys.argv:print(json.dumps({'compiled':3}));sys.exit(0)
assert json.loads((r/'build.json').read_text())=={'sourceSHA256':before,'binarySHA256':{name:sha(r/name)for name in ['NextCRMAvatarDecoder','WorkerFake','WorkerTests']}}
for mode in ['badmeta','oversize','badwidth','badindex','truncated','unknown','earlyend','stalled','inithang','stallinput']:
 p=r/('fake-'+mode);p.unlink(missing_ok=True);p.symlink_to('WorkerFake')
subprocess.run(['python3',str(n/'user-avatar-worker-fixtures.py')],check=True,capture_output=True)
for artifact,reference in [('avatar-animation/gif-finite.gif','animation'),('avatar-apng/singleExcluded.png','apng'),('avatar-streaming/webp-16mp.webp','streaming')]:
 if not(n/('build/'+artifact)).exists():subprocess.run(['node','--expose-gc',str(n/('user-avatar-'+reference+'-reference.cjs'))],check=True,cwd=n.parent.parent,capture_output=True)
subprocess.run(['node',str(n/'user-avatar-worker-reference.cjs')],check=True,cwd=n.parent.parent,capture_output=True)
f=json.loads((r/'fixtures.json').read_text())
results=[]
for f in f['fixtures']:
 p=subprocess.run([str(r/'WorkerTests'),str(r),'benchmark',f['name']],capture_output=True,text=True,timeout=30)
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 results.append(json.loads((r/(f['name']+'-result.json')).read_text()))
for mode in ['safety','races','permits']:
 p=subprocess.run([str(r/'WorkerTests'),str(r),mode],capture_output=True,text=True,timeout=60)
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
for script in ['protocol','bounds']:
 p=subprocess.run(['python3',str(n/('user-avatar-worker-'+script+'-test.py'))],capture_output=True,text=True,timeout=40)
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
parts={name:json.loads((r/(name+'-result.json')).read_text())for name in ['safety','races','permits']}
parts.update({name:json.loads((r/(name+'-verification.json')).read_text())for name in ['protocol','bounds']})
proof={'checks':sum(x['checks']for x in results)+sum(x['checks']for x in parts.values()),'benchmarks':results,**parts,'sourceSHA256':before,'sourcesStable':before=={str(p.relative_to(n)):sha(p)for p in sources},'scope':'Current production source, independently compiled helper. Playback uses one async FIFO permit; raw clients remain unrestricted. Parent benchmark is a lightweight driver, not CRM. App packaging/signature/whole-app memory are separate.'}
(r/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');assert proof['sourcesStable'];print(json.dumps({'checks':proof['checks'],'benchmarks':len(results),'permitChecks':parts['permits']['checks'],'sourcesStable':True}))
