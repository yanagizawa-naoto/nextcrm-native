#!/usr/bin/env python3
from pathlib import Path
import json,hashlib,subprocess,sys,re
n=Path(__file__).resolve().parent
names=json.loads((n/'plugins-production-sources.json').read_text())
sources=[n/(s+'.swift') for s in names]+[n/(s+'.swift') for s in ['NativeOdooCatalog', 'NativeOdooClient', 'NativeOdooCompare', 'NativeOdooCustomerInfo', 'NativeOdooMap', 'NativeOdooOrdersIn', 'NativeOdooOrdersOut', 'NativeOdooOrdersStatus', 'NativeOdooPartners', 'NativeOdooPlugin', 'NativeOdooSync', 'NativeOdooViews']]+[n/'NativeOdooEffectsTests.swift']
inputs=sources+[n/'schema.json',n/'schema.sql',n/'plugins-source-loader.cjs',n/'plugins-source-database.cjs',n/'odoo-effects-reference.cjs',n/'odoo-reference.cjs',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
inputs += [n/'plugins-production-sources.json']
before={p.name:sha(p) for p in inputs};oracle=n/'build/odoo-effects-reference.json';binary=n/('build/NativeOdooEffectsTestsDebug' if '--quick' in sys.argv else 'build/NativeOdooEffectsTests');actual=n/'build/odoo-effects-native.json'
if '--compare' not in sys.argv:
 if '--reuse' not in sys.argv and '--source-ready' not in sys.argv:subprocess.run(['node',str(n/'odoo-effects-reference.cjs'),str(oracle)],check=True)
 if '--reuse' not in sys.argv:subprocess.run(['swiftc','-swift-version','5','-parse-as-library',*(['-Onone'] if '--quick' in sys.argv else ['-O','-whole-module-optimization']),'-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)],check=True)
 if '--reuse' not in sys.argv:binary.with_suffix('.inputs.json').write_text(json.dumps({p.name:before[p.name] for p in sources}))
 r=subprocess.run([str(binary),str(n),str(oracle),str(actual)],text=True,capture_output=True,timeout=300)
 print(r.stdout,end='');print(r.stderr[:2500],end='');assert r.returncode==0
reference=json.loads(oracle.read_text());native=json.loads(actual.read_text());outputs=native['cases'];checks=0;differences=[]
def normalized(step):
 state=step['state'];mapping={}
 for model in ['Users','NumberSeries','crm_Accounts','crm_Contacts','crm_ProductCategories','crm_Products','crm_PriceLists','crm_Orders','crm_PriceListRules','crm_OrderLines']:
  for row in state[model]:
   rid=row['id']
   if rid.startswith('a0000000-'):mapping[rid]=rid;continue
   key=row.get('externalRef') if model in ['crm_Products','crm_ProductCategories','crm_PriceLists'] else row.get('number') if model=='crm_Orders' else row.get('name') if model in ['crm_Accounts','Users','NumberSeries'] else '|'.join(str(row.get(k)) for k in ['first_name','last_name','email']) if model=='crm_Contacts' else mapping.get(row['priceListId'],row['priceListId'])+'|'+str(row.get('externalRef')) if model=='crm_PriceListRules' else mapping.get(row['orderId'],row['orderId'])+'|'+str(row.get('position'))
   mapping[rid]='@'+model+':'+str(key)
 def walk(x):
  if isinstance(x,dict):return {walk(k):walk(v) for k,v in x.items()}
  if isinstance(x,list):return [walk(v) for v in x]
  if isinstance(x,str):
   for a,b in mapping.items():x=x.replace(a,b)
   # Translation test stub JSON object member order has no meaning.
   m=re.search(r':(\{.*\})$',x)
   if m:
    try:x=x[:m.start(1)]+json.dumps(walk(json.loads(m[1])),sort_keys=True,separators=(',',':'),ensure_ascii=False)
    except ValueError:pass
   return x
  return x
 result=walk(step)
 for model,rows in result['state'].items():
  for row in rows:
   if model=='crm_Contacts' and row.get('last_activity')==row.get('created_on') and row.get('created_on') is not None:row['last_activity']='@recordCreatedAt'
   for field in ['createdAt','updatedAt','created_on','cratedAt']:row.pop(field,None)
   if model=='Users':row.pop('password',None)
   if model=='crm_AuditLog':row.pop('id',None)
  result['state'][model]=sorted(rows,key=lambda v:json.dumps(v,sort_keys=True,ensure_ascii=False))
 for key in ['events','logs','notifications']:result[key]=sorted(result[key],key=lambda v:json.dumps(v,sort_keys=True,ensure_ascii=False))
 for key in ['accounts','products','orderPanels','needsOwner']:result['views'][key]=sorted(result['views'][key],key=lambda v:json.dumps(v,sort_keys=True,ensure_ascii=False))
 # Compare's bounded concurrent reads complete in unspecified order.
 for obj in [result['store'].get('compare:last'),result['views']['catalog'].get('compare')]:
  if obj:obj['mismatches']=sorted(obj['mismatches'],key=lambda v:json.dumps(v,sort_keys=True,ensure_ascii=False))
 return result

def compare(a,b,path):
 global checks
 checks+=1
 if type(a)!=type(b) and not (isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool)):
  differences.append({'path':path,'actual':a,'expected':b});return
 if isinstance(b,dict):
  if set(a)!=set(b):differences.append({'path':path+'.keys','actual':sorted(a),'expected':sorted(b)})
  for key in sorted(a.keys()&b.keys()):compare(a[key],b[key],path+'.'+key)
 elif isinstance(b,list):
  if len(a)!=len(b):differences.append({'path':path+'.length','actual':len(a),'expected':len(b)})
  for i,(av,bv) in enumerate(zip(a,b)):compare(av,bv,path+'['+str(i)+']')
 elif a!=b:differences.append({'path':path,'actual':a,'expected':b})
assert len(outputs)==len(reference['cases']), 'native scenario count differs'
assert len(native['settings'])==len(reference['settingsCases']), 'settings case count differs'
assert len(native['secrets'])==len(reference['secretCases']), 'secret case count differs'
for c,a in zip(reference['cases'],outputs):
 assert c['name']==a['name']
 assert len(c['steps'])==len(a['steps']), 'native step count differs: '+c['name']
 for i,(step,got) in enumerate(zip(c['steps'],a['steps'])):
  expected=step['expected']|{'traceErrors':[],'unusedTrace':0,'sleeps':step['sleeps']}
  compare(normalized(got),normalized(expected),c['name']+'/'+str(i))
for i,(a,b) in enumerate(zip(native['settings'],reference['settingsCases'])):compare(a,b['result'],'settings/'+str(i))
for i,(a,b) in enumerate(zip(native['secrets'],reference['secretCases'])):compare(a,b['result'],'secrets/'+str(i))
compiled=json.loads(binary.with_suffix('.inputs.json').read_text()) if binary.with_suffix('.inputs.json').exists() else {}
compiledStable=compiled=={p.name:sha(p) for p in sources}
stable=compiledStable and reference.get('oracleInputsUnchanged',False) and all(sha(n/p)==h for p,h in reference.get('oracleInputsSHA256',{}).items()) and before=={p.name:sha(p) for p in inputs} and all(sha(n.parent.parent/p)==h for p,h in reference['sourceSHA256'].items())
proof={'exit':r.returncode if '--compare' not in sys.argv else None,'stdout':r.stdout if '--compare' not in sys.argv else None,'binarySHA256':sha(binary),'compiledInputsSHA256':compiled,'compiledInputsUnchanged':compiledStable,'oracleInputsSHA256':reference.get('oracleInputsSHA256',{}),'verificationMode':'diagnostic-comparison-only' if '--compare' in sys.argv else 'debug-cached-binary-reverified' if '--reuse' in sys.argv and '--quick' in sys.argv else 'optimized-cached-binary-reverified' if '--reuse' in sys.argv else 'debug-fresh-build' if '--quick' in sys.argv else 'optimized-fresh-build','inputsSHA256':before,'sourceSHA256':reference['sourceSHA256'],'inputsUnchanged':stable,'cases':len(reference['cases']),'settingsCases':len(reference['settingsCases']),'secretCases':len(reference['secretCases']),'steps':sum(len(c['steps'])for c in reference['cases']),'checks':checks,'differenceCount':len(differences),'differences':differences[:100],'binaryBytes':binary.stat().st_size,'intentionalNativeDifferences':['Task cancellation is propagated by the native JSON2 client instead of becoming a transport retry; bounded comparison tasks are cancelled and awaited on failure.'],'remaining':['Production host registration and Japanese AppKit slot rendering/record access QA are separate integration gates.'],'scope':reference['scope']+' Native real isolated SQLite, actual data services, fake HTTP replay. Generated UUIDs normalized by business keys; database wall-clock metadata omitted and contact last_activity creation default represented relative to created_on; concurrent comparison result ordering normalized. Not a GUI/runtime registration proof.'}
(n/'build/odoo-effects-verification.json').write_text(json.dumps(proof,indent=2,ensure_ascii=False)+'\n')
print(json.dumps({k:proof[k]for k in ['cases','steps','checks','differenceCount','inputsUnchanged']}))
print(json.dumps(differences[:4],ensure_ascii=False))
assert not differences and stable
