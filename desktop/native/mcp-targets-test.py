#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
names = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeMCPTargets', 'NativeMCPTargetLists', 'NativeMCPTargetsTests', 'MailReview']
sources = [n / (name + '.swift') for name in names]
watched = sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', n / 'mcp-targets-reference.cjs', n / 'mcp-accounts-reference.cjs', Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True)
subprocess.run(['node', str(n / 'mcp-targets-reference.cjs'), str(n / 'build/mcp-targets-reference.json')], check=True)
binary = n / 'build/NativeMCPTargetsTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-target', 'arm64-apple-macos13.0', '-framework', 'Security', '-lsqlite3', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n)], capture_output=True, text=True, timeout=240)
print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True); result.check_returncode()
assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
reference = json.loads((n / 'build/mcp-targets-reference.json').read_text())
for name, digest in reference['sourceSHA256'].items(): assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / 'build/mcp-targets-verification.json').write_text(json.dumps({'sources': before, 'sourceReference': reference['sourceSHA256'], 'stdout': result.stdout, 'exit': result.returncode, 'sourceCases': len(reference['cases']), 'binaryBytes': binary.stat().st_size, 'referenceBytes': (n / 'build/mcp-targets-reference.json').stat().st_size, 'scope': 'Thirteen real target/list handlers, exact original ownership/member/count behavior and SQLite effects/audit; cancellation rollback. Synthetic Prisma oracle, no live PostgreSQL/plugins/app integration.'}, ensure_ascii=False, indent=2) + '\n')
