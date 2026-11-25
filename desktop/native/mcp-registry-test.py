#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
base = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'MailReview']
names = ['NativeMCPProtocol','NativeMCPInputCatalog','NativeMCPRequestRouter','NativeMCPAccounts','NativeMCPAccountsFixture','NativeMCPHTTPParser','NativeMCPHTTPServer','NativeMCPContacts','NativeMCPUsers','NativeMCPEmailAccounts','NativeMCPLeads','NativeMCPOpportunities','NativeMCPContracts','NativeMCPTargets','NativeMCPTargetLists','NativeMCPDocumentAccess','NativeMCPProjects','NativeMCPActivities','NativeMCPProducts','NativeMCPPriceLists','NativeMCPRegistry','NativeMCPRegistryServerFixture']
extra = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeEmbeddingVector', 'NativeEmbeddingClient', 'NativeDocumentAIText', 'NativeOpenAIChatClient', 'NativeDocumentAIWorker', 'NativeEmbeddingIndex', 'NativeAICredentials', 'NativeUserCredentialCleanup', 'NativeE2BSettings', 'NativeE2BConfiguration', 'NativeAIQAServices', 'NativeEmbeddingJobs', 'NativeEmbeddingWorker', 'NativeEnrichmentPolicy', 'NativeContactEnrichment', 'NativeContactEnrichmentWorker', 'NativeTargetEnrichment', 'NativeTargetEnrichmentWorker', 'NativeEnrichmentWeb', 'NativeEnrichmentText', 'NativeEnrichmentPrompts', 'NativeEnrichmentOpenAI', 'NativeMCPEnrichment', 'CampaignWorkflow', 'CRMCampaigns', 'NativeMCPCampaigns', 'NativeMCPOrders', 'NativeReports', 'NativeMCPReports', 'NativeDocumentFiles', 'NativeMCPDocumentStorage', 'NativeMCPDocuments', 'NativeMCPDocumentObjectStore', 'NativeMCPDocumentHTTP', 'NativeMigrationManifest', 'NativeMigrationJSON', 'NativeDataMaintenanceRecoveryTypes', 'NativeDataMaintenanceRecoveryFiles', 'NativeDataMaintenanceRecovery', 'NativeExportStaging', 'NativeOperationalAssets', 'NativeOperationalDocumentAssets', 'MailReview']
sources = [n / (name + '.swift') for name in dict.fromkeys(base + names + extra)]
watched = sources + [n/'schema.json',n/'schema.sql',n/'MCPToolCatalog.json',n/'mcp-accounts-reference.cjs',n/'mcp-registry-wire-test.cjs',Path(__file__).resolve()]
before = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node',str(n/'mcp-accounts-reference.cjs'),str(n/'build/mcp-accounts-reference.json')],check=True)
binary=n/'build/NativeMCPRegistryServerFixture'
compile_command=['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,sources),'-o',str(binary)]
manifest=n/'build/mcp-registry-build.json'
source_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
cached=json.loads(manifest.read_text()) if manifest.exists() else {}
if not binary.exists() or cached.get('sources')!=source_hashes or cached.get('command')!=compile_command or cached.get('binarySHA256')!=hashlib.sha256(binary.read_bytes()).hexdigest():
    subprocess.run(compile_command,check=True)
    assert source_hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, 'sources changed while compiling'
    manifest.write_text(json.dumps({'sources':source_hashes,'command':compile_command,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},sort_keys=True)+'\n')
result=subprocess.run(['node',str(n/'mcp-registry-wire-test.cjs'),str(binary),str(n)],capture_output=True,text=True,timeout=100)
print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
assert before == {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(n/'build/mcp-registry-verification.json').write_text(json.dumps({'sources':before,'stdout':result.stdout,'exit':result.returncode,'binaryBytes':binary.stat().st_size,'scope':'Composed123 real operations via installed SDK/native TCP, full-catalog gate, signed document transfer, current-token permissions and durable native effects. Cookie-session/app/plugin/live-provider integration remains pending.'},ensure_ascii=False,indent=2)+'\n')
