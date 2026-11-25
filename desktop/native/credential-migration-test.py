#!/usr/bin/env python3
from pathlib import Path
import datetime,hashlib,json,os,shutil,subprocess,sys,tempfile,time
P=Path(__file__).resolve().parent;N=P;R=N.parent.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
os.umask(0o077);start=time.monotonic();stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');out=P/'build'/('credential-migration-verification-'+stamp);out.mkdir(parents=True)
base=['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','InvoiceMail','InvoiceMailCredentials', 'MailReview']
native=[N/(x+'.swift') for x in base];own=[P/(x+'.swift') for x in ['NativeCredentialMigrationEnvelope','NativeCredentialMigration','NativeCredentialMigrationKeychainVault','NativeCredentialMigrationInvoiceBridge','NativeCredentialMigrationTests']]
watched=native+own+[P/'NativeCredentialMigrationEnvelopeTests.swift',P/'credential-migration-handoff.cjs',P/'credential-migration-handoff-reference.cjs',P/'credential-migration-reference.cjs',Path(__file__),N/'schema.json',N/'schema.sql',R/'lib/email-crypto.ts',R/'lib/resend.ts',R/'lib/plugins/settings.ts',R/'prisma/schema.prisma',R/'pnpm-lock.yaml',R/'node_modules/typescript/package.json']
before={str(x.relative_to(R)):sha(x) for x in watched}
pinned=out/'inputs';pinned.mkdir()
for item in native+own+[P/'NativeCredentialMigrationEnvelopeTests.swift',N/'schema.json',N/'schema.sql']:
 shutil.copy2(item,pinned/item.name)
 assert sha(pinned/item.name)==before[str(item.relative_to(R))]
compiled=native+own+[P/'NativeCredentialMigrationEnvelopeTests.swift',N/'schema.json',N/'schema.sql']
compiledSHA={x.name:sha(pinned/x.name) for x in compiled}
result={'complete':False,'sourceSHA256':before,'phases':[],'realKeychain':False,'realEnvironmentRead':False,'network':False,'sharedEdits':False,'scope':'Synthetic original TS + encrypted handoff + actual private SQLite/fake vault. Native Keychain adapter compiles but is never instantiated. No live providers or operational deployment claim.'}
def run(label,command,timeout=300):
 r=subprocess.run(command,capture_output=True,text=True,cwd=R,timeout=timeout,umask=0o077);log=out/(label+'.log');log.write_text(r.stdout+r.stderr);phase={'name':label,'exit':r.returncode,'logSHA256':sha(log)};result['phases'].append(phase)
 if r.returncode:raise RuntimeError(label+' failed; log '+str(log))
 if label in ['node','envelope','native']:
  phase['results']=[json.loads(line) for line in r.stdout.splitlines() if line.startswith('{')]
 return phase
try:
 with tempfile.TemporaryDirectory(prefix='NextCRMCredentialMigration-') as folder:
  root=Path(folder).resolve();fixture=root/'fixture'
  run('node',['node',str(P/'credential-migration-handoff-reference.cjs'),str(fixture)])
  run('envelope-compile',['swiftc','-swift-version','5','-parse-as-library','-O','-module-cache-path',str(out/'module-cache'),str(pinned/own[0].name),str(pinned/'NativeCredentialMigrationEnvelopeTests.swift'),'-o',str(out/'EnvelopeTests')])
  run('envelope',[str(out/'EnvelopeTests'),str(fixture)])
  run('native-compile',['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-module-cache-path',str(out/'module-cache'),*[str(pinned/x.name) for x in native+own],'-o',str(out/'MigrationTests')])
  run('native',[str(out/'MigrationTests'),str(pinned),str(fixture),str(root/'sqlite')])
  result['fixtureSHA256']={str(f.relative_to(root)):sha(f) for f in root.rglob('*') if f.is_file() and not f.is_symlink()}
  result['fixtureBytesRemoved']=sum(f.stat().st_size for f in root.rglob('*') if f.is_file() and not f.is_symlink())
 result['temporaryFixtureRemoved']=not root.exists()
 result['inputsUnchanged']=all(sha(R/p)==h for p,h in before.items());result['currentInputDrift']=[p for p,h in before.items() if sha(R/p)!=h];result['compiledSnapshotUnchanged']=all(sha(pinned/n)==h for n,h in compiledSHA.items());assert result['compiledSnapshotUnchanged'];result['compiledSHA256']=compiledSHA;result['complete']=True
except Exception as error:result['error']=str(error)
finally:
 cache=out/'module-cache';result['moduleCacheBytesRemoved']=sum(f.stat().st_size for f in cache.rglob('*') if f.is_file()) if cache.exists() else 0
 if cache.exists():shutil.rmtree(cache)
 result['seconds']=round(time.monotonic()-start,2);result['retainedBytes']=sum(f.stat().st_size for f in out.rglob('*') if f.is_file())
 proof=out/'verification.json';proof.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');(P/'build/credential-migration-latest.json').write_text(json.dumps({'verification':str(proof),'SHA256':sha(proof),'complete':result['complete']},indent=2)+'\n')
 print(json.dumps({k:result[k] for k in ['complete','seconds','retainedBytes','error'] if k in result}))
sys.exit(0 if result['complete'] else 1)
