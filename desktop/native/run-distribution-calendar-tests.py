#!/usr/bin/env python3
"""Link finite SQL/UI tests against an already built, fixed app test module.

The coordinator builds the module once with -enable-testing, RESTORE_APP_HOST,
and PERSONAL_APP_HOST. This runner does not compile or modify application code.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,shutil,subprocess,tempfile,time
NATIVE=Path(__file__).resolve().parent

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--core-dir',type=Path,required=True);p.add_argument('--module',default='NextCRMDistribution');a=p.parse_args()
    assert re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,80}',a.module)
    core=a.core_dir.resolve();library=core/('lib'+a.module+'.dylib');assert library.is_file()
    original=NATIVE/'tests/distribution/DistributionCalendarTests.swift'
    tracked=[original,Path(__file__),NATIVE/'NativeDistributionConfiguration.swift',NATIVE/'GoogleCalendarCredentials.swift',NATIVE/'GoogleCalendarSettingsWindow.swift',NATIVE/'GoogleCalendarSync.swift',NATIVE/'NativeBridges.h',NATIVE/'NativeMailParsing.h',NATIVE/'schema.json',NATIVE/'schema.sql']
    before={str(x.relative_to(NATIVE)):digest(x) for x in tracked};library_before=digest(library)
    output=NATIVE/'build'/'distribution-calendar-tests'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');output.mkdir(parents=True)
    fixture=Path(tempfile.mkdtemp(prefix='NextCRMDistributionCalendar-')).resolve();cache=output/'module-cache';started=time.monotonic()
    proof={'complete':False,'applicationModuleBuiltByRunner':False,'library':str(library),'librarySHA256':library_before,'inputsSHA256':before,'normalData':False,'realKeychain':False,'externalNetwork':False,'scope':'actual SQL + offscreen AppKit; injected authorization/refresh and memory credentials; not live provider or packaged App validation'}
    try:
        source=output/'Tests.swift';source.write_text(original.read_text().replace('@testable import NextCRMDistribution','@testable import '+a.module,1));binary=output/'Tests'
        command=['swiftc','-swift-version','5','-parse-as-library','-Onone','-target','arm64-apple-macos13.0','-module-cache-path',str(cache),'-I',str(core),'-L',str(core),'-l'+a.module,'-Xlinker','-rpath','-Xlinker',str(core),'-import-objc-header',str(NATIVE/'NativeBridges.h'),'-framework','AppKit','-framework','Security','-framework','CoreText','-framework','LocalAuthentication','-lsqlite3','-lxml2','-lcurl',str(source),'-o',str(binary)]
        (output/'command.json').write_text(json.dumps(command,indent=2)+'\n')
        with (output/'compile.log').open('w') as log:subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT,timeout=240)
        q=lambda x:json.dumps(str(x));home=Path.home();profile=output/'sandbox.sb'
        profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n(allow file-write* (subpath '+q(fixture)+') (subpath '+q(output)+') (literal "/dev/null") (subpath "/dev/fd"))\n(deny file-read* (subpath '+q(home/'Library/Keychains')+') (subpath '+q(home/'Library/Application Support/NextCRMNative')+') (subpath '+q(home/'Library/Application Support/NextCRM')+'))\n(deny mach-lookup (global-name "com.apple.securityd"))\n')
        env={k:v for k,v in os.environ.items() if not k.startswith('NEXTCRM_')};env['TMPDIR']=str(fixture)+os.sep
        run=subprocess.run(['/usr/bin/sandbox-exec','-f',str(profile),str(binary),str(NATIVE),str(fixture)],env=env,text=True,capture_output=True,timeout=90)
        (output/'run.log').write_text(run.stdout+run.stderr);run.check_returncode();print(run.stdout,end='')
        proof['checks']=int(re.search(r'DistributionCalendarTests: (\d+) checks passed',run.stdout)[1])
        assert before=={str(x.relative_to(NATIVE)):digest(x) for x in tracked} and digest(library)==library_before
        proof['complete']=True
    except BaseException as error:
        proof['error']=str(error);raise
    finally:
        shutil.rmtree(fixture);shutil.rmtree(cache,ignore_errors=True)
        proof.update(fixturesRemoved=True,moduleCacheRemoved=True,seconds=round(time.monotonic()-started,2))
        (output/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
        print('Proof:',output/'verification.json')
if __name__=='__main__':main()
