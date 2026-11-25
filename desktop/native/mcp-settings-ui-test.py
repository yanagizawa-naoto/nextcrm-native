#!/usr/bin/env python3
from pathlib import Path
import json,hashlib,subprocess,tempfile,uuid,argparse
n=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description="MCP settings verification; real Keychain adapter is an explicit separate mode.")
parser.add_argument("--real-keychain",action="store_true",help="Exercise one generated real Keychain item; requires an environment permitting Keychain access.")
options=parser.parse_args()
names=['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeMCPHTTPParser', 'NativeMCPHTTPServer', 'NativeMCPContacts', 'NativeMCPUsers', 'NativeMCPEmailAccounts', 'NativeMCPLeads', 'NativeMCPOpportunities', 'NativeMCPContracts', 'NativeMCPTargets', 'NativeMCPTargetLists', 'NativeMCPDocumentAccess', 'NativeMCPProjects', 'NativeMCPActivities', 'NativeMCPProducts', 'NativeMCPPriceLists', 'NativeMCPRegistry', 'NativeEmbeddingVector', 'NativeEmbeddingClient', 'NativeDocumentAIText', 'NativeOpenAIChatClient', 'NativeDocumentAIWorker', 'NativeEmbeddingIndex', 'NativeAICredentials', 'NativeUserCredentialCleanup', 'NativeE2BSettings', 'NativeE2BConfiguration', 'NativeAIQAServices', 'NativeEmbeddingJobs', 'NativeEmbeddingWorker', 'NativeEnrichmentPolicy', 'NativeContactEnrichment', 'NativeContactEnrichmentWorker', 'NativeTargetEnrichment', 'NativeTargetEnrichmentWorker', 'NativeEnrichmentWeb', 'NativeEnrichmentText', 'NativeEnrichmentPrompts', 'NativeEnrichmentOpenAI', 'NativeMCPEnrichment', 'CampaignWorkflow', 'NativeMCPCampaigns', 'NativeMCPOrders', 'NativeReports', 'NativeMCPReports', 'NativeDocumentFiles', 'NativeMCPDocumentStorage', 'NativeMCPDocuments', 'NativeMCPDocumentObjectStore', 'NativeMCPDocumentHTTP', 'NativeMCPSettings', 'NativeMCPCredentials', 'NativeMCPRuntime', 'NativeMCPSettingsWindow', 'NativeMCPQAServices', 'NativeMCPSettingsUITests', 'NativeMigrationManifest', 'NativeMigrationJSON', 'NativeDataMaintenanceRecoveryTypes', 'NativeDataMaintenanceRecoveryFiles', 'NativeDataMaintenanceRecovery', 'NativeExportStaging', 'NativeOperationalAssets', 'NativeOperationalDocumentAssets', 'MailReview']
sources=[n/(x+'.swift') for x in names]
watched=sources+[n/'schema.json',n/'schema.sql',n/'MCPToolCatalog.json',n/'mcp-accounts-reference.cjs',n/'NativeMCPSDKAdmissionFixture.swift',n/'mcp-settings-sdk-test.cjs',Path(__file__).resolve()]
before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node',str(n/'mcp-accounts-reference.cjs'),str(n/'build/mcp-accounts-reference.json')],check=True)
binary=n/'build/NativeMCPSettingsUITests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','AppKit','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,sources),'-o',str(binary)],check=True)
assert before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched},'source changed during compile'
results=[]
for mode in ([[],['--keychain']] if options.real_keychain else [[]]):
 r=subprocess.run([str(binary),str(n),*mode],capture_output=True,text=True,timeout=180)
 print(r.stdout,end='');print(r.stderr,end='');results.append({'mode':mode,'stdout':r.stdout,'exit':r.returncode})
with tempfile.TemporaryDirectory(prefix='NextCRM-MCP-QA-Process-') as root:
 (Path(root)/'.native-mail-test').write_text('NextCRM isolated mail QA\n')
 identity=str(uuid.uuid4())
 for action in [[],['read-remove']]:
  r=subprocess.run([str(binary),str(n),'--qa-process',root,identity,*action],capture_output=True,text=True,timeout=15)
  print(r.stdout,end='');print(r.stderr,end='');results.append({'mode':['qa-process',*action],'stdout':r.stdout,'exit':r.returncode})
admission=n/'build/NativeMCPSDKAdmissionFixture'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0',*[str(n/(x+'.swift')) for x in ['NativeMCPProtocol','NativeMCPHTTPParser','NativeMCPHTTPServer','NativeMCPSDKAdmissionFixture']],'-o',str(admission)],check=True)
for args in [[str(admission)],['--runtime',str(binary),str(n)]]:
 r=subprocess.run(['node',str(n/'mcp-settings-sdk-test.cjs'),*args],capture_output=True,text=True,timeout=35)
 print(r.stdout,end='');print(r.stderr,end='');results.append({'mode':['sdk-admission','runtime' if args[0]=='--runtime' else 'transport'],'stdout':r.stdout,'exit':r.returncode})
assert before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
p=n/'build/mcp-settings-ui-verification.json';p.write_text(json.dumps({'sources':before,'results':results,'binaryBytes':binary.stat().st_size,'realKeychainTest':'executed' if options.real_keychain else 'not-run: explicit --real-keychain mode required', 'scope':'Actual AppKit settings panel, isolated SQLite/runtime/fake UI secrets and persistent QA fixture. Real Keychain coverage is separately reported and never implied by a default run. Clipboard and normal app data untouched.'},ensure_ascii=False,indent=2)+'\n')
assert all(r['exit']==0 for r in results),'a verification mode failed'
