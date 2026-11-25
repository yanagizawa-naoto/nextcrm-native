#!/usr/bin/env python3
"""Real private PostgreSQL snapshot -> current production SQLite/readers only."""
from pathlib import Path
import datetime, hashlib, json, os, shutil, signal, subprocess, tempfile, time

N=Path(__file__).resolve().parent;ROOT=N.parent.parent
OUT=N/'build'/('migration-operational-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+str(os.getpid()))
OUT.mkdir(parents=True,mode=0o700);fixture=OUT/'fixture';fixture.mkdir()
names=json.loads((N/'migration-operational-sources.json').read_text());sources=[N/(x+'.swift') for x in names]
assert len(sources)==len(set(sources)) and all(p.is_file() for p in sources)
tools=['migration-source-export.cjs','migration-source-objects.cjs','migration-source-plugin-settings.cjs','migration-operational-fixture.py','migration-source-reference.cjs','migration-source-objects-reference.cjs','migration-document-versions-reference.cjs','credential-migration-handoff.cjs','migration-operational-sources.json','migration-import-test.py','plugins-source-loader.cjs','schema.json','schema.sql']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
watched=sources+[N/x for x in tools]+[Path(__file__).resolve(),ROOT/'prisma/schema.prisma']
before={str(p):sha(p) for p in watched};started=time.monotonic();phases=[]
proof={'status':'running','complete':False,'inputSHA256':before,'runDirectory':str(OUT),'phases':phases,'scope':'Exact production sources, synthetic isolated PostgreSQL snapshot and immutable object inventory, fake S3 transport, actual original document action, normal native readers. No real data/identity/provider/Keychain/activation.'}
pgbase=Path(tempfile.mkdtemp(prefix='nextcrm-operational-',dir=os.environ.get('NEXTCRM_OPERATIONAL_TMP_PARENT','/private/tmp')));pg=pgbase/'pg';sock=pgbase/'socket';sock.mkdir()
pgstarted=False;cache=OUT/'module-cache';current=None
def save():
 (OUT/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
def run(label,command,timeout=180):
 global current
 tick=time.monotonic()
 with (OUT/(label+'.log')).open('w') as log:
  current=subprocess.Popen(list(map(str,command)),cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=current.wait(timeout=timeout)
  except BaseException:
   for sig in [signal.SIGTERM,signal.SIGKILL]:
    try:os.killpg(current.pid,sig)
    except ProcessLookupError:pass
    try:current.wait(timeout=3)
    except subprocess.TimeoutExpired:pass
   current.wait();raise
  finally:current=None
 phase={'name':label,'exit':rc,'seconds':round(time.monotonic()-tick,2)};phases.append(phase);save();print(json.dumps(phase),flush=True)
 if rc:raise RuntimeError(label+' failed; see '+str(OUT/(label+'.log')))
def interrupted(signum,frame):raise RuntimeError('Owned verification interrupted by signal '+str(signum))
signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
try:
 run('initdb',['initdb','-D',pg,'--auth=trust','--no-locale','--encoding=UTF8'])
 # Unix socket only; the new test cluster cannot accept remote connections.
 pgstarted=True
 run('postgres-start',['pg_ctl','-D',pg,'-l',pgbase/'postgres.log','-o',f"-F -k {sock} -p 5432 -c listen_addresses=''",'-w','start'])
 run('fixture',['python3',N/'migration-operational-fixture.py',fixture])
 run('source',['node',N/'migration-source-reference.cjs',fixture,N/'schema.json',sock,'5432'])
 run('objects',['node',N/'migration-source-objects-reference.cjs',OUT/'source-objects-proof.json'])
 run('document-original',['node',N/'migration-document-versions-reference.cjs',fixture,OUT/'document-versions-reference.json'])
 run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-module-cache-path',cache,'-framework','AppKit','-framework','ImageIO','-framework','UniformTypeIdentifiers','-framework','PDFKit','-lsqlite3',*sources,'-o',OUT/'NativeOperationalMigrationTests'],1200)
 run('native',[OUT/'NativeOperationalMigrationTests',fixture,N,OUT])
 source=json.loads((fixture/'source-proof.json').read_text());objects=json.loads((OUT/'source-objects-proof.json').read_text());docs=json.loads((OUT/'document-versions-reference.json').read_text());native=json.loads((OUT/'native-proof.json').read_text())
 upstream={**objects['actualSourceHashes'],**docs['sourceHashes']}
 assert all(sha(ROOT/path)==digest for path,digest in upstream.items()),'original action inputs changed'
 proof.update(status='passed',complete=True,sourceChecks=source['checks'],objectChecks=objects['checks'],sourceVersionCases=len(docs['cases']),native=native,originalSourceSHA256=upstream)
except Exception as error:proof.update(status='failed',complete=False,error=str(error))
finally:
 if pgstarted:
  stopped=subprocess.run(['pg_ctl','-D',str(pg),'-m','fast','-w','stop'],capture_output=True,timeout=60)
  proof['postgresStopExit']=stopped.returncode
  proof['postgresStopped']=not (pg/'postmaster.pid').exists()
 else:proof['postgresStopped']=True
 if proof['postgresStopped']:
  shutil.rmtree(pgbase);proof['privateClusterRemoved']=True
 else:proof.update(status='failed',complete=False,privateClusterRetained=str(pgbase))
 proof['inputsUnchanged']=all(p.is_file() and sha(p)==before[str(p)] for p in watched)
 if not proof['inputsUnchanged']:proof.update(status='failed',complete=False)
 proof['moduleCacheBytes']=sum(p.stat().st_size for p in cache.rglob('*') if p.is_file()) if cache.exists() else 0
 if cache.exists():shutil.rmtree(cache)
 proof['moduleCacheRemoved']=not cache.exists();proof['seconds']=round(time.monotonic()-started,2);save()
 (N/'build/migration-operational-latest.json').write_text(json.dumps({'verification':str(OUT/'verification.json'),'SHA256':sha(OUT/'verification.json'),'complete':proof['complete']})+'\n')
 print(json.dumps({k:proof[k] for k in ['status','complete','sourceChecks','objectChecks','sourceVersionCases','native','inputsUnchanged','postgresStopped','seconds','error'] if k in proof},ensure_ascii=False),flush=True)
if not proof['complete']:raise SystemExit(1)
