#!/usr/bin/env python3
"""Original document-format comparison and disposable SVG renderer lifecycle."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,time

n=Path(__file__).resolve().parent;r=n.parent.parent
os.umask(0o077)
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
out=n/'build'/('document-formats-'+stamp+'-'+str(os.getpid()));out.mkdir(parents=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
names=['NativeDatabase.swift','NativeDocumentProcessing.swift','NativeDocumentSVGWorker.swift','NativeDocumentFormatTests.swift','NativeDocumentFormatGuardTests.swift','NativeDocumentSVGFixtureTests.swift','document-format-fixtures.py','document-format-reference.cjs','document-format-test.py']
watched=[n/name for name in names]+[r/'inngest/lib/document-text.ts',r/'inngest/functions/documents/generate-thumbnail.ts',r/'pnpm-lock.yaml']+[r/'node_modules'/name/'package.json' for name in ['sharp','mammoth','typescript']]
before={str(p.relative_to(r)):sha(p) for p in watched}
start=time.monotonic();proof={'complete':False,'productionDirect':True,'sourceSHA256':before,'phases':[],'scope':'Extraction and SVG thumbnail component; source handlers with synthetic object/Prisma adapters; no whole App or Quick Look claim','network':False,'keychain':False,'normalData':False}
def run(label,args,timeout=90):
    p=subprocess.run(args,capture_output=True,text=True,timeout=timeout,cwd=r)
    log=out/(label+'.log');log.write_text(p.stdout+p.stderr)
    proof['phases'].append({'name':label,'exit':p.returncode,'logSHA256':sha(log)})
    if p.returncode:raise RuntimeError(label+' failed; see '+str(log))
    return p.stdout
def compile(name,sources):
    run('compile-'+name,['swiftc','-swift-version','5','-parse-as-library','-O','-module-cache-path',str(out/'module-cache'),*map(str,sources),'-o',str(out/name)])
try:
    source=(n/'NativeDatabase.swift').read_text()
    declarations=re.findall(r'(?ms)^enum NativeDBError: LocalizedError \{.*?^\}',source)
    assert len(declarations)==1
    error=out/'ErrorType.swift';error.write_text('import Foundation\n'+declarations[0]+'\n')
    proof['errorDeclaration']='Exact production declaration extracted without compiling unrelated SQLite service code'
    run('fixtures',['python3',str(n/'document-format-fixtures.py'),str(out)])
    run('original',['node',str(n/'document-format-reference.cjs'),str(out)])
    compile('NextCRMDocumentSVG',[n/'NativeDocumentSVGWorker.swift'])
    compile('Probe',[error,n/'NativeDocumentProcessing.swift',n/'NativeDocumentFormatTests.swift'])
    compile('GuardTests',[error,n/'NativeDocumentProcessing.swift',n/'NativeDocumentFormatGuardTests.swift'])
    compile('FakeSVG',[n/'NativeDocumentSVGFixtureTests.swift'])
    for name in ['FakeSVGInvalid','FakeSVGOversized','FakeSVGHang','FakeSVGSandbox']:shutil.copy2(out/'FakeSVG',out/name)
    run('native',['./'+str((out/'Probe').relative_to(r)),str(out)])
    original=json.loads((out/'source.json').read_text());actual={x['name']:x for x in json.loads((out/'native.json').read_text())}
    differences={'tabs_breaks':'Preserve explicit Word line/page breaks instead of concatenating adjacent runs.',
                 'textbox':'Retain XML position of nested text rather than moving pict text after the parent paragraph.',
                 'textbox_order':'Retain XML text order before/inside/after the textbox; original mammoth moves pict text to the end.',
                 'huge-dimensions-svg':'Render vector directly at 200 pixels; original sharp refuses its input pixel dimensions.'}
    checks=0;matched=0;observed=[]
    for case in original['results']:
        got=actual[case['name']];assert 'error' not in got,got
        if case['name'] not in differences:
            assert not case.get('error'),case
            assert (case.get('text') or '')==got['text'],case['name'];matched+=1
        else:
            if case['name']=='huge-dimensions-svg':assert case.get('error')=='Error: Input image exceeds pixel limit'
            else:assert case['text']!=got['text']
            observed.append({'case':case['name'],'reason':differences[case['name']],'sourceText':case.get('text'),'nativeText':got['text']})
        checks+=1
        if case['mime']=='image/svg+xml':
            assert got['thumbnail']=={'height':200,'width':200};checks+=1
            if 'thumbnail' in case:assert case['thumbnail']['height']==200 and case['thumbnail']['width']==200
    assert len(actual)==22 and len(observed)==4
    run('guards',[str(out/'GuardTests'),str(out)],timeout=35)
    proof['guards']=json.loads((out/'guards.json').read_text());checks+=proof['guards']['checks']
    # Exercise the same file/network allowlist with an intentionally hostile fixture helper.
    quote=lambda value:json.dumps(str(value),ensure_ascii=False)
    readable=json.loads(re.search(r'let readable = (\[.*\])',(n/'NativeDocumentProcessing.swift').read_text()).group(1))
    helper=out/'FakeSVGSandbox';svg=out/'fixtures/solid.svg'
    (out/'fixtures/canary.txt').write_text('SYNTHETIC-CANARY-NOT-SECRET')
    profile='(version 1)(allow default)(deny network*)(deny file-read*)(deny file-write*)(allow file-read-metadata)(allow file-read-data (literal "/"))(allow file-read* '+''.join('(subpath '+quote(x)+')' for x in readable)+'(literal '+quote(svg)+')(literal '+quote(helper)+')(literal "/dev/null"))'
    with svg.open('rb') as source:
        p=subprocess.run(['/usr/bin/sandbox-exec','-p',profile,str(helper)],stdin=source,capture_output=True,text=True,timeout=10)
    assert p.returncode==0 and p.stdout=='sandbox read/write/network denied\n' and not (out/'forbidden-write').exists()
    checks+=3
    heavy=out/'fixtures/parent-death.svg'
    with heavy.open('w') as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">')
        for _ in range(500_000):f.write('<rect width="200" height="200" fill="red"/>')
        f.write('</svg>')
    heavy_bytes=heavy.stat().st_size
    parent=subprocess.Popen([str(out/'Probe'),str(out),'parent-death'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    child=None
    try:
        deadline=time.monotonic()+5
        while time.monotonic()<deadline and parent.poll() is None:
            lines=subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines()
            found=[line for line in lines if str(out/'NextCRMDocumentSVG')+' --parent '+str(parent.pid) in line]
            if found:child=int(found[-1].strip().split()[0]);break
            time.sleep(0.01)
        assert child is not None,'Renderer did not become observable for parent-death test'
        parent.kill();parent.wait(timeout=5);stopped=time.monotonic()
        while time.monotonic()-stopped<2:
            result=subprocess.run(['ps','-p',str(child),'-o','command='],capture_output=True,text=True)
            if str(out/'NextCRMDocumentSVG') not in result.stdout:break
            time.sleep(0.02)
        assert str(out/'NextCRMDocumentSVG') not in result.stdout,'Renderer survived parent death'
        proof['parentDeath']={'actualSIGKILL':parent.returncode==-signal.SIGKILL,'childPID':child,'childGoneSeconds':round(time.monotonic()-stopped,3),'temporaryInputBytesRemoved':heavy_bytes}
        assert proof['parentDeath']['actualSIGKILL'];checks+=2
    finally:
        if parent.poll() is None:parent.kill();parent.wait(timeout=5)
        if child is not None:
            result=subprocess.run(['ps','-p',str(child),'-o','command='],capture_output=True,text=True)
            if str(out/'NextCRMDocumentSVG') in result.stdout:os.kill(child,signal.SIGKILL)
        heavy.unlink()
    processes=subprocess.check_output(['ps','-axo','pid=,command='],text=True)
    assert not [line for line in processes.splitlines() if str(out) in line and any(x in line for x in ['NextCRMDocumentSVG --parent','FakeSVGHang --parent'])]
    checks+=1
    proof.update(checks=checks,sourceCases=22,exactTextOrNullCases=matched,intentionalDifferences=observed,
                 sandboxReadWriteNetworkDenied=True,noOwnedRendererRemaining=True,
                 inputsUnchanged=before=={str(p.relative_to(r)):sha(p) for p in watched})
    assert proof['inputsUnchanged'];proof['complete']=True
except Exception as error:proof['error']=str(error)
finally:
    cache=out/'module-cache';proof['moduleCacheBytesRemoved']=sum(p.stat().st_size for p in cache.rglob('*') if p.is_file()) if cache.exists() else 0
    if cache.exists():shutil.rmtree(cache)
    proof['seconds']=round(time.monotonic()-start,2);proof['retainedBytes']=sum(p.stat().st_size for p in out.rglob('*') if p.is_file())
    path=out/'verification.json';path.write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
    (n/'build/document-formats-latest.json').write_text(json.dumps({'verification':str(path),'SHA256':sha(path),'complete':proof['complete']},indent=2)+'\n')
    print(json.dumps({k:proof[k] for k in ['complete','checks','sourceCases','seconds','error','retainedBytes'] if k in proof},ensure_ascii=False))
sys.exit(0 if proof['complete'] else 1)
