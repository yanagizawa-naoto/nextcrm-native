#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess
n = Path(__file__).resolve().parent
(n / 'build').mkdir(exist_ok=True)
if not (n / 'build/mcp-accounts-reference.json').exists():
    subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True)
names = ['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeAPITokens','NativeMCPProtocol','NativeMCPInputCatalog','NativeMCPRequestRouter','NativeMCPAccounts','NativeMCPAccountsFixture','NativeMCPContracts','NativeMCPContractsTests', 'MailReview']
sources = [n / (name + '.swift') for name in names]
watched = sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', n / 'mcp-contracts-reference.cjs', Path(__file__).resolve()]
before = {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
def fixture_hash():
    shared = json.loads((n / 'build/mcp-accounts-reference.json').read_text())
    return hashlib.sha256(json.dumps({key: shared[key] for key in ['epoch', 'users', 'seeds', 'watchers']}, sort_keys=True).encode()).hexdigest()
account_fixture_hash = fixture_hash()
subprocess.run(['node', str(n / 'mcp-contracts-reference.cjs'), str(n / 'build/mcp-contracts-reference.json')], check=True)
binary = n / 'build/NativeMCPContractsTests'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','Security','-lsqlite3',*map(str,sources),'-o',str(binary)],check=True)
result = subprocess.run([str(binary),str(n)],capture_output=True,text=True,timeout=180)
print(result.stdout,end='',flush=True); print(result.stderr,end='',flush=True); result.check_returncode()
assert before == {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}, 'sources changed during validation'
assert fixture_hash() == account_fixture_hash, 'shared account fixture changed during validation'
reference = json.loads((n / 'build/mcp-contracts-reference.json').read_text())
for name, digest in reference['sourceSHA256'].items(): assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / 'build/mcp-contracts-verification.json').write_text(json.dumps({'sources':before,'sourceReference':reference['sourceSHA256'],'accountFixtureSHA256':account_fixture_hash,'stdout':result.stdout,'exit':result.returncode,'sourceCases':len(reference['cases']),'binaryBytes':binary.stat().st_size,'referenceBytes':(n/'build/mcp-contracts-reference.json').stat().st_size,'scope':'Five original contract tools with nested lines, Decimal rounding/JSON, date truncation, source permissions/projections and actual atomic SQLite effects; source oracle uses synthetic Prisma, live PostgreSQL/plugins/full app pending.'},ensure_ascii=False,indent=2)+'\n')
