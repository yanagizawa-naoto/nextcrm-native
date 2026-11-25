#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,tempfile,os,time,re,sys
n=Path(__file__).resolve().parent;repo=n.parent.parent
p=n/'build/user-credential-cleanup';p.mkdir(parents=True,exist_ok=True)
mode='production';ai=False
base=re.search(r'sources=\(([^)]+)\)',(n/'ai-keys-test.sh').read_text()).group(1).split();base=[x for x in base if not x.endswith('Tests')]
names=base+['NativeAPITokens','NativeUserAdministration','NativeUserAdministrationMail','NativeUserCredentialCleanup']
names+='NativeMigrationManifest NativeMigrationJSON NativeMigrationCodec NativeMigrationFiles NativeMigrationImportWorkspace NativeBackupTypes NativeBackupSQLite NativeBackupWorkspace NativeCredentialArchiveBinding NativeOperationalAssets NativeBackupOperationalAssets NativeBackupInventory NativeBackup NativeRestoreTypes NativeRestoreSchema NativeRestoreWorkspace NativeRestorePlan NativeRestore'.split()
if not ai:
 for runner in ['crm-email-test.sh','google-calendar-push-test.sh']:
  names += [x for x in re.findall(r'\$native_dir/([A-Za-z0-9_]+)\.swift',(n/runner).read_text()) if not x.endswith('Tests')]
# Compile the installed project sources directly; no candidate implementation.
sources=[n/(x+'.swift') for x in dict.fromkeys(names)]+[n/'NativeUserCredentialCleanupTests.swift']
cs=[] if ai else ['NativeMailTransport','CampaignHTML'];headers=[];objects=[]
for name in cs:headers.append(n/(name+'.h'));objects.append(p/(name+'.o'))
bridge=p/'Bridge.h'
if cs:bridge.write_text(''.join('#include "'+str(x)+'"\n' for x in headers))
sha=lambda x:hashlib.sha256(x.read_bytes()).hexdigest()
tracked=sources+[Path(__file__),n/'schema.json',n/'schema.sql',n/'ai-keys-test.sh',n/'crm-email-test.sh',n/'google-calendar-push-test.sh',repo/'prisma/schema.prisma',repo/'actions/admin/users/delete-user.ts']+[n/(x+suffix) for x in cs for suffix in ['.c','.h']]
if cs:tracked += [bridge,n/'CampaignHTMLEntities.inc']
before={str(x.relative_to(repo)):sha(x) for x in dict.fromkeys(tracked)}
proof={'scope':mode,'sourceSHA256':before,'phases':[],'realKeychain':False,'normalData':False,'externalRequests':0,'productionSources':True};log=p/(mode+'.log');binary=p/(mode+'-tests');start=time.time();complete=False
try:
 with log.open('w') as out:
  if cs:
   sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
   for name,obj in zip(cs,objects):
    args=['xcrun','clang','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-I',sdk+'/usr/include/libxml2','-c',str(n/(name+'.c')),'-o',str(obj)]
    r=subprocess.run(args,stdout=out,stderr=subprocess.STDOUT);proof['phases'].append({'name':'compile-'+name,'exit':r.returncode})
    if r.returncode:raise RuntimeError('C compilation failed')
  args=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-framework','Network','-lsqlite3','-lcurl','-lxml2']
  if cs:args+=['-import-objc-header',str(bridge)]+list(map(str,objects))
  r=subprocess.run(args+list(map(str,sources))+['-o',str(binary)],stdout=out,stderr=subprocess.STDOUT,timeout=480)
 proof['phases'].append({'name':'compile-swift','exit':r.returncode});print(json.dumps(proof['phases'][-1]),flush=True)
 if r.returncode:raise RuntimeError(log.read_text()[-6000:])
 with tempfile.TemporaryDirectory(prefix='NextCRM-PersonalCredential-Synthetic-') as tmp:
  os.chmod(tmp,0o700);args=[str(binary),str(n),str(Path(tmp).resolve())]
  r=subprocess.run(args,text=True,capture_output=True,timeout=100)
  with log.open('a') as out:out.write(r.stdout+r.stderr)
  proof['phases'].append({'name':mode,'exit':r.returncode})
  if r.returncode:raise RuntimeError(r.stdout+r.stderr)
  proof.update(json.loads(r.stdout));proof['fixtureBytes']=sum(x.stat().st_size for x in Path(tmp).rglob('*') if x.is_file())
 proof['fixtureRemoved']=not Path(tmp).exists();complete=True
finally:
 proof['sourceHashesMatch']=all(sha(repo/x)==h for x,h in before.items());proof['complete']=complete and proof['sourceHashesMatch'];proof['elapsedSeconds']=round(time.time()-start,2);(p/(mode+'-verification.json')).write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
assert proof['complete'];print(json.dumps({k:proof[k] for k in ['scope','complete','checks','sourceHashesMatch','fixtureRemoved','elapsedSeconds']}))
