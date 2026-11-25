#!/usr/bin/env python3
"""Current-schema, isolated, offline bundle fixtures. No production DB is opened."""
import base64, copy, hashlib, json, os, pathlib, re, shutil, struct, subprocess, tempfile, uuid, time
ROOT=pathlib.Path(__file__).resolve().parents[2]
NATIVE=ROOT/'desktop/native'; BUILD=NATIVE/'build'; BUILD.mkdir(exist_ok=True)
SOURCES=[NATIVE/(x+'.swift') for x in ['NativeMigrationManifest','NativeMigrationJSON','NativeMigrationCodec','NativeMigrationFiles','NativeMigrationIndex','NativeMigrationPreflight','NativeMigrationPreflightTests']]
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
cases=[];expects={};checks=0
with tempfile.TemporaryDirectory(prefix='NextCRMMigrationFixtures-') as td:
 base=pathlib.Path(td).resolve()
 def make(name,records=None,assets=None,secrets=None,jobs=None,change=None,status='validated',codes=(),**options):
  folder=base/name;folder.mkdir();(folder/'models').mkdir();(folder/'objects').mkdir()
  records=copy.deepcopy(records if records is not None else {m:[] for m in MODELS})
  auto_a,auto_s=inventories(records);assets=copy.deepcopy(auto_a if assets is None else assets);secrets=copy.deepcopy(auto_s if secrets is None else secrets);jobs=copy.deepcopy(jobs or [])
  def write(path,values):
   raw=b''.join(data(x) for x in values);(folder/path).write_bytes(raw)
   return {'path':path,'rows':len(values),'bytes':len(raw),'sha256':digest(raw)}
  manifest={'formatVersion':1,'schemaSHA256':SCHEMA['schemaSHA256'],'source':{'kind':'web-postgresql','snapshotID':'synthetic-consistent-snapshot','consistent':True,'completed':True},'models':[]}
  for m in MODELS:manifest['models'].append({'name':m,**write('models/'+m+'.ndjson',records.get(m,[]))})
  for a in assets:
   if 'path' in a:(folder/a['path']).write_bytes(b'\x00\xffA')
  for kind,values in [('assets',assets),('secrets',secrets),('jobs',jobs)]:manifest[kind]=write(kind+'.ndjson',values)
  if change:change(folder,manifest)
  (folder/'manifest.json').write_bytes(data(manifest))
  cases.append({'name':name,'bundle':str(folder),**options});expects[name]=(status,set(codes))
  return folder
 def mutate_record(name,field,value,*,records=None,code='cell.type',**kw):
  r=copy.deepcopy(records or complete);r[name][0][field]=value;return r
 complete=rows()
 make('empty-all-92')
 make('all-92-populated',complete,status='incomplete',codes=['asset.image_key'],probe='present')
 ordinary=copy.deepcopy(complete);ordinary['ImageUpload']=[]
 make('all-supported-populated',ordinary,probe='present')
 for name,change,code in [
  ('wrong-version',lambda f,m:m.update(formatVersion=2),'manifest.version'),
  ('wrong-schema',lambda f,m:m.update(schemaSHA256='0'*64),'manifest.schema'),
  ('missing-model',lambda f,m:m['models'].pop(),'manifest.missing_model'),
  ('duplicate-model',lambda f,m:m['models'].append(m['models'][0]),'manifest.models'),
  ('unknown-model',lambda f,m:m['models'][0].update(name='NoSuchModel'),'manifest.models'),
  ('unfinished',lambda f,m:m['source'].update(completed=False),'manifest.snapshot'),
  ('inconsistent',lambda f,m:m['source'].update(consistent=False),'manifest.snapshot'),
  ('path-parent',lambda f,m:m['models'][0].update(path='../outside'),'path.unsafe'),
  ('path-absolute',lambda f,m:m['models'][0].update(path='/etc/passwd'),'path.unsafe'),
  ('path-backslash',lambda f,m:m['models'][0].update(path='models\\x'),'path.unsafe'),
  ('path-empty',lambda f,m:m['models'][0].update(path='models//x'),'path.unsafe'),
  ('path-nul',lambda f,m:m['models'][0].update(path='models/\0x'),'path.unsafe'),
  ('duplicate-path',lambda f,m:m['models'][1].update(path=m['models'][0]['path']),'manifest.file'),
  ('negative-rows',lambda f,m:m['models'][0].update(rows=-1),'manifest.file'),
  ('bad-hash',lambda f,m:m['models'][0].update(sha256='abc'),'manifest.file'),
  ('digest-mismatch',lambda f,m:m['models'][0].update(sha256='0'*64),'file.digest'),
  ('bytes-mismatch',lambda f,m:m['models'][0].update(bytes=123),'file.digest'),
  ('row-count-mismatch',lambda f,m:m['models'][0].update(rows=1),'file.digest'),
  ('missing-model-file',lambda f,m:(f/m['models'][0]['path']).unlink(),'file.read')]:make(name,change=change,status='invalid',codes=[code])
 make('legacy-scope',change=lambda f,m:m['source'].update(kind='legacy-accounts'),status='incomplete',codes=['scope.auxiliary'])
 make('native-scope',change=lambda f,m:m['source'].update(kind='native-sqlite'),status='incomplete',codes=['scope.auxiliary'])
 def link_leaf(folder,m):
  p=folder/m['models'][0]['path'];p.unlink();p.symlink_to(folder/'assets.ndjson')
 make('symlink-leaf',change=link_leaf,status='invalid',codes=['file.read'])
 def link_parent(folder,m):
  (folder/'models').rename(folder/'original-models');(folder/'models').symlink_to(folder/'original-models',target_is_directory=True)
 make('symlink-parent',change=link_parent,status='invalid',codes=['path.unsafe'])
 # One complete record from every model exercises all 993 field types and FK edges.
 mutations=[
  ('int-overflow','Users','v','2147483648','cell.type'),('bigint-overflow','Employees','salary','9223372036854775808','cell.type'),
  ('decimal-scale','crm_Opportunities','budget','1.001','cell.type'),('decimal-precision','crm_Opportunities','budget','10000000000000000','cell.type'),
  ('decimal-double','crm_Opportunities','budget',0.1,'cell.type'),('decimal-exponent','crm_Opportunities','budget','1e2','cell.type'),
  ('invalid-date','Users','created_on','2023-02-29T00:00:00Z','cell.type'),('date-leap-second','Users','created_on','2024-01-01T00:00:60Z','cell.type'),
  ('date-zone','Users','created_on','2024-01-01T09:00:00+09:00','cell.type'),('date-seven-digits','Users','created_on','2024-01-01T00:00:00.1234567Z','cell.type'),
  ('date-only-time','crm_Orders','orderDate','2024-01-01T00:00:00Z','cell.type'),('year-zero','Users','created_on','0000-01-01T00:00:00Z','cell.type'),
  ('json-invalid','InstalledPlugin','settings',{'json':'{"x":}'},'json.syntax'),('json-number-raw','InstalledPlugin','settings',{'x':1},'cell.type'),
  ('bad-vector-length','crm_Embeddings_Accounts','embedding',{'base64':'AA=='},'cell.type'),
  ('bad-vector-nan','crm_Embeddings_Accounts','embedding',{'base64':base64.b64encode(struct.pack('<f',float('nan'))+bytes(6140)).decode()},'cell.type'),
  ('bad-base64','crm_Embeddings_Accounts','embedding',{'base64':'not-base64'},'cell.type'),
  ('bad-enum','Users','role','GOD','cell.type'),('boolean-number','Users','banned',1,'cell.type'),
  ('null-required','Users','email',None,'cell.null'),('string-nul','Users','email','a\0b','cell.type'),
  ('array-null','crm_Contacts','tags',[None],'cell.null'),('array-scalar','crm_Contacts','tags','[]','cell.array'),
  ('array-uuid','Boards','sharedWith',['not-uuid'],'cell.type')]
 for n,m,f,v,c in mutations:make(n,mutate_record(m,f,v,records=ordinary),status='invalid',codes=[c],probe='present')
 for n,m,f,v in [
  ('bigint-min','Employees','salary','-9223372036854775808'),('bigint-max','Employees','salary','9223372036854775807'),
  ('decimal-exact','crm_Opportunities','budget','9999999999999999.99'),('gregorian-1582','Users','created_on','1582-10-10T12:00:00.123456Z'),
  ('gregorian-0001','Users','created_on','0001-01-01T00:00:00Z'),('json-large','InstalledPlugin','settings',{'json':'{"n":1234567890123456789012345678901234567890,"value":null,"a":[true,"日本語"]}'}),
  ('json-null','InstalledPlugin','settings',{'json':'null'}),('json-canonical-equivalence-keys','InstalledPlugin','settings',{'json':'{"é":1,"é":2}'}),
  ('array-values','crm_Contacts','tags',['日本語','','é','é']),('byte-zero-vector','crm_Embeddings_Accounts','embedding',{'base64':base64.b64encode(bytes(6144)).decode()})]:make(n,mutate_record(m,f,v,records=ordinary),probe='present')
 broken=copy.deepcopy(ordinary);del broken['Users'][0]['name'];make('missing-field',broken,status='invalid',codes=['record.fields'],probe='present')
 broken=copy.deepcopy(ordinary);broken['Users'][0]['__v']=broken['Users'][0].pop('v');make('sql-alias-rejected',broken,status='invalid',codes=['record.fields'],probe='present')
 broken=copy.deepcopy(ordinary);broken['Users']=[];make('dangling-fk',broken,status='invalid',codes=['relation.missing'],probe='present')
 for table in ['crm_Accounts','DocumentsToAccounts']:
  broken=copy.deepcopy(ordinary);broken[table].append(copy.deepcopy(broken[table][0]));make('duplicate-'+table,broken,status='invalid',codes=['key.duplicate'],probe='present')
 broken=copy.deepcopy(ordinary);u=copy.deepcopy(broken['Users'][0]);u['id']=u['id'].upper();broken['Users'].append(u);make('uuid-case-duplicate',broken,status='invalid',codes=['key.duplicate'],probe='present')
 broken=copy.deepcopy(ordinary);u=copy.deepcopy(broken['Users'][0]);u['id']=key('another-user');u['email']='é';broken['Users'][0]['email']='é';broken['Users'].append(u);make('unicode-distinct-keys',broken,probe='present')
 broken=copy.deepcopy(ordinary);p=copy.deepcopy(broken['crm_Products'][0]);p['id']=key('another-product');broken['crm_Products'].append(p);make('nullable-unique-distinct',broken,probe='present')
 make('missing-asset-inventory',ordinary,assets=[],status='invalid',codes=['inventory.missing'],probe='present')
 make('missing-secret-inventory',ordinary,secrets=[],status='invalid',codes=['inventory.missing'])
 assets,secrets=inventories(ordinary)
 wrong=copy.deepcopy(assets);wrong[0]['sha256']='0'*64;make('asset-hash-mismatch',ordinary,assets=wrong,status='invalid',codes=['asset.digest'],probe='present')
 wrong=copy.deepcopy(assets);wrong[0]['bytes']=4;make('asset-size-mismatch',ordinary,assets=wrong,status='invalid',codes=['asset.digest'],probe='present')
 wrong=copy.deepcopy(assets);wrong[0]['storageKey']='wrong';make('asset-owner-value',ordinary,assets=wrong,status='invalid',codes=['asset.key'],probe='present')
 make('asset-missing-file',ordinary,change=lambda f,m:(f/assets[0]['path']).unlink(),status='invalid',codes=['file.read'],probe='present')
 wrong=copy.deepcopy(assets);wrong[0].pop('path');wrong[0]['externalURL']='https://example.invalid/file';make('asset-external',ordinary,assets=wrong,status='incomplete',codes=['asset.external'],probe='present')
 wrong=copy.deepcopy(secrets);wrong[0]['valueSHA256']='0'*64;make('secret-bad-digest',ordinary,secrets=wrong,status='invalid',codes=['secret.digest'],probe='present')
 make('secret-default-unknown',ordinary,status='incomplete',codes=['secret.unverified'])
 make('secret-rotation-missing',ordinary,status='incomplete',codes=['secret.missing'],probe='missing')
 native_records=copy.deepcopy(ordinary);native_records['ApiKeys'][0]['encryptedKey']='native-ai-keychain:'+key('native-secret')
 _,wrong=inventories(native_records);target=next(x for x in wrong if x['owner']['model']=='ApiKeys');target['storage']='native-keychain';target['namespaceSHA256']='1'*64
 make('secret-other-namespace',native_records,secrets=wrong,change=lambda f,m:m['source'].update(databaseNamespaceSHA256='2'*64),status='incomplete',codes=['secret.namespace_mismatch','secret.rebind'],probe='present')
 job={'id':'job-test','event':'invoice.email_requested','state':'pending','deliveryStarted':False,'hasReceipt':False,'policy':'manual-review','references':[ref('Users',ordinary['Users'][0])]}
 make('job-review',ordinary,jobs=[job],status='incomplete',codes=['job.recovery'],probe='present')
 unsafe=copy.deepcopy(job);unsafe.update(state='done',hasReceipt=True,policy='rebuild');make('job-unsafe-replay',ordinary,jobs=[unsafe],status='invalid',codes=['job.unsafe_replay'],probe='present')
 bad=copy.deepcopy(job);bad['references'][0]['key']['id']=key('missing');make('job-missing-reference',ordinary,jobs=[bad],status='invalid',codes=['reference.missing'],probe='present')
 def raw_model(raw):
  def change(f,m):
   (f/m['models'][0]['path']).write_bytes(raw);m['models'][0].update(rows=1,bytes=len(raw),sha256=digest(raw))
  return change
 make('outer-duplicate-key',change=raw_model(b'{"id":"a","id":"b"}\n'),status='invalid',codes=['json.syntax'])
 make('invalid-utf8',change=raw_model(b'{"id":"\xff"}\n'),status='invalid',codes=['json.syntax'])
 make('unterminated-line',change=raw_model(b'{}'),status='invalid',codes=['json.line_end'])
 make('blank-line',change=raw_model(b'\n'),status='invalid',codes=['json.blank_line'])
 make('line-limit',change=raw_model(data({'padding':'x'*2048})),lineLimit=1024,status='invalid',codes=['limit.line'])
 make('nesting-limit',change=raw_model(('['*130+'0'+']'*130+'\n').encode()),status='invalid',codes=['json.depth'])
 make('cancelled',ordinary,cancelAfter=12,status='cancelled',codes=['inspection.cancelled'])
 many={m:[] for m in MODELS};many['Users']=[{'bad':i} for i in range(1200)]
 make('diagnostic-cap',many,diagnosticLimit=7,status='invalid',codes=['record.fields'])
 stress={m:[] for m in MODELS};stress['crm_Industry_Type']=[{**{f['name']:cell('crm_Industry_Type',f) for f in MODELS['crm_Industry_Type']['fields']},'id':key('industry'+str(i))} for i in range(20000)]
 make('stream-20000',stress)

 # Additional owner, storage, typed-key, raw syntax and file-type boundaries.
 wrong=copy.deepcopy(secrets);target=next(x for x in wrong if x['owner']['model']=='ApiKeys');target['storage']='opaque-auth'
 make('secret-wrong-scheme',ordinary,secrets=wrong,status='invalid',codes=['secret.scheme'],probe='present')
 bad_records=copy.deepcopy(ordinary);bad_records['ApiKeys'][0]['encryptedKey']='not-encrypted'
 make('secret-bad-envelope',bad_records,status='invalid',codes=['secret.envelope'],probe='present')
 wrong=copy.deepcopy(secrets);target=next(x for x in wrong if x['owner']['model']=='ApiKeys');target['storage']='native-keychain';target['namespaceSHA256']='1'*64
 make('secret-bad-native-pointer',ordinary,secrets=wrong,status='invalid',codes=['secret.pointer'],probe='present')
 wrong=copy.deepcopy(assets);wrong[0].pop('storageKey');make('asset-no-key',ordinary,assets=wrong,status='invalid',codes=['asset.key'],probe='present')
 wrong=copy.deepcopy(assets);wrong[0]['owners']=[ref('crm_Accounts',ordinary['crm_Accounts'][0],'name')]
 make('asset-unrelated-owner',ordinary,assets=wrong,status='invalid',codes=['asset.owner_field'],probe='present')
 wrong=copy.deepcopy(assets);other=copy.deepcopy(wrong[0]);other['id']='another-asset';wrong.append(other)
 make('duplicate-owner',ordinary,assets=wrong,status='invalid',codes=['inventory.duplicate_owner'],probe='present')
 broken=copy.deepcopy(ordinary);broken['Users'][0]['id']=broken['Users'][0]['id'].upper();make('uuid-fk-case',broken,probe='present')
 def fifo(folder,m):
  p=folder/m['models'][0]['path'];p.unlink();os.mkfifo(p)
 make('special-fifo',change=fifo,status='invalid',codes=['file.read'])
 link=base/'root-link';link.symlink_to(base/'empty-all-92',target_is_directory=True)
 cases.append({'name':'root-symlink','bundle':str(link)});expects['root-symlink']=('invalid',{'path.unsafe'})
 make('json-numeric-leading-zero',change=raw_model(b'{"n":01}\n'),status='invalid',codes=['json.syntax'])
 make('json-bad-surrogate',change=raw_model(b'{"n":"\\ud800"}\n'),status='invalid',codes=['json.syntax'])

 def stream_records(folder,manifest):
  entry=next(m for m in manifest['models'] if m['name']=='crm_Industry_Type');h=hashlib.sha256();size=0
  with (folder/entry['path']).open('wb') as output:
   for i in range(100000):
    row={f['name']:cell('crm_Industry_Type',f) for f in MODELS['crm_Industry_Type']['fields']};row['id']=key('large-industry'+str(i));line=data(row);output.write(line);h.update(line);size+=len(line)
  entry.update(rows=100000,bytes=size,sha256=h.hexdigest())
 make('stream-100000',change=stream_records)
 def large_asset(folder,manifest):
  rows=[json.loads(line) for line in (folder/'assets.ndjson').read_text().splitlines()];chunk=bytes(range(256))*256;h=hashlib.sha256();size=0
  with (folder/rows[0]['path']).open('wb') as output:
   for _ in range(512):output.write(chunk);h.update(chunk);size+=len(chunk)
  rows[0].update(bytes=size,sha256=h.hexdigest());raw=b''.join(data(x) for x in rows);(folder/'assets.ndjson').write_bytes(raw);manifest['assets'].update(bytes=len(raw),sha256=digest(raw))
 make('stream-32mib-asset',ordinary,change=large_asset,probe='present')
 manifest_duplicate=make('manifest-duplicate-key',status='invalid',codes=['json.syntax'])
 original=(manifest_duplicate/'manifest.json').read_bytes();(manifest_duplicate/'manifest.json').write_bytes(original.replace(b'"formatVersion":1',b'"formatVersion":1,"formatVersion":1',1))
 # Hash every regular fixture before/after, and count symlinks without following.
 def file_digest(p):
  h=hashlib.sha256()
  with p.open('rb') as f:
   for chunk in iter(lambda:f.read(65536),b''):h.update(chunk)
  return h.hexdigest()
 def snapshot():
  return {str(p.relative_to(base)):('link:'+os.readlink(p) if p.is_symlink() else file_digest(p)) for p in base.rglob('*') if p.is_symlink() or p.is_file()}
 spec=base/'cases.json';spec.write_text(json.dumps(cases));before=snapshot()
 tracked=SOURCES+[NATIVE/'schema.json',ROOT/'prisma/schema.prisma',NATIVE/'NativeMigrationFormat.md',pathlib.Path(__file__)]
 hashes={str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in tracked}
 executable=BUILD/'NativeMigrationPreflightTests';log=BUILD/'migration-preflight-test.log'
 start=time.time()
 with log.open('w') as output:
  subprocess.run(['swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-O','-whole-module-optimization',*[str(p) for p in SOURCES],'-lsqlite3','-o',str(executable)],check=True,stdout=output,stderr=subprocess.STDOUT)
  output.flush()
  subprocess.run(['/usr/bin/time','-l',str(executable),str(NATIVE/'schema.json'),str(spec),str(base/'results.json')],check=True,stdout=output,stderr=subprocess.STDOUT)
 results=json.loads((base/'results.json').read_text());after=snapshot();after.pop('results.json');assert before==after,'Input bundle changed'
 errors=[]
 for outcome in results:
  name=outcome['name'];r=outcome['result'];status,codes=expects[name];actual={x['code'] for x in r['diagnostics']}
  if r['status']!=status or not codes<=actual:errors.append({'name':name,'expected':status,'actual':r['status'],'missingCodes':sorted(codes-actual),'diagnostics':r['diagnostics'][:12]})
  assert r['migrationPerformed'] is False;checks+=3
  encoded=json.dumps(r,ensure_ascii=False)
  assert 'value-ApiKeys-encryptedKey' not in encoded and 'objects/0.bin' not in encoded;checks+=2
 byname={r['name']:r['result'] for r in results}
 assert len(byname['diagnostic-cap']['diagnostics'])==7 and byname['diagnostic-cap']['errorCount']==1200;checks+=2
 assert byname['stream-20000']['checkedRows']==20000;checks+=1
 assert byname['stream-100000']['checkedRows']==100000;checks+=1
 unchanged=all(digest((ROOT/p).read_bytes())==h for p,h in hashes.items());assert unchanged;checks+=1
 stats=log.read_text();units=re.search(r'(\d+) unit checks',stats);checks+=int(units[1]) if units else 0
 rss=re.search(r'(\d+)\s+maximum resident set size',stats)
 proof={'ok':not errors,'scenarios':len(results),'checks':checks,'errors':errors,'sourceHashes':hashes,'sourceHashesStable':unchanged,'inputBundlesUnchanged':True,'allModels':len(MODELS),'allFields':sum(len(m['fields']) for m in MODELS.values()),'maximumResidentBytes':int(rss[1]) if rss else None,'seconds':round(time.time()-start,2),'binaryBytes':executable.stat().st_size,'limitations':['Synthetic offline format only; no live PostgreSQL, Keychain, importer, exporter or online backup execution.','A populated ImageUpload source is incomplete until an exporter-specific object-key inventory exists.']}
 (BUILD/'migration-preflight-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceHashes','errors','limitations']}))
 if errors:print(json.dumps(errors[:8],ensure_ascii=False));raise SystemExit(1)
