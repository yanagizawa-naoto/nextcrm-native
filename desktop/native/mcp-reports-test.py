#!/usr/bin/env python3
"""Original report TypeScript oracle versus real native router/SQLite aggregates."""
from pathlib import Path
import hashlib
import json
import subprocess
import os

n = Path(__file__).resolve().parent
names = ["NativeDatabase", "CRMModules", "InvoiceModules", "CatalogModules", "LineItemModules", "LineItemMath", "CRMLineItems", "CRMCatalog", "ProductCSV", "PricingEngine", "CRMService", "OrderModules", "OrderWorkflow", "OrderDraftStore", "CRMOrders", "InvoiceMath", "NativeAPITokens", "NativeMCPProtocol", "NativeMCPInputCatalog", "NativeMCPRequestRouter", "NativeMCPAccounts", "NativeMCPAccountsFixture", "NativeMCPLeads", "NativeMCPLeadsMail", "InvoiceMail", "InvoiceMailCredentials", "NativeReports", "NativeMCPReports", "NativeMCPReportsTests", 'MailReview']
sources = [n / (name + ".swift") for name in names]
inputs = sources + [n / "schema.json", n / "schema.sql", n / "MCPToolCatalog.json", n / "mcp-reports-reference.cjs", Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
binary = n / "build/NativeMCPReportsTests"
subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-O", "-target", "arm64-apple-macos13.0", "-framework", "Security", "-framework", "LocalAuthentication", "-lsqlite3", *map(str, sources), "-o", str(binary)], check=True)
results = []
for zone in ['Asia/Tokyo', 'UTC', 'America/New_York']:
    oracle = n / ('build/mcp-reports-reference-' + zone.replace('/', '-') + '.json')
    env = {**os.environ, 'TZ': zone}
    subprocess.run(['node', str(n / 'mcp-reports-reference.cjs'), str(oracle)], check=True, env=env)
    result = subprocess.run([str(binary), str(n), str(oracle)], text=True, capture_output=True, timeout=240, env=env)
    print(result.stdout, end='', flush=True)
    print(result.stderr[:6000], end='', flush=True)
    reference = json.loads(oracle.read_text())
    results.append({'timezone': zone, 'stdout': result.stdout, 'stderr': result.stderr[:6000], 'exit': result.returncode, 'sourceCases': len(reference['cases']), 'cookieCases': len(reference['cookieCases']), 'sourceReference': reference['sourceSHA256']})
    if result.returncode: break
stable = before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source_stable = all(hashlib.sha256((n.parent.parent / p).read_bytes()).hexdigest() == h for r in results for p, h in r['sourceReference'].items())
(n / 'build/mcp-reports-verification.json').write_text(json.dumps({'sourcesSHA256': before, 'inputsUnchanged': stable and source_stable, 'results': results, 'binaryBytes': binary.stat().st_size,
    'scope': 'Two report MCP handlers; actual original category/auth source versus SQLite aggregates. Cookie cases validate injected trusted resolver outcomes only: real native signed cookie/session integration remains a completion gate. Original activity query has no ORDER BY; fixture insertion/first-assignee order is preserved, not a PostgreSQL guaranteed order. Inherited JS object keys retained.'}, ensure_ascii=False, indent=2) + '\n')
assert stable and source_stable, 'Inputs changed during verification'
assert len(results) == 3 and all(r['exit'] == 0 for r in results), 'Report verification failed'
