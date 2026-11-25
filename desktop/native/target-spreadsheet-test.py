#!/usr/bin/env python3
"""One WMO compile; production inputs only; installed original TS dependencies."""
from pathlib import Path
import os,json,hashlib,subprocess,time,sys
n=Path(__file__).resolve().parent;root=n.parent.parent
out=n/'build/target-spreadsheet-test';out.mkdir(parents=True,exist_ok=True)
catalog=json.loads((n/'target-spreadsheet-sources.json').read_text())
sources=[n/(name+'.swift') for group in ['shared','production','tests'] for name in catalog[group]]
assert len(sources)==len(set(sources)) and all(p.is_file() for p in sources)
watched=sources+[n/'schema.json',n/'schema.sql',n/'plugins-source-loader.cjs',n/'plugins-source-database.cjs',n/'target-spreadsheet-reference.cjs',n/'target-spreadsheet-sources.json',Path(__file__)]
before={str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched};start=time.monotonic()
with (out/'reference.log').open('w') as log:
 subprocess.run(['node',str(n/'target-spreadsheet-reference.cjs'),str(out)],env={**os.environ,'TZ':'UTC'},stdout=log,stderr=subprocess.STDOUT,check=True)
reference=json.loads((out/'reference.json').read_text())
for path,digest in reference['sourceHashes'].items():assert hashlib.sha256((root/path).read_bytes()).hexdigest()==digest
binary=out/'NativeTargetSpreadsheetTests'
with (out/'compile.log').open('w') as log:
 result=subprocess.run(['swiftc','-swift-version','5','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-module-cache-path',str(out/'module-cache'),*map(str,sources),'-o',str(binary)],stdout=log,stderr=subprocess.STDOUT)
if result.returncode:print('\n'.join((out/'compile.log').read_text().splitlines()[-20:]));raise SystemExit(result.returncode)
run=subprocess.run([str(binary),str(out),*sys.argv[1:]],capture_output=True,text=True,timeout=240)
(out/'native.log').write_text(run.stdout+run.stderr)
if run.returncode:print('\n'.join((run.stdout+run.stderr).splitlines()[-20:]));raise SystemExit(run.returncode)
parsed=json.loads((out/'parser-actual.json').read_text());service=json.loads((out/'service-actual.json').read_text());controller=json.loads((out/'controller-actual.json').read_text());ui=json.loads((out/'window-actual.json').read_text())
differences=[];expected={x['id']:x for x in reference['parser']}
for actual in parsed:
 old=expected[actual['id']];rows=[{v['name']:v['value'] for v in r} for r in actual.get('rows',[])]
 if rows!=old.get('intentionalCorrection',{}).get('rows',old.get('rows')) or ('error' in actual)!=('error' in old):differences.append({'id':actual['id'],'source':old,'native':actual})
keys=[x['key'] for x in reference['fields']]+['created_by','do_not_email','do_not_email_at']
def normalized(row):
 value={key:row.get(key) for key in keys}
 if value['do_not_email_at'] is not None:value['do_not_email_at']='<date>'
 return value
def ordered(rows):return sorted([normalized(x) for x in rows],key=lambda x:json.dumps(x,sort_keys=True,ensure_ascii=False))
for actual in service['imports']:
 old=next(x for x in reference['imports'] if x['id']==actual['id'])
 if actual['imported']!=old['result']['imported'] or actual['skipped']!=old['result']['skipped'] or ordered(actual['rows'])!=ordered(old['created']):differences.append({'id':actual['id'],'source':old,'native':actual})
for actual in service['mapping']:
 old=next(x for x in reference['mapping'] if x['id']==actual['id'])
 if actual['mapping']!=old['result']['mapping']:differences.append({'id':actual['id'],'source':old,'native':actual})
unchanged=before=={str(p.relative_to(n)):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
source_unchanged=all(hashlib.sha256((root/p).read_bytes()).hexdigest()==digest for p,digest in reference['sourceHashes'].items())
proof={'inputs':before,'inputsUnchanged':unchanged,'sourceHashes':reference['sourceHashes'],'sourceUnchanged':source_unchanged,'dependencies':reference['dependencyHashes'],'parserCases':len(parsed),'sourceImportCases':len(service['imports']),'serviceChecks':service['checks'],'controllerChecks':controller['checks'],'appKitChecks':ui['checks'],'differences':differences,'intentionalCorrections':[dict(id=x['id'],sourceRows=x.get('rows'),correction=x['intentionalCorrection']) for x in expected.values() if 'intentionalCorrection' in x],'elapsedSeconds':time.monotonic()-start,'exit':run.returncode,'scope':'Actual installed TS parsers/actions, isolated Prisma adapter, real native SQLite/journal/CSV/XLSX files and AppKit controls, injected AI only. No PostgreSQL collation/live AI/full App integration claim.'}
(out/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['parserCases','sourceImportCases','serviceChecks','controllerChecks','appKitChecks','elapsedSeconds']}))
assert unchanged and source_unchanged and not differences
