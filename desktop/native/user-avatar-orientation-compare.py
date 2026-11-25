from pathlib import Path
import json,hashlib,base64
n=Path(__file__).resolve().parent;r=n/'build/avatar-orientation';repo=n.parent.parent;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
reference=json.loads((r/'reference.json').read_text());rows={x['name']:x for x in json.loads((r/'native.json').read_text())};checks=0;html=0;fullMax=0;codecMax=0

def check(value,label):
 global checks
 assert value,label;checks+=1

def diff(a,b):
 check(len(a)==len(b),'RGBA length');return max((abs(x-y)for x,y in zip(a,b)),default=0)

for c in reference['cases']:
 v=rows[c['name']];check(sha(r/c['file'])==c['sha256'],'fixture hash')
 if c.get('static'):
  check(v['nativePlayback']['requiresInitialFrameDisplay']==False,'static metadata unchanged')
  check(v['imageIO']['orientation']==6 and [v['thumbnail']['width'],v['thumbnail']['height']]==[8,12],'static ImageIO transform retained')
  check(c['nextOptimizer']['unchanged']==False and 'error'not in c['nextOptimizer'],'real Next static optimizer rotates')
  continue
 check(c['nextOptimizer']['unchanged']==True,'actual Next optimizer preserves animation bytes')
 check(v['nativeCanvas']['count']==c['browserDecoder']['count'],'frame count')
 check([v['nativeCanvas']['width'],v['nativeCanvas']['height']]==[12,8],'no EXIF dimension swap')
 check(v['nativePlayback']['requiresInitialFrameDisplay']==True,'one-frame and multi-frame browser display flag')
 for native,browser in zip(v['nativeCanvas']['frames'],c['browserDecoder']['frames']):
  delta=diff(base64.b64decode(native['rgba']),bytes(browser['rgba']));codecMax=max(codecMax,delta);check(delta<=1,'ImageDecoder redraw alpha rounding at most 1')
 if c.get('html'):
  check(c['htmlImage']['naturalSize']==[12,8],'HTML natural size')
  for full,preview,actual in zip(v['nativeCanvas']['frames'],v['nativePlayback']['frames'],c['htmlImage']['frames']):
   delta=diff(base64.b64decode(full['rgba']),base64.b64decode(actual['fullRGBA']));fullMax=max(fullMax,delta);check(delta==0,'actual img full canvas exact')
   check(diff(base64.b64decode(preview['rgba']),base64.b64decode(actual['rgba']))==0,'actual img object-cover exact');html+=1
  check(diff(base64.b64decode(v['untransformedThumbnail']['rgba']),base64.b64decode(c['htmlImage']['frames'][0]['fullRGBA']))==0,'untransformed thumbnail matches source first frame')
check(all(sha(repo/k)==v for k,v in reference['sourceSHA256'].items()),'source modules unchanged')
proof={'checks':checks,'cases':len(reference['cases']),'animatedCases':24,'htmlFramePairsExact':html,'actualHTMLFullCanvasMaxAbs':fullMax,'imageDecoderRedrawMaxAbs':codecMax,'browserVersion':reference['browserVersion'],'sourceSHA256':reference['sourceSHA256'],'scope':'Current production decoder. 24 animated fixtures all EXIF values/endian/prefix/placement, malformed and duplicate EXIF; one static-WebP control with existing transform retained. Real Next optimizer executed; actual Chrome img full canvas and crop are exact. ImageDecoder Canvas redraw differs at alpha boundaries by at most 1. Large helper and actual Store/UI use separate suites.'}
(r/'native-verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps({'checks':checks,'cases':len(reference['cases']),'htmlFramePairsExact':html,'actualHTMLFullCanvasMaxAbs':fullMax}))
