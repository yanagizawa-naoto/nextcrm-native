#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
names = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeMCPDocumentAccess', 'NativeDocumentFiles', 'NativeMCPDocumentStorage', 'NativeMCPDocuments', 'NativeMCPDocumentObjectStore', 'NativeMCPHTTPParser', 'NativeMCPHTTPServer', 'NativeMCPDocumentHTTP', 'NativeMCPDocumentHTTPFixture', 'NativeMigrationManifest', 'NativeMigrationJSON', 'NativeDataMaintenanceRecoveryTypes', 'NativeDataMaintenanceRecoveryFiles', 'NativeDataMaintenanceRecovery', 'NativeExportStaging', 'NativeOperationalAssets', 'NativeOperationalDocumentAssets', 'MailReview']
sources=[n/(name+'.swift') for name in names]
watched=sources+[n/'schema.json',n/'schema.sql',n/'MCPToolCatalog.json',n/'mcp-document-http-test.cjs',n/'mcp-accounts-reference.cjs',Path(__file__).resolve()]
before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node',str(n/'mcp-accounts-reference.cjs'),str(n/'build/mcp-accounts-reference.json')],check=True)
binary=n/'build/NativeMCPDocumentHTTPFixture'
compile_command=['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)]
manifest=n/'build/mcp-document-http-build.json'
source_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
cached=json.loads(manifest.read_text()) if manifest.exists() else {}
if not binary.exists() or cached.get('sources')!=source_hashes or cached.get('command')!=compile_command or cached.get('binarySHA256')!=hashlib.sha256(binary.read_bytes()).hexdigest():
    subprocess.run(compile_command,check=True)
    assert source_hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, 'sources changed while compiling'
    manifest.write_text(json.dumps({'sources':source_hashes,'command':compile_command,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},sort_keys=True)+'\n')
result=subprocess.run(['node',str(n/'mcp-document-http-test.cjs'),str(binary),str(n)],capture_output=True,text=True,timeout=110)
print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
assert before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(n/'build/mcp-document-http-verification.json').write_text(json.dumps({'sources':before,'stdout':result.stdout,'exit':result.returncode,'binaryBytes':binary.stat().st_size,'scope':'Real MCP SDK document capability issuance and native HTTP immutable object transfer, permissions, metadata preservation and interrupted replacement. Isolated local DB/files only; no installed app or external providers.'},ensure_ascii=False,indent=2)+'\n')
