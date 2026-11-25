#!/usr/bin/env python3
"""Original OXO handlers+DataAPI versus isolated real native SQLite effects."""
import hashlib,json,subprocess,re,sys
from pathlib import Path
n=Path(__file__).resolve().parent
source_names=json.loads((n/'plugins-production-sources.json').read_text())+['NativeOdooMap','NativeOXOCatalog','NativeOXOClient','NativeOXOConnector','NativeOXOCountries','NativeOXOCustomers','NativeOXOMap','NativeOXOOrders','NativeOXOSync','NativeOXOUIData','NativeOXOTests','NativeOXOTestJSON']
swift=[n/(s+'.swift') for s in source_names]
inputs=swift+[n/x for x in ['oxo-test.py','oxo-reference.cjs','plugins-source-loader.cjs','plugins-source-database.cjs','schema.json','schema.sql']]
hashfile=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
inputs += [n/'plugins-production-sources.json']
before={p.name:hashfile(p) for p in inputs}
reference=n/'build/oxo-reference.json';binary=n/'build/NativeOXOTests';actual=n/'build/oxo-native-results.json'
compare_only='--compare-only' in sys.argv
if not compare_only:
 cached=json.loads(reference.read_text()) if reference.exists() else {}
 if cached.get('generatorSHA256')!=hashfile(n/'oxo-reference.cjs') or not all(hashfile(n.parent.parent/p)==h for p,h in cached.get('sourceSHA256',{}).items()):
  subprocess.run(['node',str(n/'oxo-reference.cjs'),str(reference)],check=True)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macosx13.0',*[str(p) for p in swift],'-lsqlite3','-framework','Security','-o',str(binary)],check=True)
 r=subprocess.run([str(binary),str(n),str(actual)],text=True,capture_output=True);print(r.stdout,end='');print(r.stderr[:1500],end='')
 assert r.returncode==0
ref=json.loads(reference.read_text());got=json.loads(actual.read_text());checks=0
assert len(got)==len(ref['scenarios'])
# UUID generation and wall-clock audit metadata differ across engines. Normalize
# generated IDs by model+insertion ordinal; retain all user/data/store fields.
def normalized(result):
 result=json.loads(json.dumps(result));mapping={}
 for model,rows in result['snapshot'].items():
  for i,row in enumerate(rows):
   uid=row.get('id')
   if uid and not uid.startswith('a0000000-'):mapping[uid]=f'@{model}:{i}'
 def walk(value):
  if isinstance(value,str):
   for old,new in mapping.items():value=value.replace(old,new)
   return value
  if isinstance(value,list):return [walk(v) for v in value]
  if isinstance(value,dict):return {walk(k):walk(v) for k,v in value.items()}
  return value
 result=walk(result)
 for rows in result['snapshot'].values():
  for row in rows:
   for k in ['createdAt','updatedAt']:row.pop(k,None)
 # The native SDK record projection always redacts Users.password; the source
 # snapshot is raw Prisma, so compare the same public projection.
 for row in result['snapshot'].get('Users',[]):row.pop('password',None)
 # Audit changes are maps in the source; their field ordering is not meaningful.
 for row in result['snapshot'].get('crm_AuditLog',[]):
  if isinstance(row.get('changes'),list):row['changes'].sort(key=lambda x:x.get('field',''))
 # Each API returns unordered records; UI source materializes storage-id order.
 for action in result['results']:
  val=action.get('value')
  if isinstance(val,dict) and 'orderPanels' in val and 'accounts' in val:
   for k in ['accounts','products','orderPanels']:val[k].sort(key=lambda x:x['id'])
   val['needsOwner'].sort(key=lambda x:x['accountId'])
 result['store'].sort(key=lambda x:x['key'])
 return result
errors=[]
def compare(a,b,path):
 global checks
 checks+=1
 if type(a)!=type(b) and not (isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool)):raise AssertionError(f'{path}: type {type(a)} != {type(b)}')
 if isinstance(a,dict) and isinstance(b,dict):
  if set(a)!=set(b):raise AssertionError(f'{path}: keys {sorted(set(a)-set(b))} / missing {sorted(set(b)-set(a))}')
  for k in sorted(b):compare(a[k],b[k],path+'.'+k)
 elif isinstance(a,list) and isinstance(b,list):
  if len(a)!=len(b):raise AssertionError(f'{path}: count {len(a)} != {len(b)}')
  for i,(x,y) in enumerate(zip(a,b)):compare(x,y,path+f'[{i}]')
 elif a!=b:raise AssertionError(f'{path}: {str(a)[:250]!r} != {str(b)[:250]!r}')
for source,native in zip(ref['scenarios'],got):
 assert source['name']==native['name']
 try:compare(normalized(native['result']),normalized(source['result']),source['name'])
 except AssertionError as e:errors.append(str(e))
stable=not compare_only and before=={p.name:hashfile(p) for p in inputs} and all(hashfile(n.parent.parent/p)==h for p,h in ref['sourceSHA256'].items())
proof={'diagnostic':compare_only,'sourceScenarios':len(ref['scenarios']),'checks':checks,'errors':errors,'inputsUnchanged':stable,'inputsSHA256':before,'sourceSHA256':ref['sourceSHA256'],'nativeExecution':r.stdout if not compare_only else 'diagnostic reuse','binaryBytes':binary.stat().st_size,'limitations':['Synthetic Prisma adapter, not PostgreSQL or real ERP','Timestamp/id normalization; no original plugin middleware in source adapter','HTTP reason phrase and invalid UTF16 slice boundaries tracked separately']}
(n/'build/oxo-verification.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({'scenarios':len(got),'checks':checks,'errors':len(errors),'first':errors[:8],'stable':stable}))
assert not errors and (stable or compare_only)
