#!/usr/bin/env python3
"""Production-direct lock/ownership/readonly boundaries, isolated temporary data."""
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import time

n = Path(__file__).resolve().parent
repo = n.parents[1]
out = n / 'build/mail-preparation-boundary'
out.mkdir(parents=True, exist_ok=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
sources = [n / (s + '.swift') for s in ['NativeDatabase', 'InvoiceMail',
    'NativeTerminalMailBodyRecovery', 'NativeMailPreparationFiles', 'NativeMailPreparationBoundaryTests', 'MailReview']]
tracked = sources + [Path(__file__).resolve(), n / 'schema.json', n / 'schema.sql']
for path in tracked:
    assert path.is_file(), f'Missing production input: {path}'
hashes = {str(p.relative_to(repo)): sha(p) for p in tracked}
binary, result = out / 'NativeMailPreparationBoundaryTests', out / 'result.json'
result.unlink(missing_ok=True)
start = time.time()
proof = {'scope': 'Actual private process lock/SIGSTOP, finite busy return, unknown/symlink/hardlink preservation and readonly refusal; manual SQLite snapshot is not a restored-artifact validation claim.',
    'sourceSHA256': hashes, 'swiftInputs': len(sources), 'compileExit': None, 'runExit': None}

def phase(command, log, timeout):
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

try:
    with (out / 'test.log').open('w') as log:
        proof['compileExit'] = phase(['swiftc', '-swift-version', '5', '-parse-as-library',
            '-target', 'arm64-apple-macosx13.0', '-O', '-whole-module-optimization',
            '-lsqlite3', *map(str, sources), '-o', str(binary)], log, 300)
        if proof['compileExit'] == 0:
            proof['runExit'] = phase([str(binary), str(n), str(result)], log, 45)
    if result.exists():
        proof['result'] = json.loads(result.read_text())
    if binary.exists():
        proof.update(binarySHA256=sha(binary), binaryBytes=binary.stat().st_size)
finally:
    proof['seconds'] = round(time.time() - start, 3)
    proof['sourceStable'] = all(p.is_file() and sha(p) == hashes[str(p.relative_to(repo))] for p in tracked)
    (n / 'build/mail-preparation-boundary-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in proof.items() if k != 'sourceSHA256'}, ensure_ascii=False))
assert proof['compileExit'] == 0 and proof['runExit'] == 0 and proof['sourceStable']
assert proof.get('result', {}).get('checks') == 19
