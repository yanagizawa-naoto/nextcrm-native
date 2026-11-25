#!/usr/bin/env python3
"""Actual private production helper, bounded stdin and process/pipe drain. Uses foreground."""
from pathlib import Path
import subprocess,json,hashlib,plistlib,time,sys
native=Path(__file__).resolve().parent;root=native.parent.parent;output=native/'build/campaign-template-preview'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
ui=json.loads((output/'ui-verification.json').read_text());assert ui['complete'] and ui['documentsSHA256']==sha(output/'documents.json')
assert all(sha(native/p)==h for p,h in ui['sourceSHA256'].items());assert all(sha(root/p)==h for p,h in ui['originalSourceHashes'].items())
app=output/'Preview Session QA.app';contents=app/'Contents';mac=contents/'MacOS';helper=contents/'Helpers/NextCRM Mail Viewer.app';helperMac=helper/'Contents/MacOS'
mac.mkdir(parents=True,exist_ok=True);helperMac.mkdir(parents=True,exist_ok=True)
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.nextcrm.qa.template-preview-session','CFBundleName':'Preview Session QA','CFBundleExecutable':'SessionTests','CFBundlePackageType':'APPL','LSUIElement':True}))
info=plistlib.loads((native/'NativeMailHTML-Info.plist').read_bytes());info['CFBundleIdentifier']='local.nextcrm.qa.template-preview-viewer';(helper/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
source=native/'NativeMailHTML.swift';instrumented=output/'NativeMailHTMLSessionTestInstrumented.swift'
suffix='\nextension NativeMailHTMLSession { var testProcessID:Int32 { process.processIdentifier };var testProcessRunning:Bool { process.isRunning } }\n'
raw=source.read_bytes();instrumented.write_bytes(raw+suffix.encode());assert instrumented.read_bytes()==raw+suffix.encode()
helperSources=[native/p for p in ['NativeMailHTML.swift','NativeMailHTMLRenderer.swift','NativeMailHTMLApp.swift']]
tracked=helperSources+[native/'NativeMailHTML-Info.plist',native/'build-native-mail-html.sh',native/'NativeCampaignTemplatePreviewSessionTests.swift',Path(__file__),output/'documents.json',output/'ui-verification.json']
before={str(p.relative_to(native)):sha(p) for p in tracked};start=time.monotonic();complete=False
proof={'productionInputs':True,'sourceSHA256':before,'normalData':False,'keychain':False,'externalProvidersUsed':False,'remoteContentOptIn':False,'requestCounterInstrumented':False,'instrumentation':'Current production NativeMailHTML.swift exact byte prefix plus read-only test PID/isRunning suffix; no candidate implementation input.','productionPrefixSHA256':sha(source),'productionPrefixBytes':len(raw),'helperScope':'Same existing build-native-mail-html.sh Swift inputs/flags, compiled directly from current production into private QA bundle, with unique test bundle identifier and ad-hoc signature.'}
def run(args,log,timeout=180):
 result=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=timeout);(output/log).write_text(result.stdout+result.stderr);result.check_returncode();return result
try:
 helperBinary=helperMac/'NextCRMMailViewer'
 run(['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','WebKit',*helperSources,'-o',helperBinary],'session-helper-compile.log')
 run(['codesign','--force','--sign','-',helper],'session-helper-sign.log');run(['codesign','--verify','--strict',helper],'session-helper-verify.log')
 binary=mac/'SessionTests';run(['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0',instrumented,native/'NativeCampaignTemplatePreviewSessionTests.swift','-o',binary],'session-compile.log')
 result=run([binary,output,*(['--visual'] if '--visual' in sys.argv else [])],'session-run.log',170)
 proof['results']=json.loads((output/'session-results.json').read_text());assert proof['results']['checks']==10 and proof['results']['allExited']
 proof.update(exit=result.returncode,stdout=result.stdout,binarySHA256=sha(binary),helperBinarySHA256=sha(helperBinary));complete=True
finally:
 proof['sourceHashesStable']=all(sha(native/p)==h for p,h in before.items());proof['productionPrefixUnchanged']=instrumented.read_bytes()==source.read_bytes()+suffix.encode();proof['complete']=complete and proof['sourceHashesStable'] and proof['productionPrefixUnchanged'];proof['elapsedSeconds']=round(time.monotonic()-start,2)
 (output/'session-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'complete':proof['complete'],'checks':proof.get('results',{}).get('checks'),'allOwnedExited':proof.get('results',{}).get('allExited'),'sourceHashesStable':proof['sourceHashesStable']}));assert proof['complete']
