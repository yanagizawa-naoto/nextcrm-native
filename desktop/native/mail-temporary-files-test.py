#!/usr/bin/env python3
from pathlib import Path
from native_mail_build import html_inputs, html_object
import hashlib,json,subprocess,tempfile,os,time,signal,fcntl,shutil,threading,select
n=Path(__file__).resolve().parent;repo=n.parent.parent;p=n/'build/mail-temporary-files';p.mkdir(parents=True,exist_ok=True)
sha=lambda x:hashlib.sha256(x.read_bytes()).hexdigest()
sources=[n/'NativeMailHTMLText.swift',n/'NativeMail.swift',n/'NativeMailSpool.swift',n/'NativeMailTemporaryFiles.swift',n/'NativeMailMIME.swift',n/'NativeMailIMAP.swift', n/'NativeMailMIMESpool.swift', n/'NativeMailTextHTML.swift', n/'NativeMailIMAPFile.swift',n/'NativeMailClient.swift',n/'NativeMailTemporaryFilesTests.swift']
tracked=sources+html_inputs(n)+[n/'NativeMailTransport.c',n/'NativeMailTransport.h',n/'NativeMail.swift',n/'NativeMailSpool.swift',Path(__file__),repo/'actions/emails/messages.ts',repo/'actions/invoices/send-invoice-email.ts',n/'NativePluginsMail.swift',n/'NativeBackupInventory.swift',n/'InvoiceMail.swift',n/'CRMInvoiceMail.swift',n/'NativeMailSend.swift']
before={str(x.relative_to(repo)):sha(x) for x in tracked};proof={'scope':'production mail response + UID temporary spool only','actualProductionSources':True,'sourceSHA256':before,'phases':[],'networkCalls':0,'normalData':False,'productionEdited':False};binary=p/'NativeMailTemporaryFilesTests';log=p/'test.log';checks=0;children=[];start=time.time();complete=False

def check(value,name):
 global checks
 if not value:raise AssertionError(name)
 checks+=1

def run(mode,base):
 r=subprocess.run([str(binary),mode,str(base)],text=True,capture_output=True,timeout=30)
 if r.returncode:raise AssertionError(r.stdout+r.stderr)
 return json.loads(r.stdout)

def child(base):
 c=subprocess.Popen([str(binary),'child',str(base)],text=True,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 children.append(c);line=c.stdout.readline()
 if not line:raise AssertionError(c.stderr.read())
 return c,json.loads(line)['paths']

def dead(base):
 c,paths=child(base);c.kill();c.wait(timeout=10);check(c.returncode==-signal.SIGKILL,'actual SIGKILL');return {k:Path(v) for k,v in paths.items()}

def marker(path):return json.loads((path/'.lease').read_text())
def setmarker(path,value):(path/'.lease').write_text(json.dumps(value))
def namespace(base):return base/'NextCRM-MailSpools-v1'

def phase(name,args):
 with log.open('a') as out:r=subprocess.run(args,stdout=out,stderr=subprocess.STDOUT,timeout=300)
 proof['phases'].append({'name':name,'exit':r.returncode});print(json.dumps(proof['phases'][-1]),flush=True)
 if r.returncode:raise RuntimeError(log.read_text()[-6000:])

try:
 log.write_text('')
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 phase('isolated-object C compile',['xcrun','clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-c',str(n/'NativeMailTransport.c'),'-o',str(p/'NativeMailTransport.o')])
 html=html_object(n,p/'CampaignHTML.o',phase)
 phase('production Swift compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-lcurl','-lsqlite3','-lxml2','-import-objc-header',str(n/'NativeMailParsing.h'),str(p/'NativeMailTransport.o'),str(html),*map(str,sources),'-o',str(binary)])
 with tempfile.TemporaryDirectory(prefix='synthetic-',dir=p) as tmp:
  base=Path(tmp);os.chmod(base,0o700)
  def fixture(name):
   result=base/name;result.mkdir(mode=0o700);return result
  f=fixture('core');result=run('core',f);checks+=result['checks'];proof['swiftCoreChecks']=result['checks']
  f=fixture('live');c,paths=child(f);result=run('sweep',f);check(result['live']==2 and result['removed']==0,'live cross-process leases protect both')
  c.stdin.write('check\n');c.stdin.flush();check(json.loads(c.stdout.readline())['checks']==2,'live data still read')
  c.stdin.write('exit\n');c.stdin.flush();c.wait(timeout=10);check(c.returncode==0,'normal child exit');check(all(not Path(x).exists() for x in paths.values()),'normal deinit removes dirs')
  f=fixture('producer-busy');c=subprocess.Popen([str(binary),'producer',str(f)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);children.append(c)
  check(json.loads(c.stdout.readline())['ready'],'producer owns initial response before competing root lock')
  with (namespace(f)/'.lock').open('r+') as fd:
   fcntl.flock(fd,fcntl.LOCK_EX);c.stdin.write('attempt\n');c.stdin.flush()
   check(bool(select.select([c.stdout],[],[],2)[0]),'producer initializers do not wait for another process lock')
   result=json.loads(c.stdout.readline());check(result['statuses']==['response-busy','uids-busy'],'both producer initializers return typed busy');check(result['elapsedMilliseconds']<1500,'bounded producer failure')
  c.stdin.write('attempt\n');c.stdin.flush();check(bool(select.select([c.stdout],[],[],2)[0]),'unlocked producer returns')
  check(json.loads(c.stdout.readline())['statuses']==['response-ok','uids-ok'],'same producer succeeds after external lock release')
  c.stdin.write('exit\n');c.stdin.flush();c.wait(timeout=10);check(c.returncode==0,'producer clean exit')
  f=fixture('deinit-busy');c,paths=child(f)
  with (namespace(f)/'.lock').open('r+') as fd:
   fcntl.flock(fd,fcntl.LOCK_EX);c.stdin.write('exit\n');c.stdin.flush();c.wait(timeout=10)
   check(c.returncode==0,'deinit does not block behind active collector');check(all(Path(x).exists() for x in paths.values()),'busy deinit leaves owned files for later')
  check(run('sweep',f)['removed']==2,'busy-deinit released leases allow next pass')
  f=fixture('crash');paths=dead(f);check(all(x.exists() for x in paths.values()),'crash leaves actual artifacts')
  result=run('sweep',f);check(result['removed']==2,'dead original process releases kernel leases');check(all(not x.exists() for x in paths.values()),'dead body and DB removed')
  check(run('sweep',f)['removed']==0,'recovery idempotent')
  f=fixture('concurrent');paths=dead(f)
  workers=[subprocess.Popen([str(binary),'cursor',str(f)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(2)]
  results=[]
  for c in workers:
   stdout,stderr=c.communicate(timeout=10);check(c.returncode==0,'concurrent collectors return');results.append(json.loads(stdout))
  results.append(run('cursor',f));check(sum(x['removed'] for x in results)==2,'concurrent collect exactly once')
  f=fixture('root-lock');paths=dead(f)
  with (namespace(f)/'.lock').open('r+') as fd:
   fcntl.flock(fd,fcntl.LOCK_EX);result=run('sweep',f);check(result['busy'] and result['examined']==0,'root initialization/recovery is nonblocking');check(all(x.exists() for x in paths.values()),'busy keeps all artifacts')
  check(run('sweep',f)['removed']==2,'released root lock recovers')
  # Each corrupt case has one untouched sibling that must still be recoverable.
  for name,mutate in [
    ('truncated-marker',lambda d:(d/'.lease').write_text('{')),
    ('wrong-purpose',lambda d:setmarker(d,{**marker(d),'purpose':'invoice'})),
    ('wrong-version',lambda d:setmarker(d,{**marker(d),'version':2})),
    ('wrong-owner',lambda d:setmarker(d,{**marker(d),'uid':os.geteuid()+1})),
    ('wrong-root',lambda d:setmarker(d,{**marker(d),'root':{'device':0,'inode':0}})),
    ('wrong-content-inode',lambda d:setmarker(d,{**marker(d),'content':{'device':0,'inode':0}})),
    ('unknown-child',lambda d:(d/'unexpected').write_text('preserve')),
    ('sqlite-sidecar',lambda d:(d/'uids.sqlite-wal').write_bytes(b'pending SQLite')),
    ('public-mode',lambda d:os.chmod(d,0o755)),
    ('public-file',lambda d:os.chmod(d/'response',0o644)),
    ('content-symlink',lambda d:((d/'response').unlink(),(d/'response').symlink_to(base/'sentinel'))),
    ('marker-symlink',lambda d:((d/'.lease').unlink(),(d/'.lease').symlink_to(base/'sentinel'))),
    ('content-hardlink',lambda d:os.link(d/'response',d.parent/'hardlink-sentinel')),
    ('marker-hardlink',lambda d:os.link(d/'.lease',d.parent/'lease-hardlink-sentinel')),
  ]:
   (base/'sentinel').write_text('must preserve')
   f=fixture(name);paths=dead(f);target=paths['response'];mutate(target)
   result=run('sweep',f);check(target.exists(),'invalid candidate preserved '+name);check(result['removed']==1,'only valid sibling removed '+name);check((base/'sentinel').read_text()=='must preserve','no link traversal '+name)
  f=fixture('initialization-windows');paths=dead(f)
  unknown=namespace(f)/'12345678-1234-1234-1234-123456789abc';unknown.mkdir(mode=0o700);(unknown/'response').write_bytes(b'')
  truncated=namespace(f)/'12345678-1234-1234-1234-123456789abd';truncated.mkdir(mode=0o700);(truncated/'.lease').write_bytes(b'{');os.chmod(truncated/'.lease',0o600);(truncated/'response').write_bytes(b'')
  empty=namespace(f)/'12345678-1234-1234-1234-123456789abe';empty.mkdir(mode=0o700)
  result=run('sweep',f);check(result['removed']==2 and unknown.exists() and truncated.exists() and empty.exists(),'incomplete init / marker-unlinked windows stay preserved')
  f=fixture('root-symlink');paths=dead(f);owned=namespace(f);owned.rename(f/'moved');owned.symlink_to(f/'moved')
  result=subprocess.run([str(binary),'sweep',str(f)],text=True,capture_output=True,timeout=10)
  check(result.returncode!=0 and all((f/'moved'/x.name).exists() for x in paths.values()),'namespace symlink rejected without touching target')
  f=fixture('directory-symlink');paths=dead(f);d=paths['response'];d.rename(f/'moved');d.symlink_to(f/'moved')
  result=run('sweep',f);check(result['removed']==1 and (f/'moved'/'response').exists(),'candidate directory symlink preserved')
  f=fixture('missing-content');paths=dead(f);(paths['response']/'response').unlink();check(run('sweep',f)['removed']==2,'known cleanup interrupted after content unlink resumes')
  f=fixture('missing-marker');paths=dead(f);(paths['response']/'.lease').unlink();result=run('sweep',f);check(result['removed']==1 and paths['response'].exists(),'unmarked files preserved')
  f=fixture('replaced-inode');paths=dead(f);d=paths['response'];(d/'response').rename(d/'old');(d/'response').write_text('other producer');(d/'old').unlink();os.chmod(d/'response',0o600)
  check(run('sweep',f)['removed']==1 and (d/'response').read_text()=='other producer','replacement inode preserved')
  f=fixture('moved-namespace');paths=dead(f);old=namespace(f);old.rename(f/'moved');old.mkdir(mode=0o700);(old/'.lock').write_bytes(b'');os.chmod(old/'.lock',0o600)
  for d in paths.values():shutil.move(str(f/'moved'/d.name),old/d.name)
  check(run('sweep',f)['removed']==0,'namespace inode binding')
  f=fixture('legacy-and-durable');paths=dead(f)
  for directory,filename in [('NextCRM-MailResponse-old','response'),('NextCRM-MailUIDs-old','uids.sqlite'),('mail-outbox','pending.json'),('invoice-pdfs','retained.pdf')]:
   d=f/directory;d.mkdir();(d/filename).write_text('retained')
  check(run('sweep',f)['removed']==2,'new owned artifacts recovered')
  for directory,filename in [('NextCRM-MailResponse-old','response'),('NextCRM-MailUIDs-old','uids.sqlite'),('mail-outbox','pending.json'),('invoice-pdfs','retained.pdf')]:check((f/directory/filename).read_text()=='retained','outside namespace preserved '+directory)
  f=fixture('bounded');paths=dead(f)
  for i in range(150):(namespace(f)/('unowned-'+str(i))).mkdir()
  result=run('sweep',f);check(result['examined']==64 and not result['finished'],'single step strict 64-entry bound')
  result=run('cursor',f);check(result['examined']>=151 and result['calls']>50,'cursor resumes bounded pages without all-name array');check(len(list(namespace(f).glob('unowned-*')))==150,'unknown dirs intact')
  proof['fixtureBytes']=sum(x.stat().st_size for x in base.rglob('*') if x.is_file() and not x.is_symlink());proof['fixtureCount']=len(list(base.iterdir()))
 proof['fixtureRemoved']=not base.exists();complete=True
finally:
 for c in children:
  if c.poll() is None:c.kill();c.wait(timeout=10)
 proof['checks']=checks;proof['sourceHashesMatch']=all(sha(repo/x)==h for x,h in before.items());proof['complete']=complete and proof['sourceHashesMatch'];proof['elapsedSeconds']=round(time.time()-start,2);proof['artifactBytes']=sum(x.stat().st_size for x in p.rglob('*') if x.is_file())
 (n/'build/mail-temporary-files-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
assert proof['complete']
print(json.dumps({k:proof[k] for k in ['checks','complete','sourceHashesMatch','artifactBytes']}))
