#!/usr/bin/env python3
"""Actual original company-provider/actions versus optimized native implementation."""
from pathlib import Path
import hashlib
import json
import subprocess

n = Path(__file__).resolve().parent
sources = [n / (name + '.swift') for name in ['NativePluginsTypes', 'NativeAres', 'NativeCompanyRegistry', 'NativeCompanyRegistryTests']]
inputs = sources + [n / 'company-registry-reference.cjs', Path(__file__).resolve()]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
oracle = n / 'build/company-registry-reference.json'
binary = n / 'build/NativeCompanyRegistryTests'
subprocess.run(['node', str(n / 'company-registry-reference.cjs'), str(oracle)], check=True)
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(oracle)], capture_output=True, text=True, timeout=60)
print(result.stdout, end='')
print(result.stderr[:6000], end='')
reference = json.loads(oracle.read_text())
stable = hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
original_stable = all(hashlib.sha256((n.parent.parent / p).read_bytes()).hexdigest() == h for p, h in reference['sourceSHA256'].items())
proof = {'sourcesSHA256': hashes, 'originalSHA256': reference['sourceSHA256'], 'inputsUnchanged': stable and original_stable, 'exit': result.returncode, 'result': result.stdout, 'binaryBytes': binary.stat().st_size, 'scope': 'Actual original ARES/VIES and account registry actions against injected HTTP/auth/plugin state. Real request encoding, response interpretation, provider selection and cancellation. No live service, shared host integration or UI claim.'}
(n / 'build/company-registry-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
assert result.returncode == 0 and stable and original_stable, 'Company registry verification failed'
