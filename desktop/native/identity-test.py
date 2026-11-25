#!/usr/bin/env python3
"""Source HTTP endpoint oracle + provider-independent controller/SQLite session proof."""
from pathlib import Path
import hashlib, json, subprocess, sys, time, re

n = Path(__file__).resolve().parent
root = n.parent.parent
build = n / 'build'
build.mkdir(exist_ok=True)
names = ['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeAPITokens','NativeMCPProtocol','NativeMCPInputCatalog','NativeMCPRequestRouter','NativeMCPSessionAuth','NativeIdentity','NativeIdentitySQLite','NativeIdentityTests', 'MailReview']
sources = [n / (name + '.swift') for name in names]
inputs = sources + [n/'schema.json',n/'schema.sql',n/'identity-source-reference.cjs',Path(__file__).resolve()]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before = {str(p.relative_to(root)): sha(p) for p in inputs}
started = time.time()
oracle = build/'identity-source-reference.json'
result = {'sourcesSHA256':before,'phases':[],'externalRequests':0,'sharedProductionChanged':False}
def run(name, args, timeout):
    with (build/('identity-'+name+'.log')).open('w') as log:
        p = subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
    text=(build/('identity-'+name+'.log')).read_text()
    result['phases'].append({'name':name,'exit':p.returncode,'log':str((build/('identity-'+name+'.log')).relative_to(root)),'tail':text[-1800:]})
    if p.returncode:
        print(json.dumps({'phase':name,'exit':p.returncode,'tail':text[-1800:]}),flush=True)
        raise RuntimeError(name+' failed')
    print(json.dumps({'phase':name,'exit':0,'lastLine':text.strip().splitlines()[-1] if text.strip() else ''}),flush=True)
try:
    run('source',['node',str(n/'identity-source-reference.cjs'),str(oracle)],120)
    ref=json.loads(oracle.read_text())
    result.update(sourceCases=len(ref['cases']),sourceSessionCases=len(ref['sessionCases']),sourceAssertions=ref['assertions'],sourceReference=ref['sourceSHA256'],sourceFindings=ref['findings'])
    binary=build/'NativeIdentityTests'
    run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,sources),'-o',str(binary)],900)
    run('native',[str(binary),str(n),str(oracle)],120)
    result['nativeChecks']=int(re.search(r'Native identity: (\d+) checks passed',(build/'identity-native.log').read_text()).group(1))
    result['binaryBytes']=binary.stat().st_size
    result['limits']=['No identity issuer/OTP mail provider/Google exchange/UI/app integration; this is verified-session consumption only.','Provider selected only by composition, not installed or selected by this test.','Original PostgreSQL isolated with explicit Prisma adapter; real SQLite validated.','Existing-native hardening rejects expiry equality and banned cookie users.','Generic remote provider must implement authoritative transaction/fence; no remote deployment assumed.']
finally:
    result['inputsUnchanged']=all(p.exists() and sha(p)==before[str(p.relative_to(root))] for p in inputs)
    result['sourceUnchanged']=all((root/p).exists() and sha(root/p)==h for p,h in result.get('sourceReference',{}).items())
    result['elapsedSeconds']=round(time.time()-started,2)
    result['complete']=result['inputsUnchanged'] and result['sourceUnchanged'] and len(result['phases'])==3 and all(p['exit']==0 for p in result['phases'])
    (build/'identity-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
assert result['complete'], 'Incomplete verification or source drift'
