#!/usr/bin/env python3
"""Installed original MIME + real native disk ingress/SQLite; no external I/O."""
from pathlib import Path
import datetime, hashlib, json, os, re, subprocess, time

N = Path(__file__).resolve().parent
R = N.parent.parent
B = N / 'build/mail-structure-proof' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(os.getpid()))
B.mkdir(parents=True)
h = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
started = time.monotonic()
phases = []
helpers = ['NativeMailHTMLText.swift', 'NativeMailMIMESpool.swift', 'NativeMailTextHTML.swift', 'NativeMailIMAPFile.swift']
pure = ['NativeMailTemporaryFiles.swift', 'NativeMail.swift', 'NativeMailMIME.swift', 'NativeMailIMAP.swift', 'NativeMailSpool.swift', 'NativeMailClient.swift'] + helpers + ['NativeMailStructureTests.swift', 'NativeMailStructureFileTests.swift', 'NativeMailStructureLargeTests.swift']
store = list(dict.fromkeys(re.findall(r'\$native_dir/([^"/]+\.swift)', (N / 'crm-email-test.sh').read_text())))
store = list(dict.fromkeys([x for x in store if not x.endswith('Tests.swift')] + helpers + ['NativeMailSyncTests.swift', 'NativeMailContentTests.swift', 'NativeMailStructureStoreTests.swift']))
files = list(dict.fromkeys([N / x for x in pure + store + ['NativeMailTransport.c', 'NativeMailTransport.h', 'CampaignHTML.c', 'CampaignHTML.h', 'CampaignHTMLEntities.inc', 'NativeMailParsing.h', 'schema.json', 'schema.sql', 'crm-email-test.sh', 'mail-structure-test.py', 'mail-structure-reference.cjs', 'mail-structure-consumer-reference.cjs', 'mail-structure-large-reference.cjs', 'mail-structure-compare.cjs', 'plugins-source-loader.cjs']] + [R / 'pnpm-lock.yaml']))
before = {str(p.relative_to(R)): h(p) for p in files}

def run(name, command):
    start = time.monotonic()
    p = subprocess.run(command, cwd=R, capture_output=True, text=True)
    (B / (name + '.log')).write_text(p.stdout + p.stderr)
    phases.append({'name': name, 'exit': p.returncode, 'seconds': round(time.monotonic() - start, 3)})
    if p.returncode:
        raise RuntimeError(name + ': ' + str(B / (name + '.log')))
    return p

run('source', ['node', str(N / 'mail-structure-reference.cjs'), str(B)])
run('consumer-source', ['node', str(N / 'mail-structure-consumer-reference.cjs'), str(B)])
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
run('mail-c', ['clang', '-O2', '-c', str(N / 'NativeMailTransport.c'), '-o', str(B / 'mail.o')])
run('html-c', ['clang', '-O2', '-I' + sdk + '/usr/include/libxml2', '-c', str(N / 'CampaignHTML.c'), '-o', str(B / 'html.o')])
flags = ['swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-whole-module-optimization', '-lcurl', '-lsqlite3', '-lxml2', '-import-objc-header', str(N / 'NativeMailParsing.h'), str(B / 'mail.o'), str(B / 'html.o')]
run('pure-compile', flags + [str(N / x) for x in pure] + ['-o', str(B / 'Tests')])
run('pure', [str(B / 'Tests'), str(B)])
run('comparison', ['node', str(N / 'mail-structure-compare.cjs'), str(B)])
comparison = json.loads((B / 'comparison.json').read_text())
assert comparison['cases'] == 57 and not comparison['failures']
assert len(comparison['semantic']) == 1 and len(comparison['intentional']) == 3
file_checks = json.loads((B / 'file-result.json').read_text())
assert file_checks == {'checks': 28, 'cleanup': True}
run('store-compile', flags + ['-framework', 'Security', '-framework', 'LocalAuthentication'] + [str(N / x) for x in store] + ['-o', str(B / 'StoreTests')])
run('store', [str(B / 'StoreTests'), str(N), str(B)])
store_result = json.loads((B / 'store-result.json').read_text())
assert store_result['newChecks'] == 25 and store_result['existingSyncChecks'] == 31 and store_result['existingContentChecks'] == 25
large = []
for kind, size in [('text', x) for x in [8388607, 8388608, 8388609]] + [('raw', x) for x in [33554431, 33554432, 33554433]]:
    peaks = {}
    for engine, command in [('source', ['node', str(N / 'mail-structure-large-reference.cjs'), str(B), kind, str(size)]), ('native', [str(B / 'Tests'), str(B), kind, str(size)])]:
        p = run('large-' + engine + '-' + kind + '-' + str(size), ['/usr/bin/time', '-l'] + command)
        peaks[engine] = int(re.search(r'(\d+)\s+maximum resident set size', p.stderr).group(1))
    original = json.loads((B / f'large-source-{kind}-{size}.json').read_text())
    native = json.loads((B / f'large-native-{kind}-{size}.json').read_text())
    assert original == native
    large.append({'kind': kind, 'size': size, 'equal': True, 'result': native, 'maximumRSSBytes': peaks})
source_inputs = {}
for name in ['reference.json', 'consumer-reference.json']:
    source_inputs.update(json.loads((B / name).read_text())['sourceHashes'])
assert all(h(R / k) == v for k, v in before.items())
assert all(h(R / k) == v for k, v in source_inputs.items())
proof = {'phases': phases, 'inputs': before, 'sourceInputs': source_inputs, 'inputsUnchanged': True, 'comparison': comparison, 'file': file_checks, 'store': store_result, 'large': large, 'output': str(B.relative_to(R)), 'elapsedSeconds': round(time.monotonic() - started, 2), 'normalData': False, 'networkCalls': 0, 'realKeychain': False, 'memoryScope': 'Single isolated message parsing processes; large six boundaries do not include DB storage. Native uses disk IMAP literals/MIME indexes, with one scalar result expanded. This is not idle App RSS or universal constant-memory proof.'}
(B / 'verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
(N / 'build/mail-structure-verification.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'cases': 57, 'fileChecks': 28, 'storeChecks': store_result, 'largeCases': 6, 'hashesStable': True, 'proof': str((B / 'verification.json').relative_to(R))}, ensure_ascii=False))
