#!/usr/bin/env python3
"""Offline candidate import: real SQLite roundtrip, no application DB or Keychain."""
import base64, copy, hashlib, json, os, pathlib, re, shutil, struct, subprocess, tempfile, uuid, time
ROOT=pathlib.Path(__file__).resolve().parents[2]
NATIVE=ROOT/'desktop/native'; BUILD=NATIVE/'build'; BUILD.mkdir(exist_ok=True)
SOURCES=[NATIVE/(x+'.swift') for x in ['NativeMigrationManifest','NativeMigrationJSON','NativeMigrationCodec','NativeMigrationFiles','NativeMigrationIndex','NativeMigrationPreflight','NativeMigrationImportTypes','NativeMigrationImportWorkspace','NativeMigrationImportDatabase','NativeMigrationImportCodec','NativeMigrationImport','NativeMigrationImportTests']]
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
cases=[];expected={};source_records={};checks=0
with tempfile.TemporaryDirectory(prefix='NextCRMMigrationImportFixtures-') as td:
 base=pathlib.Path(td).resolve(); inputs=base/'inputs';inputs.mkdir();outputs=base/'outputs';outputs.mkdir()
 def make(name,records=None,*,status='prepared',failure=None,mutation=None,**options):
  records=copy.deepcopy(records if records is not None else {m:[] for m in MODELS});folder=inputs/name;folder.mkdir();(folder/'models').mkdir();(folder/'objects').mkdir()
  assets,secrets=inventories(records)
  def write(path,values):
   raw=b''.join(data(x) for x in values);(folder/path).write_bytes(raw);return {'path':path,'rows':len(values),'bytes':len(raw),'sha256':digest(raw)}
  manifest={'formatVersion':1,'schemaSHA256':SCHEMA['schemaSHA256'],'source':{'kind':'web-postgresql','snapshotID':'synthetic-consistent-import','consistent':True,'completed':True},'models':[]}
  for model in MODELS:manifest['models'].append({'name':model,**write('models/'+model+'.ndjson',records[model])})
  for asset in assets:(folder/asset['path']).write_bytes(b'\x00\xffA')
  for kind,values in [('assets',assets),('secrets',secrets),('jobs',[])]:manifest[kind]=write(kind+'.ndjson',values)
  if mutation:mutation(folder,manifest)
  (folder/'manifest.json').write_bytes(data(manifest))
  destination=outputs/name
  cases.append({'name':name,'bundle':str(folder),'destination':str(destination),**options});expected[name]=(status,failure);source_records[name]=records
  return folder,destination
 complete=rows()
 make('empty')
 make('all-92-exact',complete,status='preparedWithGaps')
 mixed=copy.deepcopy(complete)
 for model,records in mixed.items():
  for row in records:
   for f in MODELS[model]['fields']:
    if '@db.Uuid' in f['attributes'] and row[f['name']] is not None:
     if f['array']:row[f['name']]=[str(x).upper() for x in row[f['name']]]
     elif f['name']!='id':row[f['name']]=row[f['name']].upper()
 mixed['Boards'][0]['sharedWith']=[mixed['Users'][0]['id'].upper()]
 mixed['Documents'][0]['connected_documents']=[mixed['Documents'][0]['id'].upper()]
 mixed['InstalledPlugin'][0]['settings']={'json':'{"n":123456789012345678901234567890,"d":1.2300,"uuid":"ABCDEFAB-0000-0000-0000-000000000000","日本語":null}'}
 mixed['crm_Opportunities'][0]['budget']='9999999999999999.99';mixed['Employees'][0]['salary']='9223372036854775807'
 mixed['Users'][0]['created_on']='1582-10-10T12:34:56.123456Z';mixed['Users'][0]['name']=''
 make('typed-uuid-and-lossless',mixed,status='preparedWithGaps')
 for point in ['afterDirectory','afterSchema','afterRow','afterModels','beforeAsset','assetChunk','afterAsset','beforeCommit','beforePublish','afterResult']:
  make('fail-'+point,complete,status='failed',failure='test.failure',failAt=point)
  make('cancel-'+point,complete,status='cancelled',failure='candidate.cancelled',cancelAt=point)
 make('cancel-before-write',complete,status='cancelled',failure='candidate.cancelled',cancelAt='afterPreflight')
 make('source-changed',complete,status='failed',failure='candidate.source_changed',mutateAt='afterModels')
 _,existing=make('existing-directory',status='failed',failure='candidate.exists');existing.mkdir();(existing/'untouched.txt').write_text('keep existing directory')
 _,existing_file=make('existing-file',status='failed',failure='candidate.exists');existing_file.write_text('keep existing file')
 _,link=make('destination-symlink',status='failed',failure='candidate.exists');link.symlink_to(existing,target_is_directory=True)
 make('outside-temporary',status='failed',failure='candidate.location');cases[-1]['destination']='/Users/Shared/NativeMigrationNeverCreated'
 _,dest=make('parent-symlink',status='failed',failure='path.unsafe');alias=base/'output-alias';alias.symlink_to(outputs,target_is_directory=True);cases[-1]['destination']=str(alias/'parent-symlink')
 src,_=make('inside-bundle',status='failed',failure='candidate.location');cases[-1]['destination']=str(src/'candidate')
 make('preflight-rejected',mutation=lambda f,m:m['models'].pop(),status='rejected')
 duplicate=copy.deepcopy(complete);duplicate['DocumentsToAccounts'].append(copy.deepcopy(duplicate['DocumentsToAccounts'][0]));make('compound-duplicate',duplicate,status='rejected')
 duplicate=copy.deepcopy(complete);r=copy.deepcopy(duplicate['Users'][0]);r['id']=r['id'].upper();duplicate['Users'].append(r);make('uuid-duplicate',duplicate,status='rejected')
 def native_kind(folder,m):m['source']['kind']='native-sqlite'
 make('native-aux-unresolved',complete,mutation=native_kind,status='preparedWithGaps')
 def external_asset(folder,m):
  values=[json.loads(x) for x in (folder/'assets.ndjson').read_text().splitlines()];values[0].pop('path');values[0]['externalURL']='https://example.invalid/remote';raw=b''.join(data(x) for x in values);(folder/'assets.ndjson').write_bytes(raw);m['assets'].update(bytes=len(raw),sha256=digest(raw))
 make('external-unresolved',complete,mutation=external_asset,status='preparedWithGaps')
 def jobs(folder,m):
  raw=data({'id':'synthetic-job','event':'invoice.email_requested','state':'needs_review','deliveryStarted':True,'hasReceipt':False,'policy':'manual-review','references':[ref('Users',complete['Users'][0])]});(folder/'jobs.ndjson').write_bytes(raw);m['jobs'].update(bytes=len(raw),rows=1,sha256=digest(raw))
 make('jobs-unresolved',complete,mutation=jobs,status='preparedWithGaps')
 def large_rows(folder,m):
  entry=next(x for x in m['models'] if x['name']=='crm_Industry_Type');h=hashlib.sha256();count=0
  with (folder/entry['path']).open('wb') as f:
   for i in range(50000):
    row={f['name']:cell('crm_Industry_Type',f) for f in MODELS['crm_Industry_Type']['fields']};row['id']=key('import-industry'+str(i));row['name']='日本語業種'+str(i);line=data(row);f.write(line);h.update(line);count+=len(line)
  entry.update(rows=50000,bytes=count,sha256=h.hexdigest())
 make('stream-50000',mutation=large_rows)
 def large_asset(folder,m):
  values=[json.loads(x) for x in (folder/'assets.ndjson').read_text().splitlines()];chunk=bytes(range(256))*256;h=hashlib.sha256();size=0
  with (folder/values[0]['path']).open('wb') as f:
   for _ in range(512):f.write(chunk);h.update(chunk);size+=len(chunk)
  values[0].update(bytes=size,sha256=h.hexdigest());raw=b''.join(data(x) for x in values);(folder/'assets.ndjson').write_bytes(raw);m['assets'].update(bytes=len(raw),sha256=digest(raw))
 make('stream-32mib',complete,mutation=large_asset,status='preparedWithGaps')
 def file_hash(path):
  h=hashlib.sha256()
  with path.open('rb') as f:
   for chunk in iter(lambda:f.read(65536),b''):h.update(chunk)
  return h.hexdigest()
 def input_snapshot():return {str(p.relative_to(inputs)):file_hash(p) for p in inputs.rglob('*') if p.is_file()}
 before=input_snapshot();existing_before=(existing/'untouched.txt').read_bytes(),existing_file.read_bytes()
 spec=base/'cases.json';spec.write_text(json.dumps(cases));result_file=base/'results.json'
 tracked=SOURCES+[NATIVE/'schema.json',NATIVE/'schema.sql',ROOT/'prisma/schema.prisma',NATIVE/'NativeMigrationImportFormat.md',pathlib.Path(__file__)]
 hashes={str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in tracked};binary=BUILD/'NativeMigrationImportTests';log=BUILD/'migration-import-test.log'
 start=time.time()
 with log.open('w') as output:
  subprocess.run(['swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-O','-whole-module-optimization',*[str(p) for p in SOURCES],'-lsqlite3','-o',str(binary)],check=True,stdout=output,stderr=subprocess.STDOUT)
  subprocess.run(['/usr/bin/time','-l',str(binary),str(NATIVE/'schema.json'),str(NATIVE/'schema.sql'),str(spec),str(result_file)],check=True,stdout=output,stderr=subprocess.STDOUT)
 results=json.loads(result_file.read_text());errors=[]
 import sqlite3
 normalized_expected=0
 for model,records in mixed.items():
  for row in records:
   for f in MODELS[model]['fields']:
    if '@db.Uuid' in f['attributes'] and row[f['name']] is not None:
     values=row[f['name']] if f['array'] else [row[f['name']]];normalized_expected+=sum(x!=x.lower() for x in values)
 for outcome in results:
  name=outcome['name'];r=outcome['result'];status,code=expected[name];codes={d['code'] for d in r['diagnostics']};case=next(x for x in cases if x['name']==name);dest=pathlib.Path(case['destination'])
  if r['status']!=status or (code and code not in codes):errors.append({'name':name,'expected':status,'actual':r['status'],'diagnostics':r['diagnostics'],'preflight':r.get('preflight',{}).get('diagnostics',[])[:3]});continue
  checks+=2
  assert r['applicationRestored'] is False and r['workersStarted'] is False and r['keychainWritten'] is False;checks+=3
  if r['candidateCreated']:
   assert dest.is_dir() and not (dest/'crm.sqlite').exists();checks+=2
   assert json.loads((dest/'candidate.json').read_text())['candidateCreated'];checks+=1
   db=sqlite3.connect(f'file:{dest}/candidate.sqlite?mode=ro',uri=True)
   assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok' and not db.execute('PRAGMA foreign_key_check').fetchall();checks+=2
   assert db.execute('PRAGMA journal_mode').fetchone()[0]=='delete';checks+=1
   assert len([t for t, in db.execute("SELECT name FROM sqlite_master WHERE type='table'") if t in MODELS])==92;checks+=1
   records=source_records[name]
   for model,rows_ in records.items():
    if name=='stream-50000' and model=='crm_Industry_Type':assert db.execute('SELECT COUNT(*) FROM crm_Industry_Type').fetchone()[0]==50000;checks+=1;continue
    assert db.execute('SELECT COUNT(*) FROM "'+model+'"').fetchone()[0]==len(rows_);checks+=1
    for row in rows_:
     fields=MODELS[model]['fields'];wanted=[]
     for f in fields:
      v=row[f['name']]
      if v is None:wanted.append(None)
      elif f['array']:wanted.append(json.dumps([x.lower() if '@db.Uuid' in f['attributes'] else x for x in v],ensure_ascii=False,separators=(',',':')))
      elif f['type'] in ['Int','BigInt','Boolean']:wanted.append(int(v))
      elif f['type']=='Json':wanted.append(v['json'])
      elif f['type'].startswith('Unsupported("vector'):wanted.append(base64.b64decode(v['base64']))
      else:wanted.append(v.lower() if '@db.Uuid' in f['attributes'] else v)
     predicate=' AND '.join('"'+next(f['column'] for f in fields if f['name']==k)+'"=?' for k in MODELS[model]['primaryKey']);pk=[wanted[next(i for i,f in enumerate(fields) if f['name']==k)] for k in MODELS[model]['primaryKey']]
     actual=db.execute('SELECT '+','.join('"'+f['column']+'"' for f in fields)+' FROM "'+model+'" WHERE '+predicate,pk).fetchone()
     assert actual is not None
     for f,a,b in zip(fields,actual,wanted):assert (json.loads(a)==json.loads(b) if f['array'] and a is not None else a==b),(name,model,f['name']);checks+=1
   for hash_,path in db.execute('SELECT sha256,local_path FROM _migration_assets WHERE local_path IS NOT NULL'):assert file_hash(dest/path)==hash_;checks+=1
   db.close()
   if name=='typed-uuid-and-lossless':
    constraint_db=sqlite3.connect(dest/'candidate.sqlite');constraint_db.execute('PRAGMA foreign_keys=ON')
    probes=[
     ('uuid-primary', 'INSERT INTO crm_Industry_Type(id,__v,name) SELECT lower(upper(id)),__v,name FROM crm_Industry_Type',()),
     ('unique-email','INSERT INTO Users SELECT ?,__v,account_name,avatar,email,emailVerified,image,role,created_on,updated_at,lastLoginAt,name,password,username,userStatus,userLanguage,banned,banReason,banExpires,partnerAccountId,_native_revision,_native_search FROM Users',(key('duplicate-email-user'),)),
     ('compound-primary','INSERT INTO DocumentsToAccounts SELECT * FROM DocumentsToAccounts',()),
     ('deferred-foreign-key','UPDATE crm_Accounts SET assigned_to=?',(key('missing-user'),))]
    for label,statement,args in probes:
     try:
      constraint_db.execute('BEGIN');constraint_db.execute(statement,args);constraint_db.commit()
     except sqlite3.IntegrityError:constraint_db.rollback();checks+=1
     else:raise AssertionError('SQLite constraint was not enforced: '+label)
    assert not constraint_db.execute('PRAGMA foreign_key_check').fetchall();constraint_db.close();checks+=1
   assert (dest.stat().st_mode & 0o777)==0o700 and ((dest/'candidate.sqlite').stat().st_mode & 0o777)==0o600;checks+=2
  elif name not in ['existing-directory','existing-file','destination-symlink']:assert not dest.exists(),('failed candidate leaked',name);checks+=1
 if errors:
  print(json.dumps(errors[:12],ensure_ascii=False));raise SystemExit(1)
 after=input_snapshot();changed=[p for p,h in before.items() if after[p]!=h];assert changed==['source-changed/manifest.json'];checks+=1
 assert existing_before==((existing/'untouched.txt').read_bytes(),existing_file.read_bytes());checks+=1
 typed=next(x['result'] for x in results if x['name']=='typed-uuid-and-lossless');assert typed['normalizedUUIDValues']==normalized_expected and normalized_expected>0;checks+=1
 pending={x['name']:x['result']['pending'] for x in results};assert 'credentials' in pending['all-92-exact'] and 'jobRecovery' in pending['jobs-unresolved'] and 'nativeAuxiliaryTables' in pending['native-aux-unresolved'] and 'externalAssets' in pending['external-unresolved'];checks+=4
 stable=all(digest((ROOT/p).read_bytes())==h for p,h in hashes.items());assert stable
 text=log.read_text();rss=re.search(r'(\d+)\s+maximum resident set size',text)
 proof={'ok':not errors,'scenarios':len(results),'checks':checks,'errors':errors,'sourceHashes':hashes,'sourceHashesStable':stable,'inputBundlesUnchangedExceptExplicitMutationTest':True,'allModels':len(MODELS),'allFields':sum(len(m['fields']) for m in MODELS.values()),'normalizedUUIDValues':normalized_expected,'maximumResidentBytes':int(rss[1]) if rss else None,'seconds':round(time.time()-start,2),'binaryBytes':binary.stat().st_size,'candidateSummaries':[{'name':x['name'],'status':x['result']['status'],'importedRows':x['result']['importedRows'],'readBackRows':sum(m['readBackRows'] for m in x['result']['modelProofs']),'normalizedUUIDValues':x['result']['normalizedUUIDValues'],'pending':x['result']['pending']} for x in results if x['result']['candidateCreated']],'limitations':['Candidate preparation only: no application restore, Keychain, workers, external transfers or production PostgreSQL snapshot validation.','The source manifest mutation is an explicit isolated fault test. Other bundles and pre-existing destinations remain unchanged.']}
 (BUILD/'migration-import-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceHashes','errors','limitations','candidateSummaries']}))
 if errors:print(json.dumps(errors[:6],ensure_ascii=False));raise SystemExit(1)
