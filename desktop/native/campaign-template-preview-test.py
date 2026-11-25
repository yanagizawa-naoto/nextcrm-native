#!/usr/bin/env python3
"""Focused production template preview UI with fake viewer and original render oracle."""
from pathlib import Path
import subprocess,json,hashlib,re,time
native=Path(__file__).resolve().parent;root=native.parent.parent
output=native/'build/campaign-template-preview';output.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources=[native/x for x in re.findall(r'"\$native_dir/([^"\n]+\.swift)"',(native/'templates-test.sh').read_text()) if x!='CampaignTemplatesTests.swift']
sources += [native/x for x in ['MemoryBudget.swift','NativeEmbeddingVector.swift','NativeEmbeddingClient.swift','NativeAICredentials.swift','CampaignAI.swift','CRMCampaignDraft.swift','CampaignWorkflow.swift','CRMCampaigns.swift','CampaignRichText.swift','CampaignHTML.swift','NativeMailHTML.swift','CampaignTemplatePreview.swift','CampaignTemplateEditor.swift','NativeCampaignTemplatePreviewTests.swift']]
# AI credential hold logic is now a production dependency after the combined promotion.
sources += [native/'NativeUserCredentialCleanup.swift']
sources=list(dict.fromkeys(sources))
tracked=sources+[native/'templates-test.sh',native/'CampaignHTML.c',native/'CampaignHTML.h',native/'CampaignHTMLEntities.inc',native/'campaign-template-preview-reference.cjs',Path(__file__),native/'schema.json',native/'schema.sql']
before={str(p.relative_to(native)):sha(p) for p in tracked};start=time.monotonic();complete=False
proof={'productionInputs':True,'sourceSHA256':before,'normalData':False,'keychain':False,'externalProvidersUsed':False,'remoteContentOptIn':False,'requestCounterInstrumented':False,'viewer':'fake only; actual process join has a separate runner'}
def run(command,log,timeout=300):
 result=subprocess.run(list(map(str,command)),cwd=root,capture_output=True,text=True,timeout=timeout)
 (output/log).write_text(result.stdout+result.stderr);result.check_returncode();return result.stdout
try:
 proof['oracle']=run(['node',native/'campaign-template-preview-reference.cjs',output],'oracle.log')
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 run(['xcrun','clang','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-I',sdk+'/usr/include/libxml2','-c',native/'CampaignHTML.c','-o',output/'CampaignHTML.o'],'c-compile.log')
 binary=output/'NativeCampaignTemplatePreviewTests'
 flags=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-lxml2','-import-objc-header',native/'CampaignHTML.h',output/'CampaignHTML.o']
 run(flags+sources+['-o',binary],'compile.log')
 proof['stdout']=run([binary,native,output],'run.log',120);proof['checks']=int(re.search(r': (\d+) checks passed',proof['stdout'])[1]);assert proof['checks']==41
 proof['binarySHA256']=sha(binary);proof['documentsSHA256']=sha(output/'documents.json')
 proof['originalSourceHashes']=json.loads((output/'reference.json').read_text())['sourceHashes'];assert all(sha(root/p)==h for p,h in proof['originalSourceHashes'].items())
 complete=True
finally:
 proof['sourceHashesStable']=all(sha(native/p)==h for p,h in before.items());proof['complete']=complete and proof['sourceHashesStable'];proof['elapsedSeconds']=round(time.monotonic()-start,2)
 (output/'ui-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof.get(k) for k in ['complete','checks','sourceHashesStable','elapsedSeconds']}));assert proof['complete']
