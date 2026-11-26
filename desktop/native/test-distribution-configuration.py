#!/usr/bin/env python3
"""Finite public metadata validation; installed Swift SDK only, no network/Keychain."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,re,shutil,subprocess,tempfile,time
NATIVE=Path(__file__).resolve().parent

def main():
    spec=importlib.util.spec_from_file_location('validator',NATIVE/'validate-distribution-configuration.py');validator=importlib.util.module_from_spec(spec);spec.loader.exec_module(validator)
    client='1234567890-synthetic.apps.googleusercontent.com'
    good={'version':1,'google':{'desktopClientID':client}}
    inputs=[({'version':1,'google':None},True,None),(good,True,client),({'version':1.0,'google':None},True,None)]
    for value in [{},[],None,{'version':True,'google':None},{'version':2,'google':None},{'version':1,'google':{}},{'version':1,'google':False},{'version':1,'google':None,'token':'synthetic-no-real-token'},{'version':1,'google':{'desktopClientID':client,'client_secret':'synthetic'}},{'version':1,'google':{'desktopClientID':client,'redirect':'https://example.invalid'}}]:inputs.append((value,False,None))
    for value in ['',None,42,'example.apps.googleusercontent.com',client+'\n',' '+client,client+' ',client+'.evil',client.replace('123','１２３'),'123-😀.apps.googleusercontent.com','123-'+('a'*500)+'.apps.googleusercontent.com']:
        inputs.append(({'version':1,'google':{'desktopClientID':value}},False,None))
    cases=[dict(json=json.dumps(raw,ensure_ascii=False),valid=valid,clientID=expected) for raw,valid,expected in inputs]
    cases += [dict(json='{',valid=False,clientID=None),dict(json=' '*16385,valid=False,clientID=None)]
    for case in cases:
        try:value=validator.validate(case['json'].encode());accepted=True
        except (ValueError,UnicodeError):accepted=False
        assert accepted==case['valid']
    output=NATIVE/'build'/'distribution-configuration-tests'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');output.mkdir(parents=True)
    paths=[NATIVE/'NativeDistributionConfiguration.swift',NATIVE/'tests/distribution/DistributionConfigurationTests.swift',NATIVE/'validate-distribution-configuration.py',Path(__file__)]
    before={str(p.relative_to(NATIVE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    cache=output/'module-cache';fixture=Path(tempfile.mkdtemp(prefix='NextCRMDistributionConfig-')).resolve();start=time.monotonic()
    try:
        casespath=output/'cases.json';casespath.write_text(json.dumps(cases,ensure_ascii=False,indent=2)+'\n')
        binary=output/'DistributionConfigurationTests'
        subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-Onone','-module-cache-path',str(cache),str(paths[0]),str(paths[1]),'-o',str(binary)],check=True)
        q=lambda p:json.dumps(str(p));home=Path.home()
        profile=output/'sandbox.sb';profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n(allow file-write* (subpath '+q(fixture)+') (literal "/dev/null"))\n(deny file-read* (subpath '+q(home/'Library/Keychains')+') (subpath '+q(home/'Library/Application Support/NextCRMNative')+') (subpath '+q(home/'Library/Application Support/NextCRM')+'))\n(deny mach-lookup (global-name "com.apple.securityd"))\n')
        run=subprocess.run(['/usr/bin/sandbox-exec','-f',str(profile),str(binary),str(casespath),str(fixture)],text=True,capture_output=True,timeout=30)
        (output/'run.log').write_text(run.stdout+run.stderr);run.check_returncode();print(run.stdout,end='')
        assert before=={str(p.relative_to(NATIVE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
        proof={'complete':True,'pythonCases':len(cases),'swiftChecks':int(re.search(r'(\d+) checks passed',run.stdout)[1]),'inputsSHA256':before,'seconds':round(time.monotonic()-start,2),'network':False,'realKeychain':False,'normalData':False,'fixtureRemoved':True,'moduleCacheRemoved':True,'scope':'pure metadata + actual Foundation Bundle lookup; Calendar SQL/UI handled by shared module tests'}
        (output/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print('Proof:',output/'verification.json')
    finally:
        shutil.rmtree(fixture);shutil.rmtree(cache,ignore_errors=True)
if __name__=='__main__':main()
