#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess, os
n = Path(__file__).resolve().parent
(n / 'build').mkdir(exist_ok=True)
if not (n / 'build/mcp-accounts-reference.json').exists():
    subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True)
names = ['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeAPITokens','NativeMCPProtocol','NativeMCPInputCatalog','NativeMCPRequestRouter','NativeMCPAccounts','NativeMCPAccountsFixture','NativeMCPProducts','NativeMCPPriceLists','NativeMCPCatalogTests', 'MailReview']
sources = [n / (name + '.swift') for name in names]
watched = sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', n / 'mcp-catalog-reference.cjs', Path(__file__).resolve()]
before = {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
def fixture_hash():
    shared = json.loads((n / 'build/mcp-accounts-reference.json').read_text())
    return hashlib.sha256(json.dumps({key: shared[key] for key in ['epoch', 'users', 'seeds', 'watchers']}, sort_keys=True).encode()).hexdigest()
account_fixture_hash = fixture_hash()
subprocess.run(['node', str(n / 'mcp-catalog-reference.cjs'), str(n / 'build/mcp-catalog-reference.json')], check=True)
binary = n / 'build/NativeMCPCatalogTests'
compile_command = ['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)]
manifest = n / 'build/mcp-catalog-build.json'
cached = json.loads(manifest.read_text()) if manifest.exists() else {}
if not binary.exists() or cached.get('sources') != before or cached.get('command') != compile_command or cached.get('binarySHA256') != hashlib.sha256(binary.read_bytes()).hexdigest():
    subprocess.run(compile_command,check=True)
    manifest.write_text(json.dumps({'sources':before,'command':compile_command,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},sort_keys=True)+'\n')
start_case = int(os.environ.get('MCP_CATALOG_START_CASE', '0'))
assert start_case >= 0
result = subprocess.run([str(binary),str(n),str(start_case)],capture_output=True,text=True,timeout=180)
print(result.stdout,end='',flush=True); print(result.stderr,end='',flush=True); result.check_returncode()
assert before == {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}, 'sources changed during validation'
assert fixture_hash() == account_fixture_hash, 'shared account fixture changed during validation'
reference = json.loads((n / 'build/mcp-catalog-reference.json').read_text())
for name, digest in reference['sourceSHA256'].items(): assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / ('build/mcp-catalog-verification.json' if start_case == 0 else 'build/mcp-catalog-partial-verification.json')).write_text(json.dumps({'sources':before,'sourceReference':reference['sourceSHA256'],'accountFixtureSHA256':account_fixture_hash,'stdout':result.stdout,'exit':result.returncode,'sourceCases':len(reference['cases']),'verifiedCaseRange':[start_case,len(reference['cases'])],'dateCases':len(reference['dateCases']),'timeZone':reference['timeZone'],'nativeExtraChecks':['mandatory audit rollback'],'binaryBytes':binary.stat().st_size,'referenceBytes':(n/'build/mcp-catalog-reference.json').stat().st_size,'scope':'Thirteen original product/price-list tools and actual pricing engine/services with synthetic Prisma; native isolated SQLite state, rules, decimal arithmetic, permissions and audits. Live PostgreSQL/plugins/full app, UUID case normalization, all non-standard V8 Date syntax, and extended-year DB dates remain unverified.'},ensure_ascii=False,indent=2)+'\n')
