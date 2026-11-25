#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
names = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeMCPDocumentAccess', 'NativeDocumentFiles', 'NativeMCPDocumentStorage', 'NativeMCPDocuments', 'CRMRelationships', 'CRMProjects', 'CRMProjectTasks', 'CRMDocuments', 'NativeDocumentProcessing', 'CRMDocumentProcessing', 'NativeMCPDocumentObjectStore', 'NativeMCPDocumentObjectStoreTests', 'NativeMigrationManifest', 'NativeMigrationJSON', 'NativeDataMaintenanceRecoveryTypes', 'NativeDataMaintenanceRecoveryFiles', 'NativeDataMaintenanceRecovery', 'NativeExportStaging', 'CRMDocumentExports', 'NativeOperationalAssets', 'NativeOperationalDocumentAssets', 'NativeMigratedDocuments', 'MailReview']
sources = [n / (name + '.swift') for name in names]
watched = sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True)
binary = n / 'build/NativeMCPDocumentObjectStoreTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-target', 'arm64-apple-macos13.0', '-framework', 'Security', '-lsqlite3', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n)], capture_output=True, text=True, timeout=240)
print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True); result.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(n / 'build/mcp-document-store-verification.json').write_text(json.dumps({'sources':before,'stdout':result.stdout,'exit':result.returncode,'binaryBytes':binary.stat().st_size,'scope':'Actual SQLite native mapping and immutable files; source scalar preservation, UI preview/export/version/retry, cancellation/rollback/ref cleanup, closed-app directory backup restore. Shared HTTP transport and online backup not included.'},ensure_ascii=False,indent=2)+'\n')
