#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import subprocess

n = Path(__file__).resolve().parent
sources = [n / (x + '.swift') for x in ['NativePluginsTypes', 'NativeAres', 'NativeCompanyRegistry', 'NativeCompanyRegistryControls', 'NativeCompanyRegistryUITests']]
inputs = sources + [Path(__file__).resolve()]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
binary = n / 'build/NativeCompanyRegistryUITests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-framework', 'AppKit', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
print(result.stdout, end=''); print(result.stderr[:4000], end='')
stable = hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
(n / 'build/company-registry-ui-verification.json').write_text(json.dumps({'sourcesSHA256': hashes, 'inputsUnchanged': stable, 'exit': result.returncode, 'result': result.stdout, 'binaryBytes': binary.stat().st_size, 'scope': 'Actual AppKit controls, injected registry results, Japanese states and draft mapping, cancellation and stale-edit guards. Hidden isolated panel, no general clipboard/screenshots/data/real provider. Editor and packaged-app integration remains.'}, ensure_ascii=False, indent=2) + '\n')
assert stable and result.returncode == 0, 'Registry UI verification failed'
