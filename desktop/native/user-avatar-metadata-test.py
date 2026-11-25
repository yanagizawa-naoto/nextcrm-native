#!/usr/bin/env python3
from pathlib import Path
import struct,subprocess,json,hashlib,re,sys
n=Path(__file__).resolve().parent
files=[n/'NativeUserAvatarAnimation.swift',n/'NativeUserAvatarWebPAnimation.swift',n/'NativeUserAvatarAPNGAnimation.swift',n/'NativeUserAvatarMetadataTests.swift',Path(__file__).resolve(),n/'user-avatar-gif-loop-reference.cjs']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:sha(p)for p in files}
gif='--gif' in sys.argv;suffix='-gif' if gif else '';extension='gif' if gif else 'webp'
if gif:
 raw=(n/'build/avatar-animation/gif-maxframes.gif').read_bytes();p=13+(3*(1<<((raw[10]&7)+1)) if raw[10]&128 else 0);header=raw[:p];first=p
 def blocks(p):
  while raw[p]:p+=1+raw[p]
  return p+1
 while raw[p]==0x21:p=blocks(p+2)
 assert raw[p]==0x2c
 p+=10+(3*(1<<((raw[p+9]&7)+1)) if raw[p+9]&128 else 0);p=blocks(p+1);frame=raw[first:p];count=(4194304-len(header)-1)//len(frame);data=header+frame*count+b'\x3b';data+=bytes(4194304-len(data))
else:
 raw=(n/'build/avatar-animation/webp-maxframes.webp').read_bytes();chunks={};p=12
 while p<len(raw):
  tag=raw[p:p+4];length=struct.unpack_from('<I',raw,p+4)[0];chunks.setdefault(tag,raw[p:p+8+length+length%2]);p+=8+length+length%2
 header=chunks[b'VP8X']+chunks[b'ANIM'];frame=chunks[b'ANMF'];count=(4194304-12-len(header)-8)//len(frame);body=header+frame*count;pad=4194304-12-len(body)-8;body+=b'JUNK'+struct.pack('<I',pad)+bytes(pad);data=b'RIFF'+struct.pack('<I',4+len(body))+b'WEBP'+body
fixture=n/('build/avatar-metadata-max.'+extension);fixture.write_bytes(data);assert len(data)==4194304
binary=n/'build/NativeUserAvatarMetadataTests';result_path=n/('build/user-avatar-metadata-native'+suffix+'.json');result_path.unlink(missing_ok=True)
try:
 subprocess.run(['node',str(n/'user-avatar-gif-loop-reference.cjs')],check=True,cwd=n.parent.parent,stdout=subprocess.DEVNULL)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','CoreGraphics','-framework','ImageIO',*map(str,files[:4]),'-o',str(binary)],check=True)
 oracle=json.loads(subprocess.check_output(['node','-e',"require('sharp')(process.argv[1],{animated:true}).metadata().then(m=>console.log(JSON.stringify({frames:m.pages,loop:m.loop})))",str(fixture)],text=True,cwd=n.parent.parent))
 r=subprocess.run(['/usr/bin/time','-l',str(binary),str(fixture),str(count),str(n)],capture_output=True,text=True,timeout=120)
 proof={'exit':r.returncode,'completed':result_path.exists(),'inputsSHA256':before,'inputsUnchanged':before=={p.name:sha(p)for p in files},'fixtureBytes':len(data),'fixtureSHA256':hashlib.sha256(data).hexdigest(),'expectedFrames':count,'sourceMetadata':oracle,'browserLoops':json.loads((n/'build/user-avatar-gif-loop-reference.json').read_text())['cases'],'native':json.loads(result_path.read_text()) if result_path.exists() else None,'stdout':r.stdout,'stderr':r.stderr,'peakPhysicalFootprint':int(re.search(r'(\d+)\s+peak memory footprint',r.stderr)[1]),'peakResident':int(re.search(r'(\d+)\s+maximum resident set size',r.stderr)[1]),'temporaryFixtureRemoved':True}
 (n/('build/user-avatar-metadata-verification'+suffix+'.json')).write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:proof[k]for k in ['exit','completed','inputsUnchanged','expectedFrames','peakPhysicalFootprint']}));print(r.stdout.strip())
 if r.returncode:print(r.stderr[:3000])
 assert r.returncode==0 and proof['completed'] and proof['inputsUnchanged'] and count==oracle['frames']
finally:fixture.unlink(missing_ok=True)
