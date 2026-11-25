#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess, os
n = Path(__file__).resolve().parent
(n / 'build').mkdir(exist_ok=True)
if not (n / 'build/mcp-accounts-reference.json').exists():
    subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True)
names = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules', 'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService', 'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath', 'NativeAPITokens', 'NativeMCPProtocol', 'NativeMCPInputCatalog', 'NativeMCPRequestRouter', 'NativeMCPAccounts', 'NativeMCPAccountsFixture', 'NativeEmbeddingVector', 'NativeEmbeddingClient', 'NativeDocumentAIText', 'NativeOpenAIChatClient', 'NativeDocumentAIWorker', 'NativeEmbeddingIndex', 'NativeAICredentials', 'NativeUserCredentialCleanup', 'NativeE2BSettings', 'NativeE2BConfiguration', 'NativeAIQAServices', 'NativeEmbeddingJobs', 'NativeEmbeddingWorker', 'NativeEnrichmentPolicy', 'NativeContactEnrichment', 'NativeContactEnrichmentWorker', 'NativeTargetEnrichment', 'NativeTargetEnrichmentWorker', 'NativeEnrichmentWeb', 'NativeEnrichmentText', 'NativeEnrichmentPrompts', 'NativeEnrichmentOpenAI', 'NativeMCPEnrichment', 'NativeMCPEnrichmentTests', 'MailReview']
sources = [n / (name + '.swift') for name in names]
watched = [n/'NativeContactEnrichmentRuntime.swift', n/'NativeTargetEnrichmentRuntime.swift'] + sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', n / 'mcp-enrichment-reference.cjs', Path(__file__).resolve()]
before = {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
def fixture_hash():
    shared = json.loads((n / 'build/mcp-accounts-reference.json').read_text())
    return hashlib.sha256(json.dumps({key: shared[key] for key in ['epoch', 'users', 'seeds', 'watchers']}, sort_keys=True).encode()).hexdigest()
account_fixture_hash = fixture_hash()
subprocess.run(['node', str(n / 'mcp-enrichment-reference.cjs'), str(n / 'build/mcp-enrichment-reference.json')], check=True)
binary = n / 'build/NativeMCPEnrichmentTests'
compile_command = ['swiftc','-swift-version','5','-parse-as-library','-O','-whole-module-optimization','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3',*map(str,sources),'-o',str(binary)]
manifest = n / 'build/mcp-enrichment-build.json'
cached = json.loads(manifest.read_text()) if manifest.exists() else {}
if not binary.exists() or cached.get('sources') != before or cached.get('command') != compile_command or cached.get('binarySHA256') != hashlib.sha256(binary.read_bytes()).hexdigest():
    for command in [compile_command]:
        compiled = subprocess.run(command,capture_output=True,text=True)
        if compiled.returncode:
            print(json.dumps({'compiler':command[0],'exit':compiled.returncode,'stderr':compiled.stderr[:12000]}),flush=True)
            raise SystemExit(compiled.returncode)
    manifest.write_text(json.dumps({'sources':before,'command':compile_command,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},sort_keys=True)+'\n')
start_case = int(os.environ.get('MCP_ENRICHMENT_START_CASE', '0'))
assert start_case >= 0
result = subprocess.run([str(binary),str(n),str(start_case)],capture_output=True,text=True,timeout=420)
print(result.stdout,end='',flush=True)
if result.returncode:
    print(json.dumps({'exit':result.returncode,'stderr':result.stderr[:14000]}),flush=True)
    raise SystemExit(result.returncode)
assert before == {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}, 'sources changed during validation'
assert fixture_hash() == account_fixture_hash, 'shared account fixture changed during validation'
reference = json.loads((n / 'build/mcp-enrichment-reference.json').read_text())
for name, digest in reference['sourceSHA256'].items(): assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / ('build/mcp-enrichment-verification.json' if start_case == 0 else 'build/mcp-enrichment-partial-verification.json')).write_text(json.dumps({'sources':before,'sourceReference':reference['sourceSHA256'],'accountFixtureSHA256':account_fixture_hash,'stdout':result.stdout,'exit':result.returncode,'sourceCases':len(reference['cases']),'workerCases':sum(bool(c.get('worker')) for c in reference['cases']),'keyCases':len(reference['keyCases']),'verifiedCaseRange':[start_case,len(reference['cases'])],'binaryBytes':binary.stat().st_size,'referenceBytes':(n/'build/mcp-enrichment-reference.json').stat().st_size,'scope':'Four actual source handlers/auth/key resolution, actual bulk/contact/target workers with synthetic Prisma and provider boundaries. Native full SQLite state, durable outbox, existing workers, fake providers, current authority/edit/key/cancellation fences. Native outbox failures roll back atomically unlike source Inngest partial commits. Mac Keychain shared E2B configuration replaces server env. Live PostgreSQL/providers/E2B/network, UUID case normalization, plugin hooks and app UI integration remain outside this proof.'},ensure_ascii=False,indent=2)+'\n')
