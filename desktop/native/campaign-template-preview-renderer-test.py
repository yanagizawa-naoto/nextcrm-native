#!/usr/bin/env python3
"""Real isolated production WebKit renderer; run preview UI oracle suite first."""
from pathlib import Path
import subprocess,json,hashlib,re,zlib,struct,base64,time
native=Path(__file__).resolve().parent;root=native.parent.parent;output=native/'build/campaign-template-preview'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
ui=json.loads((output/'ui-verification.json').read_text());assert ui['complete'] and ui['documentsSHA256']==sha(output/'documents.json')
assert all(sha(native/p)==h for p,h in ui['sourceSHA256'].items())
assert all(sha(root/p)==h for p,h in ui['originalSourceHashes'].items())
sources=[native/p for p in ['NativeMailHTML.swift','NativeMailHTMLRenderer.swift','NativeCampaignTemplatePreviewRendererTests.swift']]
tracked=sources+[Path(__file__),output/'documents.json',output/'ui-verification.json'];before={str(p.relative_to(native)):sha(p) for p in tracked}
def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',8,8,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes([20,130,190,255])*8)*8))+chunk(b'IEND',b'')
(output/'pixel-base64.txt').write_text(base64.b64encode(png).decode())
start=time.monotonic();complete=False;proof={'productionInputs':True,'sourceSHA256':before,'externalProvidersUsed':False,'remoteContentOptIn':False,'requestCounterInstrumented':False,'normalData':False,'keychain':False}
try:
 binary=output/'NativeCampaignTemplatePreviewRendererTests'
 with (output/'renderer-compile.log').open('w') as log:subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','WebKit',*map(str,sources),'-o',str(binary)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
 result=subprocess.run([str(binary),str(output)],capture_output=True,text=True,timeout=150);(output/'renderer-run.log').write_text(result.stdout+result.stderr);result.check_returncode()
 proof.update(exit=result.returncode,stdout=result.stdout,checks=int(re.search(r': (\d+) checks passed',result.stdout)[1]),binarySHA256=sha(binary));assert proof['checks']==26;complete=True
finally:
 proof['sourceHashesStable']=all(sha(native/p)==h for p,h in before.items());proof['complete']=complete and proof['sourceHashesStable'];proof['elapsedSeconds']=round(time.monotonic()-start,2)
 (output/'renderer-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof.get(k) for k in ['complete','checks','sourceHashesStable','elapsedSeconds']}));assert proof['complete']
