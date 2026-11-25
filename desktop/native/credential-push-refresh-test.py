#!/usr/bin/env python3
"""Production-only focused G07 credential boundary. Private SQLite/fake stores; no Keychain or provider IO."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,subprocess,tempfile,time
N=Path(__file__).resolve().parent;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();os.umask(0o077)
out=N/'build'/('credential-push-refresh-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir(parents=True);pinned=out/'inputs';pinned.mkdir();start=time.monotonic()
names=['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeCalendarEvents', 'NativeUserCredentialCleanup', 'GoogleCalendarCredentials', 'GoogleCalendarOAuth', 'GoogleCalendarSync', 'GoogleCalendarSpool', 'NativeFreshCredentialPublication', 'GoogleCalendarOutbound', 'GoogleCalendarPushWorker', 'MailReview']
inputs=[N/(x+'.swift') for x in names]+[N/x for x in ['schema.json','schema.sql']]+[N/'NativeCredentialPushRefreshTests.swift',Path(__file__)]
before={p.name:sha(p) for p in inputs};proof={'complete':False,'sourceSHA256':before,'productionDirect':True,'realKeychain':False,'network':False,'normalData':False}
try:
 for p in inputs:shutil.copy2(p,pinned/p.name);assert sha(pinned/p.name)==before[p.name]
 link=[]
 command=['swiftc','-swift-version','5','-parse-as-library','-Onone','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-module-cache-path',str(out/'cache'),*link,*[str(pinned/(x+'.swift')) for x in names],str(pinned/'NativeCredentialPushRefreshTests.swift'),'-o',str(out/'Tests')]
 r=subprocess.run(command,capture_output=True,text=True,timeout=300);(out/'compile.log').write_text(r.stdout+r.stderr);proof['compileExit']=r.returncode;r.check_returncode()
 with tempfile.TemporaryDirectory(prefix='NextCRM-CredentialBoundary-') as temp:
  r=subprocess.run([str(out/'Tests'),str(pinned),str(Path(temp).resolve())],capture_output=True,text=True,timeout=90,umask=0o077);(out/'run.log').write_text(r.stdout+r.stderr);proof['exit']=r.returncode;r.check_returncode();proof.update(json.loads(r.stdout));assert proof['checks']==59
 proof['fixtureRemoved']=not Path(temp).exists();proof['inputHashesStable']=all(sha(p)==before[p.name] and sha(pinned/p.name)==before[p.name] for p in inputs);assert proof['inputHashesStable'];proof['binarySHA256']=sha(out/'Tests');proof['complete']=True
finally:
 if (out/'cache').exists():shutil.rmtree(out/'cache')
 proof['seconds']=round(time.monotonic()-start,2);proof['retainedBytes']=sum(p.stat().st_size for p in out.rglob('*') if p.is_file());(out/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');(N/'build/credential-push-refresh-latest.json').write_text(json.dumps({'proof':str(out/'verification.json'),'sha256':sha(out/'verification.json'),'complete':proof['complete']},indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['complete','checks','seconds','retainedBytes']}))
