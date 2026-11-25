#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,hashlib,sys
n=Path(__file__).resolve().parent
raw=(n/'build/avatar-animation/gif-maxframes.gif').read_bytes();p=13+(3*(1<<((raw[10]&7)+1)) if raw[10]&128 else 0);header=raw[:p];first=p
def blocks(p):
 while raw[p]:p+=1+raw[p]
 return p+1
while raw[p]==0x21:p=blocks(p+2)
assert raw[p]==0x2c
p+=10+(3*(1<<((raw[p+9]&7)+1)) if raw[p+9]&128 else 0);p=blocks(p+1);frame=raw[first:p];count=(4194304-len(header)-1)//len(frame);data=header+frame*count+b'\x3b';data+=bytes(4194304-len(data))
fixture=n/'build/avatar-gif-retention-probe.gif';fixture.write_bytes(data)
source=n/'NativeUserAvatarGIFRetentionProbe.swift';binary=n/'build/NativeUserAvatarGIFRetentionProbe';results=[]
try:
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO',str(source),'-o',str(binary)],check=True)
 for mode in sys.argv[1:] or ['bare','properties','reset']:
  r=subprocess.run([str(binary),str(fixture),mode,str(count)],capture_output=True,text=True,timeout=120);result=json.loads(r.stdout);results.append(result);print(json.dumps({k:result[k]for k in ['mode','count','seconds','final']}),flush=True)
 proof={'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'fixtureSHA256':hashlib.sha256(data).hexdigest(),'fixtureBytes':len(data),'results':results,'temporaryFixtureRemoved':True}
 (n/'build/user-avatar-gif-retention-probe.json').write_text(json.dumps(proof,indent=2)+'\n')
finally:fixture.unlink(missing_ok=True)
