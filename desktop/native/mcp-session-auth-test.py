#!/usr/bin/env python3
"""Installed BetterAuth + original app auth oracle versus native signed-cookie resolver."""
from pathlib import Path
import hashlib
import json
import subprocess
import os

n = Path(__file__).resolve().parent
names = ["NativeDatabase", "CRMModules", "InvoiceModules", "CatalogModules", "LineItemModules", "LineItemMath", "CRMLineItems", "CRMCatalog", "ProductCSV", "PricingEngine", "CRMService", "OrderModules", "OrderWorkflow", "OrderDraftStore", "CRMOrders", "InvoiceMath", "NativeAPITokens", "NativeMCPProtocol", "NativeMCPInputCatalog", "NativeMCPRequestRouter", "NativeMCPAccounts", "NativeMCPAccountsFixture", "NativeMCPLeads", "NativeMCPLeadsMail", "InvoiceMail", "InvoiceMailCredentials", "NativeReports", "NativeMCPReports", "NativeMCPSessionAuth", "NativeMCPSessionAuthTests", 'MailReview']
sources = [n / (name + ".swift") for name in names]
inputs = sources + [n / "schema.json", n / "schema.sql", n / "MCPToolCatalog.json", n / "mcp-session-auth-reference.cjs", n / "mcp-accounts-reference.cjs", n / "mcp-reports-reference.cjs", Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
# Own the seed generation: the report suite writes timezone-suffixed files,
# and a clean test directory must never rely on a stale unsuffixed artifact.
(n / 'build').mkdir(exist_ok=True)
seed_env = {**os.environ, 'TZ': 'Asia/Tokyo'}
subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True, env=seed_env)
seed_file = n / 'build/mcp-reports-reference.json'
subprocess.run(['node', str(n / 'mcp-reports-reference.cjs'), str(seed_file)], check=True, env=seed_env)
seed_digest = hashlib.sha256(seed_file.read_bytes()).hexdigest()
seed_sources = json.loads(seed_file.read_text())['sourceSHA256']
binary = n / "build/NativeMCPSessionAuthTests"
subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-O", "-target", "arm64-apple-macos13.0", "-framework", "Security", "-framework", "LocalAuthentication", "-lsqlite3", *map(str, sources), "-o", str(binary)], check=True)
results = []
for zone in ['http', 'https']:
    oracle = n / ('build/mcp-session-auth-reference-' + zone.replace('/', '-') + '.json')
    env = {**os.environ, 'TZ': 'Asia/Tokyo'}
    subprocess.run(['node', str(n / 'mcp-session-auth-reference.cjs'), str(oracle)] + (['--secure'] if zone == 'https' else []), check=True, env=env)
    result = subprocess.run([str(binary), str(n), str(oracle)], text=True, capture_output=True, timeout=240, env=env)
    print(result.stdout, end='', flush=True)
    print(result.stderr[:6000], end='', flush=True)
    reference = json.loads(oracle.read_text())
    results.append({'cookieMode': zone, 'stdout': result.stdout, 'stderr': result.stderr[:6000], 'exit': result.returncode, 'sourceCases': len(reference['cases']), 'intentionalNativeDifferences': ['expiresAt==now rejected/deleted', 'banned cookie users rejected/no refresh'], 'sourceReference': reference['sourceSHA256']})
    if result.returncode: break
stable = before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source_stable = all(hashlib.sha256((n.parent.parent / p).read_bytes()).hexdigest() == h for r in results for p, h in r['sourceReference'].items())
source_stable = source_stable and all(hashlib.sha256((n.parent.parent / p).read_bytes()).hexdigest() == h for p, h in seed_sources.items()) and hashlib.sha256(seed_file.read_bytes()).hexdigest() == seed_digest
(n / 'build/mcp-session-auth-verification.json').write_text(json.dumps({'sourcesSHA256': before, 'inputsUnchanged': stable and source_stable, 'results': results, 'binaryBytes': binary.stat().st_size,
    'seedFixtureSHA256': seed_digest, 'seedSourceSHA256': seed_sources,
    'scope': 'Actual app auth config, BetterAuth1.7.14/better-call1.4.4 cookie verification, auth-server/authz and users report; real SQLite session lookup/expiry/refresh/current identity. Four cases intentionally reject source expiry-equality and banned-user acceptance. TaskLocal lazy SSE, JSON errors, parallel contexts and cancellation tested. No real credentials, external provider or installed data.'}, ensure_ascii=False, indent=2) + '\n')
assert stable and source_stable, 'Inputs changed during verification'
assert len(results) == 2 and all(r['exit'] == 0 for r in results), 'Session authentication verification failed'
