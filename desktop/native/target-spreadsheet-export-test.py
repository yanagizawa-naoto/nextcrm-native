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
out = N/'build'/('target-spreadsheet-export-'+stamp+'-'+str(os.getpid()))
out.mkdir(parents=True)
names = ['NativeTargetSpreadsheetExport', 'NativeTargetSpreadsheetExportTests']
sources = [N/(name+'.swift') for name in names]
watched = sources + [Path(__file__).resolve()] + [N/'target-spreadsheet-export-reference.cjs',R/'lib/spreadsheet/export-targets.ts',R/'lib/spreadsheet/target-fields.ts',R/'pnpm-lock.yaml']+[R/'node_modules'/name/'package.json' for name in ['exceljs','papaparse','typescript']]
before = {str(p.relative_to(R)):sha(p) for p in watched}
proof = {'complete':False,'scope':'Streaming CSV/XLSX codec only: native43, actual source common output/294 roundtrip cells, 10000 rows and 1100000 UTF-16-unit cell. Selection/auth/UI/publication are separate callers. Buffer counters are not process peak.','sourceSHA256':before,'productionDirect':True,'candidateFallback':False,'phases':[],'network':False,'keychain':False,'normalData':False}
def run(label, args, timeout=300):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=R, umask=0o077)
    log = out/(label+'.log'); log.write_text(result.stdout+result.stderr)
    proof['phases'].append({'name':label,'exit':result.returncode,'logSHA256':sha(log)})
    if result.returncode: raise RuntimeError(label+' failed; see '+str(log))
    return result.stdout
def fixture_inventory(root):
    return {str(p.relative_to(root)):{'bytes':p.stat().st_size,'SHA256':sha(p)} for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
try:
    with tempfile.TemporaryDirectory(prefix='NextCRMExportCodec-') as temporary:
        fixture=Path(temporary).resolve()
        run('oracle',['node',str(N/'target-spreadsheet-export-reference.cjs'),str(fixture)])
        run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-module-cache-path',str(out/'module-cache'),*map(str,sources),'-o',str(out/'Tests')])
        proof.update(json.loads(run('native',[str(out/'Tests'),str(fixture)])))
        proof['roundtrip']=json.loads(run('roundtrip',['node',str(N/'target-spreadsheet-export-reference.cjs'),str(fixture),'verify']))
        assert proof['checks']==43 and proof['roundtrip']['roundTripCells']==294 and proof['roundtrip']['scaleRows']==10000 and proof['roundtrip']['largeCellCharacters']==1100000
        proof['fixtureFilesRemoved']=fixture_inventory(fixture)
        proof['fixtureBytesRemoved']=sum(x['bytes'] for x in proof['fixtureFilesRemoved'].values())
    proof['temporaryFixtureRemoved']=not fixture.exists();proof['binarySHA256']=sha(out/'Tests')
    proof['intentionalCorrections']=proof['roundtrip']['intentionalCorrections']
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
    (N/'build'/'target-spreadsheet-export-latest.json').write_text(json.dumps({'verification':str(evidence),'SHA256':sha(evidence),'complete':proof['complete']},indent=2)+'\n')
    print(json.dumps({k:proof[k] for k in ['complete','checks','sourceCases','seconds','retainedBytes','error'] if k in proof},ensure_ascii=False))
sys.exit(0 if proof['complete'] else 1)
