#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, subprocess

native = Path(__file__).resolve().parent
sources = ['NativeDatabase', 'CRMModules', 'InvoiceModules', 'CatalogModules', 'LineItemModules',
           'LineItemMath', 'CRMLineItems', 'CRMCatalog', 'ProductCSV', 'PricingEngine', 'CRMService',
           'OrderModules', 'OrderWorkflow', 'OrderDraftStore', 'CRMOrders', 'InvoiceMath',
           'NativeAPITokens', 'NativeAPITokensTests', 'MailReview']
paths = [native / (name + '.swift') for name in sources]
watched = paths + [native / 'schema.json', native / 'schema.sql', native / 'api-tokens-reference.cjs', Path(__file__).resolve()]
before = {str(p.relative_to(native)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
(native / 'build').mkdir(exist_ok=True)
subprocess.run(['node', str(native / 'api-tokens-reference.cjs'), str(native / 'build/api-tokens-reference.json')], check=True)
output = native / 'build/NativeAPITokensTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-target', 'arm64-apple-macos13.0',
                '-framework', 'Security', '-lsqlite3', *map(str, paths), '-o', str(output)], check=True)
result = subprocess.run([str(output), str(native)], capture_output=True, text=True)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
assert before == {str(p.relative_to(native)): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}, 'source drift during verification'
(native / 'build/api-tokens-verification.json').write_text(json.dumps({'sources': before, 'stdout': result.stdout,
    'exit': result.returncode, 'binaryBytes': output.stat().st_size,
    'originalReference': json.loads((native / 'build/api-tokens-reference.json').read_text())['sourceSHA256']}, ensure_ascii=False, indent=2) + '\n')
