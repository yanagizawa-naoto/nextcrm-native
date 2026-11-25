#!/usr/bin/env python3
"""Actual restore validation, real SQLite runtime effects, and subprocess crash recovery."""
from pathlib import Path
import hashlib,json,subprocess,tempfile,sys,time,re
n=Path(__file__).resolve().parent;root=n.parent.parent;build=n/'build'
names=['NativeDatabase','NativeMigrationManifest','NativeMigrationJSON','NativeMigrationCodec','NativeMigrationFiles','NativeMigrationImportWorkspace','NativeBackupTypes','NativeBackupSQLite','NativeBackupWorkspace','NativeCredentialArchiveBinding','NativeOperationalAssets','NativeBackupOperationalAssets','NativeBackupInventory','NativeBackup','NativeRestoreTypes','NativeRestoreSchema','NativeRestoreWorkspace','NativeRestorePlan','NativeRestore','NativeDataMaintenanceTypes','NativeDataMaintenancePublication','NativeRestoreActivationTypes','NativeRestoreActivationJournal','NativeRestoreActivationPlanCursor','NativeRestoreActivationCandidate','NativeRestoreActivation','NativeRestoreActivationTests', 'MailReview']
sources=[n/(x+'.swift') for x in names]+[n/'NativeDataMaintenanceRecoveryTypes.swift']
inputs=sources+[n/'schema.json',n/'schema.sql',n/'NativeRestoreFormat.md',n/'NativeDataMaintenanceFormat.md',n/'NativeRestoreActivationFormat.md',Path(__file__).resolve()]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):sha(p) for p in inputs};quick='--quick' in sys.argv
binary=build/('NativeRestoreActivationQuickTests' if quick else 'NativeRestoreActivationTests');log=build/'restore-activation-test.log';start=time.time();phases=[];succeeded=False
result={'sourcesSHA256':before,'optimized':not quick,'phases':phases,'externalRequests':0,'keychainAccess':False,'ordinaryDataAccess':False,'sharedProductionChanged':False}
def run(name,args,expected=0):
 with log.open('a') as out:r=subprocess.run(args,stdout=out,stderr=subprocess.STDOUT,timeout=240)
 phases.append({'name':name,'exit':r.returncode,'expected':expected})
 if r.returncode!=expected:
  print(json.dumps({'phase':name,'exit':r.returncode,'tail':log.read_text()[-3000:]}),flush=True)
  raise RuntimeError(name)
 if name in ['compile','state-sqlite-providers']:print(json.dumps({'phase':name,'exit':r.returncode}),flush=True)
log.write_text('')
try:
 run('compile',['swiftc','-swift-version','5','-parse-as-library','-target','arm64-apple-macos13.0',*(['-Onone'] if quick else ['-O','-whole-module-optimization']),*map(str,sources),'-lsqlite3','-o',str(binary)])
 run('state-sqlite-providers',[str(binary),str(n)])
 result['nativeChecks']=int(re.search(r'Native restore activation: (\d+) checks passed',log.read_text()).group(1))
 crashPoints=['selected','draining','drained','validating','reviewing','ready','pointerCommitted','committed','starting','providersStarted','active']
 with tempfile.TemporaryDirectory(prefix='NextCRMActivationCrash-') as temporary:
  for point in crashPoints:
   base=Path(temporary).resolve()/point
   run('prepare-'+point,[str(binary),str(n),'prepare',str(base)])
   run('crash-'+point,[str(binary),str(n),'crash',str(base),point],72)
   run('recover-'+point,[str(binary),str(n),'recover',str(base)])
   pointer=json.loads((base/'control/active-root.json').read_text());journal=json.loads((base/'control/activation.json').read_text())
   afterCommit=point in ['pointerCommitted','committed','starting','providersStarted','active']
   assert Path(pointer['root']['path']).name==('candidate' if afterCommit else 'old')
   assert journal['phase']==('active' if afterCommit else 'previousRestored')
   if afterCommit:
    assert journal['heldRuntimes']==['mail'] and journal['permittedRuntimes']==['local']
    ledger=base/'control'/journal['decisionsFile']
    assert sha(ledger)==journal['decisionsSHA256']
    assert len(ledger.read_bytes().splitlines())==journal['decisionsRows']==journal['seal']['planRows']
   for f in (base/'control').glob('*.json'):
    assert 'never-a-real-key' not in f.read_text() and 'syntheticSecret' not in f.read_text()
   print(json.dumps({'crash':point,'exit':72,'recoveryExit':0,'selected':'candidate' if afterCommit else 'old'}),flush=True)
 result['crashCases']=len(crashPoints);result['recoveryChecks']=sum(map(int,re.findall(r'Native restore recovery: (\d+) checks passed',log.read_text())))
 result['binaryBytes']=binary.stat().st_size
 result['limits']=['Host/App integration and real provider adapters remain unconnected; production callbacks have no default-success implementations.','Real Keychain copying/re-entry, external receipts, relay/IMAP/connector reconciliation were not performed; synthetic providers query isolated records.','Every app instance must participate in control/root fences; existing app writers are not stopped by this standalone code.','Abrupt interruption during verifier scratch copying can leave NextCRMActivationVerify-* private temporary outputs; recovery integration for that purpose is separate.','Cold candidate recovery keeps selection and requires fresh per-row provider review; never automatically returns to the old root after effects may have started.']
 succeeded=True
finally:
 result['inputsUnchanged']=all(sha(root/p)==h for p,h in before.items())
 result['elapsedSeconds']=round(time.time()-start,2)
 result['runnerExitCode']=0 if succeeded and result['inputsUnchanged'] else 1
 result['complete']=not quick and result['runnerExitCode']==0 and len(phases)==35 and all(x['exit']==x['expected'] for x in phases)
 (build/('restore-activation-quick-verification.json' if quick else 'restore-activation-verification.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
assert result['inputsUnchanged'] and len(phases)==35,'Incomplete proof or source drift'
print(json.dumps({'complete':result['complete'],'nativeChecks':result['nativeChecks'],'recoveryChecks':result['recoveryChecks'],'hashesMatch':result['inputsUnchanged'],'elapsedSeconds':result['elapsedSeconds']}),flush=True)
