#!/usr/bin/env python3
"""Finite offscreen AppKit + actual CRM routing, reusing the fixed application module."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,shutil,subprocess,tempfile,time
NATIVE=Path(__file__).resolve().parent
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--core-dir',type=Path,required=True);parser.add_argument('--module',default='NextCRMR2Integrated');args=parser.parse_args()
    assert re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,80}',args.module)
    core=args.core_dir.resolve();library=core/('lib'+args.module+'.dylib');assert library.is_file()
    output=NATIVE/'build'/'chatgpt-ui-tests'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');output.mkdir(parents=True)
    tracked=[Path(__file__),NATIVE/'NativeChatGPTUITests.swift',NATIVE/'CampaignAI.swift',NATIVE/'CampaignTemplateEditor.swift',NATIVE/'NativeAISettingsWindow.swift',NATIVE/'NativeConnectionsWindow.swift',NATIVE/'NativeBridges.h',NATIVE/'schema.json',NATIVE/'schema.sql']+[p for p in NATIVE.glob('NativeChatGPT*.swift') if not p.name.endswith('Tests.swift')]
    before={str(p.relative_to(NATIVE)):digest(p) for p in tracked};librarySHA=digest(library);started=time.monotonic()
    fixture=Path(tempfile.mkdtemp(prefix='NextCRMChatGPTUI-')).resolve();cache=output/'module-cache'
    proof={'complete':False,'applicationModuleBuiltByRunner':False,'librarySHA256':librarySHA,'inputsSHA256':before,'scope':'Actual offscreen AppKit, real SQLite CampaignAIService routing, injected provider and in-memory credentials; no live account or Keychain.'}
    try:
        source=output/'Tests.swift';source.write_text((NATIVE/'NativeChatGPTUITests.swift').read_text().replace('@testable import DistributionLoginCore','@testable import '+args.module,1));binary=output/'Tests'
        command=['xcrun','swiftc','-D','CHATGPT_INTEGRATED_TEST','-swift-version','5','-parse-as-library','-Onone','-target','arm64-apple-macos13.0','-module-cache-path',str(cache),'-I',str(core),'-L',str(core),'-l'+args.module,'-Xlinker','-rpath','-Xlinker',str(core),'-import-objc-header',str(NATIVE/'NativeBridges.h'),'-framework','AppKit','-framework','Security','-framework','Network','-framework','LocalAuthentication','-lsqlite3','-lxml2','-lcurl',str(source),'-o',str(binary)]
        (output/'command.json').write_text(json.dumps(command,indent=2)+'\n')
        with (output/'compile.log').open('w') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=240)
        q=lambda x:json.dumps(str(x));home=Path.home();profile=output/'sandbox.sb'
        profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n(allow file-write* (subpath '+q(fixture)+') (subpath '+q(output)+') (literal "/dev/null") (subpath "/dev/fd"))\n(deny file-read* (subpath '+q(home/'Library/Keychains')+') (subpath '+q(home/'Library/Application Support/NextCRMNative')+') (subpath '+q(home/'Library/Application Support/NextCRM')+'))\n(deny mach-lookup (global-name "com.apple.securityd"))\n')
        env={k:v for k,v in os.environ.items() if not k.startswith('NEXTCRM_')};env['TMPDIR']=str(fixture)+os.sep
        result=subprocess.run(['/usr/bin/sandbox-exec','-f',str(profile),str(binary),str(NATIVE),str(fixture),str(output)],env=env,capture_output=True,text=True,timeout=120)
        (output/'run.log').write_text(result.stdout+result.stderr);result.check_returncode()
        proof['checks']=int(re.search(r'NativeChatGPT UI and routing: (\d+) checks passed',result.stdout)[1]);proof['sourceStable']=before=={str(p.relative_to(NATIVE)):digest(p) for p in tracked}
        assert proof['sourceStable'] and digest(library)==librarySHA;proof['complete']=True;print(result.stdout,end='')
    finally:
        shutil.rmtree(fixture);shutil.rmtree(cache,ignore_errors=True);proof.update(seconds=round(time.monotonic()-started,2),fixturesRemoved=True,moduleCacheRemoved=True)
        (output/'verification.json').write_text(json.dumps(proof,indent=2,ensure_ascii=False)+'\n');print('Proof:',output/'verification.json')
if __name__=='__main__':main()
