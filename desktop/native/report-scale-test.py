#!/usr/bin/env python3
"""Exercise the real SQLite aggregate on a large, disposable local fixture."""
from pathlib import Path
import hashlib, json, re, subprocess

native = Path(__file__).resolve().parent
sources = [p for p in re.findall(r'"\$native_dir/([^"\n]+\.swift)"', (native / 'reports-test.sh').read_text()) if not p.endswith('Tests.swift')]
sources.append('NativeReportScaleTests.swift')
before = {p: hashlib.sha256((native / p).read_bytes()).hexdigest() for p in sources}
binary = native / 'build/NativeReportScaleTests'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-lsqlite3', *[str(native / p) for p in sources], '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(native)], capture_output=True, text=True)
print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
assert before == {p: hashlib.sha256((native / p).read_bytes()).hexdigest() for p in sources}
(native / 'build/report-scale-verification.json').write_text(json.dumps({'sources': before, 'stdout': result.stdout, 'exit': result.returncode}, ensure_ascii=False, indent=2))
