#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
base = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'MailReview']
sources = [n / (name + '.swift') for name in base + ['NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeMCPAccountsTests']]
wire_sources = [p for p in sources if p.name != 'NativeMCPAccountsTests.swift'] + [n / (name + '.swift') for name in ['NativeMCPHTTPParser', 'NativeMCPHTTPServer', 'NativeMCPContacts', 'NativeMCPUsers', 'NativeMCPAccountsServerFixture']]
watched = list(dict.fromkeys(sources + wire_sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', n / 'mcp-accounts-reference.cjs', n / 'mcp-accounts-wire-test.cjs', Path(__file__).resolve()]))
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True)
binary = n / 'build/NativeMCPAccountsTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-target', 'arm64-apple-macos13.0', '-framework', 'Security', '-lsqlite3', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n)], capture_output=True, text=True, timeout=180)
print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True); result.check_returncode()
wire_binary = n / 'build/NativeMCPAccountsServerFixture'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-target', 'arm64-apple-macos13.0', '-framework', 'Security', '-lsqlite3', *map(str, wire_sources), '-o', str(wire_binary)], check=True)
wire = subprocess.run(['node', str(n / 'mcp-accounts-wire-test.cjs'), str(wire_binary), str(n)], capture_output=True, text=True, timeout=80)
print(wire.stdout, end='', flush=True); print(wire.stderr, end='', flush=True); wire.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
reference = json.loads((n / 'build/mcp-accounts-reference.json').read_text())
for name, digest in reference['sourceSHA256'].items(): assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / 'build/mcp-accounts-verification.json').write_text(json.dumps({'sources': before, 'sourceReference': reference['sourceSHA256'], 'stdout': result.stdout, 'exit': result.returncode, 'wireStdout': wire.stdout, 'wireExit': wire.returncode, 'binaryBytes': binary.stat().st_size, 'wireBinaryBytes': wire_binary.stat().st_size, 'sourceCases': len(reference['cases']), 'scope': 'Six account handlers against original source, plus all13 implemented account/contact/user operations exercised by installed SDK over native TCP. Contact/user source comparison is recorded separately; remaining110 handlers/plugins/app integration pending.'}, ensure_ascii=False, indent=2) + '\n')
