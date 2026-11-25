#!/usr/bin/env python3
"""Synthetic AppKit/SQLite maintenance UI; hidden unless --visible is explicit."""
import pathlib,json,hashlib,subprocess,tempfile,shutil,os,time,re,textwrap,sys,plistlib
ROOT=pathlib.Path(__file__).resolve().parents[2];NATIVE=ROOT/'desktop/native';BUILD=NATIVE/'build';BUILD.mkdir(exist_ok=True)
backup_runner=(NATIVE/'native-backup-test.py').read_text()
exec(compile(backup_runner[:backup_runner.index('SOURCE_EVIDENCE=')],str(NATIVE/'native-backup-test.py'),'exec'),globals())
names=json.loads((NATIVE/'NativeDataMaintenanceSources.json').read_text())+['NativeDataMaintenanceTests']
SOURCES=[NATIVE/(name+'.swift') for name in names]
tracked=SOURCES+[NATIVE/'NativeDataMaintenanceSources.json',pathlib.Path(__file__),NATIVE/'native-backup-test.py',NATIVE/'NativeDataMaintenanceFormat.md',NATIVE/'schema.json',NATIVE/'schema.sql']
hashes={str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in tracked};binary=BUILD/'NativeDataMaintenanceTests';log=BUILD/'native-data-maintenance-test.log';start=time.time()
with log.open('w') as output:subprocess.run(['swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-O','-whole-module-optimization',*[str(p) for p in SOURCES],'-framework','AppKit','-lsqlite3','-o',str(binary)],check=True,stdout=output,stderr=subprocess.STDOUT)
checks=0;visible='--visible' in sys.argv
executable=binary
if visible:
 app=BUILD/'NativeDataMaintenanceQA.app';contents=app/'Contents';macos=contents/'MacOS';macos.mkdir(parents=True,exist_ok=True)
 executable=macos/binary.name;shutil.copy2(binary,executable)
 (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.nextcrm.maintenance.qa','CFBundleName':'NextCRMDataMaintenanceQA','CFBundleDisplayName':'NextCRM 保全検証','CFBundleExecutable':binary.name,'CFBundlePackageType':'APPL','CFBundleVersion':'1','NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,'LSUIElement':False}))
working_before=set(pathlib.Path(tempfile.gettempdir()).glob('NextCRMMaintenance-*'))
with tempfile.TemporaryDirectory(prefix='NextCRMDataMaintenanceFixtures-') as temp:
 base=pathlib.Path(temp).resolve();template=base/'original';template.mkdir()
 with log.open('a') as output:subprocess.run([str(binary),'initialize',str(NATIVE),str(template/'crm.sqlite')],check=True,stdout=output,stderr=subprocess.STDOUT)
 fixture=backup_runner[backup_runner.index(' def connect(path):'):backup_runner.index(" sources=base/'sources'")]
 exec(compile(textwrap.dedent(fixture),str(NATIVE/'native-backup-test.py')+'#fixture','exec'),globals())
 assets[direct]=bytes(range(256))*8192;(template/direct).write_bytes(assets[direct])
 db=connect(template/'crm.sqlite');db.execute("UPDATE Users SET role='admin',userStatus='ACTIVE',banned=0 WHERE id=?",(user,));db.execute('UPDATE Documents SET size=?,content_hash=? WHERE id=?',(len(assets[direct]),digest(assets[direct]),document));db.execute('UPDATE native_document_processing SET content_hash=? WHERE document_id=?',(digest(assets[direct]),document))
 db.executemany('INSERT INTO native_outbox(id,event,payload,status,created_at) VALUES(?,?,?,?,?)',((key('ui-job-'+str(i)),'native.mail.send','{}','pending','2026-01-01T00:00:00Z') for i in range(350)));db.commit();db.close()
 (base/'actor.txt').write_text(user);before=table_snapshot(template/'crm.sqlite');initial_files={str(p.relative_to(template)):file_hash(p) for p in template.rglob('*') if p.is_file() and not p.name.startswith('crm.sqlite')}
 with log.open('a') as output:subprocess.run(['/usr/bin/time','-l',str(executable),'visible' if visible else 'hidden',str(NATIVE),str(base)],check=True,stdout=output,stderr=subprocess.STDOUT)
 ui=json.loads((base/'ui-results.json').read_text());backup=pathlib.Path(ui['backupPath']);restore=pathlib.Path(ui['restorePath'])
 assert table_snapshot(backup/'database.sqlite')==before and table_snapshot(restore/'crm.sqlite')==before;checks+=len(before)*6
 for source_,hash_ in initial_files.items():assert file_hash(template/source_)==hash_;checks+=1
 files=[json.loads(x) for x in (backup/'files.ndjson').read_text().splitlines()]
 for item in files:
  assert file_hash(backup/item['archivePath'])==item['sha256'] and file_hash(restore/item['sourcePath'])==item['sha256'];checks+=2
 snapshot_=json.loads((backup/'snapshot.json').read_text());result=json.loads((restore/'restore.json').read_text());assert snapshot_['sourceNamespaceSHA256']==result['sourceNamespaceSHA256']==ui['sourceNamespace'];checks+=2
 assert result['stagingNamespaceSHA256']==ui['stagingNamespace'] and not result['activated'] and not result['workersStarted'] and not result['keychainAccessed'];checks+=4
 assert file_hash(restore/'crm.sqlite')==result['databaseSHA256'] and file_hash(restore/'resume-plan.ndjson')==result['resumePlanSHA256'];checks+=2
 assert not list((base/'outputs').glob('.nextcrm-pending-*'));assert set(pathlib.Path(tempfile.gettempdir()).glob('NextCRMMaintenance-*'))==working_before;checks+=2
 fixture_bytes=sum(p.stat().st_size for p in base.rglob('*') if p.is_file() and not p.is_symlink())
 stable=all(digest((ROOT/p).read_bytes())==h for p,h in hashes.items());assert stable
 stats=log.read_text();rss=re.search(r'(\d+)\s+maximum resident set size',stats)
 proof={'ok':True,'uiChecks':ui['checks'],'roundtripChecks':checks,'checks':ui['checks']+checks,'visiblePanel':visible,'sourceHashes':hashes,'sourceHashesStable':stable,'maximumResidentBytes':int(rss[1]) if rss else None,'seconds':round(time.time()-start,2),'binaryBytes':binary.stat().st_size,'temporaryFixtureBytes':fixture_bytes,'models':92,'tables':len(before),'managedFiles':len(files),'jobsInPlan':result['planRows'],'limitations':['Synthetic AppKit + SQLite only; no normal app data, Keychain, external transfer or activation.',('System file choosers completed by CUA button clicks; Finder reveal remains injected, and clipboard changeCount is checked without reading contents.' if visible else 'File choosers and Finder reveal callbacks are injected; system clipboard changeCount is checked without reading its contents.'),'Closing after the authorized commit seal preserves successful publication; before the seal, cancellation removes the attempt.','Existing artifact inspection hashes streamed pages; actual activation must reverify the full database/assets and resolve all eight obligations.']}
 (BUILD/'native-data-maintenance-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceHashes','limitations']}))
