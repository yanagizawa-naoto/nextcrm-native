#!/usr/bin/env python3
"""Verify the ARES plugin through the shared host and real isolated SQLite."""
from pathlib import Path
import hashlib
import json
import subprocess

n = Path(__file__).resolve().parent
manifest = n / 'plugins-production-sources.json'
names = json.loads(manifest.read_text())
names += ['NativeAres', 'NativeCompanyRegistry', 'NativeAresPlugin', 'NativeAresPluginTests']
sources = [n / (name + '.swift') for name in names]
inputs = sources + [n / 'schema.json', n / 'schema.sql', manifest, Path(__file__).resolve()]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
binary = n / 'build/NativeAresPluginTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-lsqlite3', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n)], capture_output=True, text=True, timeout=90)
print(result.stdout, end=''); print(result.stderr[:4000], end='')
stable = hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
proof = {'sourcesSHA256': hashes, 'inputsUnchanged': stable, 'exit': result.returncode, 'result': result.stdout, 'binaryBytes': binary.stat().st_size, 'scope': 'Real isolated SQLite/InstalledPlugin/Host/Context/permission gate/error logs, injected provider HTTP, fresh identity and mid-flight disabling, reopening. No live provider or app UI claim.'}
(n / 'build/ares-plugin-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
assert stable and result.returncode == 0, 'ARES plugin integration failed'
