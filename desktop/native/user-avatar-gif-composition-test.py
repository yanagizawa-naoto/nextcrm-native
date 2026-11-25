#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,hashlib
n=Path(__file__).resolve().parent
sources=[n/'NativeUserAvatarAnimation.swift',n/'NativeUserAvatarWebPAnimation.swift',n/'NativeUserAvatarAPNGAnimation.swift',n/'NativeUserAvatarGIFCompositionTests.swift',n/'user-avatar-gif-frame-reference.cjs',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:sha(p)for p in sources};binary=n/'build/NativeUserAvatarGIFCompositionTests'
subprocess.run(['node',str(sources[4])],check=True,cwd=n.parent.parent)
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO',*map(str,sources[:4]),'-o',str(binary)],check=True)
r=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=60)
result=n/'build/user-avatar-gif-composition-native.json';proof={'exit':r.returncode,'inputsSHA256':before,'inputsUnchanged':before=={p.name:sha(p)for p in sources},'native':json.loads(result.read_text())if result.exists()else None,'reference':json.loads((n/'build/user-avatar-gif-frame-reference.json').read_text()),'stdout':r.stdout,'stderr':r.stderr}
(n/'build/user-avatar-gif-composition-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(r.stdout.strip());print(r.stderr[:1000]);assert r.returncode==0 and proof['inputsUnchanged']
