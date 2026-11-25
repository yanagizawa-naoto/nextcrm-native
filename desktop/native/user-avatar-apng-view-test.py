#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,hashlib
n=Path(__file__).resolve().parent
files=[n/(name+'.swift')for name in ['NativeUserAvatarAnimation','NativeUserAvatarWebPAnimation','NativeUserAvatarAPNGAnimation','NativeUserAvatarWorkerProtocol','NativeUserAvatarWorkerClient','NativeUserAvatarView','NativeUserAvatarAPNGViewTests']]
watched=files+[Path(__file__).resolve(),n/'user-avatar-apng-reference.cjs'];sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:sha(p)for p in watched}
binary=n/'build/NativeUserAvatarAPNGViewTests';result=n/'build/user-avatar-apng-view-native.json';result.unlink(missing_ok=True)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','ImageIO',*map(str,files),'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=60)
proof={'exit':r.returncode,'inputsSHA256':before,'inputsUnchanged':before=={p.name:sha(p)for p in watched},'native':json.loads(result.read_text())if result.exists()else None,'sourceProof':'build/user-avatar-apng-reference.json','sourceProofSHA256':sha(n/'build/user-avatar-apng-reference.json'),'stdout':r.stdout,'stderr':r.stderr}
(n/'build/user-avatar-apng-view-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(r.stdout.strip());print(r.stderr[:1500]);assert r.returncode==0 and proof['inputsUnchanged']
