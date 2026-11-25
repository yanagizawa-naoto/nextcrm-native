#!/usr/bin/env python3
"""Actual production backup/restore regression, synthetic data and fake transport only."""
import hashlib,json,pathlib,subprocess,time,os
N=pathlib.Path(__file__).resolve().parent;ROOT=N.parents[1];BUILD=N/'build'/'mapped-assets-backup';BUILD.mkdir(parents=True,exist_ok=True)
NAMES=['NativeDatabase.swift', 'CRMModules.swift', 'InvoiceModules.swift', 'CatalogModules.swift', 'LineItemModules.swift', 'LineItemMath.swift', 'CRMLineItems.swift', 'CRMCatalog.swift', 'ProductCSV.swift', 'PricingEngine.swift', 'CRMService.swift', 'OrderModules.swift', 'OrderWorkflow.swift', 'OrderDraftStore.swift', 'CRMOrders.swift', 'InvoiceMath.swift', 'CRMRelationships.swift', 'CRMProjects.swift', 'CRMProjectTasks.swift', 'CRMProjectKanban.swift', 'CRMTemplates.swift', 'CampaignMergeTags.swift', 'CampaignWorkflow.swift', 'CRMCampaigns.swift', 'MailReview.swift', 'CRMCampaignDelivery.swift', 'CampaignOperations.swift', 'CampaignDispatch.swift', 'InvoiceMail.swift', 'InvoiceMailCredentials.swift', 'CampaignHTML.swift', 'CampaignMail.swift', 'CampaignMailWorker.swift', 'CampaignWebhook.swift', 'CampaignRelayClient.swift', 'CampaignRelaySync.swift', 'NativeMigrationManifest.swift', 'NativeMigrationJSON.swift', 'NativeMigrationCodec.swift', 'NativeMigrationFiles.swift', 'NativeMigrationImportWorkspace.swift', 'NativeBackupTypes.swift', 'NativeBackupSQLite.swift', 'NativeBackupWorkspace.swift', 'NativeBackupInventory.swift', 'NativeBackup.swift', 'NativeRestoreTypes.swift', 'NativeRestoreSchema.swift', 'NativeRestoreWorkspace.swift', 'NativeRestorePlan.swift', 'NativeRestore.swift', 'CampaignRuntime.swift', 'CampaignRelayCredentials.swift', 'NativeOperationalAssets.swift', 'NativeUserAvatarStore.swift', 'InvoiceWorkflow.swift', 'InvoiceDraftStore.swift', 'CRMInvoices.swift', 'CRMInvoiceSettings.swift', 'InvoicePDF.swift', 'CRMInvoicePDF.swift', 'NativeBackupOperationalAssets.swift', 'NativeCredentialArchiveBinding.swift']
sources=[N/x for x in NAMES]+[N/'NativeMappedAssetsBackupTests.swift']
inputs=sources+[N/x for x in ['CampaignHTML.c','CampaignHTML.h','CampaignHTMLEntities.inc','schema.json','schema.sql']]+[pathlib.Path(__file__)]
for p in inputs:
 if not p.is_file():raise SystemExit('Required production input missing: '+str(p))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={str(p.relative_to(ROOT)):sha(p) for p in inputs};log=BUILD/'test.log';binary=BUILD/'tests';result=BUILD/'result.json';start=time.time()
# Foundation's guarded workspace resolves the Darwin user temp path, not an
# inherited TMPDIR. Never invoke broad cleanup against either temp root.
temporary=subprocess.check_output(['/usr/bin/getconf','DARWIN_USER_TEMP_DIR'],text=True).strip()
env=os.environ.copy();env['TMPDIR']=temporary
with log.open('w') as output:
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 c=subprocess.run(['xcrun','clang','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-I',sdk+'/usr/include/libxml2','-c',str(N/'CampaignHTML.c'),'-o',str(BUILD/'CampaignHTML.o')],stdout=output,stderr=subprocess.STDOUT,env=env)
 if c.returncode:raise SystemExit(c.returncode)
 compileResult=subprocess.run(['swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-O','-whole-module-optimization','-framework','AppKit','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-lxml2','-import-objc-header',str(N/'CampaignHTML.h'),str(BUILD/'CampaignHTML.o'),*[str(p) for p in sources],'-o',str(binary)],stdout=output,stderr=subprocess.STDOUT,env=env)
 runResult=subprocess.run([str(binary),str(N),str(result)],stdout=output,stderr=subprocess.STDOUT,env=env) if compileResult.returncode==0 else None
proof={'compileExit':compileResult.returncode,'exit':None if runResult is None else runResult.returncode,'sourceSHA256':hashes,'sourceStable':all(sha(ROOT/p)==h for p,h in hashes.items()),'seconds':round(time.time()-start,3),'inputs':len(sources),'productionDirect':True,'realNetworkRequests':0,'realKeychainCalls':0,'darwinTemporaryRoot':temporary}
if runResult and result.exists():proof['result']=json.loads(result.read_text())
if binary.exists():proof['binarySHA256']=sha(binary)
(N/'build'/'mapped-assets-backup-verification.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({k:v for k,v in proof.items() if k not in ['sourceSHA256']},ensure_ascii=False))
raise SystemExit(compileResult.returncode or (runResult.returncode if runResult else 1) or (0 if proof['sourceStable'] else 1))
