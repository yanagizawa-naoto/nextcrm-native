#!/usr/bin/env python3
"""Installed original formatter + actual native receive/store, with no external I/O."""
from pathlib import Path
import datetime,hashlib,json,re,subprocess,time,os
N=Path(__file__).resolve().parent;R=N.parent.parent
B=N/'build'/'mail-html-text-proof'/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+str(os.getpid()));B.mkdir(parents=True)
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();start=time.monotonic();phases=[]
pure=['NativeMailTemporaryFiles.swift','NativeMail.swift','NativeMailMIME.swift','NativeMailIMAP.swift','NativeMailSpool.swift','NativeMailClient.swift','NativeMailHTMLText.swift','NativeMailMIMESpool.swift','NativeMailTextHTML.swift','NativeMailIMAPFile.swift','NativeMailHTMLTextTests.swift']
store=list(dict.fromkeys(re.findall(r'\$native_dir/([^"/]+\.swift)',(N/'crm-email-test.sh').read_text())))
store=[x for x in store if not x.endswith('Tests.swift')]
store=list(dict.fromkeys(store+['NativeMailHTMLText.swift','NativeMailMIMESpool.swift','NativeMailTextHTML.swift','NativeMailIMAPFile.swift','NativeMailHTMLStoreTests.swift']))
files=list(dict.fromkeys([N/x for x in pure+store+['NativeMailTransport.c','NativeMailTransport.h','CampaignHTML.c','CampaignHTML.h','CampaignHTMLEntities.inc','NativeMailParsing.h','schema.json','schema.sql','crm-email-test.sh','mail-html-text-reference.cjs','mail-html-text-large-reference.cjs','mail-html-text-test.py']]+[R/'pnpm-lock.yaml']))
before={str(p.relative_to(R)):h(p) for p in files}
def run(name,args):
 t=time.monotonic();p=subprocess.run(args,cwd=R,text=True,capture_output=True);(B/(name+'.log')).write_text(p.stdout+p.stderr);phases.append({'name':name,'exit':p.returncode,'seconds':round(time.monotonic()-t,3)})
 if p.returncode: raise RuntimeError(name+': '+str(B/(name+'.log')))
 return p
run('source',['node',str(N/'mail-html-text-reference.cjs'),str(B)])
run('source-large',['node',str(N/'mail-html-text-large-reference.cjs'),str(B)])
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
run('mail-c',['clang','-O2','-c',str(N/'NativeMailTransport.c'),'-o',str(B/'mail.o')])
run('html-c',['clang','-O2','-I'+sdk+'/usr/include/libxml2','-c',str(N/'CampaignHTML.c'),'-o',str(B/'html.o')])
flags=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-lcurl','-lsqlite3','-lxml2','-import-objc-header',str(N/'NativeMailParsing.h'),str(B/'mail.o'),str(B/'html.o')]
run('pure-compile',flags+[str(N/x) for x in pure]+['-o',str(B/'TextTests')])
run('pure',[str(B/'TextTests'),str(B)])
a=json.loads((B/'source-reference.json').read_text());b=json.loads((B/'native-result.json').read_text())
assert len(a['cases'])==len(b['pure'])==len(b['received'])==65
assert all(x['pure']==y.get('text') and (x['text'] or None)==z.get('text') for x,y,z in zip(a['cases'],b['pure'],b['received']))
assert len(a['multipart'])==len(b['multipart'])==6 and all((x['text'] or None)==y.get('text') for x,y in zip(a['multipart'],b['multipart']))
assert b['checks']==8
run('store-compile',flags+['-framework','Security','-framework','LocalAuthentication']+[str(N/x) for x in store]+['-o',str(B/'StoreTests')])
peaks={}
for mode in ['small','large-baseline','large-derived','large-limit']:
 p=run(mode,['/usr/bin/time','-l',str(B/'StoreTests'),str(N),str(B),'--'+mode]);peaks[mode]=int(re.search(r'(\d+)\s+maximum resident set size',p.stderr).group(1))
for native,source in [('large-derived','large-reference'),('large-limit','limit-reference'),('expansion-result','expansion-reference')]:
 x=json.loads((B/(native+'.json')).read_text());y=json.loads((B/(source+'.json')).read_text());assert all(x[k]==y[k] for k in ['htmlBytes','textBytes','htmlSHA256','textSHA256'])
assert all(h(R/k)==v for k,v in before.items()) and all(h(R/k)==v for k,v in a['sourceHashes'].items())
proof={'phases':phases,'inputs':before,'sourceInputs':a['sourceHashes'],'inputsUnchanged':True,'finiteHTMLCases':65,'receivedCases':65,'multipartTextCases':6,'boundaryAndCleanupChecks':b['checks'],'store':json.loads((B/'store-result.json').read_text()),'differences':0,'largeChecks':['4.5MiB HTML exact','8MiB HTML exact','409204B HTML expands to8388680B text exact'],'peakRSSBytes':peaks,'memoryScope':'Isolated test processes: parsing, strings, SQLite, full audit serialization and readback included. Not idle App footprint or a constant-memory claim. One body is expanded; no page/collection batching.','residency':{x:json.loads((B/(x+'.json')).read_text()) for x in ['large-baseline','large-derived','large-limit']},'output':str(B.relative_to(R)),'elapsedSeconds':round(time.monotonic()-start,2),'networkCalls':0,'realKeychain':False,'normalData':False}
(B/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');(N/'build/mail-html-text-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'finiteHTML':65,'receive':65,'multipart':6,'cleanup':b['checks'],'store':proof['store'],'differences':0,'hashesStable':True,'proof':str((B/'verification.json').relative_to(R))},ensure_ascii=False))
