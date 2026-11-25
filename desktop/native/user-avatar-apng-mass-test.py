#!/usr/bin/env python3
from pathlib import Path
import struct,zlib,subprocess,json,hashlib,re
n=Path(__file__).resolve().parent
sources=[n/'NativeUserAvatarAPNGAnimation.swift',n/'NativeUserAvatarAPNGMassTests.swift',n/'user-avatar-apng-mass-reference.cjs',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:sha(p)for p in sources}
def chunk(tag,b):return struct.pack('>I',len(b))+tag+b+struct.pack('>I',zlib.crc32(tag+b))
raw=(n/'build/avatar-apng/once.png').read_bytes();p=8;parts={}
while p<len(raw):
 length=struct.unpack_from('>I',raw,p)[0];parts.setdefault(raw[p+4:p+8],raw[p+8:p+8+length]);p+=length+12
payload=parts[b'IDAT'];control=bytearray(parts[b'fcTL']);control[20:24]=struct.pack('>HH',2,100)
header=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',parts[b'IHDR']);first=38+len(payload)+12;subsequent=38+len(payload)+16;count=1+(4194304-len(header)-20-first-24)//subsequent
data=bytearray(header+chunk(b'acTL',struct.pack('>II',count,1)));seq=0
for i in range(count):
 control[:4]=struct.pack('>I',seq);seq+=1;data+=chunk(b'fcTL',bytes(control))
 if i==0:data+=chunk(b'IDAT',payload)
 else:data+=chunk(b'fdAT',struct.pack('>I',seq)+payload);seq+=1
data+=chunk(b'npAD',bytes(4194304-len(data)-24))+chunk(b'IEND',b'');assert len(data)==4194304
fixture=n/'build/avatar-apng-mass.png';fixture.write_bytes(data);binary=n/'build/NativeUserAvatarAPNGMassTests';result=n/'build/user-avatar-apng-mass-native.json';result.unlink(missing_ok=True)
try:
 subprocess.run(['node',str(sources[2]),str(fixture)],check=True,cwd=n.parent.parent)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO',*map(str,sources[:2]),'-o',str(binary)],check=True)
 r=subprocess.run(['/usr/bin/time','-l',str(binary),str(fixture),str(n),str(count)],capture_output=True,text=True,timeout=120);source=json.loads((n/'build/user-avatar-apng-mass-reference.json').read_text())
 proof={'exit':r.returncode,'inputsSHA256':before,'inputsUnchanged':before=={p.name:sha(p)for p in sources},'native':json.loads(result.read_text())if result.exists()else None,'source':source,'fixtureBytes':len(data),'fixtureSHA256':hashlib.sha256(data).hexdigest(),'expectedFrames':count,'stdout':r.stdout,'stderr':r.stderr,'peakPhysicalFootprint':int(re.search(r'(\d+)\s+peak memory footprint',r.stderr)[1]),'temporaryFixtureRemoved':True}
 (n/'build/user-avatar-apng-mass-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(r.stdout.strip());print(json.dumps({'exit':r.returncode,'stable':proof['inputsUnchanged'],'peak':proof['peakPhysicalFootprint']}));assert r.returncode==0 and proof['inputsUnchanged'] and source['frames']==count and source['sha256']==proof['fixtureSHA256']
finally:fixture.unlink(missing_ok=True)
