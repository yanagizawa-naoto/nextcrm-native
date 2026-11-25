#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import subprocess

n = Path(__file__).resolve().parent
manifest = n / 'plugins-production-sources.json'
odoo = ['Map', 'Client', 'Catalog', 'OrdersIn', 'OrdersOut', 'Sync', 'Plugin', 'Views', 'CustomerInfo', 'Compare', 'OrdersStatus', 'Partners']
oxo = ['Countries', 'Map', 'Client', 'Connector', 'Customers', 'Catalog', 'Orders', 'Sync', 'UIData']
names = json.loads(manifest.read_text()) + ['NativeOdoo' + x for x in odoo] + ['NativeOXO' + x for x in oxo]
names += ['NativePluginPresentation', 'NativeAccountProtectionPresentation', 'NativeOdooPresentation', 'NativeOXOPresentation', 'NativePluginPresentationService', 'NativePluginPresentationServiceTests']
sources = [n / (x + '.swift') for x in names]
inputs = sources + [manifest, n / 'schema.json', n / 'schema.sql', Path(__file__).resolve()]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
binary = n / 'build/NativePluginPresentationServiceTests'
r = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-framework', 'Security', '-lsqlite3', *map(str, sources), '-o', str(binary)], text=True, capture_output=True)
(n / 'build/plugins-presentation-service-build.log').write_text(r.stdout + r.stderr)
if r.returncode:
    print(json.dumps({'compileExit': r.returncode, 'diagnostics': r.stderr[-6000:]})); raise SystemExit(r.returncode)
r = subprocess.run([str(binary), str(n)], text=True, capture_output=True, timeout=90)
stable = hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
proof = {'sourcesSHA256': hashes, 'inputsUnchanged': stable, 'exit': r.returncode, 'result': r.stdout, 'stderr': r.stderr[-3000:], 'binaryBytes': binary.stat().st_size, 'scope': 'Three original plugin definitions and real SQLite: slot-aware routes, projection dispatch, role change/disable rechecks, destination ACLs, no credentials/provider effects. Packaged AppKit navigation is verified separately.'}
(n / 'build/plugins-presentation-service-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in proof.items() if k not in ['sourcesSHA256', 'scope']}))
assert stable and r.returncode == 0
