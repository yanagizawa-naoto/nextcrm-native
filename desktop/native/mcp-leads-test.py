#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
names = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeMCPLeads', 'NativeMCPLeadsMail', 'InvoiceMail', 'InvoiceMailCredentials', 'NativeMCPLeadsTests', 'NativeMCPLeadsMailTests', 'NativeMCPLeadsSaveTests', 'MailReview']
sources = [n / (name + '.swift') for name in names]
watched = sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', n / 'mcp-leads-reference.cjs', Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node', str(n / 'mcp-leads-reference.cjs'), str(n / 'build/mcp-leads-reference.json')], check=True)
binary = n / 'build/NativeMCPLeadsTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-target', 'arm64-apple-macos13.0', '-framework', 'Security', '-framework', 'LocalAuthentication', '-lsqlite3', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n)], capture_output=True, text=True, timeout=180)
print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True); result.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}, 'source changed during verification'
reference = json.loads((n / 'build/mcp-leads-reference.json').read_text())
for name, digest in reference['sourceSHA256'].items(): assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / 'build/mcp-leads-verification.json').write_text(json.dumps({'sources': before, 'sourceReference': reference['sourceSHA256'], 'stdout': result.stdout, 'exit': result.returncode, 'sourceCases': len(reference['cases']), 'sourceUIActions': len(reference['uiCases']), 'binaryBytes': binary.stat().st_size, 'scope': 'Seven lead MCP operations compared against actual original source/service including audit, saved events and assignee notification decisions; Japanese mail worker isolated request tests. App/runtime/review/link behavior is verified separately by mcp-leads-ui-test.py. Actual external providers and plugin hooks are not exercised.'}, ensure_ascii=False, indent=2) + '\n')
