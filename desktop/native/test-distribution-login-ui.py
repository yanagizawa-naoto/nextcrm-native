#!/usr/bin/env python3
"""Reuse the verified application module for the distribution login UI suites.

Run test-provider-review.py first. No app-wide rebuild or dependency download.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

NATIVE = Path(__file__).resolve().parent
ROOT = NATIVE.parent.parent


def main():
    latest = json.loads((NATIVE / 'build/provider-review-tests/latest.json').read_text())
    receipt = ROOT / latest['path']
    proof = json.loads(receipt.read_text())
    if not proof.get('complete') or not proof.get('snapshotUnchanged'):
        raise SystemExit('Run test-provider-review.py successfully before the login UI suites.')
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    for name, expected in proof['inputsSHA256'].items():
        if digest(ROOT / name) != expected:
            raise SystemExit('Application module is stale: ' + name)
    core = receipt.parent / 'core'
    library = core / 'libNextCRMR2Integrated.dylib'
    if digest(library) != proof['librarySHA256']:
        raise SystemExit('Application module changed since provider verification.')
    for runner in ['run-distribution-calendar-tests.py', 'google-mail-ui-test.py',
                   'chatgpt-ui-test.py']:
        subprocess.run([sys.executable, str(NATIVE / runner), '--core-dir', str(core),
                        '--module', 'NextCRMR2Integrated'], check=True, timeout=360)
    if digest(library) != proof['librarySHA256']:
        raise SystemExit('Application module changed during login UI verification.')
    print(json.dumps({'distributionLoginUI': 'passed', 'applicationRebuilt': False}))


if __name__ == '__main__':
    main()
