#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import re
import subprocess

n = Path(__file__).resolve().parent
base = n / 'form-test.sh'
names = [x for x in re.findall(r'\$native_dir/([\w]+)\.swift', base.read_text()) if x != 'FormTests']
names += ['NativePluginsTypes', 'NativeAres', 'NativeCompanyRegistry', 'NativeCompanyRegistryControls', 'NativeCompanyRegistryEditor', 'NativeCompanyRegistryEditorTests']
sources = [n / (x + '.swift') for x in dict.fromkeys(names)]
inputs = sources + [n / 'schema.json', n / 'schema.sql', base, Path(__file__).resolve()]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
binary = n / 'build/NativeCompanyRegistryEditorTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-framework', 'AppKit', '-framework', 'CoreText', '-lsqlite3', *map(str, sources), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(n)], capture_output=True, text=True, timeout=90)
print(result.stdout, end=''); print(result.stderr[:4000], end='')
stable = hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
(n / 'build/company-registry-editor-verification.json').write_text(json.dumps({'sourcesSHA256': hashes, 'inputsUnchanged': stable, 'exit': result.returncode, 'result': result.stdout, 'binaryBytes': binary.stat().st_size, 'scope': 'Actual virtualized CRMEditor with registry accessory, mounted/offscreen fields, keyboard focus, unsaved draft/save callback, readonly guard. Isolated SQLite and injected registry; not packaged app or live service.'}, ensure_ascii=False, indent=2) + '\n')
assert stable and result.returncode == 0, 'Registry editor verification failed'
