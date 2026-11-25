#!/usr/bin/env python3
"""Direct production Mail/Google/Calendly publication failures; fake secrets only."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,tempfile,time
N=Path(__file__).resolve().parent; B=N/'build/fresh-credential'; B.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
base='NativeDatabase MailReview CRMModules InvoiceModules CatalogModules LineItemModules LineItemMath CRMLineItems CRMCatalog ProductCSV PricingEngine CRMService OrderModules OrderWorkflow OrderDraftStore CRMOrders InvoiceMath NativeUserCredentialCleanup NativeFreshCredentialPublication'.split()
suites=[('mail',base+'NativeMail NativeMailTemporaryFiles NativeMailCredentials NativeFreshCredentialTests'.split(),40),('calendar',base+'NativeCalendarEvents GoogleCalendarCredentials CalendlyCredentials CalendlyAPI CalendlySubscription CalendlyRelaySync CalendlyRelayClient CalendlyWebhook NativeFreshCalendarCredentialTests'.split(),32)]
files={N/(name+'.swift') for _,names,_ in suites for name in names}
files.update(N/x for x in ['schema.json','schema.sql','NativeMailTransport.c','NativeMailTransport.h'])
files.add(Path(__file__).resolve());before={p.name:sha(p) for p in sorted(files)}
proof={'complete':False,'productionDirect':True,'sourceSHA256':before,'phases':[],'realKeychain':False,'providerNetwork':False,'normalData':False};started=time.monotonic()
cache=B/'module-cache';cache.mkdir(exist_ok=False)
try:
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 with (B/'compile-c.log').open('w') as log:
  subprocess.run(['xcrun','clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-c',str(N/'NativeMailTransport.c'),'-o',str(B/'NativeMailTransport.o')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
 for name,names,expected in suites:
  binary=B/(name+'-tests');phase={'name':name};proof['phases'].append(phase)
  command=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-module-cache-path',str(cache)]
  if name=='mail':command+=['-lcurl','-import-objc-header',str(N/'NativeMailTransport.h'),str(B/'NativeMailTransport.o')]
  command += [str(N/(x+'.swift')) for x in names]+['-o',str(binary)]
  with (B/(name+'-compile.log')).open('w') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=360)
  phase['compileExit']=r.returncode;r.check_returncode()
  with tempfile.TemporaryDirectory(prefix='NextCRM-FreshCredential-') as tmp:
   os.chmod(tmp,0o700)
   r=subprocess.run([str(binary),str(N),str(Path(tmp).resolve())],text=True,capture_output=True,timeout=90,umask=0o077)
   (B/(name+'-run.log')).write_text(r.stdout+r.stderr);phase['exit']=r.returncode;r.check_returncode()
   phase['result']=json.loads(r.stdout);assert phase['result']['checks']==expected
  phase['fixtureRemoved']=not Path(tmp).exists();phase['binarySHA256']=sha(binary)
 proof['inputsStable']=all(sha(N/name)==digest for name,digest in before.items())
 assert proof['inputsStable'];proof['complete']=True
finally:
 if cache.exists():shutil.rmtree(cache)
 proof['seconds']=round(time.monotonic()-started,2)
 (N/'build/fresh-credential-verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({k:proof[k] for k in ['complete','productionDirect','phases','seconds']},ensure_ascii=False),flush=True)
