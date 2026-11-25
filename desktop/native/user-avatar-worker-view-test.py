#!/usr/bin/env python3
from pathlib import Path
import subprocess,hashlib,json,sys
n=Path(__file__).resolve().parent;r=n/'build/avatar-worker';r.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
subprocess.run(['python3',str(n/'user-avatar-worker-fixtures.py')],check=True)
files=[n/(x+'.swift')for x in ['NativeUserAvatarAnimation','NativeUserAvatarWebPAnimation','NativeUserAvatarAPNGAnimation','NativeUserAvatarView','NativeUserAvatarWorkerViewTests']]+[n/(x+'.swift')for x in ['NativeUserAvatarWorkerProtocol','NativeUserAvatarWorkerClient']]
before={str(p.relative_to(n)):sha(p)for p in files}
binary=r/'NativeUserAvatarWorkerViewTests'
if '--run-only' not in sys.argv:
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-D','AVATAR_WORKER_TESTING','-framework','AppKit','-framework','ImageIO',*map(str,files),'-o',str(binary)],check=True)
 (r/'view-build.json').write_text(json.dumps({'sourceSHA256':before,'binarySHA256':sha(binary)},indent=2)+'\n')
if '--compile-only' in sys.argv:print(json.dumps({'compiled':True,'bytes':binary.stat().st_size}));sys.exit(0)
assert json.loads((r/'view-build.json').read_text())=={'sourceSHA256':before,'binarySHA256':sha(binary)}
p=subprocess.run([str(binary),str(r)],capture_output=True,text=True,timeout=100)
(r/'view-test.log').write_text(p.stdout+p.stderr)
if p.returncode:raise RuntimeError(p.stdout+p.stderr)
proof={'exit':p.returncode,'native':json.loads((r/'view-native.json').read_text()),'sourceSHA256':before,'sourcesStable':before=={str(p.relative_to(n)):sha(p)for p in files}}
(r/'view-verification.json').write_text(json.dumps(proof,indent=2)+'\n');assert proof['sourcesStable'];print(json.dumps({'exit':proof['exit'],'checks':proof['native']['checks'],'sourcesStable':True}))
