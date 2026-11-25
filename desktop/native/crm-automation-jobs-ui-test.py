#!/usr/bin/env python3
from pathlib import Path
import re,subprocess,hashlib,json,tempfile,time,shutil
n=Path(__file__).resolve().parent;r=n.parent.parent
p=n/'build/crm-automation-jobs-ui';p.mkdir(parents=True,exist_ok=True)
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
# All inputs are installed production files, with no candidate fallback.
sourceNames=['NativeDatabase.swift', 'CRMModules.swift', 'InvoiceModules.swift', 'OrderModules.swift', 'CatalogModules.swift', 'LineItemModules.swift', 'LineItemMath.swift', 'CRMLineItems.swift', 'CRMCatalog.swift', 'ProductCSV.swift', 'PricingEngine.swift', 'InvoiceMath.swift', 'CRMService.swift', 'CRMRelationships.swift', 'OrderWorkflow.swift', 'OrderDraftStore.swift', 'CRMOrders.swift', 'InvoiceWorkflow.swift', 'InvoiceDraftStore.swift', 'CRMInvoices.swift', 'CRMInvoiceSettings.swift', 'InvoiceFXClient.swift', 'InvoicePDF.swift', 'CRMInvoicePDF.swift', 'InvoiceMail.swift', 'CRMInvoiceMail.swift', 'NativeTerminalMailBodyRecovery.swift', 'CRMOrderMail.swift', 'CRMAccountTasks.swift', 'CRMProjects.swift', 'CRMProjectTasks.swift', 'CRMProjectMail.swift', 'CRMTaskMail.swift', 'NativeCRMAutomationTasks.swift', 'NativeCRMTaskLink.swift', 'NativeProjectTaskLink.swift', 'NativeDeepLink.swift', 'MailReview.swift', 'CRMJobReview.swift', 'InvoiceMailCredentials.swift', 'InvoiceJobRunner.swift', 'NativeAPITokens.swift', 'NativeMCPProtocol.swift', 'NativeMCPInputCatalog.swift', 'NativeMCPRequestRouter.swift', 'NativeMCPLeads.swift', 'NativeMCPLeadsMail.swift', 'CRMProjectKanban.swift', 'CRMTemplates.swift', 'CampaignMergeTags.swift', 'CampaignWorkflow.swift', 'CRMCampaigns.swift', 'CRMCampaignDelivery.swift', 'CampaignOperations.swift', 'CampaignDispatch.swift', 'CampaignHTML.swift', 'CampaignMail.swift', 'CampaignMailWorker.swift', 'CampaignWebhook.swift', 'CampaignPublicHTTP.swift', 'CampaignRelayClient.swift', 'CampaignRelaySync.swift', 'CampaignRelayCredentials.swift', 'CampaignRuntime.swift', 'MemoryBudget.swift', 'LightweightTable.swift', 'CRMInvoiceMailWindows.swift', 'NativeCRMSweepJobs.swift', 'NativeCRMSweepLink.swift', 'NativeCRMSweepNotices.swift', 'NativeCRMAutomationSettings.swift', 'NativeCRMAutomationJobs.swift', 'NativeCRMAutomationJobsWindow.swift', 'CRMJobReviewWindow.swift', 'NativeCRMAutomationJobsUITests.swift', 'NativeOperationalAssets.swift']
files=[n/name for name in sourceNames]
# Private C object built from production source; never touches shared build/*.o.
obj=p/'CampaignHTML.o';sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','clang','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-I',sdk+'/usr/include/libxml2','-c',str(n/'CampaignHTML.c'),'-o',str(obj)],check=True)
evidence=files+[Path(__file__),n/'schema.json',n/'schema.sql',n/'CampaignHTML.c',n/'CampaignHTML.h',n/'CampaignHTMLEntities.inc',obj]
before={str(f.relative_to(r)):sha(f) for f in evidence};proof={'kind':'production source offscreen AppKit + real SQLite integration','sourceSHA256':before,'externalRequests':0,'normalData':False,'keychain':False,'database':'production NativeDatabase, no stage worker run'};start=time.monotonic()
cmd=['swiftc','-swift-version','5','-parse-as-library','-Onone','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','AppKit','-framework','CoreText','-framework','CoreGraphics','-framework','LocalAuthentication','-lsqlite3','-lxml2','-import-objc-header',str(n/'CampaignHTML.h'),str(obj),*map(str,files),'-o',str(p/'NativeCRMAutomationJobsUITests')]
with (p/'compile.log').open('w') as log:
 result=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=300)
proof['compileExit']=result.returncode
print(json.dumps({'phase':'compile','exit':result.returncode,'sources':len(files)}),flush=True)
if result.returncode==0:
 with tempfile.TemporaryDirectory(prefix='NextCRM-AutomationMonitorUI-') as tmp:
  result=subprocess.run([str(p/'NativeCRMAutomationJobsUITests'),str(n),str(Path(tmp).resolve()),str(p)],capture_output=True,text=True,timeout=90,umask=0o077)
  (p/'run.log').write_text(result.stdout+result.stderr);proof['runExit']=result.returncode;proof['stdout']=result.stdout;proof['fixtureBytes']=sum(f.stat().st_size for f in Path(tmp).rglob('*') if f.is_file())
  if result.returncode==0:proof.update(json.loads(result.stdout.strip().splitlines()[-1]))
 proof['fixtureRemoved']=not Path(tmp).exists();proof['binarySHA256']=sha(p/'NativeCRMAutomationJobsUITests')
proof['sourcesStable']=all(sha(r/f)==h for f,h in before.items());proof['elapsedSeconds']=round(time.monotonic()-start,2)
if (p/'automation-monitor.png').exists():proof['screenshotSHA256']=sha(p/'automation-monitor.png')
(p/'verification.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['compileExit','runExit','checks','sourcesStable','fixtureRemoved','elapsedSeconds'] if k in proof}),flush=True)
if proof.get('runExit')!=0 or proof.get('checks')!=56 or not proof['sourcesStable']:raise SystemExit(1)
