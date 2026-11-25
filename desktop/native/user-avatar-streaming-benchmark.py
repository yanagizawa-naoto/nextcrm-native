#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,hashlib,re,base64,time,platform
n=Path(__file__).resolve().parent
names=['NativeUserAvatarStreamingPrototype.swift','NativeUserAvatarStreamingBench.swift','user-avatar-streaming-reference.cjs','user-avatar-streaming-benchmark.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={p:sha(n/p) for p in names}
subprocess.run(['node','--expose-gc',str(n/'user-avatar-streaming-reference.cjs')],check=True,cwd=n.parent.parent,stdout=subprocess.DEVNULL)
binary=n/'build/NativeUserAvatarStreamingBench'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','ImageIO','-framework','CoreGraphics',str(n/names[0]),str(n/names[1]),'-o',str(binary)],check=True)
ref=json.loads((n/'build/user-avatar-streaming-reference.json').read_text());results=[];comparison=[];failures=[];checks=0
temp=n/'build/avatar-streaming/exact-4m.webp';source=next(c for c in ref['cases'] if c['name']=='webp-1001');temp.write_bytes((n/source['file']).read_bytes()+bytes(4*1024*1024-source['bytes']))
cases=ref['cases']+[dict(source,name='webp-exact-4m',file=str(temp.relative_to(n)),bytes=temp.stat().st_size)]
raw_previews={}
def diff(a,b):
    if len(a)!=len(b):return {'sameLength':False,'left':len(a),'right':len(b)}
    delta=[abs(x-y) for x,y in zip(a,b)];return {'sameLength':True,'differentBytes':sum(x!=0 for x in delta),'maxAbs':max(delta,default=0),'meanAbs':sum(delta)/max(1,len(delta))}
try:
 for c in cases:
  modes=['gif'] if c['format']=='gif' else (['ram','ram-browser'] if c.get('orientation') else ['ram','disk-cg','disk-area'])
  if c['name'] in ['webp-16mp','webp-alpha']:modes.append('disk-cg-uncached')
  if c['name']=='webp-exact-4m':modes=['disk-area']
  for mode in modes:
   start=time.monotonic();r=subprocess.run(['/usr/bin/time','-l',str(binary),str(n/c['file']),mode],text=True,capture_output=True,timeout=120)
   if r.returncode:failures.append({'name':c['name'],'mode':mode,'exit':r.returncode,'error':r.stderr[:600]});continue
   v=json.loads(r.stdout);v['name']=c['name'];v['inputBytes']=c['bytes'];v['peakPhysicalFootprint']=int(re.search(r'(\d+)\s+peak memory footprint',r.stderr)[1]);v['peakResident']=int(re.search(r'(\d+)\s+maximum resident set size',r.stderr)[1]);v['elapsed']=time.monotonic()-start
   checks+=1
   if v['count']!=c['frames']:failures.append({'name':c['name'],'mode':mode,'frameCount':v['count'],'expected':c['frames']})
   reference={x['index']:x for x in c['checks']}
   for frame in v['frames']:
    preview=base64.b64decode(frame.pop('preview'));raw_previews[(c['name'],mode,frame['index'])]=preview;expected=reference[frame['index']]
    if c['format']=='webp' or c['width']<=256:
     checks+=1;frame['fullCanvasExact']=frame['sha256']==expected['sha256']
     if not frame['fullCanvasExact']:
      failures.append({'name':c['name'],'mode':mode,'frame':frame['index'],'fullCanvasHashMismatch':True})
    if c.get('orientation') and frame['index']==0:
     target=base64.b64decode(c['browserDisplay'] if mode=='ram-browser' else c['display']);d=diff(preview,target);frame['orientationDifference']=d;checks+=1
     if d.get('maxAbs',999)!=0:failures.append({'name':c['name'],'mode':mode,'orientation':d})
   results.append(v)
 for c in cases:
  if c['format']!='webp' or c.get('orientation') or c['name']=='webp-exact-4m':continue
  for f in c['checks']:
   key=(c['name'],'ram',f['index'])
   if key not in raw_previews:continue
   for mode in ['disk-cg','disk-area','disk-cg-uncached']:
    other=(c['name'],mode,f['index'])
    if other in raw_previews:
     d=diff(raw_previews[key],raw_previews[other]);comparison.append({'name':c['name'],'mode':mode,'frame':f['index'],**d})
     if mode.startswith('disk-cg') and d.get('maxAbs',999)!=0:failures.append({'name':c['name'],'mode':mode,'previewDifference':d})
finally:
 temporary_bytes=temp.stat().st_size if temp.exists() else 0;temp.unlink(missing_ok=True)
stable=before=={p:sha(n/p) for p in names}
proof={'inputsSHA256':before,'inputsUnchanged':stable,'macOS':platform.mac_ver()[0],'checks':checks,'failures':failures,'results':results,'previewComparisons':comparison,'browserOrientation':ref['browserCases'],'temporaryFixtureBytesRemoved':temporary_bytes,'canvasTempFiles':'mkstemp 0600, unlinked immediately; fd closed at process exit, max logical canvas64MiB; no paths survive','scope':'Independent prototype, not production integration. Per-run separate process; source count/compose SHA versus locked sharp. Disk-area resampling is a deliberate filter difference measured separately. No external data, dependencies, ordinary app or shared production changes.'}
(n/'build/user-avatar-streaming-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'runs':len(results),'checks':checks,'failures':len(failures),'stable':stable,'temporaryBytesRemoved':temporary_bytes,'large':[{k:v[k] for k in ['name','mode','totalSeconds','peakPhysicalFootprint','peakResident','readBytes','writeBytes']}for v in results if '16mp' in v['name']]},ensure_ascii=False))
if failures:print(json.dumps(failures[:8],ensure_ascii=False))
assert not failures and stable
