#!/usr/bin/env python3
"""Production-direct focused verification; no candidate fallback or shared C objects."""
from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, sys, tempfile, time
N = Path(__file__).resolve().parent
R = N.parent.parent
os.umask(0o077)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
started = time.monotonic()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
out = N/'build'/('account-case-study-'+stamp+'-'+str(os.getpid()))
out.mkdir(parents=True)
names = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'CRMService', 'NativeAccountCaseStudy', 'NativeAccountCaseStudyWindow', 'NativeAccountCaseStudyTests', 'MailReview']
sources = [N/(name+'.swift') for name in names]
watched = sources + [Path(__file__).resolve()] + [N/'schema.json',N/'schema.sql',N/'account-case-study-reference.cjs',R/'pnpm-lock.yaml',R/'node_modules/typescript/package.json']
before = {str(p.relative_to(R)):sha(p) for p in watched}
proof = {'complete':False,'scope':'Actual original action/auth predicates 43 scenarios and native 477 checks; synthetic session/Prisma adapters, not live BetterAuth/PostgreSQL. CRMService90 remains the existing suite.','sourceSHA256':before,'productionDirect':True,'candidateFallback':False,'phases':[],'network':False,'keychain':False,'normalData':False}
def run(label, args, timeout=300):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=R, umask=0o077)
    log = out/(label+'.log'); log.write_text(result.stdout+result.stderr)
    proof['phases'].append({'name':label,'exit':result.returncode,'logSHA256':sha(log)})
    if result.returncode: raise RuntimeError(label+' failed; see '+str(log))
    return result.stdout
def fixture_inventory(root):
    return {str(p.relative_to(root)):{'bytes':p.stat().st_size,'SHA256':sha(p)} for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
try:
    with tempfile.TemporaryDirectory(prefix='NextCRMCaseStudyReference-') as temporary:
        fixture=Path(temporary).resolve()
        run('oracle',['node',str(N/'account-case-study-reference.cjs'),str(fixture/'reference.json')])
        original=json.loads((fixture/'reference.json').read_text())
        proof['originalSourceHashes']=original['sourceHashes']; proof['sourceCases']=len(original['cases']);proof['oracleLimits']=original['limits']
        assert proof['sourceCases']==43
        run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-module-cache-path',str(out/'module-cache'),'-target','arm64-apple-macos13.0','-framework','AppKit','-lsqlite3',*map(str,sources),'-o',str(out/'Tests')])
        proof.update(json.loads(run('native',[str(out/'Tests'),str(N),str(fixture)],timeout=120)))
        assert proof['checks']==477
        proof['originalHashesMatch']=all(sha(R/name)==value for name,value in original['sourceHashes'].items());assert proof['originalHashesMatch']
        proof['fixtureFilesRemoved']=fixture_inventory(fixture)
    proof['temporaryFixtureRemoved']=not fixture.exists();proof['binarySHA256']=sha(out/'Tests')
    proof['inputsUnchanged'] = before == {str(p.relative_to(R)):sha(p) for p in watched}
    assert proof['inputsUnchanged']
    proof['complete'] = True
except Exception as error:
    proof['complete'] = False
    proof['error'] = str(error)
finally:
    cache=out/'module-cache'
    proof['moduleCacheBytesRemoved']=sum(p.stat().st_size for p in cache.rglob('*') if p.is_file()) if cache.exists() else 0
    if cache.exists(): shutil.rmtree(cache)
    proof['seconds']=round(time.monotonic()-started,2)
    proof['retainedBytes']=sum(p.stat().st_size for p in out.rglob('*') if p.is_file())
    evidence=out/'verification.json'; evidence.write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
    (N/'build'/'account-case-study-latest.json').write_text(json.dumps({'verification':str(evidence),'SHA256':sha(evidence),'complete':proof['complete']},indent=2)+'\n')
    print(json.dumps({k:proof[k] for k in ['complete','checks','sourceCases','seconds','retainedBytes','error'] if k in proof},ensure_ascii=False))
sys.exit(0 if proof['complete'] else 1)
