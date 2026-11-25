#!/usr/bin/env python3
"""Real native SQLite snapshots, isolated concurrent writers and managed assets."""
import base64, copy, hashlib, json, os, pathlib, re, shutil, struct, subprocess, tempfile, uuid, time
ROOT=pathlib.Path(__file__).resolve().parents[2]
NATIVE=ROOT/'desktop/native'; BUILD=NATIVE/'build'; BUILD.mkdir(exist_ok=True)
SOURCES=[NATIVE/(x+'.swift') for x in ['NativeDatabase','NativeMigrationManifest','NativeMigrationJSON','NativeMigrationCodec','NativeMigrationFiles','NativeMigrationImportWorkspace','NativeBackupTypes','NativeBackupSQLite','NativeBackupWorkspace','NativeCredentialArchiveBinding','NativeOperationalAssets','NativeBackupOperationalAssets','NativeBackupInventory','NativeBackup','NativeBackupTests', 'MailReview']]
SCHEMA=json.loads((NATIVE/'schema.json').read_text()); MODELS={x['name']:x for x in SCHEMA['models']}
assert SCHEMA['schemaSHA256']==hashlib.sha256((ROOT/'prisma/schema.prisma').read_bytes()).hexdigest()
assert list(MODELS)==re.findall(r'^model\s+(\w+)\s*\{',(ROOT/'prisma/schema.prisma').read_text(),re.M)
def digest(b):return hashlib.sha256(b).hexdigest()
def data(v):return (json.dumps(v,ensure_ascii=False,separators=(',',':'))+'\n').encode()
def key(name):return str(uuid.uuid5(uuid.NAMESPACE_URL,'nextcrm-migration-fixture/'+name))
def cell(model,f):
 if f['optional']:return None
 t=f['type'];a=f['attributes']
 if f['array']:return []
 if t in SCHEMA['enums']:return SCHEMA['enums'][t][0]
 if t in ['Int','BigInt','Decimal']:return '0'
 if t=='Boolean':return False
 if t=='DateTime':return '2024-02-29' if re.search(r'@db.Date(?:\s|$)',a) else '2024-02-29T00:00:00.123456Z'
 if t=='Json':return {'json':'{}'}
 if t.startswith('Unsupported("vector'):return {'base64':base64.b64encode(bytes(6144)).decode()}
 if '@db.Uuid' in a:return key(model+'.'+f['name'])
 n=re.search(r'@db.VarChar\((\d+)\)',a)
 return ('JPY' if n else 'value-'+model+'-'+f['name'])[:int(n[1])] if n else 'value-'+model+'-'+f['name']
def rows():
 out={name:[{f['name']:cell(name,f) for f in model['fields']}] for name,model in MODELS.items()}
 for _ in range(4):
  for name,model in MODELS.items():
   for rel in model['relations']:
    match=re.search(r'fields:\s*\[([^]]+)\].*?references:\s*\[([^]]+)\]',rel['attributes'])
    if match:
     for a,b in zip(match[1].replace(' ','').split(','),match[2].replace(' ','').split(',')):out[name][0][a]=out[rel['type']][0][b]
 for name,fields in {'ApiKeys':['encryptedKey'],'EmailAccount':['passwordEncrypted'],'CalendarConnection':['accessTokenEncrypted','refreshTokenEncrypted'],'InstalledPlugin':['secrets']}.items():
  for field in fields:
   if out[name][0].get(field) is not None:out[name][0][field]=base64.b64encode(bytes(range(32))).decode()
 return out
ASSETS={'Documents':['key','document_file_url','thumbnail_url'],'Invoices':['pdfStorageKey'],'Invoice_Attachments':['storageKey'],'Users':['avatar','image']}
SECRETS={'Users':['password'],'ApiKeys':['encryptedKey'],'EmailAccount':['passwordEncrypted'],'CalendarConnection':['accessTokenEncrypted','refreshTokenEncrypted'],'InstalledPlugin':['secrets'],'systemServices':['servicePassword'],'Session':['token'],'Account':['accessToken','refreshToken','idToken','password'],'Verification':['value'],'ApiToken':['tokenHash'],'crm_campaign_sends':['unsubscribe_token']}
def ref(name,row,field=None):
 r={'model':name,'key':{x:row[x] for x in MODELS[name]['primaryKey']}}
 if field is not None:r['field']=field
 return r
def inventories(records):
 assets=[];secrets=[]
 for name,items in records.items():
  for row in items:
   for field in ASSETS.get(name,[]):
    if row.get(field):assets.append({'id':'asset-'+str(len(assets)),'path':'objects/'+str(len(assets))+'.bin','bytes':3,'sha256':digest(b'\x00\xffA'),'owners':[ref(name,row,field)],'storageKey':row[field]})
   for field in SECRETS.get(name,[]):
    if row.get(field):secrets.append({'id':'secret-'+str(len(secrets)),'purpose':name+'.'+field,'storage':('server-aes256gcm' if name in ['ApiKeys','EmailAccount','CalendarConnection','InstalledPlugin'] else 'opaque-auth'),'valueSHA256':digest(row[field].encode()),'owner':ref(name,row,field)})
 return assets,secrets
import sqlite3
SOURCE_EVIDENCE=['NativeUserAvatarStore.swift','NativeDocumentFiles.swift','NativeMCPDocumentObjectStore.swift','CRMInvoicePDF.swift','CRMInvoiceMail.swift','CampaignMailWorker.swift','NativeReportMail.swift','NativePluginsMail.swift']
tracked=SOURCES+[NATIVE/'schema.json',NATIVE/'schema.sql',NATIVE/'NativeBackupFormat.md',pathlib.Path(__file__)]+[NATIVE/x for x in SOURCE_EVIDENCE]
hashes={str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in tracked}
binary=BUILD/'NativeBackupTests';log=BUILD/'native-backup-test.log';start=time.time()
with log.open('w') as out:
 subprocess.run(['swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-O','-whole-module-optimization',*[str(x) for x in SOURCES],'-lsqlite3','-o',str(binary)],check=True,stdout=out,stderr=subprocess.STDOUT)
checks=2 # SQLite progress-handler interruption assertions in the Swift fixture.
with tempfile.TemporaryDirectory(prefix='NextCRMNativeBackupFixtures-') as td:
 base=pathlib.Path(td).resolve();template=base/'template';template.mkdir()
 with log.open('a') as out:subprocess.run([str(binary),'initialize',str(NATIVE/'schema.json'),str(NATIVE/'schema.sql'),str(template/'crm.sqlite')],check=True,stdout=out,stderr=subprocess.STDOUT)
 def connect(path):
  db=sqlite3.connect(path);db.create_collation('native_email',lambda a,b:(a.lower()>b.lower())-(a.lower()<b.lower()));db.create_collation('native_japanese',lambda a,b:(a>b)-(a<b));db.create_collation('native_decimal',lambda a,b:(float(a)>float(b))-(float(a)<float(b)));db.execute('PRAGMA foreign_keys=ON');return db
 original=rows();user=original['Users'][0]['id'];document=original['Documents'][0]['id']
 direct='native-documents/'+key('backup-direct')+'.txt';mapped='native-documents/'+key('backup-mapped')+'.bin';pdf='invoice-pdfs/'+key('backup-pdf')+'.pdf'
 avatarid=key('backup-avatar');thumb='native-avatars/'+avatarid+'.png';avatar_original='native-avatars/'+avatarid+'.original.png'
 invoice_job=key('backup-invoice-job');notify_job=key('backup-notify-job');mail_job=key('backup-mail-job')
 assets={direct:b'direct snapshot document',mapped:b'mapped immutable document',pdf:b'%PDF synthetic snapshot',thumb:base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3e0AAAAASUVORK5CYII='),avatar_original:b'synthetic original bytes preserved', 'mail-outbox/'+invoice_job+'.json':b'{"text":"invoice frozen"}','mail-outbox/'+notify_job+'.json':b'{"text":"notification frozen"}'}
 original['Users'][0]['avatar']='native-avatar:v1:'+avatarid+'.png';original['Users'][0]['image']=None
 original['Documents'][0].update(key=direct,size=str(len(assets[direct])),content_hash=digest(assets[direct]),document_file_url='nextcrm-local://'+direct,thumbnail_url=None)
 original['Invoices'][0]['pdfStorageKey']=pdf;original['Invoice_Attachments'][0].update(storageKey=pdf,size=str(len(assets[pdf])))
 db=connect(template/'crm.sqlite');db.execute('BEGIN')
 for name,records in original.items():
  fields=MODELS[name]['fields']
  for row in records:
   values=[]
   for f in fields:
    v=row[f['name']]
    if v is None:values.append(None)
    elif f['array']:values.append(json.dumps(v,ensure_ascii=False))
    elif f['type'] in ['Int','BigInt','Boolean']:values.append(int(v))
    elif f['type']=='Json':values.append(v['json'])
    elif f['type'].startswith('Unsupported("vector'):values.append(base64.b64decode(v['base64']))
    else:values.append(v)
   db.execute('INSERT INTO "'+name+'"('+','.join('"'+f['column']+'"' for f in fields)+') VALUES('+','.join('?' for _ in fields)+')',values)
 db.execute("INSERT INTO native_metadata VALUES('document.storage.bucket','synthetic')");db.execute("INSERT INTO native_metadata VALUES('backup.left','before')");db.execute("INSERT INTO native_metadata VALUES('backup.right','before')")
 db.execute('INSERT INTO native_document_objects VALUES(?,?,?,?,?,?,?,?)',('synthetic','logical/object',mapped,'application/octet-stream',len(assets[mapped]),digest(assets[mapped]),3,'2026-01-01T00:00:00Z'))
 for id,event,payload,result,status in [(invoice_job,'invoice.email_requested',{'sha256':digest(assets['mail-outbox/'+invoice_job+'.json']),'bytes':str(len(assets['mail-outbox/'+invoice_job+'.json']))},None,'pending'),(notify_job,'crm.task_assigned',{}, {'sha256':digest(assets['mail-outbox/'+notify_job+'.json']),'bytes':str(len(assets['mail-outbox/'+notify_job+'.json']))},'needs_review'),(key('done-body'),'reports.scheduled',{}, {'sha256':'0'*64,'bytes':'999'},'done'),(mail_job,'native.mail.send',{},None,'running')]:
  db.execute('INSERT INTO native_outbox(id,event,payload,status,created_at,result) VALUES(?,?,?,?,?,?)',(id,event,json.dumps(payload),status,'2026-01-01T00:00:00Z',json.dumps(result) if result is not None else None))
 db.execute('INSERT INTO native_mail_sends VALUES(?,?,?,?,?,?)',(mail_job,original['EmailAccount'][0]['id'],user,'synthetic-message','synthetic summary',b'fake MIME '+bytes(512*1024)))
 db.execute('INSERT INTO native_ai_key_cleanup VALUES(?,?)',(key('fake-keychain-reference'),123456.0))
 db.execute('INSERT INTO native_document_processing VALUES(?,?,?,?,?,?,?, ?,?)',(document,invoice_job,direct,digest(assets[direct]),20,1,1,b'thumbnail blob','synthetic note'))
 db.execute('INSERT INTO native_document_text VALUES(?,?,?)',(document,0,'保存する日本語本文'))
 db.execute('CREATE TABLE native_backup_extra(a TEXT,b INTEGER,PRIMARY KEY(a,b)) WITHOUT ROWID');db.executemany('INSERT INTO native_backup_extra VALUES(?,?)',[('opaque',1),('opaque',2)])
 db.commit();db.close()
 for path,value in assets.items():p=template/path;p.parent.mkdir(exist_ok=True);p.write_bytes(value);p.chmod(0o400 if path.startswith('native-avatars/') else 0o600)
 (template/'native-documents'/('.stage-'+key('unpublished')+'.txt')).write_bytes(b'partial unpublished')
 (template/'native-avatars'/(key('pending-avatar')+'.pending.png')).write_bytes(b'pending')
 (template/'native-avatars'/(key('pending-avatar')+'.pending.original.png')).write_bytes(b'pending original')
 (template/'mail-outbox'/(key('transient-plugin-body')+'.json')).write_bytes(b'transient plugin notification')
 def file_hash(path):
  h=hashlib.sha256()
  with path.open('rb') as f:
   for chunk in iter(lambda:f.read(65536),b''):h.update(chunk)
  return h.hexdigest()
 def table_snapshot(path):
  db=connect(path);output={}
  for name,sql in db.execute("SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name").fetchall():
   q='"'+name.replace('"','""')+'"';info=list(db.execute('PRAGMA table_info('+q+')'));keys=[r[1] for r in sorted(info,key=lambda r:r[5]) if r[5]]
   order=','.join('"'+k+'"' for k in keys) if 'WITHOUT ROWID' in (sql or '').upper() else 'rowid'
   h=hashlib.sha256();count=0
   for row in db.execute('SELECT * FROM '+q+' ORDER BY '+order):h.update(data([{'blob':base64.b64encode(v).decode()} if isinstance(v,bytes) else v for v in row]));count+=1
   output[name]=(sql,count,h.hexdigest())
  db.close();return output
 sources=base/'sources';sources.mkdir();outputs=base/'outputs';outputs.mkdir();cases=[];expected={};before={};before_files={}
 def make(name,*,status='preparedWithPending',code=None,mutate=None,**options):
  folder=sources/name;shutil.copytree(template,folder)
  if mutate:mutate(folder)
  destination=outputs/name
  cases.append({'name':name,'source':str(folder/'crm.sqlite'),'destination':str(destination),'documentID':document,'userID':user,**options});expected[name]=(status,code)
  before[name]=table_snapshot(folder/'crm.sqlite');before_files[name]={str(p.relative_to(folder)):file_hash(p) for p in folder.rglob('*') if p.is_file() and not p.name.startswith('crm.sqlite') and not p.is_symlink()}
  return folder,destination
 make('full-native')
 make('concurrent-cut',concurrent=True)
 make('copy-fallback',forceCopy=True)
 for point in ['beforeDirectory','beforeFence','insideFence','snapshotEstablished','pinFile','pinsComplete','afterFence','databasePage','afterDatabase','beforeFiles','fileChunk','beforePublish','afterResult']:
  make('fail-'+point,status='failed',code='test.failure',failAt=point)
  make('cancel-'+point,status='cancelled',code='backup.cancelled',cancelAt=point)
 make('missing-file',status='failed',code='file.read',mutate=lambda f:(f/direct).unlink())
 make('partial-file',status='failed',code='backup.size',mutate=lambda f:(f/direct).write_bytes(b'partial'))
 make('corrupt-file',status='failed',code='backup.hash',mutate=lambda f:(f/direct).write_bytes(bytes(len(assets[direct]))))
 def unsafe(f):
  p=f/direct;p.unlink();p.symlink_to(f/pdf)
 make('symlink-file',status='failed',code='file.read',mutate=unsafe)
 make('avatar-legacy-thumb',mutate=lambda f:(f/avatar_original).unlink())
 def multiple(f):(f/('native-avatars/'+avatarid+'.original.jpg')).write_bytes(b'another original')
 make('avatar-multiple-original',status='failed',code='backup.avatar_pair',mutate=multiple)
 def hardlink_avatar(f):os.link(f/thumb,f/'unrelated-avatar-link')
 make('avatar-hardlink-rejected',status='failed',code='backup.avatar',mutate=hardlink_avatar)
 _,existing=make('existing-destination',status='failed',code='candidate.exists');existing.mkdir();(existing/'keep.txt').write_bytes(b'keep')
 def unsafe_db_key(f):
  db=connect(f/'crm.sqlite');db.execute('UPDATE Documents SET key=?',('native-documents/../outside.txt',));db.commit();db.close()
 make('unsafe-reference',status='failed',code='path.unsafe',mutate=unsafe_db_key)
 def external(f):
  db=connect(f/'crm.sqlite');db.execute('UPDATE Invoices SET pdfStorageKey=?',('s3/external.pdf',));db.execute('UPDATE Invoice_Attachments SET storageKey=?',('s3/external.pdf',));db.commit();db.close()
 make('external-pending',mutate=external)
 def empty_mapping_hash(f):
  db=connect(f/'crm.sqlite');db.execute("UPDATE native_document_objects SET sha256=''");db.commit();db.close()
 make('mapping-empty-hash',status='failed',code='backup.metadata',mutate=empty_mapping_hash)
 def empty_mail_hash(f):
  db=connect(f/'crm.sqlite');db.execute('UPDATE native_outbox SET payload=? WHERE id=?',(json.dumps({'sha256':'','bytes':str(len(assets['mail-outbox/'+invoice_job+'.json']))}),invoice_job));db.commit();db.close()
 make('mail-empty-hash',status='failed',code='backup.mail_metadata',mutate=empty_mail_hash)

 def large(f):
  p=f/direct;h=hashlib.sha256();size=0
  with p.open('wb') as output:
   for _ in range(512):chunk=bytes(range(256))*256;output.write(chunk);h.update(chunk);size+=len(chunk)
  db=connect(f/'crm.sqlite');db.execute('UPDATE Documents SET size=?,content_hash=? WHERE id=?',(size,h.hexdigest(),document));db.commit();db.close()
 make('large-32mib',mutate=large)
 make('cancel-partial-file',status='cancelled',code='backup.cancelled',mutate=large,cancelAt='fileChunk',occurrence=3)
 make('fail-partial-pin',status='failed',code='test.failure',mutate=large,forceCopy=True,failAt='pinFile',occurrence=4)
 make('changed-pinned-inode',status='failed',code='backup.changed',mutatePinned=True)
 def many_files(f):
  db=connect(f/'crm.sqlite')
  for i in range(2048):
   path='native-documents/'+key('many-file-'+str(i))+'.bin';value=('immutable '+str(i)).encode();(f/path).write_bytes(value)
   db.execute('INSERT INTO native_document_objects VALUES(?,?,?,?,?,?,?,?)',('synthetic','many/'+str(i),path,'application/octet-stream',len(value),digest(value),1,'2026-01-01T00:00:00Z'))
  db.commit();db.close()
 make('files-2048',mutate=many_files)
 def stale_url(f):
  db=connect(f/'crm.sqlite');db.execute('UPDATE Documents SET document_file_url=?',('nextcrm-local://native-documents/'+key('obsolete-file')+'.txt',));db.commit();db.close()
 make('stale-display-url-pending',mutate=stale_url)
 folder,destination=make('destination-symlink-parent',status='failed',code='path.unsafe');link=base/'linked-output';link.symlink_to(outputs,target_is_directory=True);cases[-1]['destination']=str(link/destination.name)
 
 def many(f):
  db=connect(f/'crm.sqlite');db.execute('CREATE TABLE native_backup_many(id INTEGER PRIMARY KEY,value TEXT)');db.executemany('INSERT INTO native_backup_many VALUES(?,?)',((i,'日本語'+str(i)) for i in range(50000)));db.commit();db.close()
 make('rows-50000',mutate=many)
 spec=base/'cases.json';spec.write_text(json.dumps(cases));fixture_bytes=sum(p.stat().st_size for p in base.rglob('*') if p.is_file() and not p.is_symlink())
 with log.open('a') as output:subprocess.run(['/usr/bin/time','-l',str(binary),'run',str(NATIVE/'schema.json'),str(NATIVE/'schema.sql'),str(spec)],check=True,stdout=output,stderr=subprocess.STDOUT)
 results=json.loads((base/'results.json').read_text());errors=[]
 for outcome in results:
  name=outcome['name'];r=outcome['result'];status,code=expected[name];codes={d['code'] for d in r['diagnostics']};folder=sources/name;dest=outputs/name
  if r['status']!=status or code and code not in codes:errors.append({'name':name,'expected':status,'result':r['status'],'diagnostics':r['diagnostics']});continue
  checks+=2;assert not r['applicationRestored'] and not r['keychainExported'] and not r['workersStarted'];checks+=3
  if name!='concurrent-cut':assert table_snapshot(folder/'crm.sqlite')==before[name];checks+=len(before[name])
  else:
   current=connect(folder/'crm.sqlite');assert current.execute("SELECT value FROM native_metadata WHERE key='backup.left'").fetchone()[0]=='after' and current.execute("SELECT value FROM native_metadata WHERE key='backup.right'").fetchone()[0]=='after';current.close();assert outcome['writerCompleted'];checks+=3
  for path,hash_ in before_files[name].items():
   if name=='concurrent-cut' and path==direct:assert not (folder/path).exists();continue
   if name=='changed-pinned-inode' and path==direct:assert file_hash(folder/path)!=hash_;checks+=1;continue
   assert file_hash(folder/path)==hash_;checks+=1
  if r['candidateCreated']:
   assert not (dest/'database.sqlite-wal').exists() and not (dest/'database.sqlite-shm').exists();checks+=2
   assert table_snapshot(dest/'database.sqlite')==before[name];checks+=len(before[name])*3
   db=connect(dest/'database.sqlite');assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok' and not db.execute('PRAGMA foreign_key_check').fetchall();assert db.execute('PRAGMA journal_mode').fetchone()[0]=='wal';db.close();checks+=3
   assert file_hash(dest/'database.sqlite')==r['databaseSHA256'];assert file_hash(dest/'files.ndjson')==r['filesManifestSHA256'];assert file_hash(dest/'tables.ndjson')==r['tablesManifestSHA256'];checks+=3
   files=[json.loads(x) for x in (dest/'files.ndjson').read_text().splitlines()];assert len(files)==r['fileCount'];checks+=1
   for asset in files:assert file_hash(dest/asset['archivePath'])==asset['sha256'] and (dest/asset['archivePath']).stat().st_size==asset['bytes'];assert 'pending.' not in asset['sourcePath'] and '.stage-' not in asset['sourcePath'];checks+=3
   assert not (dest/'pins').exists() and not (dest/'files-index.sqlite').exists() and not (dest/'crm.sqlite').exists();checks+=3
   assert outcome['sourceAvatarSingleLinks'];checks+=1
   assert (dest.stat().st_mode & 0o777)==0o700;checks+=1
  elif name!='existing-destination':assert not dest.exists(),('candidate leak',name);checks+=1
 assert (existing/'keep.txt').read_bytes()==b'keep';checks+=1
 if errors:print(json.dumps(errors[:8],ensure_ascii=False));raise SystemExit(1)
 byname={x['name']:x['result'] for x in results}
 assert byname['full-native']['tableCount']>92 and byname['full-native']['fileCount']==len(assets);checks+=2
 assert byname['copy-fallback']['copiedUnderFence']==len(assets) and 'fileCopyPause' in byname['copy-fallback']['pending'];checks+=2
 assert 'avatarOriginal' in byname['avatar-legacy-thumb']['pending'] and 'externalFiles' in byname['external-pending']['pending'];checks+=2
 assert byname['files-2048']['fileCount']==len(assets)+2048 and 'externalFiles' in byname['stale-display-url-pending']['pending'];checks+=2
 stable=all(digest((ROOT/p).read_bytes())==h for p,h in hashes.items());assert stable
 stats=log.read_text();rss=re.search(r'(\d+)\s+maximum resident set size',stats)
 proof={'ok':True,'scenarios':len(results),'checks':checks,'sourceHashes':hashes,'sourceHashesStable':stable,'maximumResidentBytes':int(rss[1]) if rss else None,'seconds':round(time.time()-start,2),'binaryBytes':binary.stat().st_size,'temporaryFixtureBytes':fixture_bytes,'sourceTables':byname['full-native']['tableCount'],'managedFiles':len(assets),'largeFixtureBytes':33554432,'manyFilesFixture':2048,'manyRowsFixture':50000,'summaries':[{'name':x['name'],'status':x['result']['status'],'tableCount':x['result']['tableCount'],'fileCount':x['result']['fileCount'],'writeFenceSeconds':x['result']['writeFenceSeconds'],'linked':x['result']['pinnedByLink'],'cloned':x['result']['pinnedByClone'],'copied':x['result']['copiedUnderFence'],'pending':x['result']['pending']} for x in results if x['result']['candidateCreated']],'limitations':['Native snapshot candidate only; no Keychain export, restore activation, external request or worker start.','Concurrent test changes only its synthetic source via the existing NativeDatabase transaction API.','Cross-filesystem copy fallback is exercised through the force-copy injection, not a second physical volume.']}
 (BUILD/'native-backup-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceHashes','summaries','limitations']}))
