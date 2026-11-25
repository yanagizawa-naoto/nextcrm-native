#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,struct,subprocess,re
n=Path(__file__).resolve().parent;files=[n/'NativeUserAvatarStreamingPrototype.swift',n/'NativeUserAvatarIndexBench.swift',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={p.name:sha(p)for p in files}
source=(n/'build/avatar-streaming/webp-1001.webp').read_bytes();chunks={};p=12
while p<len(source):
 tag=source[p:p+4];length=struct.unpack_from('<I',source,p+4)[0];chunks.setdefault(tag,source[p:p+8+length+length%2]);p+=8+length+length%2
header=chunks[b'VP8X']+chunks[b'ANIM'];frame=chunks[b'ANMF'];count=(4194304-12-len(header)-8)//len(frame);body=header+frame*count;padding=4194304-12-len(body)-8;body+=b'JUNK'+struct.pack('<I',padding)+bytes(padding)
data=b'RIFF'+struct.pack('<I',4+len(body))+b'WEBP'+body;assert len(data)==4194304
fixture=n/'build/avatar-streaming/max-index.webp';fixture.write_bytes(data)
binary=n/'build/NativeUserAvatarIndexBench'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','ImageIO','-framework','CoreGraphics',str(files[0]),str(files[1]),'-o',str(binary)],check=True)
try:
 source_result=subprocess.check_output(['node','-e',"require('sharp')(process.argv[1],{animated:true}).metadata().then(m=>console.log(JSON.stringify({pages:m.pages,width:m.width,pageHeight:m.pageHeight})))",str(fixture)],text=True,cwd=n.parent.parent);oracle=json.loads(source_result)
 r=subprocess.run(['/usr/bin/time','-l',str(binary),str(fixture)],capture_output=True,text=True,timeout=60)
 result=json.loads(r.stdout) if r.returncode==0 else None
 proof={'exit':r.returncode,'inputsSHA256':before,'inputsUnchanged':before=={p.name:sha(p)for p in files},'expectedFrames':count,'sourceMetadata':oracle,'fixtureSHA256':hashlib.sha256(data).hexdigest(),'native':result,'peakPhysicalFootprint':int(re.search(r'(\d+)\s+peak memory footprint',r.stderr)[1]),'peakResident':int(re.search(r'(\d+)\s+maximum resident set size',r.stderr)[1]),'temporaryBytesRemoved':len(data),'scope':'Actual maximum-size 4 MiB RIFF with repeated valid opaque 2px ANMF chunks and bounded JUNK padding; all descriptors scanned twice, last frame decoded, not timed playback of every frame.'}
 (n/'build/user-avatar-index-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps(proof))
 assert r.returncode==0 and proof['inputsUnchanged'] and result['frames']==count==oracle['pages'] and result['lastRGBA']==[255,0,0,255]*4
finally:fixture.unlink(missing_ok=True)
