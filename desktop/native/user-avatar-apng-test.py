#!/usr/bin/env python3
from pathlib import Path
import struct,zlib,subprocess,json,hashlib
n=Path(__file__).resolve().parent
sources=[n/'NativeUserAvatarAPNGAnimation.swift',n/'NativeUserAvatarAPNGTests.swift',n/'user-avatar-apng-reference.cjs',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:sha(p)for p in sources}
subprocess.run(['node',str(sources[2])],check=True,cwd=n.parent.parent)
def chunks(raw):
 p=8;out=[]
 while p<len(raw):
  length=struct.unpack_from('>I',raw,p)[0];out.append((raw[p+4:p+8],raw[p+8:p+8+length]));p+=length+12
 return out
def encode(parts):return b'\x89PNG\r\n\x1a\n'+b''.join(struct.pack('>I',len(b))+tag+b+struct.pack('>I',zlib.crc32(tag+b))for tag,b in parts)
raw=(n/'build/avatar-apng/once.png').read_bytes();base=chunks(raw);invalid={};directory=n/'build/avatar-apng-invalid';directory.mkdir(exist_ok=True)
for p in directory.glob('*.png'):p.unlink()
def mutate(name,tag,position,replace,occurrence=0):
 items=list(base);indices=[i for i,(t,b)in enumerate(items)if t==tag];i=indices[occurrence];b=bytearray(items[i][1]);b[position:position+len(replace)]=replace;items[i]=(tag,bytes(b));invalid[name]=encode(items)
mutate('sequence-gap',b'fcTL',0,struct.pack('>I',9),1);mutate('frame-count',b'acTL',0,struct.pack('>I',99));mutate('zero-frame-count',b'acTL',0,bytes(4));mutate('dispose',b'fcTL',24,b'\x03');mutate('blend',b'fcTL',25,b'\x02');mutate('default-offset',b'fcTL',12,struct.pack('>I',1));mutate('outside-canvas',b'fcTL',4,struct.pack('>I',7),1);mutate('zero-width',b'fcTL',4,bytes(4));mutate('bad-depth',b'IHDR',8,b'\x03');mutate('oversize-canvas',b'IHDR',0,struct.pack('>I',1025));mutate('corrupt-pixels',b'IDAT',0,b'\x00')
for name,decoded in [('expanded-payload',bytes(8*1024*1024)),('wrong-filter',bytes([5])+bytes(99)),('short-pixels',bytes(3))]:
 items=[(tag,zlib.compress(decoded)if tag==b'IDAT' else data)for tag,data in base];invalid[name]=encode(items)
invalid['expanded-profile']=encode([base[0],(b'iCCP',b'Profile\0\0'+zlib.compress(bytes(4194305))),*base[1:]])
invalid['crc']=raw[:-1]+bytes([raw[-1]^1]);invalid['duplicate-header']=encode([base[0],*base]);invalid['duplicate-actl']=encode([base[0],base[1],*base[1:]]);invalid['no-iend']=encode(base[:-1]);invalid['unknown-critical']=encode([*base[:-1],(b'ABCD',b''),base[-1]]);invalid['missing-frame-data']=encode([p for i,p in enumerate(base)if i!=next(i for i,p in enumerate(base)if p[0]==b'fdAT')]);invalid['static-png']=encode([p for p in base if p[0]not in [b'acTL',b'fcTL',b'fdAT']]);invalid['missing-palette']=encode([p for p in chunks((n/'build/avatar-apng/palette2.png').read_bytes())if p[0]!=b'PLTE']);invalid['input-too-large']=raw+bytes(4194305-len(raw))
for name,data in invalid.items():(directory/(name+'.png')).write_bytes(data)
binary=n/'build/NativeUserAvatarAPNGTests';result=n/'build/user-avatar-apng-native.json';result.unlink(missing_ok=True)
try:
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO',*map(str,sources[:2]),'-o',str(binary)],check=True)
 r=subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=120)
 proof={'exit':r.returncode,'inputsSHA256':before,'inputsUnchanged':before=={p.name:sha(p)for p in sources},'invalidCases':len(invalid),'native':json.loads(result.read_text())if result.exists()else None,'source':json.loads((n/'build/user-avatar-apng-reference.json').read_text()),'stdout':r.stdout,'stderr':r.stderr,'largeInvalidFixtureRemoved':True}
 (n/'build/user-avatar-apng-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(r.stdout[:3000]);print(r.stderr[:1500]);assert r.returncode==0 and proof['inputsUnchanged']
finally:(directory/'input-too-large.png').unlink(missing_ok=True)
