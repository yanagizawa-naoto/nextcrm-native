#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import subprocess

n = Path(__file__).resolve().parent
manifest = n / 'plugins-production-sources.json'
names = json.loads(manifest.read_text()) + ['NativePluginsAdmin', 'NativePluginPresentation', 'NativePluginPresentationWindow', 'NativePluginPresentationTests']
sources = [n / (name + '.swift') for name in names]
inputs = sources + [manifest, Path(__file__).resolve()]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
binary = n / 'build/NativePluginPresentationTests'
r = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-framework', 'AppKit', '-lsqlite3', *map(str, sources), '-o', str(binary)], capture_output=True, text=True)
(n / 'build/plugins-presentation-build.log').write_text(r.stdout + r.stderr)
if r.returncode:
    print(json.dumps({'compileExit': r.returncode, 'diagnostics': r.stderr[-6000:]})); raise SystemExit(r.returncode)
r = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
stable = hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
proof = {'sourcesSHA256': hashes, 'inputsUnchanged': stable, 'exit': r.returncode, 'result': r.stdout, 'stderr': r.stderr[-3000:], 'binaryBytes': binary.stat().st_size, 'scope': 'Actual AppKit section/table controls, record navigation callback, link scheme checks, authority loss and stale-view clearing. Synthetic display DTO only; provider projections and packaged app are separate.'}
(n / 'build/plugins-presentation-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in proof.items() if k not in ['sourcesSHA256', 'scope']}))
assert stable and r.returncode == 0
