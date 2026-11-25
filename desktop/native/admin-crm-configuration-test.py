#!/usr/bin/env python3
"""Original action oracle -> isolated real SQLite effects; no live services."""
from pathlib import Path
import hashlib, json, subprocess, sys

native = Path(__file__).resolve().parent
root = native.parent.parent
sources = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules',
           'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService',
           'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath',
           'NativeCRMConfiguration', 'NativeCRMConfigurationTests', 'MailReview']
paths = [native / (name + '.swift') for name in sources]
watched = paths + [native / 'schema.json', native / 'schema.sql', native / 'admin-crm-configuration-reference.cjs', Path(__file__).resolve()]
digest = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
before = digest()
build = native / 'build'; build.mkdir(exist_ok=True)
proof = build / 'admin-crm-configuration-verification.json'
reference = build / 'admin-crm-configuration-reference.json'
binary = build / 'NativeCRMConfigurationTests'
result = {'exit': None, 'sources': before, 'limitations': ['No live PostgreSQL/provider or normal user database/Keychain was used.', 'Unicode/name ordering uses SQLite binary collation; PostgreSQL deployment collation and uppercase UUID predicate equivalence remain shared migration concerns.', 'Native CRUD adds native audit/host hooks. Source dictionary actions call neither domain event services nor audit logging.', 'getConfigValues is exposed as a bounded page for the native UI; omitted revision retains source update-by-ID semantics.']}
try:
    source = subprocess.run(['node', str(native / 'admin-crm-configuration-reference.cjs'), str(reference)], capture_output=True, text=True)
    result['sourceExit'] = source.returncode
    result['sourceStdout'] = source.stdout
    if source.returncode: raise RuntimeError(source.stderr)
    original = json.loads(reference.read_text())
    result['originalSourceHashes'] = original['sourceHashes']
    result['sourceCases'] = len(original['cases']); result['sourceChecks'] = original['checks']
    compile_result = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-whole-module-optimization', '-O', '-target', 'arm64-apple-macos13.0', '-lsqlite3', *map(str, paths), '-o', str(binary)], capture_output=True, text=True)
    result['compileExit'] = compile_result.returncode
    if compile_result.returncode: raise RuntimeError(compile_result.stderr)
    run = subprocess.run([str(binary), str(native)], capture_output=True, text=True)
    result.update(exit=run.returncode, stdout=run.stdout, stderr=run.stderr, binaryBytes=binary.stat().st_size)
    if run.returncode: raise RuntimeError(run.stderr)
    result.update(json.loads(run.stdout))
    result['sourceHashesMatch'] = before == digest()
    result['originalHashesMatch'] = all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p,h in original['sourceHashes'].items())
    assert result['sourceHashesMatch'] and result['originalHashesMatch'], 'source drift during verification'
except Exception as error:
    result['exit'] = 1; result['error'] = str(error)
finally:
    proof.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: result[k] for k in ['exit', 'sourceCases', 'sourceChecks', 'checks', 'compileExit', 'sourceHashesMatch', 'error'] if k in result}, ensure_ascii=False))
sys.exit(result['exit'])
