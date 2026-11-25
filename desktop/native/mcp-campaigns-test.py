#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess, os
n = Path(__file__).resolve().parent
(n / 'build').mkdir(exist_ok=True)
if not (n / 'build/mcp-accounts-reference.json').exists():
    subprocess.run(['node', str(n / 'mcp-accounts-reference.cjs'), str(n / 'build/mcp-accounts-reference.json')], check=True)
names = ['NativeDatabase','CRMModules','InvoiceModules','CatalogModules','LineItemModules','LineItemMath','CRMLineItems','CRMCatalog','ProductCSV','PricingEngine','CRMService','OrderModules','OrderWorkflow','OrderDraftStore','CRMOrders','InvoiceMath','NativeAPITokens','NativeMCPProtocol','NativeMCPInputCatalog','NativeMCPRequestRouter','NativeMCPAccounts','NativeMCPAccountsFixture','CampaignWorkflow','CRMCampaigns','CampaignDispatch','CampaignMergeTags','InvoiceMail','InvoiceMailCredentials','CampaignHTML','CampaignMail','CampaignMailWorker','CampaignWebhook','CampaignPublicHTTP','CampaignRelayClient','CampaignRelaySync','CampaignRelayCredentials','CampaignRuntime','MailReview','NativeMCPCampaigns','NativeMCPCampaignsTests']
sources = [n / (name + '.swift') for name in names]
watched = [n / 'CampaignHTML.c', n / 'CampaignHTML.h', n / 'CampaignHTMLEntities.inc'] + sources + [n / 'schema.json', n / 'schema.sql', n / 'MCPToolCatalog.json', n / 'mcp-campaigns-reference.cjs', Path(__file__).resolve()]
before = {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
def fixture_hash():
    shared = json.loads((n / 'build/mcp-accounts-reference.json').read_text())
    return hashlib.sha256(json.dumps({key: shared[key] for key in ['epoch', 'users', 'seeds', 'watchers']}, sort_keys=True).encode()).hexdigest()
account_fixture_hash = fixture_hash()
subprocess.run(['node', str(n / 'mcp-campaigns-reference.cjs'), str(n / 'build/mcp-campaigns-reference.json')], check=True)
binary = n / 'build/NativeMCPCampaignsTests'
sdk = subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
c_object = n / 'build/mcp-campaigns-html.o'
c_command = ['xcrun','clang','-O2','-Wall','-Wextra','-Werror','-target','arm64-apple-macos13.0','-isysroot',sdk,'-I',sdk+'/usr/include/libxml2','-c',str(n/'CampaignHTML.c'),'-o',str(c_object)]
compile_command = ['swiftc','-swift-version','5','-parse-as-library','-O','-target','arm64-apple-macos13.0','-framework','Security','-framework','LocalAuthentication','-lsqlite3','-lxml2','-import-objc-header',str(n/'CampaignHTML.h'),str(c_object),*map(str,sources),'-o',str(binary)]
manifest = n / 'build/mcp-campaigns-build.json'
cached = json.loads(manifest.read_text()) if manifest.exists() else {}
if not binary.exists() or cached.get('sources') != before or cached.get('command') != compile_command or cached.get('binarySHA256') != hashlib.sha256(binary.read_bytes()).hexdigest():
    for command in [c_command, compile_command]:
        compiled = subprocess.run(command,capture_output=True,text=True)
        if compiled.returncode:
            print(json.dumps({'compiler':command[0],'exit':compiled.returncode,'stderr':compiled.stderr[:12000]}),flush=True)
            raise SystemExit(compiled.returncode)
    manifest.write_text(json.dumps({'sources':before,'command':compile_command,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()},sort_keys=True)+'\n')
start_case = int(os.environ.get('MCP_CAMPAIGNS_START_CASE', '0'))
assert start_case >= 0
result = subprocess.run([str(binary),str(n),str(start_case)],capture_output=True,text=True,timeout=420)
print(result.stdout,end='',flush=True)
if result.returncode:
    print(json.dumps({'exit':result.returncode,'stderr':result.stderr[:14000]}),flush=True)
    raise SystemExit(result.returncode)
assert before == {str(p.relative_to(n)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}, 'sources changed during validation'
assert fixture_hash() == account_fixture_hash, 'shared account fixture changed during validation'
reference = json.loads((n / 'build/mcp-campaigns-reference.json').read_text())
for name, digest in reference['sourceSHA256'].items(): assert hashlib.sha256((n.parent.parent / name).read_bytes()).hexdigest() == digest
(n / ('build/mcp-campaigns-verification.json' if start_case == 0 else 'build/mcp-campaigns-partial-verification.json')).write_text(json.dumps({'sources':before,'sourceReference':reference['sourceSHA256'],'accountFixtureSHA256':account_fixture_hash,'stdout':result.stdout,'exit':result.returncode,'sourceCases':len(reference['cases']),'verifiedCaseRange':[start_case,len(reference['cases'])],'jsonProbeCases':len(reference['jsonProbe']),'nativeExtraChecks':['simultaneous starts','durable queue and run token','pause/resume fence','existing dispatch and fake mail transport','stable idempotency key','body merge and unsubscribe','receipt/stats','queue failure rollback'],'binaryBytes':binary.stat().st_size,'referenceBytes':(n/'build/mcp-campaigns-reference.json').stat().st_size,'scope':'Nineteen original campaign handlers/auth/first-step/run-tool with synthetic Prisma and fake Inngest; installed Prisma JSON query compiler probe with a network-free fake adapter. Native full SQLite effects, scopes, nested templates/lists, status/first-step constraints, bounded stats/claim release, durable queue/fences and existing dispatch/mail workers with fake transport. Inngest error leaves source partial commits; native queue failure intentionally rolls back atomically. Live PostgreSQL/provider/relay network, plugin hooks, app integration and UUID case normalization remain outside this proof.'},ensure_ascii=False,indent=2)+'\n')
