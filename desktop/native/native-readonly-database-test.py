#!/usr/bin/env python3
"""Production NativeDatabase readonly contract; isolated fixtures, no GUI/network.

Only the DB source is copied, byte-for-byte, with a test-only accessor suffix.
Every other dependency is compiled directly from the current production path.
"""
from pathlib import Path
import json,hashlib,subprocess,tempfile,shutil,sqlite3,os,time
n=Path(__file__).resolve().parent
c=n/'build/native-readonly-database';c.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
digest=lambda b:hashlib.sha256(b).hexdigest()
names=['CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeDatabaseReadOnlyTests','MailReview']
production=n/'NativeDatabase.swift';data=production.read_bytes()
testAccessSuffix=b"""\n#if READONLY_DB_TEST
// Read-only test access only; production prefix is byte-for-byte unchanged.
extension NativeDatabase {
 func testOnlySQL(_ sql: String) throws { try execute(sql) }
 func testOnlyScalar(_ sql: String) throws -> SQLValue? { try query(sql).first?.values.first }
}
#endif
"""
copy=c/'NativeDatabase.swift';copy.write_bytes(data+testAccessSuffix)
dependencies=[n/(name+'.swift') for name in names]
sources=[copy]+dependencies
watched=[production]+dependencies+[n/'schema.json',n/'schema.sql',Path(__file__)]
hashes={p.name:sha(p) for p in watched}
assert hashes[production.name]==digest(data)
assert copy.read_bytes()==production.read_bytes()+testAccessSuffix
binary=c/'NativeDatabaseReadOnlyTests';log=c/'test.log';start=time.time();results=[]
proofFile=n/'build/native-readonly-database-verification.json'
proofFile.write_text(json.dumps({'status':'running','inputsSHA256':hashes},indent=2)+'\n')
with log.open('w') as out:
 r=subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-D','READONLY_DB_TEST','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-lsqlite3',*map(str,sources),'-o',str(binary)],stdout=out,stderr=subprocess.STDOUT)
if r.returncode:print(json.dumps({'compileExit':r.returncode,'log':str(log)}));raise SystemExit(r.returncode)
def run(mode,path,label):
 r=subprocess.run([str(binary),mode,str(n),str(path)],capture_output=True,text=True,timeout=90)
 with log.open('a') as out:out.write(label+'\n'+r.stdout+r.stderr)
 if r.returncode:raise RuntimeError(label+': '+r.stdout+r.stderr[:1500])
 d=json.loads(r.stdout);results.append({'case':label,**d});return d
def snapshot(root):
 values={}
 for p in [root]+sorted(root.rglob('*')):
  s=p.lstat();values[str(p.relative_to(root))]={'mode':s.st_mode,'ino':s.st_ino,'dev':s.st_dev,'uid':s.st_uid,'gid':s.st_gid,'nlink':s.st_nlink,'size':s.st_size,'mtimeNS':s.st_mtime_ns,'ctimeNS':s.st_ctime_ns,'sha256':sha(p) if p.is_file() and not p.is_symlink() else None,'link':os.readlink(p) if p.is_symlink() else None}
 return values
def mutate(p,sql,values=()):
 d=sqlite3.connect(p);d.create_collation('native_email',lambda a,b:(a.lower()>b.lower())-(a.lower()<b.lower()));d.create_collation('native_decimal',lambda a,b:(a>b)-(a<b));d.create_collation('native_japanese',lambda a,b:(a>b)-(a<b));d.execute(sql,values);d.commit();d.close()
with tempfile.TemporaryDirectory(prefix='NextCRMReadOnlyDB-') as tmp:
 root=Path(tmp);template=root/'template';template.mkdir();db=template/'crm.sqlite'
 run('initialize',db,'writable initializer + hooks')
 d=sqlite3.connect(db);d.execute('PRAGMA wal_checkpoint(TRUNCATE)');d.execute('PRAGMA journal_mode=DELETE');d.close()
 assert list(template.iterdir())==[db]
 def fixture(name,edit=None,reject=False):
  folder=root/name;shutil.copytree(template,folder);p=folder/'crm.sqlite'
  if edit:edit(p)
  folder.chmod(0o750);p.chmod(0o640)
  before=snapshot(folder);run('reject' if reject else 'read',p,name);after=snapshot(folder)
  assert before==after,(name,before,after)
  results[-1]['treeSHA256']=hashlib.sha256(json.dumps(after,sort_keys=True).encode()).hexdigest();results[-1]['treeUnchanged']=True
 fixture('normal')
 fixture('escaped ? # 日本語')
 for suffix in ['-wal','-shm','-journal']:
  fixture('sidecar'+suffix,lambda p,s=suffix:Path(str(p)+s).write_bytes(b'non-empty unsealed work'),True)
 fixture('empty-wal',lambda p:Path(str(p)+'-wal').touch(),True)
 fixture('broken-schema-hash',lambda p:mutate(p,"UPDATE native_metadata SET value='wrong' WHERE key='schemaSHA256'"),True)
 fixture('missing-metadata',lambda p:mutate(p,"DELETE FROM native_metadata WHERE key='schemaSHA256'"),True)
 fixture('unsupported-db-version',lambda p:mutate(p,'PRAGMA user_version=9'),True)
 fixture('missing-model',lambda p:mutate(p,'DROP TABLE Currency'),True)
 fixture('extra-column',lambda p:mutate(p,'ALTER TABLE Currency ADD COLUMN unsupported TEXT'),True)
 def wrongType(p):
  d=sqlite3.connect(p);d.execute('PRAGMA writable_schema=ON');d.execute("UPDATE sqlite_master SET sql=replace(sql,'\"name\" TEXT NOT NULL','\"name\" BLOB NOT NULL') WHERE name='Currency'");d.execute('PRAGMA schema_version=900');d.commit();d.close()
 fixture('wrong-column-type',wrongType,True)
 fixture('zero-file',lambda p:p.write_bytes(b''),True)
 fixture('garbage-file',lambda p:p.write_bytes(b'not SQLite'),True)
 missing=root/'missing-parent'/'crm.sqlite';before=snapshot(root);run('reject',missing,'missing file creates no directory');assert before==snapshot(root)
 link=root/'link.sqlite';link.symlink_to(db);before=snapshot(root);run('reject',link,'symlink rejected');assert before==snapshot(root);link.unlink()
 link=root/'hardlink.sqlite';os.link(db,link);before=snapshot(root);run('reject',link,'hardlink rejected');assert before==snapshot(root);link.unlink()
 folder=root/'read-permissions';shutil.copytree(template,folder);p=folder/'crm.sqlite';p.chmod(0o440);folder.chmod(0o550)
 before=snapshot(folder);run('read',p,'0440 file 0550 parent');assert before==snapshot(folder);folder.chmod(0o700);p.chmod(0o600)
 # Actual WAL has a newer committed value: fail rather than silently returning
 # the older main-file page set via immutable mode.
 folder=root/'actual-wal';shutil.copytree(template,folder);p=folder/'crm.sqlite';writer=sqlite3.connect(p);writer.execute('PRAGMA journal_mode=WAL');writer.execute("UPDATE native_metadata SET value='new WAL state' WHERE key='fixture'");writer.commit()
 before=snapshot(folder);run('reject',p,'live WAL rejected without reading stale main');assert before==snapshot(folder);writer.close()
stable=all(sha(p)==hashes[p.name] for p in watched);prefixStable=copy.read_bytes()==data+testAccessSuffix and production.read_bytes()==data
proof={'status':'passed','checks':sum(r['checks'] for r in results),'scenarios':len(results),'results':results,'inputsSHA256':hashes,'productionInputsUnchanged':stable,'productionBytes':len(data),'productionPrefixSHA256':digest(data),'testOnlySuffixSHA256':digest(testAccessSuffix),'testOnlySuffixBytes':len(testAccessSuffix),'compiledCopySHA256':sha(copy),'productionPrefixIdentical':prefixStable,'dependenciesCompiledFromCurrentProductionPaths':True,'elapsedSeconds':round(time.time()-start,2),'binaryBytes':binary.stat().st_size,'temporaryFixturesRemoved':True,'scope':['Sealed, sidecar-free, immutable snapshot only; no identity bootstrap/selection or worker activation.','Persistent SQL denied by authorizer; all 63 mutation entry points guarded before hooks/no-op branches. TEMP search/report work remains supported and isolated from source tree.','Checks exact typed model table columns/declared types/nullability/ordered PK plus metadata hash/version. Full auxiliary DDL and restore seal must be independently validated by workspaceOpener.','Filesystem content/mode/owner/inode/link count/mtime/ctime/directory namespace unchanged across read/error/write-rejection paths. Filesystem-managed access time is not rewritten or guaranteed.','Concurrent external inode changes during the connection lifetime are forbidden by immutable contract; caller must retain exclusive sealed workspace ownership.']}
proofFile.write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');assert stable and prefixStable
print(json.dumps({k:proof[k] for k in ['status','checks','scenarios','productionInputsUnchanged','productionPrefixIdentical','binaryBytes']}))
