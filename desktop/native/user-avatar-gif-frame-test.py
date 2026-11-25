#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,hashlib
n=Path(__file__).resolve().parent
sources=[n/'NativeUserAvatarGIFFramePrototype.swift',n/'NativeUserAvatarGIFFrameTests.swift',n/'user-avatar-gif-frame-reference.cjs',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:sha(p)for p in sources}
raw=(n/'build/avatar-animation/gif-maxframes.gif').read_bytes();p=13+(3*(1<<((raw[10]&7)+1)) if raw[10]&128 else 0);header=raw[:p];first=p
def blocks(p):
 while raw[p]:p+=1+raw[p]
 return p+1
while raw[p]==0x21:p=blocks(p+2)
assert raw[p]==0x2c
p+=10+(3*(1<<((raw[p+9]&7)+1)) if raw[p+9]&128 else 0);p=blocks(p+1);frame=raw[first:p];count=(4194304-len(header)-1)//len(frame);data=header+frame*count+b'\x3b';data+=bytes(4194304-len(data))
fixture=n/'build/avatar-gif-frame-mass.gif';fixture.write_bytes(data);binary=n/'build/NativeUserAvatarGIFFrameTests'
try:
 subprocess.run(['node',str(sources[2])],check=True,cwd=n.parent.parent)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO',*map(str,sources[:2]),'-o',str(binary)],check=True)
 r=subprocess.run([str(binary),str(n),str(fixture)],capture_output=True,text=True,timeout=120)
 proof={'exit':r.returncode,'sourceSHA256':before,'inputsUnchanged':before=={p.name:sha(p)for p in sources},'fixtureBytes':len(data),'fixtureSHA256':hashlib.sha256(data).hexdigest(),'expectedFrames':count,'native':json.loads((n/'build/user-avatar-gif-frame-native.json').read_text()),'reference':json.loads((n/'build/user-avatar-gif-frame-reference.json').read_text()),'stdout':r.stdout,'stderr':r.stderr,'temporaryFixtureRemoved':True}
 (n/'build/user-avatar-gif-frame-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(r.stdout.strip());print(r.stderr[:2000]);assert r.returncode==0 and proof['inputsUnchanged']
finally:fixture.unlink(missing_ok=True)
