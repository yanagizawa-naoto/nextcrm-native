#!/usr/bin/env python3
"""Production-direct G05-D worker/lease regression; no candidate source fallback."""
from pathlib import Path
import hashlib
import json
import os
import re
import signal
import subprocess
import time

n = Path(__file__).resolve().parent
repo = n.parents[1]
out = n / 'build/mail-preparation-lease'
out.mkdir(parents=True, exist_ok=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
names = []
manifests = [n / 'reports-test.sh', n / 'invoice-mail-test.sh', n / 'plugins-production-sources.json']
for script in manifests[:2]:
    found = re.findall(r'"\$native_dir/([^"\n]+\.swift)"', script.read_text())
    assert found, f'No Swift inputs in {script.name}'
    names += [s for s in found if not s.endswith('Tests.swift')]
names += [s + '.swift' for s in json.loads(manifests[2].read_text())]
names += [s + '.swift' for s in [
    'NativeReportPresentation', 'NativeReportExport', 'NativeReportMailBody',
    'NativeReportMail', 'NativePluginsMail', 'NativePluginsCredentials',
    'NativeProviderRuntimeTasks', 'NativePluginsRuntime',
    'NativeTerminalMailBodyRecovery', 'NativeMailPreparationFiles']]
names = list(dict.fromkeys(names))
sources = [n / s for s in names]

# Reuse the actual report fixture, without rerunning its independent 93-check suite.
# No behavioral assertions are removed from the production report-mail runner.
original_fixture = n / 'NativeReportMailTests.swift'
text = original_fixture.read_text()
marker = '@main enum NativeReportMailTests {'
assert text.count(marker) == 1, 'Report fixture declaration changed; review extraction'
fixture_text = text.split(marker)[0]
assert fixture_text.count('private final class ') == 3
fixture = out / 'ReportMailPreparationFixture.swift'
fixture.write_text(fixture_text.replace('private final class ', 'final class '))
sources += [fixture, n / 'NativeMailPreparationTests.swift']
tracked = list(dict.fromkeys(sources + manifests + [original_fixture, Path(__file__).resolve(),
    n / 'schema.json', n / 'schema.sql'] + sorted((repo / 'prisma/initial-data').glob('*.json'))))
for path in tracked:
    assert path.is_file(), f'Missing production input: {path}'
hashes = {str(p.relative_to(repo)): sha(p) for p in tracked}
binary, result = out / 'NativeMailPreparationTests', out / 'result.json'
result.unlink(missing_ok=True)
start = time.time()
proof = {'scope': 'Actual plugin/report workers, SQLite publication, owned SIGKILL, bounded recovery and stop/drain; synthetic credentials/transport only.',
    'sourceSHA256': hashes, 'swiftInputs': len(sources), 'compileExit': None, 'runExit': None,
    'realProviderCalls': 0, 'realKeychainCalls': 0}

def phase(command, log, timeout):
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    finally:
        # Any test-owned SIGSTOP/SIGKILL child is confined to this process group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

try:
    with (out / 'test.log').open('w') as log:
        proof['compileExit'] = phase(['swiftc', '-swift-version', '5', '-parse-as-library',
            '-target', 'arm64-apple-macosx13.0', '-O', '-whole-module-optimization',
            '-framework', 'AppKit', '-framework', 'Security', '-framework', 'LocalAuthentication',
            '-framework', 'PDFKit', '-lsqlite3', *map(str, sources), '-o', str(binary)], log, 900)
        if proof['compileExit'] == 0:
            proof['runExit'] = phase([str(binary), str(n), str(result)], log, 180)
    if result.exists():
        proof['result'] = json.loads(result.read_text())
    if binary.exists():
        proof.update(binarySHA256=sha(binary), binaryBytes=binary.stat().st_size)
finally:
    proof['seconds'] = round(time.time() - start, 3)
    proof['sourceStable'] = all(p.is_file() and sha(p) == hashes[str(p.relative_to(repo))] for p in tracked)
    (n / 'build/mail-preparation-lease-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in proof.items() if k != 'sourceSHA256'}, ensure_ascii=False))
assert proof['compileExit'] == 0 and proof['runExit'] == 0 and proof['sourceStable']
assert proof.get('result', {}).get('checks') == 94
