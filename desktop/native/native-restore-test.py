#!/usr/bin/env python3
"""Offline backup -> restore -> actual NativeDatabase roundtrip, no external I/O."""
import pathlib,json,hashlib,subprocess,tempfile,shutil,os,time,re,textwrap
ROOT=pathlib.Path(__file__).resolve().parents[2];NATIVE=ROOT/'desktop/native';BUILD=NATIVE/'build';BUILD.mkdir(exist_ok=True)
# Reuse fixture definitions only; importing this text never runs the backup runner.
backup_runner=(NATIVE/'native-backup-test.py').read_text()
exec(compile(backup_runner[:backup_runner.index('SOURCE_EVIDENCE=')],str(NATIVE/'native-backup-test.py'),'exec'),globals())
SOURCES=[p for p in SOURCES if p.name!='NativeBackupTests.swift']+[NATIVE/(n+'.swift') for n in ['NativeRestoreTypes','NativeRestoreSchema','NativeRestoreWorkspace','NativeRestorePlan','NativeRestore','NativeRestoreTests']]
EVIDENCE=['NativeRestoreFormat.md','native-backup-test.py','NativeDatabase.swift','NativeProviderRuntimeTasks.swift','NativePluginsRuntime.swift','NativePluginsCredentials.swift','NativeMailSend.swift','GoogleCalendarPushWorker.swift', 'NativeUserCredentialCleanup.swift','NativeMailSync.swift','NativeMCPSettings.swift','NativeMCPCredentials.swift','NativeAICredentials.swift','NativeMailCredentials.swift','InvoiceMailCredentials.swift','GoogleCalendarCredentials.swift','CalendlyCredentials.swift','CampaignRelayCredentials.swift','CampaignRelaySync.swift','CalendlyRelaySync.swift']
tracked=list(dict.fromkeys(SOURCES+[NATIVE/x for x in EVIDENCE]+[NATIVE/'schema.json',NATIVE/'schema.sql',pathlib.Path(__file__)]));hashes={str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in tracked}
binary=BUILD/'NativeRestoreTests';log=BUILD/'native-restore-test.log';start=time.time();checks=0
with log.open('w') as output:subprocess.run(['swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-O','-whole-module-optimization',*[str(p) for p in SOURCES],'-lsqlite3','-o',str(binary)],check=True,stdout=output,stderr=subprocess.STDOUT)
with tempfile.TemporaryDirectory(prefix='NextCRMNativeRestoreFixtures-') as temp:
 base=pathlib.Path(temp).resolve();template=base/'original';template.mkdir()
 with log.open('a') as output:subprocess.run([str(binary),'initialize',str(NATIVE/'schema.json'),str(NATIVE/'schema.sql'),str(template/'crm.sqlite')],check=True,stdout=output,stderr=subprocess.STDOUT)
 # This shared fixture populates all 92 models, native aux/queues and seven assets.
 fixture=backup_runner[backup_runner.index(' def connect(path):'):backup_runner.index(" sources=base/'sources'")]
 exec(compile(textwrap.dedent(fixture),str(NATIVE/'native-backup-test.py')+'#fixture','exec'),globals())
 db=connect(template/'crm.sqlite')
 for k,v in [('mail.sync.cursor.synthetic.INBOX','{"validity":1,"uid":10}'),('campaignRelay.binding.v1','{"cursor":12,"instanceID":"synthetic"}'),('calendlyRelay.clientID.v1',key('relay-client')),('mcp.settings.v1','{"enabled":true,"secretID":"synthetic-key-only"}'),('mcp.signing.cleanup.v1','{}'),('plugins.secrets.cleanup.v1','{}')]:db.execute('INSERT INTO native_metadata VALUES(?,?)',(k,v))
 for i,state in enumerate(['pending','retry','running','needs_review','done','cancelled','unknown-state']):
  id=key('restore-job-'+state);result={'providerID':'synthetic-receipt'} if state=='done' else {'smtpAccepted':'true'} if state=='retry' else {}
  db.execute('INSERT INTO native_outbox(id,event,payload,status,created_at,lease_token,lease_until,delivery_started_at,result) VALUES(?,?,?,?,?,?,?,?,?)',(id,'native.mail.send','{}',state,'2026-01-01T00:00:00Z','old-lease' if state=='running' else None,123456 if state=='running' else None,123455 if state in ['running','needs_review','retry','done'] else None,json.dumps(result)))
 for outcome in ['confirmed','unknown']:
  db.execute('INSERT INTO native_outbox(id,event,payload,status,created_at,delivery_started_at,result) VALUES(?,?,?,?,?,?,?)',(key('calendar-'+outcome),'calendar/outbound','{}','needs_review','2026-01-01T00:00:00Z',123455,json.dumps({'requestOutcome':outcome})))
 db.commit();db.close()
 backup=base/'completed-backup';spec=base/'backup-request.json';spec.write_text(json.dumps({'source':str(template/'crm.sqlite'),'destination':str(backup)}))
 with log.open('a') as output:subprocess.run([str(binary),'backup',str(NATIVE/'schema.json'),str(NATIVE/'schema.sql'),str(spec)],check=True,stdout=output,stderr=subprocess.STDOUT)
 original_tables=table_snapshot(template/'crm.sqlite');assert table_snapshot(backup/'database.sqlite')==original_tables;checks+=len(original_tables)
 backups=base/'backups';backups.mkdir();outputs=base/'outputs';outputs.mkdir();cases=[];expected={};before={};before_tables={}
 def snapshot(f):return {str(p.relative_to(f)):file_hash(p) for p in f.rglob('*') if p.is_file() and not p.is_symlink()}
 def manifest(f,fn):
  p=f/'snapshot.json';v=json.loads(p.read_text());fn(v);p.write_text(json.dumps(v))
 def rewrite_lines(f,name,fn):
  p=f/name;values=[json.loads(x) for x in p.read_text().splitlines()];fn(values);p.write_bytes(b''.join(data(x) for x in values));field='filesManifestSHA256' if name=='files.ndjson' else 'tablesManifestSHA256';manifest(f,lambda m:m.update({field:file_hash(p)}))
 def rehash_database(f,mutation):
  db=connect(f/'database.sqlite');mutation(db);db.commit();db.close()
  all_=table_snapshot(f/'database.sqlite');tables=[{'name':n,'rows':v[1],'schemaSHA256':digest((v[0] or '').encode())} for n,v in all_.items()];(f/'tables.ndjson').write_bytes(b''.join(data(x) for x in tables))
  manifest(f,lambda m:m.update(databaseBytes=(f/'database.sqlite').stat().st_size,databaseSHA256=file_hash(f/'database.sqlite'),tablesManifestSHA256=file_hash(f/'tables.ndjson'),tableCount=len(tables),totalRows=sum(v[1] for v in all_.values())))
 def make(name,*,status='staged',code=None,mutate=None,**options):
  folder=backups/name;shutil.copytree(backup,folder)
  if mutate:mutate(folder)
  destination=outputs/name;cases.append({'name':name,'backup':str(folder),'destination':str(destination),**options});expected[name]=(status,code);before[name]=snapshot(folder)
  if status=='staged':before_tables[name]=table_snapshot(folder/'database.sqlite')
  return folder,destination
 make('complete-roundtrip')
 for point in ['beforeRead','beforeDirectory','beforeDatabase','databaseChunk','manifestChunk','table','afterDatabase','asset','assetChunk','beforeReferences','reference','beforePlan','planRow','beforePublish','afterResult']:
  make('fail-'+point,status='failed',code='test.failure',failAt=point)
  make('cancel-'+point,status='cancelled',code='restore.cancelled',cancelAt=point)
 make('manifest-not-completed',status='failed',code='restore.manifest',mutate=lambda f:manifest(f,lambda m:m.update(candidateCreated=False)))
 make('manifest-version',status='failed',code='restore.manifest',mutate=lambda f:manifest(f,lambda m:m.update(formatVersion=2)))
 make('manifest-state-inconsistent',status='failed',code='restore.manifest',mutate=lambda f:manifest(f,lambda m:m.update(status='prepared')))
 make('remote-schema-rejected-offline',status='failed',code='restore.schema',remoteSchema=True)
 make('manifest-size-limit',status='failed',code='limit.file',mutate=lambda f:(f/'snapshot.json').write_bytes(b' '*((4*1024*1024)+1)))
 def long_line(f):
  p=f/'files.ndjson';p.write_bytes(b'{"oversize":"'+b'x'*65536+b'"}\n');manifest(f,lambda m:m.update(filesManifestSHA256=file_hash(p)))
 make('manifest-line-limit',status='failed',code='limit.line',mutate=long_line)

 make('manifest-wrong-type',status='failed',code='restore.manifest',mutate=lambda f:manifest(f,lambda m:m.update(fileCount='7')))
 make('manifest-unknown-field',status='failed',code='restore.manifest',mutate=lambda f:manifest(f,lambda m:m.update(unexpected=True)))
 def duplicate_json(f):p=f/'snapshot.json';p.write_text(p.read_text().replace('{','{"formatVersion":1,',1))
 make('manifest-duplicate-key',status='failed',code='json.syntax',mutate=duplicate_json)
 make('database-hash',status='failed',code='restore.hash',mutate=lambda f:manifest(f,lambda m:m.update(databaseSHA256='0'*64)))
 make('tables-hash',status='failed',code='restore.manifest_hash',mutate=lambda f:(f/'tables.ndjson').write_bytes(b'{}\n'))
 make('files-hash',status='failed',code='restore.manifest_hash',mutate=lambda f:(f/'files.ndjson').write_bytes(b'{}\n'))
 make('table-count',status='failed',code='restore.table',mutate=lambda f:rewrite_lines(f,'tables.ndjson',lambda rows:rows[0].update(rows=rows[0]['rows']+1)))
 make('table-missing',status='failed',code='file.digest',mutate=lambda f:rewrite_lines(f,'tables.ndjson',lambda rows:rows.pop()))
 make('table-duplicate',status='failed',code='restore.duplicate',mutate=lambda f:rewrite_lines(f,'tables.ndjson',lambda rows:rows.append(rows[0])))
 make('schema-revision',status='failed',code='restore.revision',mutate=lambda f:rehash_database(f,lambda db:db.execute("UPDATE native_metadata SET value=? WHERE key='schemaSHA256'",('0'*64,))))
 make('record-revision',status='failed',code='restore.revision',mutate=lambda f:rehash_database(f,lambda db:db.execute('UPDATE Users SET _native_revision=0')))
 make('mapping-revision',status='failed',code='restore.revision',mutate=lambda f:rehash_database(f,lambda db:db.execute('UPDATE native_document_objects SET revision=0')))
 make('crm-schema',status='failed',code='restore.schema',mutate=lambda f:rehash_database(f,lambda db:db.execute('ALTER TABLE Users ADD COLUMN unexpected TEXT')))
 make('missing-auxiliary',status='failed',code='restore.schema',mutate=lambda f:rehash_database(f,lambda db:db.execute('DROP TABLE native_legacy_accounts')))
 def bad_fk(f):
  db=connect(f/'database.sqlite');db.execute('PRAGMA foreign_keys=OFF');db.execute('UPDATE native_document_processing SET document_id=?',(key('missing-parent'),));db.commit();db.close();rehash_database(f,lambda db:None)
 make('foreign-key',status='failed',code='restore.integrity',mutate=bad_fk)
 make('asset-unsafe-source',status='failed',code='path.unsafe',mutate=lambda f:rewrite_lines(f,'files.ndjson',lambda rows:rows[0].update(sourcePath='../outside')))
 make('asset-unsafe-archive',status='failed',code='restore.asset',mutate=lambda f:rewrite_lines(f,'files.ndjson',lambda rows:rows[0].update(archivePath='../../outside')))
 make('asset-duplicate',status='failed',code='restore.duplicate',mutate=lambda f:rewrite_lines(f,'files.ndjson',lambda rows:rows.append(rows[0])))
 def asset_path(f):return f/json.loads((f/'files.ndjson').read_text().splitlines()[0])['archivePath']
 make('asset-missing',status='failed',code='file.read',mutate=lambda f:asset_path(f).unlink())
 make('asset-corrupt',status='failed',code='restore.hash',mutate=lambda f:asset_path(f).write_bytes(b'changed'))
 def symlink_asset(f):p=asset_path(f);p.unlink();p.symlink_to(f/'database.sqlite')
 make('asset-symlink',status='failed',code='file.read',mutate=symlink_asset)
 def omitted_asset(f):
  rewrite_lines(f,'files.ndjson',lambda rows:rows.pop());lines=[json.loads(x) for x in (f/'files.ndjson').read_text().splitlines()];manifest(f,lambda m:m.update(fileCount=len(lines),totalFileBytes=sum(x['bytes'] for x in lines)))
 make('asset-omitted-from-inventory',status='failed',code='file.read',mutate=omitted_asset)
 def undeclared_extra(f):
  extra={'sourcePath':'native-documents/'+key('unreferenced-restore')+'.txt','archivePath':'assets/'+digest(b'extra')+'.blob','bytes':5,'sha256':digest(b'extra')};(f/extra['archivePath']).write_bytes(b'extra');rewrite_lines(f,'files.ndjson',lambda rows:rows.append(extra));manifest(f,lambda m:m.update(fileCount=m['fileCount']+1,totalFileBytes=m['totalFileBytes']+5))
 make('asset-unreferenced',status='failed',code='restore.references',mutate=undeclared_extra)
 make('pending-omitted',status='failed',code='restore.pending',mutate=lambda f:manifest(f,lambda m:m.update(pending=[p for p in m['pending'] if p!='externalFiles'])))
 make('manifest-changed-during-staging',status='failed',code='restore.changed',mutateManifest=True)
 make('auxiliary-schema',status='failed',code='restore.schema',mutate=lambda f:rehash_database(f,lambda db:db.execute('ALTER TABLE native_ai_key_cleanup ADD COLUMN extra TEXT')))
 def large_asset(f):
  rows_=[json.loads(x) for x in (f/'files.ndjson').read_text().splitlines()];item=next(x for x in rows_ if x['sourcePath']==direct);p=f/item['archivePath'];h=hashlib.sha256()
  with p.open('wb') as output:
   for _ in range(512):chunk=bytes(range(256))*256;output.write(chunk);h.update(chunk)
  item.update(bytes=p.stat().st_size,sha256=h.hexdigest());(f/'files.ndjson').write_bytes(b''.join(data(x) for x in rows_))
  manifest(f,lambda m:m.update(filesManifestSHA256=file_hash(f/'files.ndjson'),totalFileBytes=sum(x['bytes'] for x in rows_)))
  rehash_database(f,lambda db:db.execute('UPDATE Documents SET size=?,content_hash=? WHERE key=?',(item['bytes'],item['sha256'],direct)))
 make('large-32mib',mutate=large_asset)
 make('cancel-partial-asset',status='cancelled',code='restore.cancelled',mutate=large_asset,cancelAt='assetChunk',occurrence=10)
 def many_assets(f):
  rows_=[json.loads(x) for x in (f/'files.ndjson').read_text().splitlines()];records=[]
  for i in range(2048):
   content=('restore asset '+str(i)).encode();hash_=digest(content);path='native-documents/'+key('restore-many-'+str(i))+'.bin';archive='assets/'+hash_+'.blob';(f/archive).write_bytes(content);rows_.append({'sourcePath':path,'archivePath':archive,'bytes':len(content),'sha256':hash_});records.append(('synthetic','restore-many/'+str(i),path,'application/octet-stream',len(content),hash_,1,'2026-01-01T00:00:00Z'))
  (f/'files.ndjson').write_bytes(b''.join(data(x) for x in rows_));manifest(f,lambda m:m.update(fileCount=len(rows_),totalFileBytes=sum(x['bytes'] for x in rows_),filesManifestSHA256=file_hash(f/'files.ndjson')))
  rehash_database(f,lambda db:db.executemany('INSERT INTO native_document_objects VALUES(?,?,?,?,?,?,?,?)',records))
 make('files-2048',mutate=many_assets)
 def many_jobs(f):
  rehash_database(f,lambda db:db.executemany('INSERT INTO native_outbox(id,event,payload,status,created_at,lease_token,lease_until,delivery_started_at) VALUES(?,?,?,?,?,?,?,?)',((key('bulk-job-'+str(i)),'plugin/custom','{}','running','2026-01-01T00:00:00Z','synthetic-old-lease',100,99) for i in range(50000))))
 make('jobs-50000',mutate=many_jobs)
 make('cancel-partial-plan',status='cancelled',code='restore.cancelled',mutate=many_jobs,cancelAt='planRow',occurrence=1000)
 def missing_original(f):
  rows_=[json.loads(x) for x in (f/'files.ndjson').read_text().splitlines()];removed=next(x for x in rows_ if '.original.' in x['sourcePath']);rows_.remove(removed);(f/removed['archivePath']).unlink();(f/'files.ndjson').write_bytes(b''.join(data(x) for x in rows_));manifest(f,lambda m:m.update(fileCount=len(rows_),totalFileBytes=sum(x['bytes'] for x in rows_),filesManifestSHA256=file_hash(f/'files.ndjson'),pending=m['pending']+['avatarOriginal']))
 make('legacy-original-pending',mutate=missing_original)

 _,existing=make('existing-destination',status='failed',code='candidate.exists');existing.mkdir();(existing/'keep').write_bytes(b'keep')
 f,d=make('symlink-destination-parent',status='failed',code='path.unsafe');link=base/'linked-outputs';link.symlink_to(outputs,target_is_directory=True);cases[-1]['destination']=str(link/d.name)
 spec=base/'restore-cases.json';spec.write_text(json.dumps(cases));fixture_bytes=sum(p.stat().st_size for p in base.rglob('*') if p.is_file() and not p.is_symlink())
 with log.open('a') as output:subprocess.run(['/usr/bin/time','-l',str(binary),'restore',str(NATIVE/'schema.json'),str(NATIVE/'schema.sql'),str(spec)],check=True,stdout=output,stderr=subprocess.STDOUT)
 outcomes=json.loads((base/'results.json').read_text());errors=[]
 for outcome in outcomes:
  name=outcome['name'];r=outcome['result'];status,code=expected[name];codes={d['code'] for d in r['diagnostics']};folder=backups/name;dest=outputs/name
  if r['status']!=status or code and code not in codes:errors.append({'name':name,'expected':status,'result':r['status'],'diagnostics':r['diagnostics']});continue
  checks+=2;assert not r['activated'] and not r['workersStarted'] and not r['keychainAccessed'];assert r['activationGate']['phase']=='requiresActivationReview' and len(r['activationGate']['obligations'])==8;checks+=5
  current=snapshot(folder)
  if name=='manifest-changed-during-staging':current.pop('snapshot.json');wanted={k:v for k,v in before[name].items() if k!='snapshot.json'}
  else:wanted=before[name]
  assert current==wanted,('source changed',name);checks+=len(wanted)
  if r['candidateCreated']:
   assert outcome['opened'] and outcome['modelsRead']==92;checks+=93
   assert table_snapshot(dest/'crm.sqlite')==before_tables[name];checks+=len(before_tables[name])*3
   assert file_hash(dest/'crm.sqlite')==r['databaseSHA256'];checks+=1
   for file,field in [('files.ndjson','filesManifestSHA256'),('tables.ndjson','tablesManifestSHA256'),('backup-snapshot.json','backupManifestSHA256')]:assert file_hash(dest/file)==r[field];checks+=1
   assert (dest.stat().st_mode&0o777)==0o700;checks+=1
   records=[json.loads(x) for x in (folder/'files.ndjson').read_text().splitlines()]
   for item in records:
    p=dest/item['sourcePath'];assert file_hash(p)==item['sha256'] and p.stat().st_size==item['bytes'];assert p.stat().st_nlink==1;checks+=3
    if item['sourcePath'].startswith(('native-avatars/','native-documents/')):assert p.stat().st_mode&0o777==0o400;checks+=1
   plan=[json.loads(x) for x in (dest/'resume-plan.ndjson').read_text().splitlines()];assert len(plan)==r['planRows'] and file_hash(dest/'resume-plan.ndjson')==r['resumePlanSHA256'];checks+=2
   assert not any((dest/x).exists() for x in ['restore-index.sqlite','schema-reference.sqlite','pins']);checks+=3
  elif name!='existing-destination':assert not dest.exists(),('candidate leak',name);checks+=1
 assert not list(outputs.glob('restore-inspection-*'));assert (existing/'keep').read_bytes()==b'keep';checks+=2
 if errors:print(json.dumps(errors[:10],ensure_ascii=False));raise SystemExit(1)
 byname={x['name']:x['result'] for x in outcomes};assert byname['files-2048']['fileCount']==2055 and byname['jobs-50000']['planRows']>50000 and 'avatarOriginal' in byname['legacy-original-pending']['inheritedPending'];checks+=3
 good=outcomes[0]['result'];plan=[json.loads(x) for x in (outputs/'complete-roundtrip/resume-plan.ndjson').read_text().splitlines()];byid={x['key']:x for x in plan if x['model']=='native_outbox'}
 assert 'deliveryUnknown' in byid[key('restore-job-running')]['flags'] and 'leaseOwnership' in byid[key('restore-job-running')]['flags'];checks+=2
 assert 'receiptRecorded' in byid[key('restore-job-retry')]['flags'] and byid[key('restore-job-done')]['kind']=='terminalReceipt';checks+=2
 assert 'unknownState' in byid[key('restore-job-unknown-state')]['flags'];checks+=1
 assert 'receiptRecorded' in byid[key('calendar-confirmed')]['flags'] and 'deliveryUnknown' in byid[key('calendar-unknown')]['flags'];checks+=2
 assert {'credential','credentialCleanup','relayBinding','mailCursor','serviceSetting','pluginState','keychainOnlySettings'}<={x['kind'] for x in plan};checks+=7
 assert 'synthetic-key-only' not in (outputs/'complete-roundtrip/resume-plan.ndjson').read_text();checks+=1
 stable=all(digest((ROOT/p).read_bytes())==h for p,h in hashes.items());assert stable
 stats=log.read_text();rss=re.search(r'(\d+)\s+maximum resident set size',stats)
 proof={'ok':True,'scenarios':len(outcomes),'checks':checks,'sourceHashes':hashes,'sourceHashesStable':stable,'maximumResidentBytes':int(rss[1]) if rss else None,'seconds':round(time.time()-start,2),'binaryBytes':binary.stat().st_size,'temporaryFixtureBytes':fixture_bytes,'modelsRead':92,'largeAssetBytes':33554432,'manyAssets':2048,'manyJobs':50000,'tableCount':good['tableCount'],'fileCount':good['fileCount'],'planRows':good['planRows'],'planCounts':good['planCounts'],'activationGate':good['activationGate'],'limitations':['Only private offline staging; no activation, Keychain, external I/O or worker start.','Actual NativeDatabase opens restored synthetic data; all original tables/aux/receipts and asset bytes are compared.','Unsigned manifest provenance, final namespace binding and external outcome reconciliation require the separate activation component.']}
 (BUILD/'native-restore-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceHashes','activationGate','limitations']}))
