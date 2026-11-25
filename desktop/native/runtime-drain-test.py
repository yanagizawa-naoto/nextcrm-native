#!/usr/bin/env python3
"""Test production runtime wrappers; --candidate explicitly selects isolated copies."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,time
parser=argparse.ArgumentParser();parser.add_argument('--candidate',action='store_true');options=parser.parse_args()
n=Path(__file__).resolve().parent;root=n.parent.parent;b=n/'build';candidate=b/'runtime-drain-candidate'
names=json.loads((n/'RuntimeDrainSources.json').read_text())
wrappers={'NativeMailRuntime.swift','GoogleCalendarRuntime.swift','CalendlyRuntime.swift'}
sources=[(candidate if options.candidate and name in wrappers else n)/name for name in names]+[n/'NativeRuntimeDrainTests.swift',n/'NativeRuntimeWorkerDrainTests.swift']
assert len(sources)==len(set(sources))
assert all(((candidate if options.candidate else n)/x) in sources for x in wrappers)
inputs=sources+[n/x for x in ['RuntimeDrainSources.json','schema.json','schema.sql','NativeBridges.h','NativePluginsHTTP.h','NativeMailTransport.c','NativeMailTransport.h','CampaignHTML.c','CampaignHTML.h','CampaignHTMLEntities.inc']]+[Path(__file__).resolve()]
if options.candidate:inputs += [n/x for x in sorted(wrappers)]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):sha(p) for p in inputs};phases=[];start=time.time();success=False
result={'candidateOnly':options.candidate,'productionWrappers':not options.candidate,'sourcesSHA256':before,'phases':phases,'ordinaryDataAccess':False,'keychainAccess':False,'externalRequests':0}
output=candidate if options.candidate else b/'runtime-drain-production';output.mkdir(exist_ok=True)
log=b/'runtime-drain-test.log';binary=output/'NativeRuntimeDrainTests';log.write_text('')
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
cflags=['xcrun','clang','-O2','-std=c11','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk]
commands=[('mail-c',cflags+['-c',str(n/'NativeMailTransport.c'),'-o',str(output/'NativeMailTransport.o')]),('html-c',cflags+['-I'+sdk+'/usr/include/libxml2','-c',str(n/'CampaignHTML.c'),'-o',str(output/'CampaignHTML.o')])]
commands += [('compile',['swiftc','-D','RUNTIME_DRAIN_TESTS','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-framework','Network','-lsqlite3','-lxml2','-lcurl','-import-objc-header',str(n/'NativeBridges.h'),str(output/'NativeMailTransport.o'),str(output/'CampaignHTML.o'),*map(str,sources),'-o',str(binary)]),('sqlite-file-drain',[str(binary),str(n)])]
try:
 for name,args in commands:
  with log.open('a') as out:r=subprocess.run(args,stdout=out,stderr=subprocess.STDOUT,timeout=600)
  phases.append({'name':name,'exit':r.returncode});print(json.dumps(phases[-1]),flush=True)
  if r.returncode:raise RuntimeError(log.read_text()[-6000:])
 result['checks']=int(re.search(r'Runtime wrapper drain: (\d+) checks passed',log.read_text()).group(1));result['binaryBytes']=binary.stat().st_size;success=True
finally:
 result['inputsUnchanged']=all(sha(root/p)==h for p,h in before.items());result['elapsedSeconds']=round(time.time()-start,2)
 result['complete']=success and result['inputsUnchanged'];result['runnerExitCode']=0 if result['complete'] else 1
 (b/'runtime-drain-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
assert result['complete'],'Source drift or incomplete checks'
print(json.dumps({'complete':True,'checks':result['checks'],'hashesMatch':True,'elapsedSeconds':result['elapsedSeconds']}))
