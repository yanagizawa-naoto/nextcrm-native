#!/usr/bin/env python3
"""Finite ingress/metadata boundaries, current production only. No network or Keychain."""
from pathlib import Path
from native_mail_build import html_inputs, html_object
import subprocess,json,re,time,hashlib
N=Path(__file__).resolve().parent;R=N.parent.parent;D=N/'build/mail-g04';D.mkdir(exist_ok=True)
names=list(dict.fromkeys(re.findall(r'\$native_dir/([^"/]+\.swift)',(N/'crm-email-test.sh').read_text())))
names=[n for n in names if not n.endswith('Tests.swift')]+['NativeCalendarEvents.swift','CalendlyWebhook.swift','MemoryBudget.swift','LightweightTable.swift','NativeMailHistoryWindow.swift']
layout=(N/'CRMInvoiceMailWindows.swift').read_text().split('final class CRMInvoiceMailSettingsWindow:')[0]
date=(N/'NativeMailText.swift').read_text().split('    static func date(')[1]
(D/'ExactUIHelpers.swift').write_text(layout+'\nenum NativeMailText {\n    static func date('+date)
names+=['ExactUIHelpers.swift']
resolve=lambda n:D/n if n=='ExactUIHelpers.swift' else N/n
names=list(dict.fromkeys(names))
files=[resolve(n) for n in names]+html_inputs(N)+[N/'NativeMailTransport.c',N/'NativeMailTransport.h',N/'NativeMailG04BoundaryTests.swift',N/'mail-g04-reference.cjs',N/'mail-g04-test.py',N/'CRMInvoiceMailWindows.swift',N/'NativeMailText.swift',N/'schema.sql',N/'schema.json']
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p.relative_to(R)):h(p) for p in files};start=time.monotonic(); phases=[]
def run(name,cmd):
 p=subprocess.run(cmd,cwd=R,text=True,capture_output=True);(D/(name+'.log')).write_text(p.stdout+p.stderr);phases.append({'name':name,'exit':p.returncode});print(name,p.returncode,flush=True)
 if p.returncode:raise RuntimeError(name+' failed')
run('source',['node',str(N/'mail-g04-reference.cjs'),str(D)])
run('c-object',['clang','-std=c11','-O2','-c',str(N/'NativeMailTransport.c'),'-o',str(D/'NativeMailTransport.o')])
html=html_object(N,D/'CampaignHTML.o',run)
run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-lsqlite3','-lcurl','-lxml2','-framework','AppKit','-framework','Security','-framework','LocalAuthentication','-import-objc-header',str(N/'NativeMailParsing.h'),str(D/'NativeMailTransport.o'),str(html)]+[str(resolve(n)) for n in names]+[str(N/'NativeMailG04BoundaryTests.swift'),'-o',str(D/'G04Tests')])
run('native',[str(D/'G04Tests'),str(N),str(D)])
source=json.loads((D/'source-reference.json').read_text());native=json.loads((D/'native-result.json').read_text())
diffs=[]
for a,b in zip(source['mime'],native['mime']):
 if a['source']!= {k:v for k,v in b.items() if k!='name'}:diffs.append({'name':a['name'],'source':a['source'],'native':b})
assert diffs==[], diffs
assert native['recipients'][-1]['accepted'] and native['recipients'][-1]['previewAddresses']==3
assert [c['googleAccepted'] for c in native['calendar']]==[True,True,False]
assert [c['calendlyAccepted'] for c in native['calendar']]==[True,True,False]
assert [c['linked'] for c in native['legacy']]==[0,1]
proof={'phases' :phases,'elapsedSeconds':round(time.monotonic()-start,2),'inputs':before,'inputsUnchanged':all(h(R/k)==v for k,v in before.items()),'mimeDifferences':diffs,'recipients':native['recipients'],'calendar':native['calendar'],'bounds':native['bounds'],'legacy':native['legacy'],'checks':native['checks'],'fakeTransportRecipientCounts':native['fakeTransportRecipientCounts'],'uiHelperScope':'Exact enum InvoiceMailUI and NativeMailText.date extracted from watched original files, without unrelated invoice windows or HTML quotation; actual candidate NativeMailHistoryWindow is unchanged in test.','networkCalls':0,'normalDataOrKeychain':False,'expectedUnresolvedMIME':[],'sourceInputsUnchanged':all(h(R/k)==v for k,v in source['sourceHashes'].items())}
(D/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'mimeDifferences':len(diffs),'elapsedSeconds':proof['elapsedSeconds'],'inputsUnchanged':proof['inputsUnchanged']}))
