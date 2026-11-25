#!/usr/bin/env python3
from pathlib import Path
import datetime,hashlib,json,os,shutil,subprocess,tempfile,time,sys
P=Path(__file__).resolve().parent;C=P;N=P;R=N.parent.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
os.umask(0o077);start=time.monotonic();out=P/'build'/('credential-archive-verification-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir(parents=True);pinned=out/'inputs';pinned.mkdir()
names=['NativeDatabase','NativeMigrationManifest','NativeMigrationJSON','NativeMigrationCodec','NativeMigrationFiles','NativeMigrationImportWorkspace','NativeBackupTypes','NativeBackupSQLite','NativeBackupWorkspace','NativeOperationalAssets','NativeBackupOperationalAssets','NativeBackupInventory','NativeBackup','NativeRestoreTypes','NativeRestoreSchema','NativeRestorePlan','NativeRestoreWorkspace','NativeRestore', 'MailReview']
inputs=[N/(x+'.swift') for x in names]+[P/'NativeCredentialArchiveBinding.swift',P/'NativeCredentialMigrationArchive.swift',P/'NativeCredentialMigrationArchiveReader.swift',C/'NativeCredentialMigrationEnvelope.swift',P/'NativeCredentialArchiveTests.swift']
watched=inputs+[Path(__file__),N/'schema.json',N/'schema.sql',N/'credential-migration-handoff.cjs',C/'credential-migration-reference.cjs',N/'credential-migration-handoff-reference.cjs']
before={str(f.relative_to(R)):sha(f) for f in watched};result={'complete':False,'sourceSHA256':before,'phases':[],'scope':'Actual private SQLite -> NativeBackup -> held NativeRestore -> explicit nonsecret namespace rebind -> authenticated encrypted readback. No runtime or real Keychain activation.'}
for f in inputs+[N/'schema.json',N/'schema.sql']:shutil.copy2(f,pinned/f.name);assert sha(pinned/f.name)==sha(f)
copysha={f.name:sha(pinned/f.name) for f in inputs+[N/'schema.json',N/'schema.sql']}
def run(name,args):
 r=subprocess.run(args,cwd=R,capture_output=True,text=True,timeout=300,umask=0o077);log=out/(name+'.log');log.write_text(r.stdout+r.stderr);phase={'name':name,'exit':r.returncode,'logSHA256':sha(log)};result['phases'].append(phase)
 if r.returncode:raise RuntimeError(name+' failed; '+str(log))
 phase['results']=[json.loads(s) for s in r.stdout.splitlines() if s.startswith('{')]
try:
 with tempfile.TemporaryDirectory(prefix='NextCRMCredentialArchive-',dir=subprocess.check_output(['getconf','DARWIN_USER_TEMP_DIR'],text=True).strip()) as td:
  root=Path(td).resolve();fixture=root/'fixture';run('fixture',['node',str(N/'credential-migration-handoff-reference.cjs'),str(fixture)])
  f=json.loads((fixture/'handoff-fixture.json').read_text());operational=fixture/'operational';operational.mkdir(mode=0o700)
  shutil.copy2(fixture/'handoff/credentials.handoff',operational/'credentials.handoff')
  holds=[]
  for item,ref in zip(f['items'],f['refs']):holds.append({k:item[k] for k in ['kind','owner','valueSHA256','classification']}|{'requiresOriginalSource':False,'handoff':ref})
  holds.extend([{'kind':'jobs','classification':'external-inngest-inventory-required','requiresOriginalSource':True},{'kind':'source-table','table':'synthetic_unknown_table','classification':'unknown-schema-table','requiresOriginalSource':True},{'kind':'asset','storageKeySHA256':'1'*64,'classification':'unknown-owner','requiresOriginalSource':True}])
  held=b''.join((json.dumps(h,ensure_ascii=False,separators=(',',':'))+'\n').encode() for h in holds);(operational/'migration-holds.ndjson').write_bytes(held)
  report={'formatVersion':1,'schemaSHA256':f['schemaSHA256'],'evidence':{'snapshot':f['snapshotID']},'credentialHandoff':f['descriptor'],'holds':{'path':'holds.ndjson','rows':len(holds),'bytes':len(held),'sha256':hashlib.sha256(held).hexdigest()},'credentialsMigrated':False}
  (operational/'migration-source-report.json').write_text(json.dumps(report,separators=(',',':'))+'\n')
  objects=[]
  if '--clone-unavailable' in sys.argv:
   shim=out/'NoClone.c';shim.write_text('#include <errno.h>\nint fclonefileat(int source, int directory, const char *name, int flags) { (void)source; (void)directory; (void)name; (void)flags; errno=ENOTSUP; return -1; }\n')
   obj=out/'NoClone.o';run('compile-clone-shim',['clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-c',str(shim),'-o',str(obj)]);objects=[str(obj)];result['cloneUnavailableShimSHA256']=sha(shim)
  result['cloneMode']='forced-ENOTSUP' if objects else 'system'
  run('compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-lsqlite3','-module-cache-path',str(out/'cache'),*[str(pinned/x.name) for x in inputs],*objects,'-o',str(out/'Tests')])
  run('native',[str(out/'Tests'),str(pinned),str(fixture),str(root/'data')])
  result['temporaryBytesRemoved']=sum(f.stat().st_size for f in root.rglob('*') if f.is_file() and not f.is_symlink())
 result['temporaryRemoved']=not root.exists();result['inputsUnchanged']=all(sha(R/f)==h for f,h in before.items());result['compiledSnapshotUnchanged']=all(sha(pinned/f)==h for f,h in copysha.items());assert result['inputsUnchanged'] and result['compiledSnapshotUnchanged'];result['complete']=True
except Exception as e:result['error']=str(e)
finally:
 if (out/'cache').exists():shutil.rmtree(out/'cache')
 result['seconds']=round(time.monotonic()-start,2);result['retainedBytes']=sum(f.stat().st_size for f in out.rglob('*') if f.is_file());proof=out/'verification.json';proof.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');(P/'build/credential-archive-latest.json').write_text(json.dumps({'verification':str(proof),'SHA256':sha(proof),'complete':result['complete']},indent=2)+'\n');print(json.dumps({k:result[k] for k in ['complete','seconds','retainedBytes','error'] if k in result}));sys.exit(0 if result['complete'] else 1)
